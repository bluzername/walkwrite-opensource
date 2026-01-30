import Foundation
import AVFoundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

/// Delegate protocol for ContinuousRecorder events
public protocol ContinuousRecorderDelegate: AnyObject {
    /// Called when a speech segment is detected and finalized
    func continuousRecorder(_ recorder: ContinuousRecorder, didDetectSpeechSegment segment: SpeechSegment)

    /// Called periodically with audio level for UI visualization
    func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateAudioLevel level: Float)

    /// Called when VAD state changes
    func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateVADState isSpeech: Bool, probability: Float)

    /// Called when recording statistics are updated
    func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateStats stats: AudioSegmentManager.RecordingStats)

    /// Called when an error occurs
    func continuousRecorder(_ recorder: ContinuousRecorder, didEncounterError error: Error)
}

/// Default implementations for optional delegate methods
public extension ContinuousRecorderDelegate {
    func continuousRecorder(_ recorder: ContinuousRecorder, didDetectSpeechSegment segment: SpeechSegment) {}
    func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateAudioLevel level: Float) {}
    func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateVADState isSpeech: Bool, probability: Float) {}
    func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateStats stats: AudioSegmentManager.RecordingStats) {}
    func continuousRecorder(_ recorder: ContinuousRecorder, didEncounterError error: Error) {}
}

/// Continuous recorder that uses AVAudioEngine with VAD-based filtering
public final class ContinuousRecorder: @unchecked Sendable {

    // MARK: - Types

    public enum State: Sendable {
        case idle
        case recording
        case paused
        case stopping
    }

    public enum RecorderError: Error, LocalizedError {
        case audioEngineSetupFailed(String)
        case permissionDenied
        case alreadyRecording
        case notRecording
        case formatConversionFailed

        public var errorDescription: String? {
            switch self {
            case .audioEngineSetupFailed(let reason):
                return "Audio engine setup failed: \(reason)"
            case .permissionDenied:
                return "Microphone permission denied"
            case .alreadyRecording:
                return "Recording is already in progress"
            case .notRecording:
                return "No recording in progress"
            case .formatConversionFailed:
                return "Failed to convert audio format"
            }
        }
    }

    // MARK: - Properties

    public weak var delegate: ContinuousRecorderDelegate?

    public private(set) var state: State = .idle
    public private(set) var vadConfiguration: VADConfiguration

    private let audioEngine = AVAudioEngine()
    private let vad: VADProtocol
    private let vadStateMachine: VADStateMachine
    private let segmentManager: AudioSegmentManager

    private let sampleRate: Double = 16000.0
    private let targetFormat: AVAudioFormat

    private var recordingStartTime: Date?
    private var pausedDuration: TimeInterval = 0
    private var lastPauseTime: Date?

    private let lock = NSLock()

    // For keeping full audio (if needed for fallback)
    private var keepFullAudio: Bool = false
    private var fullAudioBuffer: [Float] = []
    private var fullAudioURL: URL?

    // Stats update timer
    private var statsTimer: Timer?

    // MARK: - Computed Properties

    public var elapsedTime: TimeInterval {
        guard let startTime = recordingStartTime else { return 0 }
        let baseTime = Date().timeIntervalSince(startTime)
        return baseTime - pausedDuration
    }

    public var speechDuration: TimeInterval {
        segmentManager.getStats().speechDuration
    }

    // MARK: - Initialization

