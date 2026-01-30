import Foundation
import AVFoundation
import Accelerate

/// Manages audio segments detected by VAD, including buffering and export
public final class AudioSegmentManager: @unchecked Sendable {

    // MARK: - Types

    /// Represents a chunk of audio data with timing information
    public struct AudioChunk: Sendable {
        public let samples: [Float]
        public let startTime: TimeInterval
        public let endTime: TimeInterval

        public var duration: TimeInterval {
            endTime - startTime
        }

        public init(samples: [Float], startTime: TimeInterval, endTime: TimeInterval) {
            self.samples = samples
            self.startTime = startTime
            self.endTime = endTime
        }
    }

    /// Mapping between concatenated audio time and original recording time
    public struct TimeMapping: Codable, Sendable {
        public let concatenatedRange: ClosedRange<TimeInterval>
        public let originalRange: ClosedRange<TimeInterval>

        public init(concatenatedRange: ClosedRange<TimeInterval>, originalRange: ClosedRange<TimeInterval>) {
            self.concatenatedRange = concatenatedRange
            self.originalRange = originalRange
        }
    }

    /// Statistics about the recording session
    public struct RecordingStats: Sendable {
        public let totalRecordingDuration: TimeInterval
        public let speechDuration: TimeInterval
        public let silenceDuration: TimeInterval
        public let segmentCount: Int

        public var speechPercentage: Double {
            guard totalRecordingDuration > 0 else { return 0 }
            return speechDuration / totalRecordingDuration * 100
        }

        public init(totalRecordingDuration: TimeInterval, speechDuration: TimeInterval, silenceDuration: TimeInterval, segmentCount: Int) {
            self.totalRecordingDuration = totalRecordingDuration
            self.speechDuration = speechDuration
            self.silenceDuration = silenceDuration
            self.segmentCount = segmentCount
        }
    }

    // MARK: - Properties

    private let sampleRate: Double
    private let lock = NSLock()

    // Circular buffer for recent audio (keeps last N seconds for segment recovery)
    private var audioBuffer: [Float] = []
    private var bufferStartTime: TimeInterval = 0
    private let maxBufferDuration: TimeInterval = 5.0  // Keep 5 seconds of history

    // Collected speech segments
    private var speechSegments: [(segment: SpeechSegment, samples: [Float])] = []

    // Time tracking
    private var recordingStartTime: TimeInterval = 0
    private var currentTime: TimeInterval = 0
    private var totalSpeechDuration: TimeInterval = 0

    // Time mappings for diarization
    private var timeMappings: [TimeMapping] = []

    // MARK: - Computed Properties

    private var maxBufferSamples: Int {
        Int(maxBufferDuration * sampleRate)
    }

    // MARK: - Initialization

    public init(sampleRate: Double = 16000.0) {
        self.sampleRate = sampleRate
    }

    // MARK: - Public Methods

    /// Start a new recording session
    public func startSession() {
        lock.lock()
        defer { lock.unlock() }

        audioBuffer = []
        bufferStartTime = 0
        speechSegments = []
        recordingStartTime = 0
        currentTime = 0
        totalSpeechDuration = 0
        timeMappings = []
    }

    /// Add audio samples to the buffer
    /// - Parameters:
    ///   - samples: Audio samples to add
    ///   - timestamp: Current timestamp in the recording
    public func addSamples(_ samples: [Float], timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        // Update current time
        currentTime = timestamp + TimeInterval(samples.count) / sampleRate

        // Add to circular buffer
        audioBuffer.append(contentsOf: samples)

        // Trim buffer if it exceeds max duration
        if audioBuffer.count > maxBufferSamples {
            let samplesToRemove = audioBuffer.count - maxBufferSamples
            audioBuffer.removeFirst(samplesToRemove)
            bufferStartTime += TimeInterval(samplesToRemove) / sampleRate
        }
    }

    /// Extract and store a speech segment
    /// - Parameter segment: The speech segment to extract
    /// - Returns: True if extraction was successful
    @discardableResult
    public func extractSegment(_ segment: SpeechSegment) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        // Calculate sample indices
        let segmentStartSample = Int((segment.startTime - bufferStartTime) * sampleRate)
        let segmentEndSample = Int((segment.endTime - bufferStartTime) * sampleRate)

        // Check if segment is within buffer
        guard segmentStartSample >= 0 else {
            NSLog("AudioSegmentManager: Segment start \(segment.startTime) is before buffer start \(bufferStartTime)")
            return false
        }

        guard segmentEndSample <= audioBuffer.count else {
            NSLog("AudioSegmentManager: Segment end is beyond buffer")
            return false
        }

        // Extract samples
        let samples = Array(audioBuffer[segmentStartSample..<segmentEndSample])

        // Store segment with its samples
        speechSegments.append((segment: segment, samples: samples))
        totalSpeechDuration += segment.duration

        // Create time mapping
        let concatenatedStart = timeMappings.last?.concatenatedRange.upperBound ?? 0
        let concatenatedEnd = concatenatedStart + segment.duration
        let mapping = TimeMapping(
            concatenatedRange: concatenatedStart...concatenatedEnd,
            originalRange: segment.startTime...segment.endTime
        )
        timeMappings.append(mapping)

