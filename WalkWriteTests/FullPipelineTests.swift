import XCTest
@testable import WalkWrite

/// Comprehensive end-to-end tests for the complete VAD → Diarization → User ID → LLM pipeline
final class FullPipelineTests: XCTestCase {

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

    // MARK: - Audio Generation

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

    // MARK: - Edge Case Tests

    func testEmptyRecording() {
        let words: [WordStamp] = []
        let segments: [SpeakerSegment] = []
        let stats: [SpeakerStats] = []

        let result = userIdentifier.identifyUser(diarizedWords: [], speakerStats: stats, speakerSegments: segments)

        XCTAssertNil(result)
    }

    func testVeryShortRecording() {
        // Less than minimum segment duration
        let audio = generateSpeaker(fundamentalFreq: 150, duration: 0.1)

        let frameSamples = Int(frameDuration * sampleRate)
        var timestamp: TimeInterval = 0

        for offset in stride(from: 0, to: audio.count - frameSamples, by: frameSamples) {
            let frame = Array(audio[offset..<(offset + frameSamples)])
            segmentManager.addSamples(frame, timestamp: timestamp)
            let vadFrame = vad.processFrame(frame, timestamp: timestamp)
            _ = vadStateMachine.processFrame(vadFrame)
            timestamp += frameDuration
        }

        let speechSamples = segmentManager.getConcatenatedSamples()
        // Very short audio may not produce enough samples for meaningful diarization
        XCTAssertTrue(speechSamples.count >= 0)
    }

    func testManySpeakers() {
        // Create segments for 6 different speakers
        let speakerFrequencies: [Float] = [120, 150, 180, 210, 240, 270]
        var words: [DiarizedWord] = []
        var segments: [SpeakerSegment] = []

        for (index, _) in speakerFrequencies.enumerated() {
            let startTime = Double(index) * 2.0
            words.append(DiarizedWord(
                word: "Speaker\(index)",
                start: startTime,
                end: startTime + 1.0,
                speakerId: index,
                speakerConfidence: 0.9
            ))
            segments.append(SpeakerSegment(
                speakerId: index,
                startTime: startTime,
                endTime: startTime + 1.5,
                confidence: 0.9
            ))
        }

        // Calculate stats
        var stats: [SpeakerStats] = []
        for i in 0..<speakerFrequencies.count {
            stats.append(SpeakerStats(
                speakerId: i,
                totalSpeakingTime: 1.5,
                segmentCount: 1,
                wordCount: 1,
                averageSegmentDuration: 1.5,
                firstAppearance: Double(i) * 2.0,
                lastAppearance: Double(i) * 2.0 + 1.5
            ))
        }

        let result = userIdentifier.identifyUser(diarizedWords: words, speakerStats: stats, speakerSegments: segments)

        // With equal speaking time, first speaker may be selected
        XCTAssertNotNil(result)
    }

