import XCTest
@testable import WalkWrite

final class AudioSegmentManagerTests: XCTestCase {

    var manager: AudioSegmentManager!
    let sampleRate: Double = 16000.0

    override func setUp() {
        super.setUp()
        manager = AudioSegmentManager(sampleRate: sampleRate)
        manager.startSession()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func generateSamples(duration: TimeInterval, value: Float = 0.5) -> [Float] {
        let count = Int(duration * sampleRate)
        return [Float](repeating: value, count: count)
    }

    private func generateSineWave(duration: TimeInterval, frequency: Float = 440) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { i in
            let t = Float(i) / Float(sampleRate)
            return 0.5 * sin(2 * .pi * frequency * t)
        }
    }

    // MARK: - Session Management Tests

    func testStartSessionClearsState() {
        // Add some samples
        manager.addSamples(generateSamples(duration: 1.0), timestamp: 0)

        // Extract a segment
        let segment = SpeechSegment(startTime: 0, endTime: 0.5, isFinal: true)
        manager.extractSegment(segment)

        // Start new session
        manager.startSession()

        // Should be cleared
        XCTAssertTrue(manager.getSpeechSegments().isEmpty)
        XCTAssertTrue(manager.getTimeMappings().isEmpty)

        let stats = manager.getStats()
        XCTAssertEqual(stats.speechDuration, 0)
        XCTAssertEqual(stats.segmentCount, 0)
    }

    // MARK: - Sample Addition Tests

    func testAddSamplesUpdatesBuffer() {
        let samples = generateSamples(duration: 0.5)
        manager.addSamples(samples, timestamp: 0)

        // Adding more samples
        let moreSamples = generateSamples(duration: 0.5)
        manager.addSamples(moreSamples, timestamp: 0.5)

        // Should be able to extract a segment covering both
        let segment = SpeechSegment(startTime: 0, endTime: 1.0, isFinal: true)
        let success = manager.extractSegment(segment)

        XCTAssertTrue(success)
    }

    func testBufferTrimsOldSamples() {
        // Add 6 seconds of audio (buffer keeps 5 seconds max)
        for i in 0..<12 {
            let timestamp = Double(i) * 0.5
            manager.addSamples(generateSamples(duration: 0.5), timestamp: timestamp)
        }

        // Trying to extract a segment from the beginning should fail
        let oldSegment = SpeechSegment(startTime: 0, endTime: 0.5, isFinal: true)
        let success = manager.extractSegment(oldSegment)

        XCTAssertFalse(success, "Old segment should fail to extract")
    }

    // MARK: - Segment Extraction Tests

    func testExtractSegmentSuccess() {
        let samples = generateSamples(duration: 2.0)
        manager.addSamples(samples, timestamp: 0)

        let segment = SpeechSegment(startTime: 0.5, endTime: 1.5, isFinal: true)
        let success = manager.extractSegment(segment)

        XCTAssertTrue(success)
        XCTAssertEqual(manager.getSpeechSegments().count, 1)
    }

    func testExtractSegmentFailsForFutureSegment() {
        let samples = generateSamples(duration: 1.0)
        manager.addSamples(samples, timestamp: 0)

        let futureSegment = SpeechSegment(startTime: 2.0, endTime: 3.0, isFinal: true)
        let success = manager.extractSegment(futureSegment)

        XCTAssertFalse(success)
    }

    func testMultipleSegmentExtraction() {
        // Add audio
        manager.addSamples(generateSamples(duration: 3.0), timestamp: 0)

        // Extract multiple segments
        let segment1 = SpeechSegment(startTime: 0, endTime: 0.5, isFinal: true)
        let segment2 = SpeechSegment(startTime: 1.0, endTime: 1.5, isFinal: true)
        let segment3 = SpeechSegment(startTime: 2.0, endTime: 2.5, isFinal: true)

        XCTAssertTrue(manager.extractSegment(segment1))
        XCTAssertTrue(manager.extractSegment(segment2))
        XCTAssertTrue(manager.extractSegment(segment3))

        XCTAssertEqual(manager.getSpeechSegments().count, 3)
    }

    // MARK: - Statistics Tests

