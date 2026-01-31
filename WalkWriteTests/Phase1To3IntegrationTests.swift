import XCTest
@testable import WalkWrite

/// Integration tests that verify the complete VAD → Diarization → User Identification pipeline
final class Phase1To3IntegrationTests: XCTestCase {

    // MARK: - Properties

    var vad: EnergyBasedVAD!
    var vadStateMachine: VADStateMachine!
    var segmentManager: AudioSegmentManager!
    var embeddingEngine: AcousticSpeakerEmbedding!
    var clusterer: SpeakerClusterer!
    var assigner: WordSpeakerAssigner!
    var userIdentifier: UserIdentifier!

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
        userIdentifier = UserIdentifier()
    }

    override func tearDown() {
        vad = nil
        vadStateMachine = nil
        segmentManager = nil
        embeddingEngine = nil
        clusterer = nil
        assigner = nil
        userIdentifier = nil
        super.tearDown()
    }

    // MARK: - Audio Generation Helpers

    private func generateSilence(duration: TimeInterval) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { _ in Float.random(in: -0.0001...0.0001) }
    }

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

    private func processVAD(samples: [Float], startTimestamp: TimeInterval) -> [SpeechSegment] {
        var timestamp = startTimestamp
        let frameSamples = Int(frameDuration * sampleRate)
        var offset = 0
        var segments: [SpeechSegment] = []

        while offset + frameSamples <= samples.count {
            let frame = Array(samples[offset..<(offset + frameSamples)])
            segmentManager.addSamples(frame, timestamp: timestamp)
            let vadFrame = vad.processFrame(frame, timestamp: timestamp)

            if let segment = vadStateMachine.processFrame(vadFrame) {
                segmentManager.extractSegment(segment)
                segments.append(segment)
            }

            offset += frameSamples
            timestamp += frameDuration
        }

        if let final = vadStateMachine.finalize(at: timestamp) {
            segmentManager.extractSegment(final)
            segments.append(final)
        }

        return segments
    }

    // MARK: - Full Pipeline Tests

    func testFullPipelineWithUserIdentification() {
        // Generate conversation: User speaks more, then other speaker, then user again
        var audio: [Float] = []

        // Calibration silence
        audio.append(contentsOf: generateSilence(duration: 0.3))

        // User speaking (Speaker 0) - longer segment
        let userStart1 = 0.3
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.5))
        let userEnd1 = userStart1 + 1.5

        // Gap
        audio.append(contentsOf: generateSilence(duration: 0.5))

        // Other speaker (Speaker 1) - shorter segment
        let otherStart = userEnd1 + 0.5
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 220, duration: 0.8))
        let otherEnd = otherStart + 0.8

        // Gap
        audio.append(contentsOf: generateSilence(duration: 0.5))

        // User speaking again (Speaker 0)
        let userStart2 = otherEnd + 0.5
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.2))

        // Process through VAD
        let vadSegments = processVAD(samples: audio, startTimestamp: 0)
        XCTAssertGreaterThan(vadSegments.count, 0, "VAD should detect speech segments")

        // Get time mappings
        let timeMappings = segmentManager.getTimeMappings()
        XCTAssertGreaterThan(timeMappings.count, 0, "Should have time mappings")

        // Simulate transcription with word timestamps
        let words = [
            WordStamp(word: "Hello", start: userStart1 + 0.1, end: userStart1 + 0.4),
            WordStamp(word: "I'm", start: userStart1 + 0.5, end: userStart1 + 0.7),
            WordStamp(word: "recording", start: userStart1 + 0.8, end: userStart1 + 1.2),
            WordStamp(word: "Hi", start: otherStart + 0.1, end: otherStart + 0.3),
            WordStamp(word: "there", start: otherStart + 0.4, end: otherStart + 0.6),
            WordStamp(word: "Yes", start: userStart2 + 0.1, end: userStart2 + 0.3),
            WordStamp(word: "exactly", start: userStart2 + 0.4, end: userStart2 + 0.7)
        ]

        // Get speech samples and extract embeddings
        let speechSamples = segmentManager.getConcatenatedSamples()
        XCTAssertGreaterThan(speechSamples.count, 0, "Should have speech samples")

        let config = DiarizationConfig.default
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

        if embeddings.count > 1 {
            // Cluster speakers
            let speakerSegments = clusterer.cluster(embeddings: embeddings, config: config)

            // Assign words to speakers
            let diarizedWords = assigner.assign(words: words, speakerSegments: speakerSegments)
            XCTAssertEqual(diarizedWords.count, 7)

            // Calculate stats
            let statsCalculator = SpeakerStatsCalculator()
            let stats = statsCalculator.calculateStats(words: diarizedWords, segments: speakerSegments)

            // Identify user
            let userResult = userIdentifier.identifyUser(
                diarizedWords: diarizedWords,
                speakerStats: stats,
                speakerSegments: speakerSegments
            )

            XCTAssertNotNil(userResult, "Should identify a user")
            XCTAssertGreaterThanOrEqual(userResult?.confidence ?? 0, 0.3, "Confidence should be reasonable")
        }
    }

    func testPipelineWithSingleSpeaker() {
        // Generate single speaker audio
        var audio: [Float] = []
        audio.append(contentsOf: generateSilence(duration: 0.3))
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 2.0))
        audio.append(contentsOf: generateSilence(duration: 0.5))
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.5))

        // Process through VAD
        _ = processVAD(samples: audio, startTimestamp: 0)

        // Simulate words
        let words = [
            WordStamp(word: "Hello", start: 0.3, end: 0.6),
            WordStamp(word: "world", start: 0.7, end: 1.0),
            WordStamp(word: "testing", start: 2.8, end: 3.2)
        ]

        // Get speech samples
        let speechSamples = segmentManager.getConcatenatedSamples()
        let config = DiarizationConfig.default
        let windowSamples = Int(config.windowSize * sampleRate)
        let stepSamples = Int(config.windowStep * sampleRate)

        var segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)] = []
        var offset = 0
        while offset + windowSamples <= speechSamples.count {
            let windowData = Array(speechSamples[offset..<min(offset + windowSamples, speechSamples.count)])
            segments.append((windowData, Double(offset) / sampleRate, config.windowSize))
            offset += stepSamples
        }

        let embeddings = embeddingEngine.batchExtract(segments: segments, sampleRate: sampleRate)

        if embeddings.count > 0 {
            let speakerSegments = clusterer.cluster(embeddings: embeddings, config: config)
            let diarizedWords = assigner.assign(words: words, speakerSegments: speakerSegments)

            let statsCalculator = SpeakerStatsCalculator()
            let stats = statsCalculator.calculateStats(words: diarizedWords, segments: speakerSegments)

            let userResult = userIdentifier.identifyUser(
                diarizedWords: diarizedWords,
                speakerStats: stats
            )

            // Single speaker should always be identified as user with high confidence
            if stats.count == 1 {
                XCTAssertNotNil(userResult)
                XCTAssertEqual(userResult?.confidence, 1.0)
                XCTAssertEqual(userResult?.reason, .singleSpeaker)
            }
        }
    }

    func testTimeMappingPreservedThroughPipeline() {
        // Generate audio with gaps
        var audio: [Float] = []
        audio.append(contentsOf: generateSilence(duration: 0.5))  // 0-0.5
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.0))  // 0.5-1.5
        audio.append(contentsOf: generateSilence(duration: 1.0))  // 1.5-2.5
        audio.append(contentsOf: generateSpeaker(fundamentalFreq: 150, duration: 1.0))  // 2.5-3.5

        _ = processVAD(samples: audio, startTimestamp: 0)

        let timeMappings = segmentManager.getTimeMappings()

        // Verify mappings exist
        XCTAssertGreaterThan(timeMappings.count, 0)

        // Verify mappings are valid
        for mapping in timeMappings {
            XCTAssertGreaterThanOrEqual(mapping.concatenatedRange.lowerBound, 0)
            XCTAssertGreaterThan(mapping.concatenatedRange.upperBound, mapping.concatenatedRange.lowerBound)
            XCTAssertGreaterThanOrEqual(mapping.originalRange.lowerBound, 0)
            XCTAssertGreaterThan(mapping.originalRange.upperBound, mapping.originalRange.lowerBound)
        }

        // Test time conversion
        for mapping in timeMappings {
            let originalMid = (mapping.originalRange.lowerBound + mapping.originalRange.upperBound) / 2
            let concatenatedTime = segmentManager.originalToConcatenatedTime(originalMid)
            XCTAssertNotNil(concatenatedTime)

            if let concatTime = concatenatedTime {
                let backToOriginal = segmentManager.concatenatedToOriginalTime(concatTime)
                XCTAssertNotNil(backToOriginal)
                if let origTime = backToOriginal {
                    XCTAssertEqual(origTime, originalMid, accuracy: 0.1)
                }
            }
        }
    }

    func testSpeakerLabelingIntegration() {
        // Create mock diarization result
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "world", start: 0.3, end: 0.6, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1.0, end: 1.3, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "there", start: 1.3, end: 1.6, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "Yes", start: 2.0, end: 2.3, speakerId: 0, speakerConfidence: 0.9)
        ]

        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 2.0, segmentCount: 2, wordCount: 3),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 1.0, segmentCount: 1, wordCount: 2)
        ]

        // Identify user
        let userResult = userIdentifier.identifyUser(diarizedWords: words, speakerStats: stats)
        XCTAssertNotNil(userResult)

        let userId = userResult?.userId

        // Generate labels
        let labels = SpeakerLabeler.generateLabels(speakerStats: stats, userId: userId)
        XCTAssertEqual(labels.count, 2)

        // Format transcript
        let transcript = SpeakerLabeler.formatTranscript(
            diarizedWords: words,
            speakerStats: stats,
            userId: userId
        )
        XCTAssertFalse(transcript.isEmpty)
        XCTAssertTrue(transcript.contains("Hello"))
        XCTAssertTrue(transcript.contains("Hi"))

        // Generate LLM context
        let context = SpeakerLabeler.generateLLMContext(speakerStats: stats, userId: userId)
        XCTAssertTrue(context.contains("2 speaker(s)"))
    }

    func testNoteModelWithDiarizationFields() {
        // Create a note with all diarization fields
        var note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Hello world",
            words: [WordStamp(word: "Hello", start: 0, end: 0.3)]
        )

        // Add VAD metadata
        note.originalRecordingDuration = 120.0
        note.speechDuration = 45.0
        note.vadSegments = [
            SpeechSegment(id: UUID(), startTime: 0, endTime: 10, isFinal: true)
        ]

        // Add diarization data
        note.diarizedWords = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9)
        ]
        note.speakerSegments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 10, confidence: 0.9)
        ]
        note.speakerStats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 45, segmentCount: 5, wordCount: 100)
        ]
        note.speakerCount = 1
        note.identifiedUserId = 0
        note.diarizationCompleted = true
        note.diarizationFailed = false

        // Verify convenience properties
        XCTAssertTrue(note.hasDiarization)
        XCTAssertFalse(note.hasMultipleSpeakers)
        XCTAssertFalse(note.formattedTranscript.isEmpty)
    }

    func testNoteModelMultipleSpeakers() {
        var note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Hello world"
        )

        note.diarizedWords = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1, end: 1.3, speakerId: 1, speakerConfidence: 0.8)
        ]
        note.speakerCount = 2
        note.diarizationCompleted = true

        XCTAssertTrue(note.hasDiarization)
        XCTAssertTrue(note.hasMultipleSpeakers)
    }
}

// MARK: - Note Extension Tests

final class NoteExtensionTests: XCTestCase {

    func testFormattedTranscriptWithDiarization() {
        var note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Hello world Hi there"
        )

        note.diarizedWords = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "world", start: 0.3, end: 0.6, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1, end: 1.3, speakerId: 1, speakerConfidence: 0.8),
            DiarizedWord(word: "there", start: 1.3, end: 1.6, speakerId: 1, speakerConfidence: 0.8)
        ]
        note.identifiedUserId = 0
        note.diarizationCompleted = true

        let formatted = note.formattedTranscript
        XCTAssertTrue(formatted.contains("[User]:") || formatted.contains("[Speaker 1]:"))
        XCTAssertTrue(formatted.contains("Hello"))
    }

    func testFormattedTranscriptFallback() {
        let note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Hello world",
            cleanedTranscript: "Hello, world!"
        )

        let formatted = note.formattedTranscript
        XCTAssertEqual(formatted, "Hello, world!")
    }

    func testFormattedTranscriptRawFallback() {
        let note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Hello world"
        )

        let formatted = note.formattedTranscript
        XCTAssertEqual(formatted, "Hello world")
    }
}