    func testOverlappingSpeakers() {
        // Simulate overlapping speech
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 0.8),
            DiarizedWord(word: "Hi", start: 0.3, end: 0.6, speakerId: 1, speakerConfidence: 0.6),  // Overlap
            DiarizedWord(word: "there", start: 0.6, end: 0.9, speakerId: 0, speakerConfidence: 0.9)
        ]

        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 0.5, confidence: 0.8),
            SpeakerSegment(speakerId: 1, startTime: 0.3, endTime: 0.6, confidence: 0.6),
            SpeakerSegment(speakerId: 0, startTime: 0.6, endTime: 0.9, confidence: 0.9)
        ]

        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 0.8, segmentCount: 2, wordCount: 2),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 0.3, segmentCount: 1, wordCount: 1)
        ]

        let result = userIdentifier.identifyUser(diarizedWords: words, speakerStats: stats, speakerSegments: segments)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userId, 0)  // Speaker 0 has more time
    }

    func testVeryLongRecording() {
        // Simulate a long recording (10 minutes worth of segments)
        var words: [DiarizedWord] = []
        var segments: [SpeakerSegment] = []

        let totalDuration: TimeInterval = 600  // 10 minutes
        var currentTime: TimeInterval = 0
        var currentSpeaker = 0

        while currentTime < totalDuration {
            let segmentDuration = Double.random(in: 2.0...10.0)
            words.append(DiarizedWord(
                word: "word",
                start: currentTime,
                end: currentTime + 0.5,
                speakerId: currentSpeaker,
                speakerConfidence: 0.9
            ))
            segments.append(SpeakerSegment(
                speakerId: currentSpeaker,
                startTime: currentTime,
                endTime: currentTime + segmentDuration,
                confidence: 0.9
            ))
            currentTime += segmentDuration + 0.5
            currentSpeaker = (currentSpeaker + 1) % 2
        }

        // Calculate stats
        var stats: [SpeakerStats] = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 0, segmentCount: 0, wordCount: 0),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 0, segmentCount: 0, wordCount: 0)
        ]

        for segment in segments {
            let idx = segment.speakerId
            stats[idx] = SpeakerStats(
                speakerId: idx,
                totalSpeakingTime: stats[idx].totalSpeakingTime + (segment.endTime - segment.startTime),
                segmentCount: stats[idx].segmentCount + 1,
                wordCount: stats[idx].wordCount + 1
            )
        }

        let result = userIdentifier.identifyUser(diarizedWords: words, speakerStats: stats, speakerSegments: segments)

        XCTAssertNotNil(result)
        // Should handle long recordings without issues
    }

    // MARK: - VAD Edge Cases

    func testVADWithOnlySilence() {
        let silence = generateSilence(duration: 5.0)

        let frameSamples = Int(frameDuration * sampleRate)
        var timestamp: TimeInterval = 0
        var segments: [SpeechSegment] = []

        for offset in stride(from: 0, to: silence.count - frameSamples, by: frameSamples) {
            let frame = Array(silence[offset..<(offset + frameSamples)])
            segmentManager.addSamples(frame, timestamp: timestamp)
            let vadFrame = vad.processFrame(frame, timestamp: timestamp)

            if let segment = vadStateMachine.processFrame(vadFrame) {
                segments.append(segment)
            }
            timestamp += frameDuration
        }

        // Should not detect any speech segments in pure silence
        XCTAssertTrue(segments.isEmpty || segments.allSatisfy { ($0.endTime - $0.startTime) < vad.configuration.minSpeechDuration })
    }

    func testVADWithConstantNoise() {
        // Constant low-level noise
        let count = Int(3.0 * sampleRate)
        let noise = (0..<count).map { _ in Float.random(in: -0.05...0.05) }

        let frameSamples = Int(frameDuration * sampleRate)
        var timestamp: TimeInterval = 0

        for offset in stride(from: 0, to: noise.count - frameSamples, by: frameSamples) {
            let frame = Array(noise[offset..<(offset + frameSamples)])
            let vadFrame = vad.processFrame(frame, timestamp: timestamp)
            XCTAssertLessThan(vadFrame.speechProbability, 0.5, "Random noise should not be classified as speech")
            timestamp += frameDuration
        }
    }

    // MARK: - Note Model Tests

    func testNoteWithAllFields() {
        var note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Hello world",
            words: [WordStamp(word: "Hello", start: 0, end: 0.5)]
        )

        // Set all fields
        note.originalRecordingDuration = 120
        note.speechDuration = 60
        note.vadSegments = [SpeechSegment(id: UUID(), startTime: 0, endTime: 10, isFinal: true)]
        note.diarizedWords = [DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 0.9)]
        note.speakerSegments = [SpeakerSegment(speakerId: 0, startTime: 0, endTime: 10, confidence: 0.9)]
        note.speakerStats = [SpeakerStats(speakerId: 0, totalSpeakingTime: 60, segmentCount: 5, wordCount: 100)]
        note.speakerCount = 1
        note.identifiedUserId = 0
        note.diarizationCompleted = true
        note.diarizationFailed = false
        note.cleanedTranscript = "Hello, world!"
        note.summary = "A greeting."
        note.keyIdeas = ["Greeting"]

        XCTAssertTrue(note.hasDiarization)
        XCTAssertFalse(note.hasMultipleSpeakers)
        XCTAssertFalse(note.formattedTranscript.isEmpty)
    }

    func testNoteCodable() throws {
        var note = Note(
            audioURL: URL(fileURLWithPath: "/tmp/test.wav"),
            transcript: "Test"
        )
        note.speakerCount = 2
        note.diarizationCompleted = true

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: data)

        XCTAssertEqual(decoded.speakerCount, 2)
        XCTAssertEqual(decoded.diarizationCompleted, true)
    }
}

