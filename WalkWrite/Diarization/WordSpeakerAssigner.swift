import Foundation

// MARK: - Diarized Word

/// A transcribed word with speaker assignment
public struct DiarizedWord: Codable, Sendable, Hashable {
    /// The transcribed word text
    public let word: String

    /// Start time in seconds (in the audio file)
    public let start: Double

    /// End time in seconds (in the audio file)
    public let end: Double

    /// Assigned speaker ID (0-based)
    public let speakerId: Int

    /// Confidence of the speaker assignment (0.0 - 1.0)
    public let speakerConfidence: Float

    public var duration: Double {
        end - start
    }

    public init(
        word: String,
        start: Double,
        end: Double,
        speakerId: Int,
        speakerConfidence: Float
    ) {
        self.word = word
        self.start = start
        self.end = end
        self.speakerId = speakerId
        self.speakerConfidence = speakerConfidence
    }

    /// Create from a WordStamp with speaker assignment
    public init(wordStamp: WordStamp, speakerId: Int, confidence: Float) {
        self.word = wordStamp.word
        self.start = wordStamp.start
        self.end = wordStamp.end
        self.speakerId = speakerId
        self.speakerConfidence = confidence
    }
}

// MARK: - Word Speaker Assigner

/// Assigns speaker IDs to transcribed words based on speaker segments
public final class WordSpeakerAssigner: @unchecked Sendable {

    // MARK: - Initialization

    public init() {}

    // MARK: - Assignment

    /// Assign speakers to words based on segment overlap
    /// - Parameters:
    ///   - words: Transcribed words with timestamps
    ///   - speakerSegments: Speaker segments from clustering
    /// - Returns: Words with speaker assignments
    public func assign(
        words: [WordStamp],
        speakerSegments: [SpeakerSegment]
    ) -> [DiarizedWord] {
        guard !speakerSegments.isEmpty else {
            // No speaker segments - assign all to speaker 0
            return words.map { word in
                DiarizedWord(wordStamp: word, speakerId: 0, confidence: 0.0)
            }
        }

        return words.map { word in
            let (speakerId, confidence) = findBestSpeaker(
                wordStart: word.start,
                wordEnd: word.end,
                segments: speakerSegments
            )
            return DiarizedWord(wordStamp: word, speakerId: speakerId, confidence: confidence)
        }
    }

    /// Assign speakers with time mapping (for VAD-filtered audio)
    /// - Parameters:
    ///   - words: Transcribed words (in concatenated audio time)
    ///   - speakerSegments: Speaker segments (in original recording time)
    ///   - timeMappings: Mappings from concatenated to original time
    /// - Returns: Words with speaker assignments
    public func assignWithTimeMapping(
        words: [WordStamp],
        speakerSegments: [SpeakerSegment],
        timeMappings: [AudioSegmentManager.TimeMapping]
    ) -> [DiarizedWord] {
        guard !speakerSegments.isEmpty else {
            return words.map { word in
                DiarizedWord(wordStamp: word, speakerId: 0, confidence: 0.0)
            }
        }

        return words.map { word in
            // Convert word times to original recording time
            let originalStart = concatenatedToOriginal(word.start, mappings: timeMappings)
            let originalEnd = concatenatedToOriginal(word.end, mappings: timeMappings)

            let (speakerId, confidence) = findBestSpeaker(
                wordStart: originalStart ?? word.start,
                wordEnd: originalEnd ?? word.end,
                segments: speakerSegments
            )

            return DiarizedWord(wordStamp: word, speakerId: speakerId, confidence: confidence)
        }
    }

    // MARK: - Speaker Finding

    /// Find the best speaker for a word based on overlap with segments
    private func findBestSpeaker(
        wordStart: Double,
        wordEnd: Double,
        segments: [SpeakerSegment]
    ) -> (speakerId: Int, confidence: Float) {
        var bestSpeakerId = 0
        var bestOverlap: Double = 0
        var totalOverlap: Double = 0

        for segment in segments {
            let overlap = computeOverlap(
                start1: wordStart,
                end1: wordEnd,
                start2: segment.startTime,
                end2: segment.endTime
            )

            if overlap > 0 {
                totalOverlap += overlap * Double(segment.confidence)

                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeakerId = segment.speakerId
                }
            }
        }

        // Calculate confidence based on overlap quality
        let wordDuration = wordEnd - wordStart
        let confidence: Float
        if wordDuration > 0 {
            let overlapRatio = bestOverlap / wordDuration
            confidence = min(1.0, Float(overlapRatio))
        } else {
            confidence = 0.5  // Default for zero-duration words
        }

