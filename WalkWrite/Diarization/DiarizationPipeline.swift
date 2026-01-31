import Foundation
import AVFoundation

// MARK: - Diarization Result

/// Complete result of the diarization process
public struct DiarizationResult: Codable, Sendable {
    /// Words with speaker assignments
    public let diarizedWords: [DiarizedWord]

    /// Speaker segments (time ranges attributed to each speaker)
    public let speakerSegments: [SpeakerSegment]

    /// Statistics for each speaker
    public let speakerStats: [SpeakerStats]

    /// Total number of unique speakers detected
    public let speakerCount: Int

    /// The identified user's speaker ID (most consistent speaker)
    public let identifiedUserId: Int?

    public init(
        diarizedWords: [DiarizedWord],
        speakerSegments: [SpeakerSegment],
        speakerStats: [SpeakerStats],
        speakerCount: Int,
        identifiedUserId: Int? = nil
    ) {
        self.diarizedWords = diarizedWords
        self.speakerSegments = speakerSegments
        self.speakerStats = speakerStats
        self.speakerCount = speakerCount
        self.identifiedUserId = identifiedUserId
    }

    /// Create an empty result (no speakers detected)
    public static let empty = DiarizationResult(
        diarizedWords: [],
        speakerSegments: [],
        speakerStats: [],
        speakerCount: 0
    )
}

// MARK: - Diarization Error

public enum DiarizationError: Error, LocalizedError {
    case audioLoadFailed(String)
    case insufficientAudio
    case embeddingExtractionFailed
    case clusteringFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .audioLoadFailed(let reason):
            return "Failed to load audio: \(reason)"
        case .insufficientAudio:
            return "Audio too short for diarization"
        case .embeddingExtractionFailed:
            return "Failed to extract speaker embeddings"
        case .clusteringFailed:
            return "Failed to cluster speakers"
        case .cancelled:
            return "Diarization was cancelled"
        }
    }
}

// MARK: - Diarization Pipeline

