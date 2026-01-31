import SwiftUI

// MARK: - Speaker Colors

/// Provides consistent colors for speaker visualization
public enum SpeakerColors {
    /// Primary colors for speakers (user is always first)
    private static let palette: [Color] = [
        .blue,        // User/Speaker 0
        .green,       // Speaker 1
        .orange,      // Speaker 2
        .purple,      // Speaker 3
        .pink,        // Speaker 4
        .teal,        // Speaker 5
        .indigo,      // Speaker 6
        .mint,        // Speaker 7
        .cyan,        // Speaker 8
        .brown        // Speaker 9
    ]

    /// Get color for a speaker
    public static func color(for speakerId: Int, isUser: Bool = false) -> Color {
        if isUser {
            return .blue  // User always gets blue
        }
        let index = speakerId % palette.count
        return palette[index]
    }

    /// Get a lighter version for backgrounds
    public static func backgroundColor(for speakerId: Int, isUser: Bool = false) -> Color {
        return color(for: speakerId, isUser: isUser).opacity(0.15)
    }
}

// MARK: - Speaker Badge

/// Small badge showing speaker identity
struct SpeakerBadge: View {
    let speakerId: Int
    let isUser: Bool
    let label: String?

    init(speakerId: Int, isUser: Bool = false, label: String? = nil) {
        self.speakerId = speakerId
        self.isUser = isUser
        self.label = label
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(SpeakerColors.color(for: speakerId, isUser: isUser))
                .frame(width: 8, height: 8)

            Text(displayLabel)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(SpeakerColors.color(for: speakerId, isUser: isUser))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SpeakerColors.backgroundColor(for: speakerId, isUser: isUser))
        .clipShape(Capsule())
    }

    private var displayLabel: String {
        if let label = label {
            return label
        }
        return isUser ? "You" : "Speaker \(speakerId + 1)"
    }
}

// MARK: - Speaker Stats Card

/// Card showing statistics for a single speaker
struct SpeakerStatsCard: View {
    let stats: SpeakerStats
    let isUser: Bool
    let totalDuration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                SpeakerBadge(speakerId: stats.speakerId, isUser: isUser)
                Spacer()
                Text(formatPercentage(stats.totalSpeakingTime / max(totalDuration, 1)))
                    .font(.headline)
                    .foregroundStyle(SpeakerColors.color(for: stats.speakerId, isUser: isUser))
            }

            // Stats grid
            HStack(spacing: 16) {
                StatItem(
                    icon: "clock",
                    value: formatDuration(stats.totalSpeakingTime),
                    label: "Speaking"
                )

                StatItem(
                    icon: "text.word.spacing",
                    value: "\(stats.wordCount)",
                    label: "Words"
                )

                StatItem(
                    icon: "rectangle.split.3x1",
                    value: "\(stats.segmentCount)",
                    label: "Segments"
                )
            }

            // Speaking rate
            if stats.totalSpeakingTime > 0 {
                let wordsPerMinute = Double(stats.wordCount) / (stats.totalSpeakingTime / 60.0)
                Text("\(Int(wordsPerMinute)) words/min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(SpeakerColors.backgroundColor(for: stats.speakerId, isUser: isUser))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 60 {
            return String(format: "%.0fs", duration)
        }
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

    private func formatPercentage(_ ratio: Double) -> String {
        return String(format: "%.0f%%", ratio * 100)
    }
}

struct StatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(value)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Speaker Overview

/// Overview of all speakers in a note
struct SpeakerOverview: View {
    let speakerStats: [SpeakerStats]
    let identifiedUserId: Int?
    let totalDuration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "person.2")
                Text("\(speakerStats.count) Speaker\(speakerStats.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
            }

            // Speaker breakdown bar
            if speakerStats.count > 1 {
                SpeakerBreakdownBar(
                    speakerStats: speakerStats,
                    identifiedUserId: identifiedUserId,
                    totalDuration: totalDuration
                )
            }

            // Individual speaker cards
            ForEach(sortedStats, id: \.speakerId) { stats in
                SpeakerStatsCard(
                    stats: stats,
                    isUser: stats.speakerId == identifiedUserId,
                    totalDuration: totalDuration
                )
            }
        }
    }

    private var sortedStats: [SpeakerStats] {
        speakerStats.sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }
    }
}

// MARK: - Speaker Breakdown Bar

/// Visual bar showing speaker time distribution
struct SpeakerBreakdownBar: View {
    let speakerStats: [SpeakerStats]
    let identifiedUserId: Int?
    let totalDuration: TimeInterval

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(sortedStats, id: \.speakerId) { stats in
                    let ratio = stats.totalSpeakingTime / max(totalDuration, 1)
                    let width = max(geometry.size.width * CGFloat(ratio), 4)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(SpeakerColors.color(
                            for: stats.speakerId,
                            isUser: stats.speakerId == identifiedUserId
                        ))
                        .frame(width: width)
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var sortedStats: [SpeakerStats] {
        speakerStats.sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }
    }
}

// MARK: - Diarized Transcript View

/// Displays transcript with speaker labels and color coding
struct DiarizedTranscriptView: View {
    let diarizedWords: [DiarizedWord]
    let identifiedUserId: Int?
    let playbackTime: TimeInterval?

    @State private var showSpeakerLabels = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle for speaker labels
            Toggle("Show speaker labels", isOn: $showSpeakerLabels)
                .font(.caption)
                .padding(.horizontal)

