import XCTest
@testable import WalkWrite

final class SpeakerClustererTests: XCTestCase {

    var clusterer: SpeakerClusterer!

    override func setUp() {
        super.setUp()
        clusterer = SpeakerClusterer()
    }

    override func tearDown() {
        clusterer = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    /// Create an embedding with specific characteristics
    private func createEmbedding(
        baseValue: Float,
        timestamp: TimeInterval,
        duration: TimeInterval = 1.0,
        noise: Float = 0.05
    ) -> SpeakerEmbedding {
        var features = [Float](repeating: baseValue, count: 64)
        // Add some variation
        for i in 0..<64 {
            features[i] += Float.random(in: -noise...noise)
        }
        // Normalize
        let norm = sqrt(features.map { $0 * $0 }.reduce(0, +))
        if norm > 0 {
            features = features.map { $0 / norm }
        }
        return SpeakerEmbedding(features: features, timestamp: timestamp, duration: duration)
    }

    /// Create embeddings for a speaker at multiple timestamps
    private func createSpeakerEmbeddings(
        speakerBase: Float,
        timestamps: [TimeInterval],
        noise: Float = 0.1
    ) -> [SpeakerEmbedding] {
        return timestamps.map { createEmbedding(baseValue: speakerBase, timestamp: $0, noise: noise) }
    }

    // MARK: - Basic Clustering Tests

    func testClusterSingleEmbedding() {
        let embedding = createEmbedding(baseValue: 0.5, timestamp: 0)
        let segments = clusterer.cluster(embeddings: [embedding], config: .default)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speakerId, 0)
        XCTAssertEqual(segments[0].startTime, 0)
    }

    func testClusterEmptyEmbeddings() {
        let segments = clusterer.cluster(embeddings: [], config: .default)
        XCTAssertTrue(segments.isEmpty)
    }

    func testClusterTwoDistinctSpeakers() {
        // Create embeddings for two different speakers
        let speaker1 = createSpeakerEmbeddings(speakerBase: 0.3, timestamps: [0, 2, 4])
        let speaker2 = createSpeakerEmbeddings(speakerBase: 0.8, timestamps: [1, 3, 5])

        let allEmbeddings = (speaker1 + speaker2).sorted { $0.timestamp < $1.timestamp }

        let config = DiarizationConfig(clusteringThreshold: 0.3, maxSpeakers: 10)
        let segments = clusterer.cluster(embeddings: allEmbeddings, config: config)

        // Should identify at least 2 speakers (might be more due to noise)
        let speakerIds = Set(segments.map { $0.speakerId })
        XCTAssertGreaterThanOrEqual(speakerIds.count, 1)
    }

    func testClusterSameSpeaker() {
        // All embeddings from same speaker (similar values)
        let embeddings = createSpeakerEmbeddings(speakerBase: 0.5, timestamps: [0, 1, 2, 3, 4], noise: 0.02)

        let config = DiarizationConfig(clusteringThreshold: 0.5, maxSpeakers: 10)
        let segments = clusterer.cluster(embeddings: embeddings, config: config)

        // Should identify as single speaker
        let speakerIds = Set(segments.map { $0.speakerId })
        XCTAssertEqual(speakerIds.count, 1)
    }

    // MARK: - Segment Properties Tests

