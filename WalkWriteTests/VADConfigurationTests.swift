import XCTest
@testable import WalkWrite

final class VADConfigurationTests: XCTestCase {

    // MARK: - Default Configuration Tests

    func testDefaultConfiguration() {
        let config = VADConfiguration.default

        XCTAssertEqual(config.speechThreshold, 0.5)
        XCTAssertEqual(config.silenceThreshold, 0.35)
        XCTAssertEqual(config.minSpeechDuration, 0.25)
        XCTAssertEqual(config.minSilenceDuration, 0.3)
        XCTAssertEqual(config.windowSizeSamples, 512)
        XCTAssertEqual(config.windowStepSamples, 256)
    }

    func testAggressiveConfiguration() {
        let config = VADConfiguration.aggressive

        // Aggressive should have higher thresholds
        XCTAssertGreaterThan(config.speechThreshold, VADConfiguration.default.speechThreshold)
        XCTAssertGreaterThan(config.silenceThreshold, VADConfiguration.default.silenceThreshold)
        XCTAssertGreaterThanOrEqual(config.minSpeechDuration, VADConfiguration.default.minSpeechDuration)
        XCTAssertGreaterThan(config.minSilenceDuration, VADConfiguration.default.minSilenceDuration)
    }

    func testPermissiveConfiguration() {
        let config = VADConfiguration.permissive

        // Permissive should have lower thresholds
        XCTAssertLessThan(config.speechThreshold, VADConfiguration.default.speechThreshold)
        XCTAssertLessThan(config.silenceThreshold, VADConfiguration.default.silenceThreshold)
        XCTAssertLessThan(config.minSpeechDuration, VADConfiguration.default.minSpeechDuration)
        XCTAssertLessThan(config.minSilenceDuration, VADConfiguration.default.minSilenceDuration)
    }

    func testCustomConfiguration() {
        let config = VADConfiguration(
            speechThreshold: 0.7,
            silenceThreshold: 0.5,
            minSpeechDuration: 0.5,
            minSilenceDuration: 1.0,
            windowSizeSamples: 1024,
            windowStepSamples: 512
        )

        XCTAssertEqual(config.speechThreshold, 0.7)
        XCTAssertEqual(config.silenceThreshold, 0.5)
        XCTAssertEqual(config.minSpeechDuration, 0.5)
        XCTAssertEqual(config.minSilenceDuration, 1.0)
        XCTAssertEqual(config.windowSizeSamples, 1024)
        XCTAssertEqual(config.windowStepSamples, 512)
    }

    // MARK: - Threshold Invariants

    func testThresholdInvariantsDefault() {
        let config = VADConfiguration.default
        // Silence threshold should be less than speech threshold
        XCTAssertLessThan(config.silenceThreshold, config.speechThreshold)
    }

    func testThresholdInvariantsAggressive() {
        let config = VADConfiguration.aggressive
        XCTAssertLessThan(config.silenceThreshold, config.speechThreshold)
    }

    func testThresholdInvariantsPermissive() {
        let config = VADConfiguration.permissive
        XCTAssertLessThan(config.silenceThreshold, config.speechThreshold)
    }

    // MARK: - Codable Tests

    func testConfigurationCodable() throws {
        let original = VADConfiguration(
            speechThreshold: 0.6,
            silenceThreshold: 0.4,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            windowSizeSamples: 768,
            windowStepSamples: 384
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VADConfiguration.self, from: encoded)

        XCTAssertEqual(decoded.speechThreshold, original.speechThreshold)
        XCTAssertEqual(decoded.silenceThreshold, original.silenceThreshold)
        XCTAssertEqual(decoded.minSpeechDuration, original.minSpeechDuration)
        XCTAssertEqual(decoded.minSilenceDuration, original.minSilenceDuration)
        XCTAssertEqual(decoded.windowSizeSamples, original.windowSizeSamples)
        XCTAssertEqual(decoded.windowStepSamples, original.windowStepSamples)
    }
}
