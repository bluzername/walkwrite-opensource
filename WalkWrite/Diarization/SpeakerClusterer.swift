import Foundation
import Accelerate

// MARK: - Speaker Segment

/// A segment of audio attributed to a specific speaker
public struct SpeakerSegment: Codable, Sendable, Identifiable {
    public let id: UUID
    public let speakerId: Int
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    public var timeRange: ClosedRange<TimeInterval> {
        startTime...endTime
    }

    public var duration: TimeInterval {
        endTime - startTime
    }

    public init(
        id: UUID = UUID(),
        speakerId: Int,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float
    ) {
        self.id = id
        self.speakerId = speakerId
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

// MARK: - Cluster

/// Internal representation of a cluster during AHC
private struct Cluster {
    var id: Int
    var embeddings: [SpeakerEmbedding]
    var centroid: [Float]

    /// Compute centroid as mean of all embeddings
    mutating func updateCentroid() {
        guard !embeddings.isEmpty else { return }

        let dim = embeddings[0].features.count
        var sum = [Float](repeating: 0, count: dim)

        for embedding in embeddings {
            for i in 0..<dim {
                sum[i] += embedding.features[i]
            }
        }

        let count = Float(embeddings.count)
        centroid = sum.map { $0 / count }
    }

    /// Get all timestamps from embeddings in this cluster
    var timestamps: [(start: TimeInterval, end: TimeInterval)] {
        embeddings.map { ($0.timestamp, $0.timestamp + $0.duration) }
    }
}

// MARK: - Speaker Clusterer

/// Clusters speaker embeddings to identify unique speakers
///
/// Uses Agglomerative Hierarchical Clustering (AHC) with average linkage
/// and cosine distance. The algorithm:
/// 1. Starts with each embedding as its own cluster
/// 2. Iteratively merges the two closest clusters
/// 3. Stops when distance exceeds threshold or max speakers reached
public final class SpeakerClusterer: @unchecked Sendable {

    // MARK: - Properties

    private let lock = NSLock()

    // MARK: - Initialization

    public init() {}

    // MARK: - Clustering

    /// Cluster embeddings into speaker groups
    /// - Parameters:
    ///   - embeddings: Array of speaker embeddings with timestamps
    ///   - config: Diarization configuration
    /// - Returns: Array of speaker segments with speaker IDs
    public func cluster(
        embeddings: [SpeakerEmbedding],
        config: DiarizationConfig
    ) -> [SpeakerSegment] {
        guard embeddings.count > 0 else { return [] }

        // Handle single embedding case
        if embeddings.count == 1 {
            return [SpeakerSegment(
                speakerId: 0,
                startTime: embeddings[0].timestamp,
                endTime: embeddings[0].timestamp + embeddings[0].duration,
                confidence: 1.0
            )]
        }

        // Initialize clusters (one per embedding)
        var clusters = embeddings.enumerated().map { idx, embedding in
            var cluster = Cluster(
                id: idx,
                embeddings: [embedding],
                centroid: embedding.features
            )
            return cluster
        }

        // Compute initial distance matrix
        var distanceMatrix = computeDistanceMatrix(clusters)

        // Agglomerative clustering
        while clusters.count > 1 {
            // Find minimum distance pair
            guard let (i, j, minDist) = findMinimumDistance(distanceMatrix, clusterCount: clusters.count) else {
                break
            }

            // Stop if minimum distance exceeds threshold or max speakers reached
            if minDist > config.clusteringThreshold || clusters.count <= config.maxSpeakers {
                if minDist > config.clusteringThreshold {
                    break
                }
            }

            // Also stop if we've reached a reasonable number of clusters
            if clusters.count <= 2 && minDist > config.clusteringThreshold * 0.8 {
                break
            }

            // Merge clusters i and j
            clusters[i].embeddings.append(contentsOf: clusters[j].embeddings)
            clusters[i].updateCentroid()
            clusters.remove(at: j)

            // Recompute distance matrix
            distanceMatrix = computeDistanceMatrix(clusters)
        }

        // Convert clusters to speaker segments
        return convertToSegments(clusters)
    }

    /// Cluster with automatic threshold selection
    public func clusterAutomatic(
        embeddings: [SpeakerEmbedding],
        maxSpeakers: Int = 10
    ) -> [SpeakerSegment] {
        guard embeddings.count > 1 else {
            if let first = embeddings.first {
                return [SpeakerSegment(
                    speakerId: 0,
                    startTime: first.timestamp,
                    endTime: first.timestamp + first.duration,
                    confidence: 1.0
                )]
            }
            return []
        }

        // Try to find optimal threshold using elbow method
        let thresholds: [Float] = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7]
        var bestThreshold: Float = 0.4
        var bestScore: Float = 0

        for threshold in thresholds {
            let config = DiarizationConfig(
                clusteringThreshold: threshold,
                maxSpeakers: maxSpeakers
            )
            let segments = cluster(embeddings: embeddings, config: config)

            // Score based on cluster quality (silhouette-like)
            let score = evaluateClusteringQuality(segments, embeddings: embeddings)
            if score > bestScore {
                bestScore = score
                bestThreshold = threshold
            }
        }

        // Cluster with best threshold
        let config = DiarizationConfig(
            clusteringThreshold: bestThreshold,
            maxSpeakers: maxSpeakers
        )
        return cluster(embeddings: embeddings, config: config)
    }

    // MARK: - Distance Computation

    /// Compute pairwise distance matrix between clusters
    private func computeDistanceMatrix(_ clusters: [Cluster]) -> [[Float]] {
        let n = clusters.count
        var matrix = [[Float]](repeating: [Float](repeating: Float.infinity, count: n), count: n)

        for i in 0..<n {
            matrix[i][i] = 0
            for j in (i + 1)..<n {
                let dist = averageLinkageDistance(clusters[i], clusters[j])
                matrix[i][j] = dist
                matrix[j][i] = dist
            }
        }

        return matrix
    }

    /// Compute average linkage distance between two clusters
    private func averageLinkageDistance(_ a: Cluster, _ b: Cluster) -> Float {
        var totalDist: Float = 0
        var count = 0

        for embA in a.embeddings {
            for embB in b.embeddings {
                totalDist += cosineDistance(embA.features, embB.features)
                count += 1
            }
        }

        return count > 0 ? totalDist / Float(count) : Float.infinity
    }

    /// Compute cosine distance between two vectors
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        return 1.0 - cosineSimilarity(a, b)
    }

