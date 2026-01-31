import Foundation

// MARK: - User Identification Result

/// Result of user identification process
public struct UserIdentificationResult: Codable, Sendable {
    /// The identified user's speaker ID
    public let userId: Int

    /// Confidence in the user identification (0.0 - 1.0)
    public let confidence: Float

    /// Why this speaker was identified as the user
    public let reason: IdentificationReason

    /// Statistics about the identified user
    public let userStats: SpeakerStats

    public init(userId: Int, confidence: Float, reason: IdentificationReason, userStats: SpeakerStats) {
        self.userId = userId
        self.confidence = confidence
        self.reason = reason
        self.userStats = userStats
    }
}

/// Reason for user identification
public enum IdentificationReason: String, Codable, Sendable {
    /// User identified by having the most speaking time
    case mostSpeakingTime

    /// User identified by appearing first and having substantial speaking time
    case firstSpeakerWithSubstantialTime

    /// User identified by having the most segments (most active speaker)
    case mostSegments

    /// User identified by a combination of factors
    case combinedFactors

    /// Only one speaker detected
    case singleSpeaker

    public var description: String {
        switch self {
        case .mostSpeakingTime:
            return "Speaker with the most speaking time"
        case .firstSpeakerWithSubstantialTime:
            return "First speaker with substantial speaking time"
        case .mostSegments:
            return "Most active speaker (most segments)"
        case .combinedFactors:
            return "Identified by multiple factors"
        case .singleSpeaker:
            return "Only speaker detected"
        }
    }
}

// MARK: - User Identifier Configuration

/// Configuration for user identification algorithm
public struct UserIdentificationConfig: Codable, Sendable {
    /// Minimum speaking time ratio to consider a speaker as user candidate (0.0 - 1.0)
    /// A speaker must have at least this fraction of total speaking time
    public var minSpeakingTimeRatio: Float

    /// Weight for speaking time in the scoring algorithm
    public var speakingTimeWeight: Float

    /// Weight for segment count in the scoring algorithm
    public var segmentCountWeight: Float

    /// Weight for first appearance in the scoring algorithm
    public var firstAppearanceWeight: Float

    /// Minimum confidence to return a valid identification
    public var minConfidence: Float

    public init(
        minSpeakingTimeRatio: Float = 0.2,
        speakingTimeWeight: Float = 0.5,
        segmentCountWeight: Float = 0.3,
        firstAppearanceWeight: Float = 0.2,
        minConfidence: Float = 0.3
    ) {
        self.minSpeakingTimeRatio = minSpeakingTimeRatio
        self.speakingTimeWeight = speakingTimeWeight
        self.segmentCountWeight = segmentCountWeight
        self.firstAppearanceWeight = firstAppearanceWeight
        self.minConfidence = minConfidence
    }

    public static let `default` = UserIdentificationConfig()

    /// More conservative identification (requires stronger signal)
    public static let conservative = UserIdentificationConfig(
        minSpeakingTimeRatio: 0.3,
        speakingTimeWeight: 0.6,
        segmentCountWeight: 0.25,
        firstAppearanceWeight: 0.15,
        minConfidence: 0.5
    )

    /// Lenient identification (works better with few speakers)
    public static let lenient = UserIdentificationConfig(
        minSpeakingTimeRatio: 0.1,
        speakingTimeWeight: 0.4,
        segmentCountWeight: 0.35,
        firstAppearanceWeight: 0.25,
        minConfidence: 0.2
    )
}

// MARK: - User Identifier

/// Identifies the most likely "user" speaker from diarization results
///
/// The user is typically:
/// 1. The speaker with the most speaking time
/// 2. The first speaker (in a voice note, user often starts speaking)
/// 3. The most consistent speaker across the recording
///
/// This information helps the LLM understand context and provide
/// better summaries and analysis.
public final class UserIdentifier: Sendable {

    private let config: UserIdentificationConfig

