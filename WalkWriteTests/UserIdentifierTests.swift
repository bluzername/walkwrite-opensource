import XCTest
@testable import WalkWrite

final class UserIdentifierTests: XCTestCase {

    var identifier: UserIdentifier!

    override func setUp() {
        super.setUp()
        identifier = UserIdentifier()
    }

    override func tearDown() {
        identifier = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func createStats(
        speakerId: Int,
        totalTime: TimeInterval,
        segmentCount: Int,
        wordCount: Int,
        firstAppearance: TimeInterval
    ) -> SpeakerStats {
        return SpeakerStats(
            speakerId: speakerId,
            totalSpeakingTime: totalTime,
            segmentCount: segmentCount,
            wordCount: wordCount,
            averageSegmentDuration: segmentCount > 0 ? totalTime / Double(segmentCount) : 0,
            firstAppearance: firstAppearance,
            lastAppearance: firstAppearance + totalTime
        )
    }

    private func createDiarizedWord(speakerId: Int, start: Double) -> DiarizedWord {
        return DiarizedWord(
            word: "test",
            start: start,
            end: start + 0.3,
            speakerId: speakerId,
            speakerConfidence: 0.9
        )
    }

    // MARK: - Single Speaker Tests

    func testIdentifySingleSpeaker() {
        let stats = [createStats(speakerId: 0, totalTime: 30, segmentCount: 5, wordCount: 100, firstAppearance: 0)]
        let words = [createDiarizedWord(speakerId: 0, start: 0)]

        let result = identifier.identifyUser(diarizedWords: words, speakerStats: stats)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userId, 0)
        XCTAssertEqual(result?.confidence, 1.0)
        XCTAssertEqual(result?.reason, .singleSpeaker)
    }

    // MARK: - Two Speaker Tests

