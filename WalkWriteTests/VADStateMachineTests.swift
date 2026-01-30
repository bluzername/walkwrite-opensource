import XCTest
@testable import WalkWrite

final class VADStateMachineTests: XCTestCase {

    var stateMachine: VADStateMachine!
    var config: VADConfiguration!

    override func setUp() {
        super.setUp()
        config = VADConfiguration(
            speechThreshold: 0.5,
            silenceThreshold: 0.35,
            minSpeechDuration: 0.25,
            minSilenceDuration: 0.3,
            windowSizeSamples: 512,
            windowStepSamples: 256
        )
        stateMachine = VADStateMachine(configuration: config)
    }

    override func tearDown() {
        stateMachine = nil
        config = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func createSpeechFrame(at timestamp: TimeInterval, duration: TimeInterval = 0.032) -> VADFrame {
        return VADFrame(speechProbability: 0.8, isSpeech: true, timestamp: timestamp, duration: duration)
    }

    private func createSilenceFrame(at timestamp: TimeInterval, duration: TimeInterval = 0.032) -> VADFrame {
        return VADFrame(speechProbability: 0.2, isSpeech: false, timestamp: timestamp, duration: duration)
    }

    // MARK: - Initial State Tests

    func testInitialStateIsIdle() {
        let state = stateMachine.getState()
        if case .idle = state {
            // Expected
        } else {
            XCTFail("Initial state should be idle")
        }
    }

    func testInitiallyNoCompletedSegments() {
        XCTAssertTrue(stateMachine.getCompletedSegments().isEmpty)
    }

    func testInitiallyNoCurrentSegment() {
        XCTAssertNil(stateMachine.getCurrentSegment())
    }

    // MARK: - State Transition Tests

    func testIdleToSpeechTransition() {
        let frame = createSpeechFrame(at: 0.0)
        _ = stateMachine.processFrame(frame)

        let state = stateMachine.getState()
        if case .inSpeech = state {
            // Expected
        } else {
            XCTFail("Should transition to inSpeech after speech frame")
        }

        XCTAssertNotNil(stateMachine.getCurrentSegment())
    }

    func testSilenceInIdleStateStaysIdle() {
        let frame = createSilenceFrame(at: 0.0)
        _ = stateMachine.processFrame(frame)

        let state = stateMachine.getState()
        if case .idle = state {
            // Expected
        } else {
            XCTFail("Should remain idle after silence frame")
        }

        XCTAssertNil(stateMachine.getCurrentSegment())
    }

    func testSpeechToSilenceTransition() {
        // Start speech
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.0))

        // Brief silence
        _ = stateMachine.processFrame(createSilenceFrame(at: 0.032))

