import XCTest
@testable import WalkWrite

final class SpeakerEmbeddingTests: XCTestCase {

    var embeddingEngine: AcousticSpeakerEmbedding!
    let sampleRate: Double = 16000.0

    override func setUp() {
        super.setUp()
        embeddingEngine = AcousticSpeakerEmbedding()
    }

    override func tearDown() {
        embeddingEngine = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Generate a sine wave with harmonics (voice-like)
    private func generateVoiceLike(
        fundamentalFreq: Float,
        duration: TimeInterval,
        amplitude: Float = 0.3
    ) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        return (0..<sampleCount).map { i in
            let t = Float(i) / Float(sampleRate)
            let f1 = amplitude * sin(2 * .pi * fundamentalFreq * t)
            let f2 = (amplitude * 0.5) * sin(2 * .pi * (fundamentalFreq * 2) * t)
            let f3 = (amplitude * 0.25) * sin(2 * .pi * (fundamentalFreq * 3) * t)
            return f1 + f2 + f3
        }
    }

    /// Generate white noise
    private func generateNoise(duration: TimeInterval, amplitude: Float = 0.1) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        return (0..<sampleCount).map { _ in Float.random(in: -amplitude...amplitude) }
    }

    /// Generate silence
    private func generateSilence(duration: TimeInterval) -> [Float] {
        let sampleCount = Int(duration * sampleRate)
        return [Float](repeating: 0, count: sampleCount)
    }

    // MARK: - Basic Extraction Tests

    func testEmbeddingDimension() {
        XCTAssertEqual(embeddingEngine.embeddingDimension, 64)
    }

    func testExtractEmbeddingFromVoice() {
        let samples = generateVoiceLike(fundamentalFreq: 150, duration: 1.5)
        let embedding = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)

        XCTAssertEqual(embedding.count, 64)
        XCTAssertFalse(embedding.allSatisfy { $0 == 0 }, "Embedding should not be all zeros")
    }

    func testExtractEmbeddingFromNoise() {
        let samples = generateNoise(duration: 1.5)
        let embedding = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)

        XCTAssertEqual(embedding.count, 64)
    }

    func testExtractEmbeddingFromSilence() {
        let samples = generateSilence(duration: 1.5)
        let embedding = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)

        XCTAssertEqual(embedding.count, 64)
    }

    func testExtractEmbeddingShortAudio() {
        let samples = generateVoiceLike(fundamentalFreq: 150, duration: 0.1)
        let embedding = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)

        XCTAssertEqual(embedding.count, 64)
    }

    func testExtractEmbeddingEmptyAudio() {
        let embedding = embeddingEngine.extractEmbedding(from: [], sampleRate: sampleRate)

        XCTAssertEqual(embedding.count, 64)
        XCTAssertTrue(embedding.allSatisfy { $0 == 0 }, "Empty audio should produce zero embedding")
    }

    // MARK: - Normalization Tests

    func testEmbeddingIsNormalized() {
        let samples = generateVoiceLike(fundamentalFreq: 200, duration: 1.5)
        let embedding = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)

        // Check L2 norm is approximately 1
        let norm = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        XCTAssertEqual(norm, 1.0, accuracy: 0.01, "Embedding should be L2 normalized")
    }

    // MARK: - Consistency Tests

    func testSameAudioProducesSameEmbedding() {
        let samples = generateVoiceLike(fundamentalFreq: 150, duration: 1.5)

        let embedding1 = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)
        let embedding2 = embeddingEngine.extractEmbedding(from: samples, sampleRate: sampleRate)

        // Should be identical
        for i in 0..<embedding1.count {
            XCTAssertEqual(embedding1[i], embedding2[i], accuracy: 0.0001)
        }
    }

    func testDifferentPitchProducesDifferentEmbedding() {
        let lowPitch = generateVoiceLike(fundamentalFreq: 100, duration: 1.5)
        let highPitch = generateVoiceLike(fundamentalFreq: 300, duration: 1.5)

        let embedding1 = embeddingEngine.extractEmbedding(from: lowPitch, sampleRate: sampleRate)
        let embedding2 = embeddingEngine.extractEmbedding(from: highPitch, sampleRate: sampleRate)

        // Should be different
        var differences = 0
        for i in 0..<embedding1.count {
            if abs(embedding1[i] - embedding2[i]) > 0.01 {
                differences += 1
            }
        }

        XCTAssertGreaterThan(differences, 10, "Different pitches should produce different embeddings")
    }

    // MARK: - Batch Extraction Tests

    func testBatchExtraction() {
        let segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)] = [
            (generateVoiceLike(fundamentalFreq: 150, duration: 1.0), 0.0, 1.0),
            (generateVoiceLike(fundamentalFreq: 200, duration: 1.0), 1.5, 1.0),
            (generateVoiceLike(fundamentalFreq: 150, duration: 1.0), 3.0, 1.0)
        ]

        let embeddings = embeddingEngine.batchExtract(segments: segments, sampleRate: sampleRate)

        XCTAssertEqual(embeddings.count, 3)

        // Check timestamps
        XCTAssertEqual(embeddings[0].timestamp, 0.0)
        XCTAssertEqual(embeddings[1].timestamp, 1.5)
        XCTAssertEqual(embeddings[2].timestamp, 3.0)

        // Check durations
        XCTAssertEqual(embeddings[0].duration, 1.0)
        XCTAssertEqual(embeddings[1].duration, 1.0)
        XCTAssertEqual(embeddings[2].duration, 1.0)

        // All should have correct dimension
        for emb in embeddings {
            XCTAssertEqual(emb.features.count, 64)
        }
    }

    func testBatchExtractionEmpty() {
        let embeddings = embeddingEngine.batchExtract(segments: [], sampleRate: sampleRate)
        XCTAssertTrue(embeddings.isEmpty)
    }

    // MARK: - Speaker Embedding Struct Tests

    func testSpeakerEmbeddingInit() {
        let features = [Float](repeating: 0.1, count: 64)
        let embedding = SpeakerEmbedding(features: features, timestamp: 1.5, duration: 1.0)

        XCTAssertEqual(embedding.features.count, 64)
        XCTAssertEqual(embedding.timestamp, 1.5)
        XCTAssertEqual(embedding.duration, 1.0)
        XCTAssertEqual(embedding.dimension, 64)
    }

    func testSpeakerEmbeddingCodable() throws {
        let features = [Float](repeating: 0.1, count: 64)
        let original = SpeakerEmbedding(features: features, timestamp: 1.5, duration: 1.0)

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpeakerEmbedding.self, from: encoded)

        XCTAssertEqual(decoded.features.count, original.features.count)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.duration, original.duration)
    }
}