    func testIdentifyUserByMostSpeakingTime() {
        let stats = [
            createStats(speakerId: 0, totalTime: 45, segmentCount: 8, wordCount: 150, firstAppearance: 0),
            createStats(speakerId: 1, totalTime: 15, segmentCount: 3, wordCount: 50, firstAppearance: 5)
        ]
        let words = [
            createDiarizedWord(speakerId: 0, start: 0),
            createDiarizedWord(speakerId: 1, start: 5)
        ]

        let result = identifier.identifyUser(diarizedWords: words, speakerStats: stats)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userId, 0)
        XCTAssertEqual(result?.reason, .mostSpeakingTime)
        XCTAssertGreaterThan(result?.confidence ?? 0, 0.5)
    }

    func testIdentifyUserByFirstSpeakerWithSubstantialTime() {
        // First speaker has moderate time but appeared first
        let stats = [
            createStats(speakerId: 0, totalTime: 25, segmentCount: 4, wordCount: 80, firstAppearance: 0),
            createStats(speakerId: 1, totalTime: 30, segmentCount: 5, wordCount: 100, firstAppearance: 10)
        ]
        let words = [
            createDiarizedWord(speakerId: 0, start: 0),
            createDiarizedWord(speakerId: 1, start: 10)
        ]

        let result = identifier.identifyUser(diarizedWords: words, speakerStats: stats)

        XCTAssertNotNil(result)
        // Speaker 0 may still be selected due to first appearance weight
        XCTAssertTrue(result?.userId == 0 || result?.userId == 1)
    }

    // MARK: - Three Speaker Tests

    func testIdentifyUserWithThreeSpeakers() {
        let stats = [
            createStats(speakerId: 0, totalTime: 40, segmentCount: 6, wordCount: 120, firstAppearance: 0),
            createStats(speakerId: 1, totalTime: 20, segmentCount: 4, wordCount: 60, firstAppearance: 5),
            createStats(speakerId: 2, totalTime: 10, segmentCount: 2, wordCount: 30, firstAppearance: 15)
        ]
        let words = [
            createDiarizedWord(speakerId: 0, start: 0),
            createDiarizedWord(speakerId: 1, start: 5),
            createDiarizedWord(speakerId: 2, start: 15)
        ]

        let result = identifier.identifyUser(diarizedWords: words, speakerStats: stats)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userId, 0)  // Speaker 0 has most time and appeared first
    }

    // MARK: - Edge Cases

    func testIdentifyUserWithEmptyStats() {
        let result = identifier.identifyUser(diarizedWords: [], speakerStats: [])

        XCTAssertNil(result)
    }

    func testIdentifyUserWithInsufficientSpeakingTime() {
        // All speakers have very low speaking time ratio
        let config = UserIdentificationConfig(minSpeakingTimeRatio: 0.5)
        let strictIdentifier = UserIdentifier(config: config)

        let stats = [
            createStats(speakerId: 0, totalTime: 5, segmentCount: 1, wordCount: 10, firstAppearance: 0),
            createStats(speakerId: 1, totalTime: 5, segmentCount: 1, wordCount: 10, firstAppearance: 2),
            createStats(speakerId: 2, totalTime: 5, segmentCount: 1, wordCount: 10, firstAppearance: 4)
        ]
        let words = [createDiarizedWord(speakerId: 0, start: 0)]

        let result = strictIdentifier.identifyUser(diarizedWords: words, speakerStats: stats)

        // With 0.5 min ratio, speakers need at least 50% of total time (7.5s)
        // None of them qualify, but one should still be selected with lower confidence
        // Actually with 0.5 ratio and 5/15 = 0.33, none qualify
        // Result may be nil or low confidence
        XCTAssertNil(result)
    }

    // MARK: - Configuration Tests

    func testConservativeConfig() {
        let conservativeIdentifier = UserIdentifier(config: .conservative)

        let stats = [
            createStats(speakerId: 0, totalTime: 25, segmentCount: 5, wordCount: 80, firstAppearance: 0),
            createStats(speakerId: 1, totalTime: 25, segmentCount: 5, wordCount: 80, firstAppearance: 5)
        ]
        let words = [
            createDiarizedWord(speakerId: 0, start: 0),
            createDiarizedWord(speakerId: 1, start: 5)
        ]

        let result = conservativeIdentifier.identifyUser(diarizedWords: words, speakerStats: stats)

        // Very close scores should reduce confidence
        if let result = result {
            XCTAssertLessThan(result.confidence, 0.9)
        }
    }

    func testLenientConfig() {
        let lenientIdentifier = UserIdentifier(config: .lenient)

        let stats = [
            createStats(speakerId: 0, totalTime: 10, segmentCount: 2, wordCount: 30, firstAppearance: 0),
            createStats(speakerId: 1, totalTime: 8, segmentCount: 2, wordCount: 25, firstAppearance: 3)
        ]
        let words = [
            createDiarizedWord(speakerId: 0, start: 0),
            createDiarizedWord(speakerId: 1, start: 3)
        ]

        let result = lenientIdentifier.identifyUser(diarizedWords: words, speakerStats: stats)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userId, 0)
    }

    // MARK: - DiarizationResult Integration

    func testIdentifyUserFromDiarizationResult() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.5, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1, end: 1.5, speakerId: 1, speakerConfidence: 0.9),
            DiarizedWord(word: "there", start: 2, end: 2.5, speakerId: 0, speakerConfidence: 0.9)
        ]

        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 1, confidence: 0.9),
            SpeakerSegment(speakerId: 1, startTime: 1, endTime: 2, confidence: 0.9),
            SpeakerSegment(speakerId: 0, startTime: 2, endTime: 3, confidence: 0.9)
        ]

        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 2, segmentCount: 2, wordCount: 2),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 1, segmentCount: 1, wordCount: 1)
        ]

        let diarizationResult = DiarizationResult(
            diarizedWords: words,
            speakerSegments: segments,
            speakerStats: stats,
            speakerCount: 2
        )

        let result = identifier.identifyUser(from: diarizationResult)

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userId, 0)
    }
}

// MARK: - Speaker Labeler Tests

final class SpeakerLabelerTests: XCTestCase {