/// Orchestrates the complete speaker diarization process
///
/// Pipeline stages:
/// 1. Load and preprocess audio
/// 2. Extract speaker embeddings from overlapping windows
/// 3. Cluster embeddings to identify unique speakers
/// 4. Assign speakers to transcribed words
/// 5. Calculate speaker statistics
/// 6. Optionally identify the "user" (most consistent speaker)
public actor DiarizationPipeline {

    // MARK: - Properties

    private let embeddingEngine: SpeakerEmbeddingProtocol
    private let clusterer: SpeakerClusterer
    private let assigner: WordSpeakerAssigner
    private let statsCalculator: SpeakerStatsCalculator

    private var isCancelled = false

    // MARK: - Initialization

    public init(
        embeddingEngine: SpeakerEmbeddingProtocol? = nil,
        clusterer: SpeakerClusterer? = nil,
        assigner: WordSpeakerAssigner? = nil,
        statsCalculator: SpeakerStatsCalculator? = nil
    ) {
        self.embeddingEngine = embeddingEngine ?? SpeakerEmbeddingFactory.createDefault()
        self.clusterer = clusterer ?? SpeakerClusterer()
        self.assigner = assigner ?? WordSpeakerAssigner()
        self.statsCalculator = statsCalculator ?? SpeakerStatsCalculator()
    }

    // MARK: - Public API

    /// Run diarization on audio file with transcription
    /// - Parameters:
    ///   - audioURL: URL to the audio file
    ///   - words: Transcribed words with timestamps
    ///   - config: Diarization configuration
    ///   - progressHandler: Optional callback for progress updates
    /// - Returns: Diarization result with speaker assignments
    public func diarize(
        audioURL: URL,
        words: [WordStamp],
        config: DiarizationConfig = .default,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> DiarizationResult {
        isCancelled = false

        // Stage 1: Load audio (10%)
        progressHandler?(0.1)
        let samples = try loadAudio(from: audioURL, sampleRate: config.sampleRate)

        guard !isCancelled else { throw DiarizationError.cancelled }

        // Check minimum audio length
        let duration = Double(samples.count) / config.sampleRate
        guard duration >= config.minSegmentDuration else {
            throw DiarizationError.insufficientAudio
        }

        // Stage 2: Extract embeddings (40%)
        progressHandler?(0.2)
        let embeddings = extractEmbeddings(
            from: samples,
            sampleRate: config.sampleRate,
            config: config
        )
        progressHandler?(0.5)

        guard !isCancelled else { throw DiarizationError.cancelled }
        guard !embeddings.isEmpty else {
            throw DiarizationError.embeddingExtractionFailed
        }

        // Stage 3: Cluster speakers (20%)
        progressHandler?(0.6)
        var speakerSegments = clusterer.cluster(embeddings: embeddings, config: config)
        progressHandler?(0.7)

        guard !isCancelled else { throw DiarizationError.cancelled }

        // Stage 4: Refine segments
        speakerSegments = clusterer.refineSegments(speakerSegments, minDuration: config.minSegmentDuration)

        // Stage 5: Assign speakers to words (10%)
        progressHandler?(0.8)
        var diarizedWords = assigner.assign(words: words, speakerSegments: speakerSegments)

        // Smooth and relabel
        diarizedWords = assigner.smoothAssignments(diarizedWords)
        let (relabeledWords, _) = assigner.relabelSpeakers(diarizedWords)
        diarizedWords = relabeledWords

        guard !isCancelled else { throw DiarizationError.cancelled }

        // Stage 6: Calculate statistics (10%)
        progressHandler?(0.9)
        let stats = statsCalculator.calculateStats(words: diarizedWords, segments: speakerSegments)
        let speakerCount = Set(diarizedWords.map { $0.speakerId }).count

        // Identify user (speaker with most speaking time)
        let identifiedUserId = stats.first?.speakerId

        progressHandler?(1.0)

        return DiarizationResult(
            diarizedWords: diarizedWords,
            speakerSegments: speakerSegments,
            speakerStats: stats,
            speakerCount: speakerCount,
            identifiedUserId: identifiedUserId
        )
    }

    /// Run diarization with VAD time mappings
    public func diarizeWithTimeMapping(
        audioURL: URL,
        words: [WordStamp],
        timeMappings: [AudioSegmentManager.TimeMapping],
        config: DiarizationConfig = .default,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> DiarizationResult {
        isCancelled = false

        // Load audio
        progressHandler?(0.1)
        let samples = try loadAudio(from: audioURL, sampleRate: config.sampleRate)

        guard !isCancelled else { throw DiarizationError.cancelled }

        let duration = Double(samples.count) / config.sampleRate
        guard duration >= config.minSegmentDuration else {
            throw DiarizationError.insufficientAudio
        }

        // Extract embeddings
        progressHandler?(0.2)
        let embeddings = extractEmbeddings(
            from: samples,
            sampleRate: config.sampleRate,
            config: config
        )
        progressHandler?(0.5)

        guard !isCancelled else { throw DiarizationError.cancelled }
        guard !embeddings.isEmpty else {
            throw DiarizationError.embeddingExtractionFailed
        }

        // Cluster
        progressHandler?(0.6)
        var speakerSegments = clusterer.cluster(embeddings: embeddings, config: config)
        speakerSegments = clusterer.refineSegments(speakerSegments, minDuration: config.minSegmentDuration)
        progressHandler?(0.7)

        guard !isCancelled else { throw DiarizationError.cancelled }

        // Assign with time mapping
        progressHandler?(0.8)
        var diarizedWords = assigner.assignWithTimeMapping(
            words: words,
            speakerSegments: speakerSegments,
            timeMappings: timeMappings
        )

        diarizedWords = assigner.smoothAssignments(diarizedWords)
        let (relabeledWords, _) = assigner.relabelSpeakers(diarizedWords)
        diarizedWords = relabeledWords

        guard !isCancelled else { throw DiarizationError.cancelled }

        // Statistics
        progressHandler?(0.9)
        let stats = statsCalculator.calculateStats(words: diarizedWords, segments: speakerSegments)
        let speakerCount = Set(diarizedWords.map { $0.speakerId }).count
        let identifiedUserId = stats.first?.speakerId

        progressHandler?(1.0)

        return DiarizationResult(
            diarizedWords: diarizedWords,
            speakerSegments: speakerSegments,
            speakerStats: stats,
            speakerCount: speakerCount,
            identifiedUserId: identifiedUserId
        )
    }

    /// Cancel ongoing diarization
    public func cancel() {
        isCancelled = true
    }

    // MARK: - Private Methods

    /// Load audio file and convert to samples
    private func loadAudio(from url: URL, sampleRate: Double) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DiarizationError.audioLoadFailed(error.localizedDescription)
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Calculate output frame count
        let ratio = sampleRate / file.fileFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(file.length) * ratio)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outputFrameCount) else {
            throw DiarizationError.audioLoadFailed("Failed to create audio buffer")
        }

        // Read with format conversion
        if file.fileFormat.sampleRate == sampleRate && file.fileFormat.channelCount == 1 {
            // Direct read
            do {
                try file.read(into: buffer)
            } catch {
                throw DiarizationError.audioLoadFailed(error.localizedDescription)
            }
        } else {
            // Need conversion
            let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )!

            do {
                try file.read(into: sourceBuffer)
            } catch {
                throw DiarizationError.audioLoadFailed(error.localizedDescription)
            }

            // Convert
            guard let converter = AVAudioConverter(from: sourceBuffer.format, to: format) else {
                throw DiarizationError.audioLoadFailed("Failed to create audio converter")
            }

            var error: NSError?
            converter.convert(to: buffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if let error = error {
                throw DiarizationError.audioLoadFailed(error.localizedDescription)
            }
        }

        // Extract samples
        guard let channelData = buffer.floatChannelData else {
            throw DiarizationError.audioLoadFailed("No channel data")
        }

        let samples = Array(UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        ))

        return samples
    }

    /// Extract speaker embeddings from audio using sliding windows
    private func extractEmbeddings(
        from samples: [Float],
        sampleRate: Double,
        config: DiarizationConfig
    ) -> [SpeakerEmbedding] {
        let windowSamples = Int(config.windowSize * sampleRate)
        let stepSamples = Int(config.windowStep * sampleRate)

        guard samples.count >= windowSamples else {
            // Audio too short - extract single embedding
            let features = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)
            return [SpeakerEmbedding(
                features: features,
                timestamp: 0,
                duration: Double(samples.count) / sampleRate
            )]
        }

        var segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)] = []
        var offset = 0

        while offset + windowSamples <= samples.count {
            let windowEnd = min(offset + windowSamples, samples.count)
            let windowSamples = Array(samples[offset..<windowEnd])
            let timestamp = Double(offset) / sampleRate
            let duration = Double(windowEnd - offset) / sampleRate

            segments.append((windowSamples, timestamp, duration))
            offset += stepSamples
        }

        // Handle remaining samples if significant
        let remaining = samples.count - offset
        if remaining >= windowSamples / 2 {
            let windowSamples = Array(samples[offset...])
            let timestamp = Double(offset) / sampleRate
            let duration = Double(remaining) / sampleRate
            segments.append((windowSamples, timestamp, duration))
        }

        return embeddingEngine.batchExtract(segments: segments, sampleRate: sampleRate)
    }
}