    func testStatsReflectExtractedSegments() {
        manager.addSamples(generateSamples(duration: 2.0), timestamp: 0)

        let segment1 = SpeechSegment(startTime: 0, endTime: 0.5, isFinal: true)
        let segment2 = SpeechSegment(startTime: 1.0, endTime: 1.3, isFinal: true)

        manager.extractSegment(segment1)
        manager.extractSegment(segment2)

        let stats = manager.getStats()

        XCTAssertEqual(stats.segmentCount, 2)
        XCTAssertEqual(stats.speechDuration, 0.8, accuracy: 0.01)  // 0.5 + 0.3
    }

    func testSpeechPercentageCalculation() {
        // Add 2 seconds of audio
        manager.addSamples(generateSamples(duration: 2.0), timestamp: 0)

        // Extract 1 second of speech
        let segment = SpeechSegment(startTime: 0.5, endTime: 1.5, isFinal: true)
        manager.extractSegment(segment)

        let stats = manager.getStats()

        // Speech percentage should be around 50%
        XCTAssertEqual(stats.speechPercentage, 50.0, accuracy: 5.0)
    }

    // MARK: - Time Mapping Tests

    func testTimeMappingCreatedOnExtraction() {
        manager.addSamples(generateSamples(duration: 2.0), timestamp: 0)

        let segment = SpeechSegment(startTime: 0.5, endTime: 1.0, isFinal: true)
        manager.extractSegment(segment)

        let mappings = manager.getTimeMappings()

        XCTAssertEqual(mappings.count, 1)

        let mapping = mappings[0]
        XCTAssertEqual(mapping.originalRange.lowerBound, 0.5, accuracy: 0.001)
        XCTAssertEqual(mapping.originalRange.upperBound, 1.0, accuracy: 0.001)
        XCTAssertEqual(mapping.concatenatedRange.lowerBound, 0.0, accuracy: 0.001)
        XCTAssertEqual(mapping.concatenatedRange.upperBound, 0.5, accuracy: 0.001)
    }

    func testMultipleTimeMappings() {
        manager.addSamples(generateSamples(duration: 3.0), timestamp: 0)

        // First segment: 0.5-1.0 (0.5s) -> concatenated 0-0.5
        let segment1 = SpeechSegment(startTime: 0.5, endTime: 1.0, isFinal: true)
        manager.extractSegment(segment1)

        // Second segment: 2.0-2.5 (0.5s) -> concatenated 0.5-1.0
        let segment2 = SpeechSegment(startTime: 2.0, endTime: 2.5, isFinal: true)
        manager.extractSegment(segment2)

        let mappings = manager.getTimeMappings()

        XCTAssertEqual(mappings.count, 2)

        // Second mapping should start where first ended
        XCTAssertEqual(mappings[1].concatenatedRange.lowerBound, 0.5, accuracy: 0.01)
    }

    // MARK: - Time Conversion Tests

    func testOriginalToConcatenatedTime() {
        manager.addSamples(generateSamples(duration: 3.0), timestamp: 0)

        // Segment from 1.0 to 2.0 -> concatenated 0-1.0
        let segment = SpeechSegment(startTime: 1.0, endTime: 2.0, isFinal: true)
        manager.extractSegment(segment)

        // Original time 1.5 should map to concatenated time 0.5
        let concatenatedTime = manager.originalToConcatenatedTime(1.5)
        XCTAssertNotNil(concatenatedTime)
        XCTAssertEqual(concatenatedTime!, 0.5, accuracy: 0.01)
    }

    func testOriginalToConcatenatedTimeOutsideSegment() {
        manager.addSamples(generateSamples(duration: 3.0), timestamp: 0)

        let segment = SpeechSegment(startTime: 1.0, endTime: 2.0, isFinal: true)
        manager.extractSegment(segment)

        // Time outside any segment should return nil
        let result = manager.originalToConcatenatedTime(0.5)
        XCTAssertNil(result)
    }

    func testConcatenatedToOriginalTime() {
        manager.addSamples(generateSamples(duration: 3.0), timestamp: 0)

        // Segment from 1.0 to 2.0 -> concatenated 0-1.0
        let segment = SpeechSegment(startTime: 1.0, endTime: 2.0, isFinal: true)
        manager.extractSegment(segment)

        // Concatenated time 0.5 should map to original time 1.5
        let originalTime = manager.concatenatedToOriginalTime(0.5)
        XCTAssertNotNil(originalTime)
        XCTAssertEqual(originalTime!, 1.5, accuracy: 0.01)
    }

