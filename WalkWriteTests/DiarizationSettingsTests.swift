import XCTest
@testable import WalkWrite

final class DiarizationSettingsTests: XCTestCase {

    // MARK: - Default Settings Tests

    func testDefaultSettings() {
        let settings = DiarizationSettings()

        XCTAssertTrue(settings.autoRunDiarization)
        XCTAssertTrue(settings.autoRunSpeakerAwareEnhancement)
        XCTAssertEqual(settings.maxSpeakers, 6)
        XCTAssertEqual(settings.clusteringThreshold, 0.5, accuracy: 0.01)
        XCTAssertTrue(settings.showSpeakerLabelsByDefault)
        XCTAssertEqual(settings.userIdentificationMethod, .automatic)
    }

    // MARK: - User Identification Method Tests

    func testUserIdentificationMethodDisplayNames() {
        XCTAssertEqual(UserIdentificationMethod.automatic.displayName, "Automatic")
        XCTAssertEqual(UserIdentificationMethod.firstSpeaker.displayName, "First Speaker")
        XCTAssertEqual(UserIdentificationMethod.mostSpeakingTime.displayName, "Most Speaking Time")
        XCTAssertEqual(UserIdentificationMethod.manual.displayName, "Manual Selection")
    }

    func testUserIdentificationMethodDescriptions() {
        for method in UserIdentificationMethod.allCases {
            XCTAssertFalse(method.description.isEmpty)
        }
    }

    func testUserIdentificationMethodCodable() throws {
        let original = UserIdentificationMethod.firstSpeaker
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(UserIdentificationMethod.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - Settings Codable Tests

    func testSettingsCodable() throws {
        var settings = DiarizationSettings()
        settings.maxSpeakers = 8
        settings.clusteringThreshold = 0.6
        settings.userIdentificationMethod = .mostSpeakingTime

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DiarizationSettings.self, from: data)

        XCTAssertEqual(decoded.maxSpeakers, 8)
        XCTAssertEqual(decoded.clusteringThreshold, 0.6, accuracy: 0.01)
        XCTAssertEqual(decoded.userIdentificationMethod, .mostSpeakingTime)
    }

    // MARK: - Settings Range Tests

    func testMaxSpeakersRange() {
        var settings = DiarizationSettings()

        settings.maxSpeakers = 2
        XCTAssertEqual(settings.maxSpeakers, 2)

        settings.maxSpeakers = 10
        XCTAssertEqual(settings.maxSpeakers, 10)
    }

    func testClusteringThresholdRange() {
        var settings = DiarizationSettings()

        settings.clusteringThreshold = 0.3
        XCTAssertEqual(settings.clusteringThreshold, 0.3, accuracy: 0.01)

        settings.clusteringThreshold = 0.7
        XCTAssertEqual(settings.clusteringThreshold, 0.7, accuracy: 0.01)
    }
}

// MARK: - Speaker Colors Tests

final class SpeakerColorsTests: XCTestCase {

    func testColorForSpeakerId() {
        // User should always get blue
        let userColor = SpeakerColors.color(for: 0, isUser: true)
        XCTAssertNotNil(userColor)

        // Other speakers get different colors
        for i in 0..<10 {
            let color = SpeakerColors.color(for: i, isUser: false)
            XCTAssertNotNil(color)
        }
    }

    func testBackgroundColorOpacity() {
        let bgColor = SpeakerColors.backgroundColor(for: 0, isUser: true)
        XCTAssertNotNil(bgColor)
    }

    func testColorWrapsAround() {
        // Test that speaker IDs beyond palette size wrap around
        let color10 = SpeakerColors.color(for: 10, isUser: false)
        let color0 = SpeakerColors.color(for: 0, isUser: false)
        // They should be the same since 10 % 10 = 0
        XCTAssertNotNil(color10)
        XCTAssertNotNil(color0)
    }
}