    public init(config: UserIdentificationConfig = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Identify the user from diarization results
    /// - Parameters:
    ///   - diarizedWords: Words with speaker assignments
    ///   - speakerStats: Statistics for each speaker
    ///   - speakerSegments: Speaker segments (optional, for additional analysis)
    /// - Returns: User identification result, or nil if identification failed
    public func identifyUser(
        diarizedWords: [DiarizedWord],
        speakerStats: [SpeakerStats],
        speakerSegments: [SpeakerSegment]? = nil
    ) -> UserIdentificationResult? {
        guard !speakerStats.isEmpty else { return nil }

        // Single speaker case
        if speakerStats.count == 1 {
            let stats = speakerStats[0]
            return UserIdentificationResult(
                userId: stats.speakerId,
                confidence: 1.0,
                reason: .singleSpeaker,
                userStats: stats
            )
        }

        // Calculate scores for each speaker
        var scores: [(speakerId: Int, score: Float, stats: SpeakerStats)] = []

        let totalSpeakingTime = speakerStats.reduce(0.0) { $0 + $1.totalSpeakingTime }
        let maxSpeakingTime = speakerStats.map { $0.totalSpeakingTime }.max() ?? 1.0
        let maxSegmentCount = speakerStats.map { $0.segmentCount }.max() ?? 1
        let minFirstAppearance = speakerStats.map { $0.firstAppearance }.min() ?? 0.0
        let maxFirstAppearance = speakerStats.map { $0.firstAppearance }.max() ?? 1.0
        let appearanceRange = max(maxFirstAppearance - minFirstAppearance, 0.1)

        for stats in speakerStats {
            // Skip speakers with insufficient speaking time
            let speakingRatio = Float(stats.totalSpeakingTime / max(totalSpeakingTime, 0.1))
            if speakingRatio < config.minSpeakingTimeRatio {
                continue
            }

            // Calculate component scores
            let speakingTimeScore = Float(stats.totalSpeakingTime / maxSpeakingTime)
            let segmentScore = Float(stats.segmentCount) / Float(max(maxSegmentCount, 1))

            // Earlier appearance gets higher score
            let appearanceScore = 1.0 - Float((stats.firstAppearance - minFirstAppearance) / appearanceRange)

            // Weighted combination
            let totalScore = speakingTimeScore * config.speakingTimeWeight +
                             segmentScore * config.segmentCountWeight +
                             appearanceScore * config.firstAppearanceWeight

            scores.append((stats.speakerId, totalScore, stats))
        }

        // Sort by score descending
        scores.sort { $0.score > $1.score }

        guard let best = scores.first else { return nil }

        // Determine the reason for identification
        let reason = determineReason(
            speakerId: best.speakerId,
            stats: best.stats,
            allStats: speakerStats,
            totalSpeakingTime: totalSpeakingTime
        )

        // Calculate confidence
        let confidence = calculateConfidence(
            bestScore: best.score,
            scores: scores,
            speakerStats: speakerStats
        )

        guard confidence >= config.minConfidence else { return nil }

        return UserIdentificationResult(
            userId: best.speakerId,
            confidence: confidence,
            reason: reason,
            userStats: best.stats
        )
    }

    /// Identify user from a complete diarization result
    public func identifyUser(from result: DiarizationResult) -> UserIdentificationResult? {
        return identifyUser(
            diarizedWords: result.diarizedWords,
            speakerStats: result.speakerStats,
            speakerSegments: result.speakerSegments
        )
    }

    // MARK: - Private Methods

    private func determineReason(
        speakerId: Int,
        stats: SpeakerStats,
        allStats: [SpeakerStats],
        totalSpeakingTime: TimeInterval
    ) -> IdentificationReason {
        let sortedBySpeakingTime = allStats.sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }
        let sortedBySegments = allStats.sorted { $0.segmentCount > $1.segmentCount }
        let sortedByAppearance = allStats.sorted { $0.firstAppearance < $1.firstAppearance }

        let isMostSpeakingTime = sortedBySpeakingTime.first?.speakerId == speakerId
        let isMostSegments = sortedBySegments.first?.speakerId == speakerId
        let isFirstSpeaker = sortedByAppearance.first?.speakerId == speakerId

        // Check if it's clear-cut most speaking time
        if isMostSpeakingTime {
            let ratio = stats.totalSpeakingTime / max(totalSpeakingTime, 0.1)
            if ratio > 0.5 {
                return .mostSpeakingTime
            }
        }

        // First speaker with substantial time
        if isFirstSpeaker && stats.totalSpeakingTime / max(totalSpeakingTime, 0.1) > 0.25 {
            return .firstSpeakerWithSubstantialTime
        }

        // Most segments
        if isMostSegments && !isMostSpeakingTime {
            return .mostSegments
        }

        // Combined factors
        return .combinedFactors
    }