        return (bestSpeakerId, confidence)
    }

    /// Compute overlap duration between two time ranges
    private func computeOverlap(
        start1: Double,
        end1: Double,
        start2: TimeInterval,
        end2: TimeInterval
    ) -> Double {
        let overlapStart = max(start1, start2)
        let overlapEnd = min(end1, end2)
        return max(0, overlapEnd - overlapStart)
    }

    /// Convert concatenated time to original recording time
    private func concatenatedToOriginal(
        _ time: Double,
        mappings: [AudioSegmentManager.TimeMapping]
    ) -> TimeInterval? {
        for mapping in mappings {
            if mapping.concatenatedRange.contains(time) {
                let offset = time - mapping.concatenatedRange.lowerBound
                return mapping.originalRange.lowerBound + offset
            }
        }
        return nil
    }

    // MARK: - Post-Processing

    /// Smooth speaker assignments to reduce rapid speaker changes
    /// - Parameters:
    ///   - words: Diarized words
    ///   - minWordCount: Minimum consecutive words to keep a speaker change
    /// - Returns: Smoothed diarized words
    public func smoothAssignments(
        _ words: [DiarizedWord],
        minWordCount: Int = 2
    ) -> [DiarizedWord] {
        guard words.count > minWordCount else { return words }

        var smoothed = words

        // Find isolated speaker changes and correct them
        var i = 0
        while i < smoothed.count {
            // Find run of same speaker
            var runEnd = i + 1
            while runEnd < smoothed.count && smoothed[runEnd].speakerId == smoothed[i].speakerId {
                runEnd += 1
            }

            let runLength = runEnd - i

            // If run is too short, try to merge with neighbors
            if runLength < minWordCount {
                let prevSpeaker = i > 0 ? smoothed[i - 1].speakerId : -1
                let nextSpeaker = runEnd < smoothed.count ? smoothed[runEnd].speakerId : -1

                // If both neighbors have the same speaker, change this run
                if prevSpeaker == nextSpeaker && prevSpeaker != -1 {
                    for j in i..<runEnd {
                        smoothed[j] = DiarizedWord(
                            word: smoothed[j].word,
                            start: smoothed[j].start,
                            end: smoothed[j].end,
                            speakerId: prevSpeaker,
                            speakerConfidence: smoothed[j].speakerConfidence * 0.7
                        )
                    }
                }
            }

            i = runEnd
        }

        return smoothed
    }

    /// Assign consistent speaker labels based on speaking order
    /// Speaker 0 becomes "Speaker 1" (or "User"), etc.
    public func relabelSpeakers(_ words: [DiarizedWord]) -> (words: [DiarizedWord], speakerOrder: [Int]) {
        // Find order of first appearance
        var speakerOrder: [Int] = []
        var speakerMap: [Int: Int] = [:]

        for word in words {
            if speakerMap[word.speakerId] == nil {
                speakerMap[word.speakerId] = speakerOrder.count
                speakerOrder.append(word.speakerId)
            }
        }

        // Relabel words
        let relabeled = words.map { word in
            DiarizedWord(
                word: word.word,
                start: word.start,
                end: word.end,
                speakerId: speakerMap[word.speakerId] ?? word.speakerId,
                speakerConfidence: word.speakerConfidence
            )
        }

        return (relabeled, speakerOrder)
    }
}

// MARK: - Speaker Statistics

/// Statistics about a speaker's contribution
public struct SpeakerStats: Codable, Sendable {
    public let speakerId: Int
    public var totalSpeakingTime: TimeInterval
    public var segmentCount: Int
    public var wordCount: Int
    public var averageSegmentDuration: TimeInterval
    public var firstAppearance: TimeInterval
    public var lastAppearance: TimeInterval
    public var label: String?

    public init(
        speakerId: Int,
        totalSpeakingTime: TimeInterval = 0,
        segmentCount: Int = 0,
        wordCount: Int = 0,
        averageSegmentDuration: TimeInterval = 0,
        firstAppearance: TimeInterval = 0,
        lastAppearance: TimeInterval = 0,
        label: String? = nil
    ) {
        self.speakerId = speakerId
        self.totalSpeakingTime = totalSpeakingTime
        self.segmentCount = segmentCount
        self.wordCount = wordCount
        self.averageSegmentDuration = averageSegmentDuration
        self.firstAppearance = firstAppearance
        self.lastAppearance = lastAppearance
        self.label = label
    }
}

/// Computes statistics about speakers
public final class SpeakerStatsCalculator {

    public init() {}

    /// Calculate statistics for all speakers
    public func calculateStats(
        words: [DiarizedWord],
        segments: [SpeakerSegment]
    ) -> [SpeakerStats] {
        var statsMap: [Int: SpeakerStats] = [:]

        // Initialize from segments
        for segment in segments {
            var stats = statsMap[segment.speakerId] ?? SpeakerStats(speakerId: segment.speakerId)
            stats.totalSpeakingTime += segment.duration
            stats.segmentCount += 1

            if stats.firstAppearance == 0 || segment.startTime < stats.firstAppearance {
                stats.firstAppearance = segment.startTime
            }
            if segment.endTime > stats.lastAppearance {
                stats.lastAppearance = segment.endTime
            }

            statsMap[segment.speakerId] = stats
        }

        // Add word counts
        for word in words {
            var stats = statsMap[word.speakerId] ?? SpeakerStats(speakerId: word.speakerId)
            stats.wordCount += 1
            statsMap[word.speakerId] = stats
        }

        // Calculate averages
        var result = statsMap.values.map { stats -> SpeakerStats in
            var s = stats
            if s.segmentCount > 0 {
                s.averageSegmentDuration = s.totalSpeakingTime / TimeInterval(s.segmentCount)
            }
            return s
        }

        // Sort by speaking time (most to least)
        result.sort { $0.totalSpeakingTime > $1.totalSpeakingTime }

        // Assign labels
        for i in 0..<result.count {
            if i == 0 {
                result[i].label = "Speaker 1"  // Will be replaced with "User" if identified
            } else {
                result[i].label = "Speaker \(i + 1)"
            }
        }

        return result
    }
}