            // Transcript content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(groupedByTurns.enumerated()), id: \.offset) { _, turn in
                        SpeakerTurnView(
                            turn: turn,
                            isUser: turn.speakerId == identifiedUserId,
                            showLabel: showSpeakerLabels,
                            playbackTime: playbackTime
                        )
                    }
                }
                .padding()
            }
        }
    }

    /// Groups consecutive words by the same speaker into "turns"
    private var groupedByTurns: [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        var currentTurn: SpeakerTurn?

        for word in diarizedWords {
            if let turn = currentTurn, turn.speakerId == word.speakerId {
                currentTurn?.words.append(word)
            } else {
                if let turn = currentTurn {
                    turns.append(turn)
                }
                currentTurn = SpeakerTurn(speakerId: word.speakerId, words: [word])
            }
        }

        if let turn = currentTurn {
            turns.append(turn)
        }

        return turns
    }
}

/// Represents a continuous segment of speech by one speaker
struct SpeakerTurn: Identifiable {
    let id = UUID()
    let speakerId: Int
    var words: [DiarizedWord]

    var text: String {
        words.map { $0.word }.joined(separator: " ")
    }

    var startTime: Double {
        words.first?.start ?? 0
    }

    var endTime: Double {
        words.last?.end ?? 0
    }
}

/// View for a single speaker turn
struct SpeakerTurnView: View {
    let turn: SpeakerTurn
    let isUser: Bool
    let showLabel: Bool
    let playbackTime: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showLabel {
                SpeakerBadge(speakerId: turn.speakerId, isUser: isUser)
            }

            Text(attributedText)
                .textSelection(.enabled)
                .padding(.leading, showLabel ? 8 : 0)
        }
        .padding(.vertical, 4)
    }

    private var attributedText: AttributedString {
        var result = AttributedString()

        for (index, word) in turn.words.enumerated() {
            var wordAttr = AttributedString(word.word)

            // Highlight current word during playback
            if let time = playbackTime, time >= word.start && time <= word.end {
                wordAttr.foregroundColor = SpeakerColors.color(for: turn.speakerId, isUser: isUser)
                wordAttr.font = .body.bold()
            }

            result += wordAttr

            // Add space between words (except before punctuation)
            if index < turn.words.count - 1 {
                let nextWord = turn.words[index + 1].word
                let punctuation: Set<String> = [".", ",", "?", "!", ";", ":"]
                if !punctuation.contains(nextWord) && !nextWord.hasPrefix("'") {
                    result += AttributedString(" ")
                }
            }
        }

        return result
    }
}

// MARK: - Diarization Status View

/// Shows the status of diarization processing
struct DiarizationStatusView: View {
    let note: Note

    var body: some View {
        Group {
            if note.diarizationFailed == true {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Speaker detection failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if note.diarizationCompleted != true && note.diarizedWords == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Detecting speakers...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let count = note.speakerCount, count > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.green)
                    Text("\(count) speakers detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if note.speakerCount == 1 {
                HStack(spacing: 8) {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.blue)
                    Text("Single speaker")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Speaker Timeline View

/// Visual timeline showing when each speaker spoke
struct SpeakerTimelineView: View {
    let speakerSegments: [SpeakerSegment]
    let identifiedUserId: Int?
    let totalDuration: TimeInterval
    let currentTime: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline")
                .font(.headline)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 24)

                    // Speaker segments
                    ForEach(Array(speakerSegments.enumerated()), id: \.offset) { _, segment in
                        let startRatio = segment.startTime / max(totalDuration, 1)
                        let endRatio = segment.endTime / max(totalDuration, 1)
                        let width = max((endRatio - startRatio) * geometry.size.width, 2)
                        let offset = startRatio * geometry.size.width

                        RoundedRectangle(cornerRadius: 2)
                            .fill(SpeakerColors.color(
                                for: segment.speakerId,
                                isUser: segment.speakerId == identifiedUserId
                            ))
                            .frame(width: width, height: 20)
                            .offset(x: offset, y: 2)
                    }

                    // Playhead
                    if let time = currentTime {
                        let position = (time / max(totalDuration, 1)) * geometry.size.width
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2, height: 28)
                            .offset(x: position - 1, y: -2)
                    }
                }
            }
            .frame(height: 28)

            // Time labels
            HStack {
                Text("0:00")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatDuration(totalDuration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

// MARK: - Previews

#Preview("Speaker Badge") {
    VStack(spacing: 12) {
        SpeakerBadge(speakerId: 0, isUser: true)
        SpeakerBadge(speakerId: 1, isUser: false)
        SpeakerBadge(speakerId: 2, isUser: false, label: "John")
    }
    .padding()
}

#Preview("Speaker Stats Card") {
    SpeakerStatsCard(
        stats: SpeakerStats(
            speakerId: 0,
            totalSpeakingTime: 45.5,
            segmentCount: 8,
            wordCount: 150
        ),
        isUser: true,
        totalDuration: 60.0
    )
    .padding()
}

#Preview("Speaker Breakdown Bar") {
    SpeakerBreakdownBar(
        speakerStats: [
            SpeakerStats(speakerId: 0, totalSpeakingTime: 30, segmentCount: 5, wordCount: 100),
            SpeakerStats(speakerId: 1, totalSpeakingTime: 20, segmentCount: 3, wordCount: 60),
            SpeakerStats(speakerId: 2, totalSpeakingTime: 10, segmentCount: 2, wordCount: 30)
        ],
        identifiedUserId: 0,
        totalDuration: 60.0
    )
    .padding()
}