// MARK: - Diarization Config Tests

final class DiarizationConfigTests: XCTestCase {

    func testDefaultConfig() {
        let config = DiarizationConfig.default

        XCTAssertEqual(config.windowSize, 1.5)
        XCTAssertEqual(config.windowStep, 0.75)
        XCTAssertEqual(config.minSegmentDuration, 0.5)
        XCTAssertEqual(config.maxSpeakers, 10)
        XCTAssertEqual(config.sampleRate, 16000.0)
    }

    func testFewSpeakersConfig() {
        let config = DiarizationConfig.fewSpeakers

        XCTAssertGreaterThan(config.windowSize, DiarizationConfig.default.windowSize)
        XCTAssertLessThan(config.maxSpeakers, DiarizationConfig.default.maxSpeakers)
    }

    func testManySpeakersConfig() {
        let config = DiarizationConfig.manySpeakers

        XCTAssertLessThan(config.windowSize, DiarizationConfig.default.windowSize)
        XCTAssertGreaterThan(config.maxSpeakers, DiarizationConfig.default.maxSpeakers)
    }

    func testCustomConfig() {
        let config = DiarizationConfig(
            windowSize: 2.0,
            windowStep: 1.0,
            minSegmentDuration: 0.3,
            maxSpeakers: 5,
            clusteringThreshold: 0.5,
            sampleRate: 22050.0
        )

        XCTAssertEqual(config.windowSize, 2.0)
        XCTAssertEqual(config.windowStep, 1.0)
        XCTAssertEqual(config.minSegmentDuration, 0.3)
        XCTAssertEqual(config.maxSpeakers, 5)
        XCTAssertEqual(config.clusteringThreshold, 0.5)
        XCTAssertEqual(config.sampleRate, 22050.0)
    }

    func testConfigCodable() throws {
        let original = DiarizationConfig(
            windowSize: 1.8,
            windowStep: 0.9,
            maxSpeakers: 6
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DiarizationConfig.self, from: encoded)

        XCTAssertEqual(decoded.windowSize, original.windowSize)
        XCTAssertEqual(decoded.windowStep, original.windowStep)
        XCTAssertEqual(decoded.maxSpeakers, original.maxSpeakers)
    }
}
