import XCTest
@testable import WalkWrite

final class WordSpeakerAssignerTests: XCTestCase {

    var assigner: WordSpeakerAssigner!

    override func setUp() {
        super.setUp()
        assigner = WordSpeakerAssigner()
    }

    override func tearDown() {
        assigner = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func createWord(text: String, start: Double, end: Double) -> WordStamp {
        return WordStamp(word: text, start: start, end: end)
    }

    private func createSegment(speakerId: Int, start: TimeInterval, end: TimeInterval) -> SpeakerSegment {
        return SpeakerSegment(speakerId: speakerId, startTime: start, endTime: end, confidence: 1.0)
    }

    // MARK: - Basic Assignment Tests

    func testAssignSingleWordSingleSpeaker() {
        let words = [createWord(text: "Hello", start: 0.5, end: 1.0)]
        let segments = [createSegment(speakerId: 0, start: 0, end: 2)]

        let result = assigner.assign(words: words, speakerSegments: segments)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].word, "Hello")
        XCTAssertEqual(result[0].speakerId, 0)
        XCTAssertGreaterThan(result[0].speakerConfidence, 0)
    }

    func testAssignMultipleWordsSingleSpeaker() {
        let words = [
            createWord(text: "Hello", start: 0.5, end: 1.0),
            createWord(text: "world", start: 1.0, end: 1.5),
            createWord(text: "!", start: 1.5, end: 1.6)
        ]
        let segments = [createSegment(speakerId: 0, start: 0, end: 2)]

        let result = assigner.assign(words: words, speakerSegments: segments)

        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.speakerId == 0 })
    }

    func testAssignWordsToMultipleSpeakers() {
        let words = [
            createWord(text: "Hello", start: 0.5, end: 1.0),
            createWord(text: "Hi", start: 2.5, end: 3.0),
            createWord(text: "there", start: 3.0, end: 3.5)
        ]
        let segments = [
            createSegment(speakerId: 0, start: 0, end: 2),
            createSegment(speakerId: 1, start: 2, end: 4)
        ]

        let result = assigner.assign(words: words, speakerSegments: segments)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].speakerId, 0)
        XCTAssertEqual(result[1].speakerId, 1)
        XCTAssertEqual(result[2].speakerId, 1)
    }

    // MARK: - No Segments Tests

    func testAssignWithNoSegments() {
        let words = [
            createWord(text: "Hello", start: 0.5, end: 1.0),
            createWord(text: "world", start: 1.0, end: 1.5)
        ]

        let result = assigner.assign(words: words, speakerSegments: [])

        XCTAssertEqual(result.count, 2)
        // Should default to speaker 0 with low confidence
        XCTAssertTrue(result.allSatisfy { $0.speakerId == 0 })
        XCTAssertTrue(result.allSatisfy { $0.speakerConfidence == 0.0 })
    }

    // MARK: - Overlap Calculation Tests

    func testWordFullyInsideSegment() {
        let words = [createWord(text: "Hello", start: 1.0, end: 2.0)]
        let segments = [createSegment(speakerId: 0, start: 0, end: 5)]

        let result = assigner.assign(words: words, speakerSegments: segments)

        XCTAssertEqual(result[0].speakerId, 0)
        XCTAssertEqual(result[0].speakerConfidence, 1.0, accuracy: 0.01)
    }

    func testWordPartiallyOverlapsSegment() {
        let words = [createWord(text: "Hello", start: 1.5, end: 2.5)]  // 1 second
        let segments = [createSegment(speakerId: 0, start: 0, end: 2)]  // Overlaps 0.5s

        let result = assigner.assign(words: words, speakerSegments: segments)

        XCTAssertEqual(result[0].speakerId, 0)
        XCTAssertEqual(result[0].speakerConfidence, 0.5, accuracy: 0.01)  // 0.5s / 1s
    }

    func testWordBetweenTwoSegments() {
        let words = [createWord(text: "Hello", start: 1.8, end: 2.2)]  // Straddles boundary
        let segments = [
            createSegment(speakerId: 0, start: 0, end: 2),    // 0.2s overlap
            createSegment(speakerId: 1, start: 2, end: 4)     // 0.2s overlap
        ]

        let result = assigner.assign(words: words, speakerSegments: segments)

        // Should assign to one of them (whichever has more overlap or first)
        XCTAssertTrue(result[0].speakerId == 0 || result[0].speakerId == 1)
    }

    // MARK: - Smoothing Tests

    func testSmoothAssignmentsRemovesIsolated() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0),
            DiarizedWord(word: "world", start: 0.5, end: 1.0, speakerId: 1, speakerConfidence: 0.5),  // Isolated
            DiarizedWord(word: "!", start: 1.0, end: 1.1, speakerId: 0, speakerConfidence: 1.0)
        ]

        let smoothed = assigner.smoothAssignments(words, minWordCount: 2)

        // Middle word should be reassigned to speaker 0
        XCTAssertEqual(smoothed[1].speakerId, 0)
    }

    func testSmoothAssignmentsPreservesLongRuns() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0),
            DiarizedWord(word: "world", start: 0.5, end: 1.0, speakerId: 0, speakerConfidence: 1.0),
            DiarizedWord(word: "Hi", start: 1.0, end: 1.5, speakerId: 1, speakerConfidence: 1.0),
            DiarizedWord(word: "there", start: 1.5, end: 2.0, speakerId: 1, speakerConfidence: 1.0)
        ]

        let smoothed = assigner.smoothAssignments(words, minWordCount: 2)

        // Both runs should be preserved
        XCTAssertEqual(smoothed[0].speakerId, 0)
        XCTAssertEqual(smoothed[1].speakerId, 0)
        XCTAssertEqual(smoothed[2].speakerId, 1)
        XCTAssertEqual(smoothed[3].speakerId, 1)
    }

    // MARK: - Relabeling Tests

    func testRelabelSpeakersOrderByAppearance() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 5, speakerConfidence: 1.0),
            DiarizedWord(word: "world", start: 0.5, end: 1.0, speakerId: 3, speakerConfidence: 1.0),
            DiarizedWord(word: "Hi", start: 1.0, end: 1.5, speakerId: 5, speakerConfidence: 1.0)
        ]

        let (relabeled, order) = assigner.relabelSpeakers(words)

        // First appearing speaker (5) should become 0
        XCTAssertEqual(relabeled[0].speakerId, 0)
        // Second appearing speaker (3) should become 1
        XCTAssertEqual(relabeled[1].speakerId, 1)
        // Third word should use relabeled speaker 0
        XCTAssertEqual(relabeled[2].speakerId, 0)

        XCTAssertEqual(order, [5, 3])
    }

    func testRelabelSpeakersEmpty() {
        let (relabeled, order) = assigner.relabelSpeakers([])

        XCTAssertTrue(relabeled.isEmpty)
        XCTAssertTrue(order.isEmpty)
    }

    // MARK: - DiarizedWord Tests

    func testDiarizedWordInit() {
        let word = DiarizedWord(
            word: "Hello",
            start: 1.5,
            end: 2.0,
            speakerId: 2,
            speakerConfidence: 0.85
        )

        XCTAssertEqual(word.word, "Hello")
        XCTAssertEqual(word.start, 1.5)
        XCTAssertEqual(word.end, 2.0)
        XCTAssertEqual(word.duration, 0.5)
        XCTAssertEqual(word.speakerId, 2)
        XCTAssertEqual(word.speakerConfidence, 0.85)
    }

    func testDiarizedWordFromWordStamp() {
        let wordStamp = WordStamp(word: "world", start: 2.0, end: 2.5)
        let diarized = DiarizedWord(wordStamp: wordStamp, speakerId: 1, confidence: 0.9)

        XCTAssertEqual(diarized.word, "world")
        XCTAssertEqual(diarized.start, 2.0)
        XCTAssertEqual(diarized.end, 2.5)
        XCTAssertEqual(diarized.speakerId, 1)
        XCTAssertEqual(diarized.speakerConfidence, 0.9)
    }

    func testDiarizedWordCodable() throws {
        let original = DiarizedWord(
            word: "test",
            start: 1.0,
            end: 1.5,
            speakerId: 3,
            speakerConfidence: 0.75
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiarizedWord.self, from: encoded)

        XCTAssertEqual(decoded.word, original.word)
        XCTAssertEqual(decoded.start, original.start)
        XCTAssertEqual(decoded.end, original.end)
        XCTAssertEqual(decoded.speakerId, original.speakerId)
        XCTAssertEqual(decoded.speakerConfidence, original.speakerConfidence)
    }

    func testDiarizedWordHashable() {
        let word1 = DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0)
        let word2 = DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0)
        let word3 = DiarizedWord(word: "World", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0)

        XCTAssertEqual(word1, word2)
        XCTAssertNotEqual(word1, word3)

        var set: Set<DiarizedWord> = []
        set.insert(word1)
        set.insert(word2)  // Should not add duplicate
        XCTAssertEqual(set.count, 1)
    }
}