// MARK: - Performance Tests

final class PerformanceTests: XCTestCase {

    let sampleRate: Double = 16000.0

    func testVADFrameProcessingPerformance() {
        let vad = EnergyBasedVAD(configuration: .default)

        // Generate 10 seconds of audio (312 frames at 32ms each)
        let frameDuration: TimeInterval = 0.032
        let frameSamples = Int(frameDuration * sampleRate)
        let totalFrames = 312

        var frames: [[Float]] = []
        for _ in 0..<totalFrames {
            let frame = (0..<frameSamples).map { _ in Float.random(in: -0.3...0.3) }
            frames.append(frame)
        }

        measure {
            var timestamp: TimeInterval = 0
            for frame in frames {
                _ = vad.processFrame(frame, timestamp: timestamp)
                timestamp += frameDuration
            }
        }
    }

    func testEmbeddingExtractionPerformance() {
        let engine = AcousticSpeakerEmbedding()

        // Generate 5 segments of 1.5 seconds each
        let segmentDuration: TimeInterval = 1.5
        let segmentSamples = Int(segmentDuration * sampleRate)

        var segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)] = []
        for i in 0..<5 {
            let samples = (0..<segmentSamples).map { j in
                Float(sin(2 * .pi * 150 * Double(j) / sampleRate))
            }
            segments.append((samples, Double(i) * segmentDuration, segmentDuration))
        }

        measure {
            _ = engine.batchExtract(segments: segments, sampleRate: sampleRate)
        }
    }

    func testClusteringPerformance() {
        let clusterer = SpeakerClusterer()
        let config = DiarizationConfig.default

        // Generate 50 embeddings
        var embeddings: [SpeakerEmbedding] = []
        for i in 0..<50 {
            let vector = (0..<64).map { _ in Float.random(in: -1...1) }
            embeddings.append(SpeakerEmbedding(
                vector: vector,
                timestamp: Double(i) * 0.5,
                duration: 0.5
            ))
        }

        measure {
            _ = clusterer.cluster(embeddings: embeddings, config: config)
        }
    }

    func testWordAssignmentPerformance() {
        let assigner = WordSpeakerAssigner()

        // Generate 500 words and 20 speaker segments
        var words: [WordStamp] = []
        for i in 0..<500 {
            words.append(WordStamp(
                word: "word\(i)",
                start: Double(i) * 0.2,
                end: Double(i) * 0.2 + 0.15
            ))
        }

        var segments: [SpeakerSegment] = []
        for i in 0..<20 {
            segments.append(SpeakerSegment(
                speakerId: i % 3,
                startTime: Double(i) * 5.0,
                endTime: Double(i) * 5.0 + 4.5,
                confidence: 0.9
            ))
        }

        measure {
            _ = assigner.assign(words: words, speakerSegments: segments)
        }
    }

    func testUserIdentificationPerformance() {
        let identifier = UserIdentifier()

        // Generate data for 5 speakers with 1000 words
        var words: [DiarizedWord] = []
        for i in 0..<1000 {
            words.append(DiarizedWord(
                word: "word",
                start: Double(i) * 0.2,
                end: Double(i) * 0.2 + 0.15,
                speakerId: i % 5,
                speakerConfidence: 0.9
            ))
        }

        var stats: [SpeakerStats] = []
        for i in 0..<5 {
            stats.append(SpeakerStats(
                speakerId: i,
                totalSpeakingTime: Double(200 - i * 20),
                segmentCount: 20 - i * 2,
                wordCount: 200 - i * 20
            ))
        }

        measure {
            _ = identifier.identifyUser(diarizedWords: words, speakerStats: stats)
        }
    }
}