    public init(vadConfiguration: VADConfiguration = .default, keepFullAudio: Bool = false) {
        self.vadConfiguration = vadConfiguration
        self.keepFullAudio = keepFullAudio
        self.vad = VADFactory.createDefault(configuration: vadConfiguration)
        self.vadStateMachine = VADStateMachine(configuration: vadConfiguration)
        self.segmentManager = AudioSegmentManager(sampleRate: sampleRate)

        // Create target format (16kHz, mono, Float32)
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Public Methods

    /// Request microphone permission
    @discardableResult
    public func requestPermission() async -> Bool {
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Start continuous recording with VAD
    public func startRecording() throws {
        lock.lock()
        defer { lock.unlock() }

        guard state == .idle else {
            throw RecorderError.alreadyRecording
        }

        // Setup audio session
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        #endif

        // Reset state
        vad.reset()
        vadStateMachine.reset()
        segmentManager.startSession()
        fullAudioBuffer = []
        pausedDuration = 0
        lastPauseTime = nil

        // Create output file for full audio if needed
        if keepFullAudio {
            let filename = ISO8601DateFormatter().string(from: .now) + "_full.wav"
            fullAudioURL = AppFolders.notes.appendingPathComponent(filename)
        }

        // Setup audio engine
        try setupAudioEngine()

        // Start the engine
        try audioEngine.start()

        recordingStartTime = Date()
        state = .recording

        // Start stats timer
        startStatsTimer()

        NSLog("ContinuousRecorder: Started recording")
    }

    /// Pause recording
    public func pauseRecording() {
        lock.lock()
        defer { lock.unlock() }

        guard state == .recording else { return }

        audioEngine.pause()
        lastPauseTime = Date()
        state = .paused

        stopStatsTimer()

        NSLog("ContinuousRecorder: Paused recording")
    }

    /// Resume recording
    public func resumeRecording() throws {
        lock.lock()
        defer { lock.unlock() }

        guard state == .paused else { return }

        if let pauseTime = lastPauseTime {
            pausedDuration += Date().timeIntervalSince(pauseTime)
        }
        lastPauseTime = nil

        try audioEngine.start()
        state = .recording

        startStatsTimer()

        NSLog("ContinuousRecorder: Resumed recording")
    }

    /// Stop recording and export speech-only audio
    /// - Returns: URL to the exported WAV file containing only speech
    public func stopRecording() throws -> URL {
        lock.lock()

        guard state == .recording || state == .paused else {
            lock.unlock()
            throw RecorderError.notRecording
        }

        state = .stopping

        // Stop the audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        stopStatsTimer()

        // Finalize any in-progress segment
        let currentTime = elapsedTime
        if let finalSegment = vadStateMachine.finalize(at: currentTime) {
            segmentManager.extractSegment(finalSegment)
            lock.unlock()
            delegate?.continuousRecorder(self, didDetectSpeechSegment: finalSegment)
            lock.lock()
        }

        // Export speech-only audio
        let filename = ISO8601DateFormatter().string(from: recordingStartTime ?? Date()) + ".wav"
        let outputURL = AppFolders.notes.appendingPathComponent(filename)

        lock.unlock()

        do {
            try segmentManager.exportToWAV(url: outputURL)
        } catch AudioSegmentError.noSpeechDetected {
            // If no speech was detected, export the full audio if we have it
            if keepFullAudio && !fullAudioBuffer.isEmpty {
                try exportFullAudio(to: outputURL)
            } else {
                // Create an empty/minimal WAV file
                try createEmptyWAV(at: outputURL)
            }
        }

        lock.lock()
        state = .idle
        recordingStartTime = nil
        lock.unlock()

        NSLog("ContinuousRecorder: Stopped recording. Output: \(outputURL.path)")

        return outputURL
    }

    /// Get current recording statistics
    public func getStats() -> AudioSegmentManager.RecordingStats {
        return segmentManager.getStats()
    }

    /// Get time mappings for diarization
    public func getTimeMappings() -> [AudioSegmentManager.TimeMapping] {
        return segmentManager.getTimeMappings()
    }

    /// Update VAD configuration
    public func updateVADConfiguration(_ config: VADConfiguration) {
        lock.lock()
        vadConfiguration = config
        vad.updateConfiguration(config)
        lock.unlock()
    }

    // MARK: - Private Methods

    private func setupAudioEngine() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Check input format
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.audioEngineSetupFailed("Invalid input format")
        }

        // Create format converter if needed
        let converter: AVAudioConverter?
        if inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1 {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            converter = nil
        }

        // Calculate buffer size for ~32ms chunks at input sample rate
        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate * 0.032)

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer, time: time, converter: converter)
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, converter: AVAudioConverter?) {
        lock.lock()
        guard state == .recording else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Convert to target format if needed
        let samples: [Float]
        if let converter = converter {
            guard let convertedBuffer = convertBuffer(buffer, using: converter) else {
                delegate?.continuousRecorder(self, didEncounterError: RecorderError.formatConversionFailed)
                return
            }
            samples = extractSamples(from: convertedBuffer)
        } else {
            samples = extractSamples(from: buffer)
        }

        guard !samples.isEmpty else { return }

        // Calculate current timestamp
        let timestamp = elapsedTime

        // Keep full audio if enabled
        if keepFullAudio {
            lock.lock()
            fullAudioBuffer.append(contentsOf: samples)
            lock.unlock()
        }

        // Add samples to segment manager
        segmentManager.addSamples(samples, timestamp: timestamp)

        // Process through VAD
        let vadFrame = vad.processFrame(samples, timestamp: timestamp)

        // Update delegate with audio level and VAD state
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.continuousRecorder(self, didUpdateAudioLevel: vadFrame.speechProbability)
            self.delegate?.continuousRecorder(self, didUpdateVADState: vadFrame.isSpeech, probability: vadFrame.speechProbability)
        }

        // Process through state machine
        if let completedSegment = vadStateMachine.processFrame(vadFrame) {
            // Extract and store the segment
            segmentManager.extractSegment(completedSegment)

            // Notify delegate
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.continuousRecorder(self, didDetectSpeechSegment: completedSegment)
            }
        }
    }

    private func convertBuffer(_ inputBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            NSLog("ContinuousRecorder: Conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }

    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let floatChannelData = buffer.floatChannelData else { return [] }
        let channelData = floatChannelData[0]
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }

    private func startStatsTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let stats = self.segmentManager.getStats()
                self.delegate?.continuousRecorder(self, didUpdateStats: stats)
            }
        }
    }

    private func stopStatsTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.statsTimer?.invalidate()
            self?.statsTimer = nil
        }
    }

    private func exportFullAudio(to url: URL) throws {
        guard !fullAudioBuffer.isEmpty else {
            throw AudioSegmentError.noSpeechDetected
        }

        // Convert Float to Int16
        var int16Samples = [Int16](repeating: 0, count: fullAudioBuffer.count)
        for (index, sample) in fullAudioBuffer.enumerated() {
            let clamped = max(-1.0, min(1.0, sample))
            int16Samples[index] = Int16(clamped * Float(Int16.max))
        }

        // Create WAV file
        var header = createWAVHeader(dataSize: UInt32(int16Samples.count * 2))
        var data = Data()
        data.append(Data(bytes: &header, count: MemoryLayout.size(ofValue: header)))
        int16Samples.withUnsafeBufferPointer { buffer in
            data.append(Data(buffer: buffer.withMemoryRebound(to: UInt8.self) { $0 }))
        }

        try data.write(to: url)
    }

    private func createEmptyWAV(at url: URL) throws {
        // Create a minimal WAV file with silence
        let silenceSamples: [Int16] = [Int16](repeating: 0, count: Int(sampleRate))  // 1 second of silence
        var header = createWAVHeader(dataSize: UInt32(silenceSamples.count * 2))
        var data = Data()
        data.append(Data(bytes: &header, count: MemoryLayout.size(ofValue: header)))
        silenceSamples.withUnsafeBufferPointer { buffer in
            data.append(Data(buffer: buffer.withMemoryRebound(to: UInt8.self) { $0 }))
        }
        try data.write(to: url)
    }

    private func createWAVHeader(dataSize: UInt32) -> WAVHeaderStruct {
        return WAVHeaderStruct(
            sampleRate: UInt32(sampleRate),
            numChannels: 1,
            bitsPerSample: 16,
            dataSize: dataSize
        )
    }
}

// MARK: - WAV Header

private struct WAVHeaderStruct {
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