// MARK: - Speaker Stats Tests

final class SpeakerStatsTests: XCTestCase {

    var calculator: SpeakerStatsCalculator!

    override func setUp() {
        super.setUp()
        calculator = SpeakerStatsCalculator()
    }

    override func tearDown() {
        calculator = nil
        super.tearDown()
    }

    func testCalculateStats() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0),
            DiarizedWord(word: "world", start: 0.5, end: 1.0, speakerId: 0, speakerConfidence: 1.0),
            DiarizedWord(word: "Hi", start: 2.0, end: 2.5, speakerId: 1, speakerConfidence: 1.0)
        ]

        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 1.5, confidence: 1.0),
            SpeakerSegment(speakerId: 1, startTime: 2.0, endTime: 3.0, confidence: 1.0)
        ]

        let stats = calculator.calculateStats(words: words, segments: segments)

        XCTAssertEqual(stats.count, 2)

        // Speaker 0 should have more speaking time (sorted by speaking time)
        XCTAssertEqual(stats[0].speakerId, 0)
        XCTAssertEqual(stats[0].wordCount, 2)
        XCTAssertEqual(stats[0].segmentCount, 1)

        XCTAssertEqual(stats[1].speakerId, 1)
        XCTAssertEqual(stats[1].wordCount, 1)
    }

    func testSpeakerStatsLabels() {
        let words = [
            DiarizedWord(word: "A", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 1.0),
            DiarizedWord(word: "B", start: 1, end: 1.5, speakerId: 1, speakerConfidence: 1.0)
        ]

        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 1, confidence: 1.0),
            SpeakerSegment(speakerId: 1, startTime: 1, endTime: 2, confidence: 1.0)
        ]

        let stats = calculator.calculateStats(words: words, segments: segments)

        XCTAssertEqual(stats[0].label, "Speaker 1")
        XCTAssertEqual(stats[1].label, "Speaker 2")
    }

    func testSpeakerStatsCodable() throws {
        let original = SpeakerStats(
            speakerId: 1,
            totalSpeakingTime: 5.5,
            segmentCount: 3,
            wordCount: 25,
            averageSegmentDuration: 1.83,
            firstAppearance: 0.5,
            lastAppearance: 10.0,
            label: "Speaker 2"
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpeakerStats.self, from: encoded)

        XCTAssertEqual(decoded.speakerId, original.speakerId)
        XCTAssertEqual(decoded.totalSpeakingTime, original.totalSpeakingTime)
        XCTAssertEqual(decoded.wordCount, original.wordCount)
        XCTAssertEqual(decoded.label, original.label)
    }
}
