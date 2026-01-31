import XCTest
@testable import WalkWrite

/// Integration tests that verify Phase 1 (VAD) and Phase 2 (Diarization) work together
final class Phase1And2IntegrationTests: XCTestCase {

    // MARK: - Properties

    var vad: EnergyBasedVAD!
    var vadStateMachine: VADStateMachine!
    var segmentManager: AudioSegmentManager!
    var embeddingEngine: AcousticSpeakerEmbedding!
    var clusterer: SpeakerClusterer!
    var assigner: WordSpeakerAssigner!

    let sampleRate: Double = 16000.0
    let frameDuration: TimeInterval = 0.032

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        let config = VADConfiguration.default
        vad = EnergyBasedVAD(configuration: config)
        vadStateMachine = VADStateMachine(configuration: config)
        segmentManager = AudioSegmentManager(sampleRate: sampleRate)
        segmentManager.startSession()
        embeddingEngine = AcousticSpeakerEmbedding()
        clusterer = SpeakerClusterer()
        assigner = WordSpeakerAssigner()
    }

    override func tearDown() {
        vad = nil
        vadStateMachine = nil
        segmentManager = nil
        embeddingEngine = nil
        clusterer = nil
        assigner = nil
        super.tearDown()
    }

    // MARK: - Audio Generation Helpers

    /// Generate silence
    private func generateSilence(duration: TimeInterval) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { _ in Float.random(in: -0.0001...0.0001) }
    }

    /// Generate voice-like audio for a specific speaker
    private func generateSpeaker(
        fundamentalFreq: Float,
        duration: TimeInterval,
        amplitude: Float = 0.3
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { i in
            let t = Float(i) / Float(sampleRate)
            let f1 = amplitude * sin(2 * .pi * fundamentalFreq * t)
            let f2 = (amplitude * 0.5) * sin(2 * .pi * (fundamentalFreq * 2) * t)
            let f3 = (amplitude * 0.25) * sin(2 * .pi * (fundamentalFreq * 3) * t)
            return f1 + f2 + f3
        }
    }

    /// Process audio through VAD pipeline
    private func processVAD(samples: [Float], startTimestamp: TimeInterval) -> [SpeechSegment] {
        var timestamp = startTimestamp
        let frameSamples = Int(frameDuration * sampleRate)
        var offset = 0
        var segments: [SpeechSegment] = []

        while offset + frameSamples <= samples.count {
            let frame = Array(samples[offset..<(offset + frameSamples)])

            // Add to segment manager
            segmentManager.addSamples(frame, timestamp: timestamp)

            // Process through VAD
            let vadFrame = vad.processFrame(frame, timestamp: timestamp)

            // Process through state machine
            if let segment = vadStateMachine.processFrame(vadFrame) {
                segmentManager.extractSegment(segment)
                segments.append(segment)
            }

            offset += frameSamples
            timestamp += frameDuration
        }

        // Finalize any remaining segment
        if let final = vadStateMachine.finalize(at: timestamp) {
            segmentManager.extractSegment(final)
            segments.append(final)
        }

        return segments
    }

    // MARK: - Integration Tests

    func testVADToEmbeddingPipeline() {
        // Generate speech with silence gaps
        var audio: [Float] = []

        // Calibration silence
        audio.append(contentsOf: generateSilence(duration: 0.3))

        // Speech segment
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.0))

        // Silence
        audio.append(contentsOf: generateSilence(duration: 0.5))

        // More speech
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.0))

        // Process through VAD
        let vadSegments = processVAD(samples: audio, startTimestamp: 0)

        // Should detect speech segments
        XCTAssertGreaterThan(vadSegments.count, 0, "VAD should detect speech segments")

        // Get concatenated speech samples
        let speechSamples = segmentManager.getConcatenatedSamples()
        XCTAssertGreaterThan(speechSamples.count, 0, "Should have speech samples")

        // Extract embeddings from speech
        let embedding = embeddingEngine.extractEmbedding(from: speechSamples, sampleRate: sampleRate)

        XCTAssertEqual(embedding.count, 64, "Embedding should have correct dimension")
        XCTAssertFalse(embedding.allSatisfy { $0 == 0 }, "Embedding should not be all zeros")
    }

    func testVADTimeMappingWithDiarization() {
        // Generate two speakers with gaps
        var audio: [Float] = []

        // Calibration
        audio.append(contentsOf: generateSilence(duration: 0.3))

        // Speaker 1
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 120, duration: 0.8))

        // Gap
        audio.append(contentsOf: generateSilence(duration: 0.5))

        // Speaker 2 (different pitch)
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 250, duration: 0.8))

        // Gap
        audio.append(contentsOf: generateSilence(duration: 0.5))

        // Speaker 1 again
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 120, duration: 0.8))

        // Process through VAD
        _ = processVAD(samples: audio, startTimestamp: 0)

        // Get time mappings
        let mappings = segmentManager.getTimeMappings()

        // Should have multiple mappings for the speech segments
        XCTAssertGreaterThan(mappings.count, 0, "Should have time mappings")

        // Verify mapping properties
        for mapping in mappings {
            XCTAssertGreaterThanOrEqual(mapping.concatenatedRange.lowerBound, 0)
            XCTAssertGreaterThan(mapping.concatenatedRange.upperBound, mapping.concatenatedRange.lowerBound)
            XCTAssertGreaterThanOrEqual(mapping.originalRange.lowerBound, 0)
            XCTAssertGreaterThan(mapping.originalRange.upperBound, mapping.originalRange.lowerBound)
        }
    }

    func testFullPipelineWithSimulatedTranscription() {
        // Generate multi-speaker audio
        var audio: [Float] = []

        // Calibration
        audio.append(contentsOf: generateSilence(duration: 0.3))

        // Speaker 1 segment
        let speaker1Start = 0.3
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 120, duration: 1.0))
        let speaker1End = speaker1Start + 1.0

        // Gap
        audio.append(contentsOf: generateSilence(duration: 0.5))

        // Speaker 2 segment
        let speaker2Start = speaker1End + 0.5
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 250, duration: 1.0))
        let speaker2End = speaker2Start + 1.0

        // Process through VAD
        _ = processVAD(samples: audio, startTimestamp: 0)

        // Simulate transcription with word timestamps
        let words = [
            WordStamp(word: "Hello", start: speaker1Start + 0.1, end: speaker1Start + 0.3),
            WordStamp(word: "world", start: speaker1Start + 0.4, end: speaker1Start + 0.6),
            WordStamp(word: "Hi", start: speaker2Start + 0.1, end: speaker2Start + 0.3),
            WordStamp(word: "there", start: speaker2Start + 0.4, end: speaker2Start + 0.6)
        ]

        // Get speech samples and extract embeddings
        let speechSamples = segmentManager.getConcatenatedSamples()
        let config = DiarizationConfig.default

        // Create embeddings for each segment
        let windowSamples = Int(config.windowSize * sampleRate)
        let stepSamples = Int(config.windowStep * sampleRate)

        var segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)] = []
        var offset = 0
        while offset + windowSamples <= speechSamples.count {
            let windowEnd = min(offset + windowSamples, speechSamples.count)
            let windowData = Array(speechSamples[offset..<windowEnd])
            let timestamp = Double(offset) / sampleRate
            segments.append((windowData, timestamp, config.windowSize))
            offset += stepSamples
        }

        let embeddings = embeddingEngine.batchExtract(segments: segments, sampleRate: sampleRate)

        // Cluster speakers (if we have enough embeddings)
        if embeddings.count > 1 {
            let speakerSegments = clusterer.cluster(embeddings: embeddings, config: config)

            // Assign words to speakers
            let diarizedWords = assigner.assign(words: words, speakerSegments: speakerSegments)

            XCTAssertEqual(diarizedWords.count, 4)

            // Verify all words have speaker assignments
            for word in diarizedWords {
                XCTAssertGreaterThanOrEqual(word.speakerId, 0)
                XCTAssertGreaterThanOrEqual(word.speakerConfidence, 0)
                XCTAssertLessThanOrEqual(word.speakerConfidence, 1)
            }
        }
    }

    func testStatisticsCalculation() {
        // Create some diarized words
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "world", start: 0.3, end: 0.6, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1.0, end: 1.3, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "there", start: 1.3, end: 1.6, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "OK", start: 2.0, end: 2.2, speakerId: 0, speakerConfidence: 0.85)
        ]

        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 0.8, confidence: 0.9),
            SpeakerSegment(speakerId: 1, startTime: 1.0, endTime: 1.8, confidence: 0.8),
            SpeakerSegment(speakerId: 0, startTime: 2.0, endTime: 2.5, confidence: 0.85)
        ]

        let calculator = SpeakerStatsCalculator()
        let stats = calculator.calculateStats(words: words, segments: segments)

        XCTAssertEqual(stats.count, 2)

        // Find speaker 0 stats
        let speaker0Stats = stats.first { $0.speakerId == 0 }
        XCTAssertNotNil(speaker0Stats)
        XCTAssertEqual(speaker0Stats?.wordCount, 3)
        XCTAssertEqual(speaker0Stats?.segmentCount, 2)

        // Find speaker 1 stats
        let speaker1Stats = stats.first { $0.speakerId == 1 }
        XCTAssertNotNil(speaker1Stats)
        XCTAssertEqual(speaker1Stats?.wordCount, 2)
        XCTAssertEqual(speaker1Stats?.segmentCount, 1)
    }

    func testTranscriptFormatting() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "world", start: 0.3, end: 0.6, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: ".", start: 0.6, end: 0.65, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1.0, end: 1.3, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "there", start: 1.3, end: 1.6, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "!", start: 1.6, end: 1.65, speakerId: 1, speakerConfidence: 0.8)
        ]

        let formatted = DiarizedTranscriptFormatter.format(words: words, userSpeakerId: 0)

        XCTAssertTrue(formatted.contains("[User]:"))
        XCTAssertTrue(formatted.contains("[Speaker 2]:"))
        XCTAssertTrue(formatted.contains("Hello"))
        XCTAssertTrue(formatted.contains("Hi"))
    }

    func testTranscriptFormattingAsTurns() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "world", start: 0.3, end: 0.6, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1.0, end: 1.3, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "there", start: 1.3, end: 1.6, speakerId: 1, speakerConfidence: 0.8)
        ]

        let turns = DiarizedTranscriptFormatter.formatAsTurns(words: words, userSpeakerId: 0)

        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speaker, "User")
        XCTAssertTrue(turns[0].text.contains("Hello"))
        XCTAssertEqual(turns[1].speaker, "Speaker 2")
        XCTAssertTrue(turns[1].text.contains("Hi"))
    }

    // MARK: - Error Handling Tests

    func testDiarizationWithEmptyAudio() {
        let embeddings: [SpeakerEmbedding] = []
        let segments = clusterer.cluster(embeddings: embeddings, config: .default)

        XCTAssertTrue(segments.isEmpty)
    }

    func testDiarizationWithSingleFrame() {
        let samples = generateSpeaker(fundamentalFreq: 150, duration: 0.5)
        let embedding = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)
        let embeddings = [SpeakerEmbedding(features: embedding, timestamp: 0, duration: 0.5)]

        let segments = clusterer.cluster(embeddings: embeddings, config: .default)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerId, 0)
    }

    // MARK: - Time Mapping Consistency Tests

    func testTimeMappingBidirectional() {
        // Generate audio with speech segments
        var audio: [Float] = []
        audio.append(contentsOf: generateSilence(duration: 0.5))
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.0))
        audio.append(contentsOf: generateSilence(duration: 0.5))
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 200, duration: 1.0))

        // Process through VAD
        _ = processVAD(samples: audio, startTimestamp: 0)

        let mappings = segmentManager.getTimeMappings()

        // Test bidirectional mapping
        for mapping in mappings {
            let midOriginal = (mapping.originalRange.lowerBound + mapping.originalRange.upperBound) / 2
            let midConcatenated = (mapping.concatenatedRange.lowerBound + mapping.concatenatedRange.upperBound) / 2

            // Original to concatenated
            let toConcatenated = segmentManager.originalToConcatenatedTime(midOriginal)
            XCTAssertNotNil(toConcatenated)

            // Concatenated to original
            let toOriginal = segmentManager.concatenatedToOriginalTime(midConcatenated)
            XCTAssertNotNil(toOriginal)

            // Should be close to our original midpoint
            if let orig = toOriginal {
                XCTAssertEqual(orig, midOriginal, accuracy: 0.1)
            }
        }
    }
}
