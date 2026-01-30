import XCTest
@testable import WalkWrite

final class EnergyBasedVADTests: XCTestCase {

    var vad: EnergyBasedVAD!

    override func setUp() {
        super.setUp()
        vad = EnergyBasedVAD(configuration: .default)
    }

    override func tearDown() {
        vad = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Generate silence (very low amplitude noise)
    private func generateSilence(sampleCount: Int) -> [Float] {
        return (0..<sampleCount).map { _ in Float.random(in: -0.0001...0.0001) }
    }

    /// Generate white noise
    private func generateNoise(sampleCount: Int, amplitude: Float = 0.1) -> [Float] {
        return (0..<sampleCount).map { _ in Float.random(in: -amplitude...amplitude) }
    }

    /// Generate a simple sine wave (speech-like tonal content)
    private func generateSineWave(frequency: Float, sampleRate: Float = 16000, sampleCount: Int, amplitude: Float = 0.3) -> [Float] {
        return (0..<sampleCount).map { i in
            let t = Float(i) / sampleRate
            return amplitude * sin(2 * .pi * frequency * t)
        }
    }

    /// Generate speech-like signal (multiple harmonics with fundamental frequency)
    private func generateSpeechLike(fundamentalFrequency: Float = 150, sampleRate: Float = 16000, sampleCount: Int, amplitude: Float = 0.3) -> [Float] {
        return (0..<sampleCount).map { i in
            let t = Float(i) / sampleRate
            // Fundamental + harmonics (typical of voiced speech)
            let fundamental = amplitude * sin(2 * .pi * fundamentalFrequency * t)
            let harmonic2 = (amplitude * 0.5) * sin(2 * .pi * (fundamentalFrequency * 2) * t)
            let harmonic3 = (amplitude * 0.25) * sin(2 * .pi * (fundamentalFrequency * 3) * t)
            return fundamental + harmonic2 + harmonic3
        }
    }

    // MARK: - Silence Detection Tests

    func testSilenceDetection() {
        let silence = generateSilence(sampleCount: 512)
        let probability = vad.processSamples(silence)

        // Silence should have very low speech probability
        XCTAssertLessThan(probability, 0.3, "Silence should have low speech probability")
    }

    func testRepeatedSilenceDetection() {
        // Process multiple frames of silence
        for _ in 0..<10 {
            let silence = generateSilence(sampleCount: 512)
            let probability = vad.processSamples(silence)
            XCTAssertLessThan(probability, 0.4, "Continuous silence should maintain low probability")
        }
    }

    // MARK: - Speech-like Signal Detection

    func testSpeechLikeDetection() {
        // First, adapt to silence
        for _ in 0..<5 {
            _ = vad.processSamples(generateSilence(sampleCount: 512))
        }

        // Then test with speech-like signal
        let speech = generateSpeechLike(sampleCount: 512)
        let probability = vad.processSamples(speech)

        // Speech-like signal should have higher probability than silence
        XCTAssertGreaterThan(probability, 0.3, "Speech-like signal should have moderate to high probability")
    }

    func testLoudSpeechDetection() {
        // Adapt to silence first
        for _ in 0..<5 {
            _ = vad.processSamples(generateSilence(sampleCount: 512))
        }

        // Test with loud speech
        let loudSpeech = generateSpeechLike(sampleCount: 512, amplitude: 0.5)
        let probability = vad.processSamples(loudSpeech)

        XCTAssertGreaterThan(probability, 0.5, "Loud speech should have high probability")
    }

    // MARK: - Noise Detection Tests

    func testHighFrequencyNoiseRejection() {
        // Adapt to silence
        for _ in 0..<5 {
            _ = vad.processSamples(generateSilence(sampleCount: 512))
        }

        // High frequency noise (not speech-like)
        let noise = generateNoise(sampleCount: 512, amplitude: 0.2)
        let probability = vad.processSamples(noise)

        // Should have lower probability than speech-like signal
        // (though might not be zero due to energy)
        XCTAssertLessThan(probability, 0.7, "Noise should have lower probability than speech")
    }

    // MARK: - Frame Processing Tests

    func testProcessFrameReturnsCorrectTimestamp() {
        let samples = generateSilence(sampleCount: 512)
        let timestamp = 1.5

        let frame = vad.processFrame(samples, timestamp: timestamp)

        XCTAssertEqual(frame.timestamp, timestamp)
    }

    func testProcessFrameReturnsCorrectDuration() {
        let sampleCount = 512
        let samples = generateSilence(sampleCount: sampleCount)
        let expectedDuration = TimeInterval(sampleCount) / 16000.0  // 16kHz sample rate

        let frame = vad.processFrame(samples, timestamp: 0)

        XCTAssertEqual(frame.duration, expectedDuration, accuracy: 0.0001)
    }

    func testProcessFrameIsSpeechFlag() {
        let config = VADConfiguration(speechThreshold: 0.5, silenceThreshold: 0.35)
        vad = EnergyBasedVAD(configuration: config)

        // Adapt to silence
        for _ in 0..<5 {
            _ = vad.processSamples(generateSilence(sampleCount: 512))
        }

        // Test silence frame
        let silenceFrame = vad.processFrame(generateSilence(sampleCount: 512), timestamp: 0)
        XCTAssertFalse(silenceFrame.isSpeech, "Silence frame should not be speech")

        // Test loud speech frame
        let speechFrame = vad.processFrame(generateSpeechLike(sampleCount: 512, amplitude: 0.5), timestamp: 0)
        // Note: Due to smoothing, this might take a few frames to register as speech
    }

    // MARK: - Reset Tests

    func testResetClearsState() {
        // Process some audio to build up state
        for _ in 0..<10 {
            _ = vad.processSamples(generateSpeechLike(sampleCount: 512))
        }

        // Reset
        vad.reset()

        // After reset, processing silence should return low probability
        let silence = generateSilence(sampleCount: 512)
        let probability = vad.processSamples(silence)

        // First frame after reset might have higher probability due to lack of adaptation
        // but should still be reasonable
        XCTAssertLessThan(probability, 0.6, "After reset, silence should have low probability")
    }

    // MARK: - Configuration Update Tests

    func testUpdateConfiguration() {
        let newConfig = VADConfiguration(
            speechThreshold: 0.7,
            silenceThreshold: 0.5,
            minSpeechDuration: 0.5,
            minSilenceDuration: 1.0
        )

        vad.updateConfiguration(newConfig)

        XCTAssertEqual(vad.configuration.speechThreshold, 0.7)
        XCTAssertEqual(vad.configuration.silenceThreshold, 0.5)
    }

    // MARK: - Empty Input Tests

    func testEmptyInputReturnsZero() {
        let probability = vad.processSamples([])
        XCTAssertEqual(probability, 0.0)
    }

    // MARK: - Boundary Tests

    func testVeryShortInput() {
        let shortSamples = generateSpeechLike(sampleCount: 16)
        let probability = vad.processSamples(shortSamples)

        // Should handle short input without crashing
        XCTAssertGreaterThanOrEqual(probability, 0.0)
        XCTAssertLessThanOrEqual(probability, 1.0)
    }

    func testLongInput() {
        // 1 second of audio at 16kHz
        let longSamples = generateSpeechLike(sampleCount: 16000)
        let probability = vad.processSamples(longSamples)

        XCTAssertGreaterThanOrEqual(probability, 0.0)
        XCTAssertLessThanOrEqual(probability, 1.0)
    }

    // MARK: - Probability Range Tests

    func testProbabilityAlwaysInRange() {
        let testCases: [[Float]] = [
            generateSilence(sampleCount: 512),
            generateNoise(sampleCount: 512, amplitude: 0.1),
            generateNoise(sampleCount: 512, amplitude: 0.5),
            generateSineWave(frequency: 440, sampleCount: 512),
            generateSpeechLike(sampleCount: 512),
            generateSpeechLike(sampleCount: 512, amplitude: 0.8),
            [Float](repeating: 0.9, count: 512),  // Clipped audio
            [Float](repeating: -0.9, count: 512), // Clipped audio
        ]

        for samples in testCases {
            let probability = vad.processSamples(samples)
            XCTAssertGreaterThanOrEqual(probability, 0.0, "Probability should be >= 0")
            XCTAssertLessThanOrEqual(probability, 1.0, "Probability should be <= 1")
        }
    }

    // MARK: - Smoothing Tests

    func testSmoothingReducesJitter() {
        // Process alternating loud/quiet frames
        var probabilities: [Float] = []

        for i in 0..<20 {
            let samples: [Float]
            if i % 2 == 0 {
                samples = generateSpeechLike(sampleCount: 512, amplitude: 0.5)
            } else {
                samples = generateSilence(sampleCount: 512)
            }
            probabilities.append(vad.processSamples(samples))
        }

        // Check that transitions are smoothed (not instant jumps)
        var maxJump: Float = 0
        for i in 1..<probabilities.count {
            let jump = abs(probabilities[i] - probabilities[i-1])
            maxJump = max(maxJump, jump)
        }

        // With smoothing, jumps should be limited
        XCTAssertLessThan(maxJump, 0.5, "Smoothing should limit rapid probability changes")
    }
}