    /// Compute cosine similarity between two vectors
    public func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 1e-10 ? dotProduct / denominator : 0
    }

    /// Find the minimum distance pair in the matrix
    private func findMinimumDistance(_ matrix: [[Float]], clusterCount: Int) -> (Int, Int, Float)? {
        var minI = 0
        var minJ = 1
        var minDist: Float = Float.infinity

        for i in 0..<clusterCount {
            for j in (i + 1)..<clusterCount {
                if matrix[i][j] < minDist {
                    minDist = matrix[i][j]
                    minI = i
                    minJ = j
                }
            }
        }

        guard minDist < Float.infinity else { return nil }
        return (minI, minJ, minDist)
    }

    // MARK: - Segment Conversion

    /// Convert clusters to speaker segments
    private func convertToSegments(_ clusters: [Cluster]) -> [SpeakerSegment] {
        var segments: [SpeakerSegment] = []

        for (speakerId, cluster) in clusters.enumerated() {
            // Sort embeddings by timestamp
            let sortedEmbeddings = cluster.embeddings.sorted { $0.timestamp < $1.timestamp }

            // Merge consecutive embeddings into segments
            var currentStart = sortedEmbeddings[0].timestamp
            var currentEnd = sortedEmbeddings[0].timestamp + sortedEmbeddings[0].duration

            for i in 1..<sortedEmbeddings.count {
                let embedding = sortedEmbeddings[i]
                let embeddingEnd = embedding.timestamp + embedding.duration

                // Check if this embedding is close enough to merge
                if embedding.timestamp - currentEnd < 0.5 {  // 500ms gap threshold
                    currentEnd = max(currentEnd, embeddingEnd)
                } else {
                    // Create segment for previous range
                    segments.append(SpeakerSegment(
                        speakerId: speakerId,
                        startTime: currentStart,
                        endTime: currentEnd,
                        confidence: 1.0
                    ))
                    currentStart = embedding.timestamp
                    currentEnd = embeddingEnd
                }
            }

            // Add final segment
            segments.append(SpeakerSegment(
                speakerId: speakerId,
                startTime: currentStart,
                endTime: currentEnd,
                confidence: 1.0
            ))
        }

        // Sort by start time
        return segments.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Quality Evaluation

    /// Evaluate clustering quality (simplified silhouette score)
    private func evaluateClusteringQuality(
        _ segments: [SpeakerSegment],
        embeddings: [SpeakerEmbedding]
    ) -> Float {
        let speakerIds = Set(segments.map { $0.speakerId })

        // Penalize single cluster or too many clusters
        if speakerIds.count <= 1 {
            return 0.1
        }
        if speakerIds.count > 8 {
            return 0.3
        }

        // Group embeddings by assigned speaker
        var speakerEmbeddings: [Int: [SpeakerEmbedding]] = [:]
        for embedding in embeddings {
            // Find which segment this embedding belongs to
            let segment = segments.first { seg in
                embedding.timestamp >= seg.startTime &&
                embedding.timestamp < seg.endTime
            }
            if let seg = segment {
                speakerEmbeddings[seg.speakerId, default: []].append(embedding)
            }
        }

        // Compute within-cluster cohesion
        var totalCohesion: Float = 0
        var clusterCount = 0

        for (_, embs) in speakerEmbeddings {
            if embs.count > 1 {
                var pairwiseSim: Float = 0
                var pairCount = 0
                for i in 0..<embs.count {
                    for j in (i+1)..<embs.count {
                        pairwiseSim += cosineSimilarity(embs[i].features, embs[j].features)
                        pairCount += 1
                    }
                }
                if pairCount > 0 {
                    totalCohesion += pairwiseSim / Float(pairCount)
                    clusterCount += 1
                }
            }
        }

        // Score based on cohesion and reasonable cluster count
        let cohesionScore = clusterCount > 0 ? totalCohesion / Float(clusterCount) : 0.5
        let countScore = 1.0 - abs(Float(speakerIds.count) - 2.0) / 10.0  // Prefer 2-3 speakers

        return (cohesionScore + countScore) / 2.0
    }

    // MARK: - Refinement

    /// Refine speaker segments by smoothing short segments
    public func refineSegments(
        _ segments: [SpeakerSegment],
        minDuration: TimeInterval = 0.3
    ) -> [SpeakerSegment] {
        guard segments.count > 1 else { return segments }

        var refined = segments.sorted { $0.startTime < $1.startTime }

        // First pass: merge very short segments with neighbors
        var i = 0
        while i < refined.count {
            if refined[i].duration < minDuration {
                // Find best neighbor to merge with
                let prevSpeaker = i > 0 ? refined[i - 1].speakerId : -1
                let nextSpeaker = i < refined.count - 1 ? refined[i + 1].speakerId : -1

                if prevSpeaker == nextSpeaker && prevSpeaker != -1 {
                    // Merge with both (they're the same speaker)
                    refined[i] = SpeakerSegment(
                        speakerId: prevSpeaker,
                        startTime: refined[i].startTime,
                        endTime: refined[i].endTime,
                        confidence: refined[i].confidence * 0.8
                    )
                } else if prevSpeaker != -1 {
                    // Merge with previous
                    refined[i] = SpeakerSegment(
                        speakerId: prevSpeaker,
                        startTime: refined[i].startTime,
                        endTime: refined[i].endTime,
                        confidence: refined[i].confidence * 0.7
                    )
                } else if nextSpeaker != -1 {
                    // Merge with next
                    refined[i] = SpeakerSegment(
                        speakerId: nextSpeaker,
                        startTime: refined[i].startTime,
                        endTime: refined[i].endTime,
                        confidence: refined[i].confidence * 0.7
                    )
                }
            }
            i += 1
        }

        // Second pass: merge consecutive segments with same speaker
        var merged: [SpeakerSegment] = []
        var current = refined[0]

        for i in 1..<refined.count {
            if refined[i].speakerId == current.speakerId {
                // Extend current segment
                current = SpeakerSegment(
                    speakerId: current.speakerId,
                    startTime: current.startTime,
                    endTime: refined[i].endTime,
                    confidence: (current.confidence + refined[i].confidence) / 2
                )
            } else {
                merged.append(current)
                current = refined[i]
            }
        }
        merged.append(current)

        return merged
    }
}