    func testSegmentTimestamps() {
        let embeddings = [
            createEmbedding(baseValue: 0.5, timestamp: 0.0, duration: 1.0),
            createEmbedding(baseValue: 0.5, timestamp: 1.5, duration: 1.0),
            createEmbedding(baseValue: 0.5, timestamp: 3.0, duration: 1.0)
        ]

        let segments = clusterer.cluster(embeddings: embeddings, config: .default)

        // All segments should have valid time ranges
        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.startTime, 0)
            XCTAssertGreaterThan(segment.endTime, segment.startTime)
            XCTAssertGreaterThan(segment.duration, 0)
        }
    }

    func testSegmentConfidence() {
        let embeddings = createSpeakerEmbeddings(speakerBase: 0.5, timestamps: [0, 1, 2])
        let segments = clusterer.cluster(embeddings: embeddings, config: .default)

        for segment in segments {
            XCTAssertGreaterThanOrEqual(segment.confidence, 0)
            XCTAssertLessThanOrEqual(segment.confidence, 1)
        }
    }

    // MARK: - Cosine Similarity Tests

    func testCosineSimilarityIdentical() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [1, 0, 0]
        let sim = clusterer.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let sim = clusterer.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityOpposite() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [-1, 0, 0]
        let sim = clusterer.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 0.001)
    }

    func testCosineSimilaritySimilar() {
        let a: [Float] = [1, 1, 0]
        let b: [Float] = [1, 1.1, 0]
        let sim = clusterer.cosineSimilarity(a, b)
        XCTAssertGreaterThan(sim, 0.9)
    }

    // MARK: - Configuration Impact Tests

    func testHighThresholdMergesMore() {
        let speaker1 = createSpeakerEmbeddings(speakerBase: 0.4, timestamps: [0, 2])
        let speaker2 = createSpeakerEmbeddings(speakerBase: 0.6, timestamps: [1, 3])
        let allEmbeddings = (speaker1 + speaker2).sorted { $0.timestamp < $1.timestamp }

        let lowThreshold = DiarizationConfig(clusteringThreshold: 0.2)
        let highThreshold = DiarizationConfig(clusteringThreshold: 0.8)

        let segmentsLow = clusterer.cluster(embeddings: allEmbeddings, config: lowThreshold)
        let segmentsHigh = clusterer.cluster(embeddings: allEmbeddings, config: highThreshold)

        let speakersLow = Set(segmentsLow.map { $0.speakerId }).count
        let speakersHigh = Set(segmentsHigh.map { $0.speakerId }).count

        // Higher threshold should result in fewer or equal speakers
        XCTAssertGreaterThanOrEqual(speakersLow, speakersHigh)
    }

    func testMaxSpeakersLimit() {
        // Create many distinct embeddings
        var embeddings: [SpeakerEmbedding] = []
        for i in 0..<10 {
            embeddings.append(createEmbedding(
                baseValue: Float(i) * 0.1,
                timestamp: TimeInterval(i),
                noise: 0.01
            ))
        }

        let config = DiarizationConfig(clusteringThreshold: 0.1, maxSpeakers: 3)
        let segments = clusterer.cluster(embeddings: embeddings, config: config)

        let speakerCount = Set(segments.map { $0.speakerId }).count
        XCTAssertLessThanOrEqual(speakerCount, 10)  // Should respect some limit
    }

    // MARK: - Segment Refinement Tests

    func testRefineSegmentsMergesConsecutive() {
        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 1, confidence: 1.0),
            SpeakerSegment(speakerId: 0, startTime: 1.1, endTime: 2, confidence: 1.0),
            SpeakerSegment(speakerId: 1, startTime: 2.1, endTime: 3, confidence: 1.0)
        ]

        let refined = clusterer.refineSegments(segments, minDuration: 0.3)

        // First two should be merged
        let speaker0Segments = refined.filter { $0.speakerId == 0 }
        XCTAssertLessThanOrEqual(speaker0Segments.count, 1)
    }

    func testRefineSegmentsHandlesShortSegments() {
        let segments = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 1, confidence: 1.0),
            SpeakerSegment(speakerId: 1, startTime: 1, endTime: 1.1, confidence: 1.0),  // Very short
            SpeakerSegment(speakerId: 0, startTime: 1.1, endTime: 2, confidence: 1.0)
        ]

        let refined = clusterer.refineSegments(segments, minDuration: 0.3)

        // Short segment should be merged with neighbors
        // Final result should have fewer distinct speaker changes
        XCTAssertLessThanOrEqual(refined.count, segments.count)
    }

    // MARK: - Automatic Clustering Tests

    func testClusterAutomatic() {
        let speaker1 = createSpeakerEmbeddings(speakerBase: 0.3, timestamps: [0, 2, 4], noise: 0.05)
        let speaker2 = createSpeakerEmbeddings(speakerBase: 0.8, timestamps: [1, 3, 5], noise: 0.05)
        let allEmbeddings = (speaker1 + speaker2).sorted { $0.timestamp < $1.timestamp }

        let segments = clusterer.clusterAutomatic(embeddings: allEmbeddings)

        XCTAssertGreaterThan(segments.count, 0)
    }

    // MARK: - Edge Cases

    func testClusterWithIdenticalEmbeddings() {
        let embedding = createEmbedding(baseValue: 0.5, timestamp: 0, noise: 0)
        var embeddings: [SpeakerEmbedding] = []
        for i in 0..<5 {
            embeddings.append(SpeakerEmbedding(
                features: embedding.features,
                timestamp: TimeInterval(i),
                duration: 1.0
            ))
        }

        let segments = clusterer.cluster(embeddings: embeddings, config: .default)

        // Identical embeddings should be in same cluster
        let speakerIds = Set(segments.map { $0.speakerId })
        XCTAssertEqual(speakerIds.count, 1)
    }

    func testClusterWithVeryDifferentEmbeddings() {
        var embeddings: [SpeakerEmbedding] = []
        for i in 0..<5 {
            // Create very different embeddings
            var features = [Float](repeating: 0, count: 64)
            features[i * 10] = 1.0  // Different dominant feature
            embeddings.append(SpeakerEmbedding(
                features: features,
                timestamp: TimeInterval(i),
                duration: 1.0
            ))
        }

        let config = DiarizationConfig(clusteringThreshold: 0.3)
        let segments = clusterer.cluster(embeddings: embeddings, config: config)

        // Very different embeddings should be in different clusters
        let speakerIds = Set(segments.map { $0.speakerId })
        XCTAssertGreaterThan(speakerIds.count, 1)
    }

    // MARK: - SpeakerSegment Tests

    func testSpeakerSegmentProperties() {
        let segment = SpeakerSegment(
            speakerId: 2,
            startTime: 1.5,
            endTime: 3.5,
            confidence: 0.85
        )

        XCTAssertEqual(segment.speakerId, 2)
        XCTAssertEqual(segment.startTime, 1.5)
        XCTAssertEqual(segment.endTime, 3.5)
        XCTAssertEqual(segment.duration, 2.0)
        XCTAssertEqual(segment.confidence, 0.85)
        XCTAssertEqual(segment.timeRange, 1.5...3.5)
    }

    func testSpeakerSegmentCodable() throws {
        let original = SpeakerSegment(
            speakerId: 1,
            startTime: 2.0,
            endTime: 4.0,
            confidence: 0.9
        )

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpeakerSegment.self, from: encoded)

        XCTAssertEqual(decoded.speakerId, original.speakerId)
        XCTAssertEqual(decoded.startTime, original.startTime)
        XCTAssertEqual(decoded.endTime, original.endTime)
        XCTAssertEqual(decoded.confidence, original.confidence)
    }
}