        let state = stateMachine.getState()
        if case .inSilence = state {
            // Expected
        } else {
            XCTFail("Should transition to inSilence after silence during speech")
        }
    }

    func testSpeechResumesFromSilence() {
        // Start speech
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.0))

        // Brief silence
        _ = stateMachine.processFrame(createSilenceFrame(at: 0.032))

        // Resume speech
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.064))

        let state = stateMachine.getState()
        if case .inSpeech = state {
            // Expected
        } else {
            XCTFail("Should return to inSpeech when speech resumes")
        }
    }

    // MARK: - Segment Completion Tests

    func testSegmentCompletesAfterSufficientSilence() {
        let frameDuration = 0.032

        // Start speech at t=0
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.0, duration: frameDuration))

        // Continue speech until we have enough duration (0.3s min)
        var t = frameDuration
        while t < 0.35 {  // A bit more than minSpeechDuration
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        let speechEndTime = t

        // Now add silence frames until segment completes (0.3s min silence)
        var completedSegment: SpeechSegment? = nil
        while completedSegment == nil && t < speechEndTime + 0.5 {
            completedSegment = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        XCTAssertNotNil(completedSegment, "Segment should complete after sufficient silence")
        XCTAssertTrue(completedSegment!.isFinal)
        XCTAssertGreaterThanOrEqual(completedSegment!.duration, config.minSpeechDuration)
    }

    func testShortSpeechIsDiscarded() {
        let frameDuration = 0.032

        // Very short speech (less than minSpeechDuration)
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.0, duration: frameDuration))
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.032, duration: frameDuration))
        // Only ~64ms of speech

        // Long silence
        var t = 0.064
        var completedSegment: SpeechSegment? = nil
        while t < 0.5 {
            completedSegment = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Short speech should be discarded
        XCTAssertNil(completedSegment, "Short speech segments should be discarded")
        XCTAssertTrue(stateMachine.getCompletedSegments().isEmpty)
    }

    // MARK: - Segment Properties Tests

    func testSegmentTimingIsCorrect() {
        let frameDuration = 0.032
        let speechStartTime = 0.5

        // Start speech
        _ = stateMachine.processFrame(createSpeechFrame(at: speechStartTime, duration: frameDuration))

        // Continue speech
        var t = speechStartTime + frameDuration
        while t < speechStartTime + 0.4 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        let expectedSpeechEndTime = t

        // Add silence to complete segment
        var completedSegment: SpeechSegment? = nil
        while completedSegment == nil && t < expectedSpeechEndTime + 0.5 {
            completedSegment = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        XCTAssertNotNil(completedSegment)
        XCTAssertEqual(completedSegment!.startTime, speechStartTime, accuracy: 0.001)
    }

    func testSegmentExtendsDuringSpeech() {
        let frameDuration = 0.032

        // Start speech
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.0, duration: frameDuration))

        var currentSegment = stateMachine.getCurrentSegment()
        let initialEndTime = currentSegment?.endTime ?? 0

        // Continue speech
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.032, duration: frameDuration))

        currentSegment = stateMachine.getCurrentSegment()
        XCTAssertGreaterThan(currentSegment?.endTime ?? 0, initialEndTime)
    }

    // MARK: - Finalize Tests

    func testFinalizeCompletesInProgressSegment() {
        let frameDuration = 0.032

        // Start speech and continue for a while
        var t = 0.0
        while t < 0.4 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Finalize
        let finalSegment = stateMachine.finalize(at: t)

        XCTAssertNotNil(finalSegment)
        XCTAssertTrue(finalSegment!.isFinal)
    }

    func testFinalizeWhileIdleReturnsNil() {
        let segment = stateMachine.finalize(at: 1.0)
        XCTAssertNil(segment)
    }

    func testFinalizeShortSegmentReturnsNil() {
        let frameDuration = 0.032

        // Very short speech
        _ = stateMachine.processFrame(createSpeechFrame(at: 0.0, duration: frameDuration))

        let segment = stateMachine.finalize(at: 0.032)
        XCTAssertNil(segment, "Finalizing short segment should return nil")
    }

    func testFinalizeResetsState() {
        let frameDuration = 0.032

        // Build up speech
        var t = 0.0
        while t < 0.4 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        _ = stateMachine.finalize(at: t)

        let state = stateMachine.getState()
        if case .idle = state {
            // Expected
        } else {
            XCTFail("State should be idle after finalize")
        }

        XCTAssertNil(stateMachine.getCurrentSegment())
    }

    // MARK: - Reset Tests

    func testResetClearsEverything() {
        let frameDuration = 0.032

        // Process some speech
        for i in 0..<15 {
            let t = Double(i) * frameDuration
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
        }

        // Add silence to complete segment
        for i in 15..<30 {
            let t = Double(i) * frameDuration
            _ = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
        }

        // Should have at least one completed segment
        XCTAssertFalse(stateMachine.getCompletedSegments().isEmpty)

        // Reset
        stateMachine.reset()

        // Everything should be cleared
        XCTAssertTrue(stateMachine.getCompletedSegments().isEmpty)
        XCTAssertNil(stateMachine.getCurrentSegment())

        let state = stateMachine.getState()
        if case .idle = state {
            // Expected
        } else {
            XCTFail("State should be idle after reset")
        }
    }

    // MARK: - Multiple Segments Tests

    func testMultipleSegmentsAreTracked() {
        let frameDuration = 0.032

        // First segment
        var t = 0.0
        while t < 0.4 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Silence to complete first segment
        while t < 0.8 {
            _ = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Second segment
        while t < 1.2 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Silence to complete second segment
        while t < 1.6 {
            _ = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        let segments = stateMachine.getCompletedSegments()
        XCTAssertEqual(segments.count, 2, "Should have two completed segments")
    }

    // MARK: - Edge Cases

    func testRapidSpeechSilenceAlternation() {
        let frameDuration = 0.032

        // Rapid alternation (should not create segments due to short durations)
        for i in 0..<20 {
            let t = Double(i) * frameDuration
            if i % 2 == 0 {
                _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            } else {
                _ = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            }
        }

        // Should not have completed any segments (all too short)
        XCTAssertTrue(stateMachine.getCompletedSegments().isEmpty)
    }

    func testBriefSilenceInterruptionDoesNotSplitSegment() {
        let frameDuration = 0.032

        // Speech
        var t = 0.0
        while t < 0.2 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Brief silence (less than minSilenceDuration)
        while t < 0.3 {
            _ = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // More speech
        while t < 0.5 {
            _ = stateMachine.processFrame(createSpeechFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        // Long silence to complete
        while t < 0.9 {
            _ = stateMachine.processFrame(createSilenceFrame(at: t, duration: frameDuration))
            t += frameDuration
        }

        let segments = stateMachine.getCompletedSegments()
        XCTAssertEqual(segments.count, 1, "Brief silence should not split segment")
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAccess() {
        let expectation = XCTestExpectation(description: "Concurrent access")
        let iterations = 100

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let t = Double(i) * 0.01
            if i % 3 == 0 {
                _ = self.stateMachine.processFrame(self.createSpeechFrame(at: t))
            } else if i % 3 == 1 {
                _ = self.stateMachine.processFrame(self.createSilenceFrame(at: t))
            } else {
                _ = self.stateMachine.getCompletedSegments()
                _ = self.stateMachine.getCurrentSegment()
                _ = self.stateMachine.getState()
            }
        }

        // If we get here without crashing, thread safety is working
        expectation.fulfill()
        wait(for: [expectation], timeout: 5.0)
    }
}