    // MARK: - Concatenated Samples Tests

    func testGetConcatenatedSamples() {
        // Generate distinct samples for each segment
        let samples1 = [Float](repeating: 0.3, count: Int(0.5 * sampleRate))
        let samples2 = [Float](repeating: 0.7, count: Int(0.5 * sampleRate))

        // Add first batch
        manager.addSamples(samples1 + samples2, timestamp: 0)

        // Extract first segment (samples1)
        let segment1 = SpeechSegment(startTime: 0, endTime: 0.5, isFinal: true)
        manager.extractSegment(segment1)

        // Extract second segment (samples2)
        let segment2 = SpeechSegment(startTime: 0.5, endTime: 1.0, isFinal: true)
        manager.extractSegment(segment2)

        let concatenated = manager.getConcatenatedSamples()

        // Should have both segments concatenated
        let expectedCount = Int(1.0 * sampleRate)
        XCTAssertEqual(concatenated.count, expectedCount)

        // Check values from first segment
        XCTAssertEqual(concatenated[0], 0.3, accuracy: 0.01)

        // Check values from second segment
        XCTAssertEqual(concatenated[Int(0.5 * sampleRate)], 0.7, accuracy: 0.01)
    }

    // MARK: - WAV Export Tests

    func testExportToWAV() throws {
        // Add audio with actual waveform
        let samples = generateSineWave(duration: 1.0)
        manager.addSamples(samples, timestamp: 0)

        // Extract segment
        let segment = SpeechSegment(startTime: 0, endTime: 1.0, isFinal: true)
        manager.extractSegment(segment)

        // Export
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export.wav")

        try manager.exportToWAV(url: tempURL)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))

        // Verify file is not empty
        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(fileSize, 44)  // At least WAV header size

        // Clean up
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportEmptyThrowsError() {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_empty.wav")

        // Try to export without any segments
        XCTAssertThrowsError(try manager.exportToWAV(url: tempURL)) { error in
            XCTAssertTrue(error is AudioSegmentError)
            if case AudioSegmentError.noSpeechDetected = error {
                // Expected
            } else {
                XCTFail("Expected noSpeechDetected error")
            }
        }
    }

    // MARK: - Edge Cases

    func testVeryShortSegment() {
        let samples = generateSamples(duration: 0.1)
        manager.addSamples(samples, timestamp: 0)

        // Very short segment (16ms)
        let segment = SpeechSegment(startTime: 0, endTime: 0.016, isFinal: true)
        let success = manager.extractSegment(segment)

        XCTAssertTrue(success)

        let concatenated = manager.getConcatenatedSamples()
        XCTAssertEqual(concatenated.count, Int(0.016 * sampleRate))
    }

    func testOverlappingSegments() {
        manager.addSamples(generateSamples(duration: 2.0), timestamp: 0)

        // Extract overlapping segments (shouldn't happen in practice, but test it)
        let segment1 = SpeechSegment(startTime: 0, endTime: 1.0, isFinal: true)
        let segment2 = SpeechSegment(startTime: 0.5, endTime: 1.5, isFinal: true)

        XCTAssertTrue(manager.extractSegment(segment1))
        XCTAssertTrue(manager.extractSegment(segment2))

        // Both should be stored
        XCTAssertEqual(manager.getSpeechSegments().count, 2)
    }

    // MARK: - Thread Safety Tests

    func testConcurrentAddAndExtract() {
        let expectation = XCTestExpectation(description: "Concurrent operations")
        let iterations = 50

        // Pre-fill buffer
        manager.addSamples(generateSamples(duration: 5.0), timestamp: 0)

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            if i % 2 == 0 {
                // Add samples
                let timestamp = 5.0 + Double(i) * 0.1
                self.manager.addSamples(self.generateSamples(duration: 0.1), timestamp: timestamp)
            } else {
                // Extract segment
                let start = Double(i % 5) * 0.5
                let segment = SpeechSegment(startTime: start, endTime: start + 0.3, isFinal: true)
                _ = self.manager.extractSegment(segment)
            }
        }

        expectation.fulfill()
        wait(for: [expectation], timeout: 5.0)
    }
}