// MARK: - Shared Instance

extension DiarizationPipeline {
    /// Shared diarization pipeline instance
    public static let shared = DiarizationPipeline()
}

// MARK: - Transcript Formatting

/// Utilities for formatting diarized transcripts
public enum DiarizedTranscriptFormatter {

    /// Format transcript with speaker labels
    public static func format(
        words: [DiarizedWord],
        userSpeakerId: Int? = nil
    ) -> String {
        guard !words.isEmpty else { return "" }

        var result = ""
        var currentSpeakerId = -1

        for word in words {
            if word.speakerId != currentSpeakerId {
                if !result.isEmpty {
                    result += "\n"
                }

                let label: String
                if let userId = userSpeakerId, word.speakerId == userId {
                    label = "User"
                } else {
                    label = "Speaker \(word.speakerId + 1)"
                }

                result += "[\(label)]: "
                currentSpeakerId = word.speakerId
            }

            // Add word with proper spacing
            if result.last == " " || result.last == "[" || result.last == ":" {
                result += word.word
            } else {
                // Check if word needs space before it
                let needsSpace = !isPunctuation(word.word)
                if needsSpace && !result.isEmpty && result.last != " " && result.last != "\n" {
                    result += " "
                }
                result += word.word
            }
        }

        return result
    }

    /// Format as conversation turns
    public static func formatAsTurns(
        words: [DiarizedWord],
        userSpeakerId: Int? = nil
    ) -> [(speaker: String, text: String)] {
        guard !words.isEmpty else { return [] }

        var turns: [(speaker: String, text: String)] = []
        var currentSpeakerId = words[0].speakerId
        var currentText = ""

        for word in words {
            if word.speakerId != currentSpeakerId {
                // Save current turn
                if !currentText.isEmpty {
                    let label: String
                    if let userId = userSpeakerId, currentSpeakerId == userId {
                        label = "User"
                    } else {
                        label = "Speaker \(currentSpeakerId + 1)"
                    }
                    turns.append((label, currentText.trimmingCharacters(in: .whitespaces)))
                }

                currentSpeakerId = word.speakerId
                currentText = word.word
            } else {
                // Continue current turn
                if !isPunctuation(word.word) && !currentText.isEmpty {
                    currentText += " "
                }
                currentText += word.word
            }
        }

        // Add final turn
        if !currentText.isEmpty {
            let label: String
            if let userId = userSpeakerId, currentSpeakerId == userId {
                label = "User"
            } else {
                label = "Speaker \(currentSpeakerId + 1)"
            }
            turns.append((label, currentText.trimmingCharacters(in: .whitespaces)))
        }

        return turns
    }

    private static func isPunctuation(_ word: String) -> Bool {
        let punctuation = CharacterSet.punctuationCharacters
        return word.unicodeScalars.allSatisfy { punctuation.contains($0) }
    }
}
