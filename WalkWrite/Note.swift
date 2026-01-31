import Foundation

// WordStamp is now defined in WhisperEngine.swift

/// Domain model representing one voice note.
public struct Note: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var createdAt: Date
    public var duration: TimeInterval
    public var audioURL: URL        // path on disk
    public var transcript: String
    public var words: [WordStamp]

    // MARK: – LLM post-processing results (optional)
    /// Transcript after grammar/filler-word cleanup produced by Gemma.
    public var cleanedTranscript: String?

    /// One-paragraph gist of the note.
    public var summary: String?

    /// Up to ten key ideas extracted and lightly elaborated by the LLM.
    public var keyIdeas: [String]?

    /// Flag persisted when the last attempt at generating the cleaned transcript
    /// / summary / key-ideas pipeline failed. `nil` means no attempt yet or the
    /// last run succeeded, `true` indicates the most recent run threw and
    /// aborted early. UI can surface a "Try Again" button based on this.
    public var enhancementFailed: Bool?

    // MARK: – Phase 1: VAD metadata (optional)

    /// Original recording duration before VAD filtering (nil for traditional mode)
    public var originalRecordingDuration: TimeInterval?

    /// Duration of speech detected by VAD (nil for traditional mode)
    public var speechDuration: TimeInterval?

    /// Speech segments detected by VAD
    public var vadSegments: [SpeechSegment]?

    // MARK: – Phase 2/3: Diarization data (optional)

    /// Words with speaker assignments from diarization
    public var diarizedWords: [DiarizedWord]?

    /// Speaker segments from clustering
    public var speakerSegments: [SpeakerSegment]?

    /// Statistics for each detected speaker
    public var speakerStats: [SpeakerStats]?

    /// Total number of unique speakers detected
    public var speakerCount: Int?

    /// The identified user's speaker ID (most consistent speaker by speaking time)
    public var identifiedUserId: Int?

    /// Cleaned transcript with speaker labels
    public var diarizedCleanedTranscript: String?

    /// Summary that incorporates speaker context
    public var speakerAwareSummary: String?

    /// Whether diarization processing has been completed
    public var diarizationCompleted: Bool?

    /// Whether diarization processing failed
    public var diarizationFailed: Bool?

    public init(id: UUID = .init(),
                createdAt: Date = .now,
                duration: TimeInterval = 0,
                audioURL: URL,
                transcript: String = "",
                words: [WordStamp] = [],
                cleanedTranscript: String? = nil,
                summary: String? = nil,
                keyIdeas: [String]? = nil,
                enhancementFailed: Bool? = nil,
                originalRecordingDuration: TimeInterval? = nil,
                speechDuration: TimeInterval? = nil,
                vadSegments: [SpeechSegment]? = nil,
                diarizedWords: [DiarizedWord]? = nil,
                speakerSegments: [SpeakerSegment]? = nil,
                speakerStats: [SpeakerStats]? = nil,
                speakerCount: Int? = nil,
                identifiedUserId: Int? = nil,
                diarizedCleanedTranscript: String? = nil,
                speakerAwareSummary: String? = nil,
                diarizationCompleted: Bool? = nil,
                diarizationFailed: Bool? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.audioURL = audioURL
        self.transcript = transcript
        self.words = words

        self.cleanedTranscript = cleanedTranscript
        self.summary = summary
        self.keyIdeas = keyIdeas
        self.enhancementFailed = enhancementFailed

        self.originalRecordingDuration = originalRecordingDuration
        self.speechDuration = speechDuration
        self.vadSegments = vadSegments

        self.diarizedWords = diarizedWords
        self.speakerSegments = speakerSegments
        self.speakerStats = speakerStats
        self.speakerCount = speakerCount
        self.identifiedUserId = identifiedUserId
        self.diarizedCleanedTranscript = diarizedCleanedTranscript
        self.speakerAwareSummary = speakerAwareSummary
        self.diarizationCompleted = diarizationCompleted
        self.diarizationFailed = diarizationFailed
    }

    // MARK: - Convenience Properties

    /// Returns true if this note has diarization data
    public var hasDiarization: Bool {
        diarizationCompleted == true && diarizedWords != nil && !diarizedWords!.isEmpty
    }

    /// Returns true if multiple speakers were detected
    public var hasMultipleSpeakers: Bool {
        (speakerCount ?? 0) > 1
    }

    /// Returns the formatted transcript with speaker labels if available
    public var formattedTranscript: String {
        if let diarizedWords = diarizedWords, !diarizedWords.isEmpty {
            return DiarizedTranscriptFormatter.format(words: diarizedWords, userSpeakerId: identifiedUserId)
        }
        return cleanedTranscript ?? transcript
    }

    // MARK: – Persistence helper

    static var indexFile: URL {
        AppFolders.notes.appendingPathComponent("notes.json")
    }
}