        return true
    }

    /// Get current recording statistics
    public func getStats() -> RecordingStats {
        lock.lock()
        defer { lock.unlock() }

        let totalDuration = currentTime - recordingStartTime
        return RecordingStats(
            totalRecordingDuration: totalDuration,
            speechDuration: totalSpeechDuration,
            silenceDuration: totalDuration - totalSpeechDuration,
            segmentCount: speechSegments.count
        )
    }

    /// Get all collected speech segments
    public func getSpeechSegments() -> [SpeechSegment] {
        lock.lock()
        defer { lock.unlock() }
        return speechSegments.map { $0.segment }
    }

    /// Get time mappings for diarization
    public func getTimeMappings() -> [TimeMapping] {
        lock.lock()
        defer { lock.unlock() }
        return timeMappings
    }

    /// Get concatenated speech samples
    public func getConcatenatedSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        var result: [Float] = []
        for (_, samples) in speechSegments {
            result.append(contentsOf: samples)
        }
        return result
    }

    /// Export concatenated audio to a WAV file
    /// - Parameter url: Destination URL for the WAV file
    /// - Throws: Error if export fails
    public func exportToWAV(url: URL) throws {
        let samples = getConcatenatedSamples()
        guard !samples.isEmpty else {
            throw AudioSegmentError.noSpeechDetected
        }

        try writeWAVFile(samples: samples, to: url, sampleRate: sampleRate)
    }

    /// Convert original recording timestamp to concatenated audio timestamp
    /// - Parameter originalTime: Time in the original recording
    /// - Returns: Corresponding time in concatenated audio, or nil if not in speech
    public func originalToConcatenatedTime(_ originalTime: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }

        for mapping in timeMappings {
            if mapping.originalRange.contains(originalTime) {
                let offset = originalTime - mapping.originalRange.lowerBound
                return mapping.concatenatedRange.lowerBound + offset
            }
        }
        return nil
    }

    /// Convert concatenated audio timestamp to original recording timestamp
    /// - Parameter concatenatedTime: Time in the concatenated audio
    /// - Returns: Corresponding time in original recording
    public func concatenatedToOriginalTime(_ concatenatedTime: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }

        for mapping in timeMappings {
            if mapping.concatenatedRange.contains(concatenatedTime) {
                let offset = concatenatedTime - mapping.concatenatedRange.lowerBound
                return mapping.originalRange.lowerBound + offset
            }
        }
        return nil
    }

    // MARK: - Private Methods

    private func writeWAVFile(samples: [Float], to url: URL, sampleRate: Double) throws {
        // Convert Float to Int16
        var int16Samples = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            // Clamp to [-1, 1] and convert to Int16
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples[index] = Int16(clamped * Float(Int16.max))
        }

        // Create WAV header
        var header = WAVHeader(
            sampleRate: UInt32(sampleRate),
            numChannels: 1,
            bitsPerSample: 16,
            dataSize: UInt32(int16Samples.count * 2)
        )

        // Write file
        var data = Data()
        data.append(Data(bytes: &header, count: MemoryLayout<WAVHeader>.size))
        int16Samples.withUnsafeBufferPointer { buffer in
            data.append(Data(buffer: buffer.withMemoryRebound(to: UInt8.self) { $0 }))
        }

        try data.write(to: url)
    }
}

// MARK: - WAV Header

private struct WAVHeader {
    var riffChunkId: (UInt8, UInt8, UInt8, UInt8) = (0x52, 0x49, 0x46, 0x46)  // "RIFF"
    var riffChunkSize: UInt32 = 0
    var waveFormat: (UInt8, UInt8, UInt8, UInt8) = (0x57, 0x41, 0x56, 0x45)   // "WAVE"
    var fmtChunkId: (UInt8, UInt8, UInt8, UInt8) = (0x66, 0x6D, 0x74, 0x20)   // "fmt "
    var fmtChunkSize: UInt32 = 16
    var audioFormat: UInt16 = 1  // PCM
    var numChannels: UInt16 = 1
    var sampleRate: UInt32 = 16000
    var byteRate: UInt32 = 32000
    var blockAlign: UInt16 = 2
    var bitsPerSample: UInt16 = 16
    var dataChunkId: (UInt8, UInt8, UInt8, UInt8) = (0x64, 0x61, 0x74, 0x61)  // "data"
    var dataChunkSize: UInt32 = 0

    init(sampleRate: UInt32, numChannels: UInt16, bitsPerSample: UInt16, dataSize: UInt32) {
        self.sampleRate = sampleRate
        self.numChannels = numChannels
        self.bitsPerSample = bitsPerSample
        self.byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        self.blockAlign = numChannels * (bitsPerSample / 8)
        self.dataChunkSize = dataSize
        self.riffChunkSize = 36 + dataSize
    }
}

// MARK: - Errors

public enum AudioSegmentError: Error, LocalizedError {
    case noSpeechDetected
    case bufferUnderrun
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSpeechDetected:
            return "No speech was detected in the recording"
        case .bufferUnderrun:
            return "Audio buffer underrun - segment data lost"
        case .exportFailed(let reason):
            return "Failed to export audio: \(reason)"
        }
    }
}