    private func calculateConfidence(
        bestScore: Float,
        scores: [(speakerId: Int, score: Float, stats: SpeakerStats)],
        speakerStats: [SpeakerStats]
    ) -> Float {
        // Base confidence from score
        var confidence = min(bestScore, 1.0)

        // Boost if there's a clear winner (significant gap to second place)
        if scores.count >= 2 {
            let gap = bestScore - scores[1].score
            if gap > 0.2 {
                confidence = min(confidence + 0.1, 1.0)
            } else if gap < 0.05 {
                // Reduce confidence if scores are very close
                confidence *= 0.8
            }
        }

        // Boost for single speaker
        if speakerStats.count == 1 {
            confidence = 1.0
        }

        return confidence
    }
}

// MARK: - Speaker Labeling

/// Utility for labeling speakers in the transcript
public enum SpeakerLabeler {

    /// Generate labels for all speakers with user designation
    /// - Parameters:
    ///   - speakerStats: Statistics for all speakers
    ///   - userId: The identified user's speaker ID
    ///   - customUserLabel: Custom label for the user (default: "You")
    /// - Returns: Dictionary mapping speaker IDs to labels
    public static func generateLabels(
        speakerStats: [SpeakerStats],
        userId: Int?,
        customUserLabel: String = "You"
    ) -> [Int: String] {
        var labels: [Int: String] = [:]
        var otherCount = 1

        // Sort by speaking time to give consistent numbering
        let sorted = speakerStats.sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }

        for stats in sorted {
            if stats.speakerId == userId {
                labels[stats.speakerId] = customUserLabel
            } else {
                labels[stats.speakerId] = "Speaker \(otherCount + 1)"
                otherCount += 1
            }
        }

        return labels
    }

    /// Generate a formatted transcript with proper speaker labels
    /// - Parameters:
    ///   - diarizedWords: Words with speaker assignments
    ///   - speakerStats: Statistics for all speakers
    ///   - userId: The identified user's speaker ID
    ///   - userLabel: Label for the user
    /// - Returns: Formatted transcript string
    public static func formatTranscript(
        diarizedWords: [DiarizedWord],
        speakerStats: [SpeakerStats],
        userId: Int?,
        userLabel: String = "You"
    ) -> String {
        guard !diarizedWords.isEmpty else { return "" }

        let labels = generateLabels(speakerStats: speakerStats, userId: userId, customUserLabel: userLabel)

        var result = ""
        var currentSpeakerId = -1

        for word in diarizedWords {
            if word.speakerId != currentSpeakerId {
                if !result.isEmpty {
                    result += "\n\n"
                }

                let label = labels[word.speakerId] ?? "Speaker \(word.speakerId + 1)"
                result += "[\(label)]: "
                currentSpeakerId = word.speakerId
            }

            // Add word with proper spacing
            if !result.hasSuffix(" ") && !result.hasSuffix("[") && !result.hasSuffix(":") && !result.hasSuffix("\n") {
                let needsSpace = !isPunctuation(word.word)
                if needsSpace {
                    result += " "
                }
            }
            result += word.word
        }

        return result
    }

    /// Generate an LLM-friendly context string describing the speakers
    /// - Parameters:
    ///   - speakerStats: Statistics for all speakers
    ///   - userId: The identified user's speaker ID
    /// - Returns: Context string for LLM prompts
    public static func generateLLMContext(
        speakerStats: [SpeakerStats],
        userId: Int?
    ) -> String {
        guard !speakerStats.isEmpty else { return "" }

        var context = "This transcript contains \(speakerStats.count) speaker(s):\n"

        let labels = generateLabels(speakerStats: speakerStats, userId: userId)
        let sorted = speakerStats.sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }

        for stats in sorted {
            let label = labels[stats.speakerId] ?? "Speaker \(stats.speakerId + 1)"
            let duration = formatDuration(stats.totalSpeakingTime)
            let isUser = stats.speakerId == userId

            if isUser {
                context += "- \(label) (the person recording this voice note): spoke for \(duration), \(stats.wordCount) words\n"
            } else {
                context += "- \(label): spoke for \(duration), \(stats.wordCount) words\n"
            }
        }

        if let userId = userId {
            context += "\nWhen summarizing, focus on the perspective of '\(labels[userId] ?? "You")' (the person who recorded this)."
        }

        return context
    }

    private static func isPunctuation(_ word: String) -> Bool {
        let punctuation = CharacterSet.punctuationCharacters
        return word.unicodeScalars.allSatisfy { punctuation.contains($0) }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.0f seconds", duration)
        } else {
            let minutes = Int(duration / 60)
            let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
            if seconds == 0 {
                return "\(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
    }
}