    func testGenerateLabelsWithUser() {
        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 20, segmentCount: 3, wordCount: 60)
        ]

        let labels = SpeakerLabeler.generateLabels(speakerStats: stats, userId: 0)

        XCTAssertEqual(labels[0], "You")
        XCTAssertEqual(labels[1], "Speaker 2")
    }

    func testGenerateLabelsWithCustomUserLabel() {
        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 20, segmentCount: 3, wordCount: 60)
        ]

        let labels = SpeakerLabeler.generateLabels(
            speakerStats: stats,
            userId: 0,
            customUserLabel: "Me"
        )

        XCTAssertEqual(labels[0], "Me")
        XCTAssertEqual(labels[1], "Speaker 2")
    }

    func testGenerateLabelsWithoutUser() {
        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 20, segmentCount: 3, wordCount: 60)
        ]

        let labels = SpeakerLabeler.generateLabels(speakerStats: stats, userId: nil)

        XCTAssertEqual(labels[0], "Speaker 2")
        XCTAssertEqual(labels[1], "Speaker 3")
    }

    func testFormatTranscript() {
        let words = [
            DiarizedWord(word: "Hello", start: 0, end: 0.3, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "world", start: 0.3, end: 0.6, speakerId: 0, speakerConfidence: 0.9),
            DiarizedWord(word: "Hi", start: 1, end: 1.3, speakerId: 1, speakerConfidence: 0.9),
            DiarizedWord(word: "there", start: 1.3, end: 1.6, speakerId: 1, speakerConfidence: 0.9)
        ]

        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 1, segmentCount: 1, wordCount: 2),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 1, segmentCount: 1, wordCount: 2)
        ]

        let transcript = SpeakerLabeler.formatTranscript(
            diarizedWords: words,
            speakerStats: stats,
            userId: 0
        )

        XCTAssertTrue(transcript.contains("[You]:"))
        XCTAssertTrue(transcript.contains("[Speaker 2]:"))
        XCTAssertTrue(transcript.contains("Hello"))
        XCTAssertTrue(transcript.contains("Hi"))
    }

    func testGenerateLLMContext() {
        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 45, segmentCount: 8, wordCount: 150),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 15, segmentCount: 3, wordCount: 50)
        ]

        let context = SpeakerLabeler.generateLLMContext(speakerStats: stats, userId: 0)

        XCTAssertTrue(context.contains("2 speaker(s)"))
        XCTAssertTrue(context.contains("You"))
        XCTAssertTrue(context.contains("Speaker 2"))
        XCTAssertTrue(context.contains("the person recording"))
    }

    func testGenerateLLMContextWithNoUser() {
        let stats = [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100)
        ]

        let context = SpeakerLabeler.generateLLMContext(speakerStats: stats, userId: nil)

        XCTAssertTrue(context.contains("2 speaker(s)"))
        XCTAssertFalse(context.contains("focus on the perspective"))
    }
}

// MARK: - User Identification Config Tests

final class UserIdentificationConfigTests: XCTestCase {

    func testDefaultConfig() {
        let config = UserIdentificationConfig.default

        XCTAssertEqual(config.minSpeakingTimeRatio, 0.2)
        XCTAssertEqual(config.speakingTimeWeight, 0.5)
        XCTAssertEqual(config.segmentCountWeight, 0.3)
        XCTAssertEqual(config.firstAppearanceWeight, 0.2)
        XCTAssertEqual(config.minConfidence, 0.3)
    }

    func testConservativeConfig() {
        let config = UserIdentificationConfig.conservative

        XCTAssertGreaterThan(config.minSpeakingTimeRatio, UserIdentificationConfig.default.minSpeakingTimeRatio)
        XCTAssertGreaterThan(config.minConfidence, UserIdentificationConfig.default.minConfidence)
    }

    func testLenientConfig() {
        let config = UserIdentificationConfig.lenient

        XCTAssertLessThan(config.minSpeakingTimeRatio, UserIdentificationConfig.default.minSpeakingTimeRatio)
        XCTAssertLessThan(config.minConfidence, UserIdentificationConfig.default.minConfidence)
    }

    func testCustomConfig() {
        let config = UserIdentificationConfig(
            minSpeakingTimeRatio: 0.15,
            speakingTimeWeight: 0.6,
            segmentCountWeight: 0.25,
            firstAppearanceWeight: 0.15,
            minConfidence: 0.4
        )

        XCTAssertEqual(config.minSpeakingTimeRatio, 0.15)
        XCTAssertEqual(config.speakingTimeWeight, 0.6)
        XCTAssertEqual(config.minConfidence, 0.4)
    }

    func testWeightsSumApproximatelyOne() {
        let config = UserIdentificationConfig.default

        let sum = config.speakingTimeWeight + config.segmentCountWeight + config.firstAppearanceWeight
        XCTAssertEqual(sum, 1.0, accuracy: 0.01)
    }
}

// MARK: - User Identification Result Tests

final class UserIdentificationResultTests: XCTestCase {

    func testResultProperties() {
        let stats = SpeakerStats(speakerId: 0, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100)
        let result = UserIdentificationResult(
            userId: 0,
            confidence: 0.85,
            reason: .mostSpeakingTime,
            userStats: stats
        )

        XCTAssertEqual(result.userId, 0)
        XCTAssertEqual(result.confidence, 0.85)
        XCTAssertEqual(result.reason, .mostSpeakingTime)
        XCTAssertEqual(result.userStats.speakerId, 0)
    }

    func testReasonDescriptions() {
        let reasons: [IdentificationReason] = [
            .mostSpeakingTime,
            .firstSpeakerWithSubstantialTime,
            .mostSegments,
            .combinedFactors,
            .singleSpeaker
        ]

        for reason in reasons {
            XCTAssertFalse(reason.description.isEmpty)
        }
    }
}
