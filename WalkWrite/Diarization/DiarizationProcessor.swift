import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Diarization Processing Tracker

/// Tracks ongoing diarization processing to prevent duplicate jobs
actor DiarizationProcessTracker {
    static let shared = DiarizationProcessTracker()

    private var current: UUID?

    /// Returns `true` when the caller successfully acquired the slot
    func start(_ id: UUID) -> Bool {
        guard current == nil else { return false }
        current = id
        return true
    }

    func finish(_ id: UUID) {
        if current == id { current = nil }
    }

    func isProcessing(_ id: UUID) -> Bool {
        current == id
    }
}

// MARK: - Diarization Processor

/// Handles the complete diarization flow for a note
/// Runs diarization, identifies user, and triggers speaker-aware LLM enhancement
public func enqueueDiarization(
    for note: Note,
    in store: NoteStore,
    timeMappings: [AudioSegmentManager.TimeMapping]? = nil
) {
    Task { @MainActor in
        // Mark diarization as in progress
        var fresh = note
        fresh.diarizationFailed = nil
        fresh.diarizationCompleted = false
        store.update(fresh)
    }

    Task.detached(priority: .utility) { [weak store] in
        #if canImport(UIKit)
        let backgroundTaskID = await UIApplication.shared.beginBackgroundTask(withName: "Diarization-\(note.id)") {
            NSLog("Diarization background task expiring for note \(note.id)")
        }
        #endif

        defer {
            #if canImport(UIKit)
            Task {
                await UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
            #endif
        }

        // Prevent duplicate runs
        guard await DiarizationProcessTracker.shared.start(note.id) else {
            NSLog("Diarization for note \(note.id) already in progress")
            return
        }

        defer {
            Task {
                await DiarizationProcessTracker.shared.finish(note.id)
            }
        }

        do {
            NSLog("Starting diarization for note \(note.id)")

            // Run diarization pipeline
            let pipeline = DiarizationPipeline.shared
            let config = DiarizationConfig.default

            let result: DiarizationResult
            if let mappings = timeMappings, !mappings.isEmpty {
                // Use time mapping for VAD-filtered audio
                result = try await pipeline.diarizeWithTimeMapping(
                    audioURL: note.audioURL,
                    words: note.words,
                    timeMappings: mappings,
                    config: config
                ) { progress in
                    NSLog("Diarization progress: \(Int(progress * 100))%")
                }
            } else {
                // Standard diarization
                result = try await pipeline.diarize(
                    audioURL: note.audioURL,
                    words: note.words,
                    config: config
                ) { progress in
                    NSLog("Diarization progress: \(Int(progress * 100))%")
                }
            }

            NSLog("Diarization complete: \(result.speakerCount) speakers, \(result.diarizedWords.count) words")

            // Identify user
            let userIdentifier = UserIdentifier()
            let userResult = userIdentifier.identifyUser(from: result)

            NSLog("User identification: \(userResult?.userId ?? -1) with confidence \(userResult?.confidence ?? 0)")

            // Update note with diarization results
            if let store {
                await MainActor.run {
                    if var n = store[note.id] {
                        n.diarizedWords = result.diarizedWords
                        n.speakerSegments = result.speakerSegments
                        n.speakerStats = result.speakerStats
                        n.speakerCount = result.speakerCount
                        n.identifiedUserId = userResult?.userId ?? result.identifiedUserId
                        n.diarizationCompleted = true
                        n.diarizationFailed = false
                        store.update(n)
                        NSLog("Updated note \(note.id) with diarization results")
                    }
                }
            }

        } catch DiarizationError.cancelled {
            NSLog("Diarization cancelled for note \(note.id)")
            if let store {
                await MainActor.run {
                    if var n = store[note.id] {
                        n.diarizationFailed = true
                        n.diarizationCompleted = false
                        store.update(n)
                    }
                }
            }
        } catch DiarizationError.insufficientAudio {
            NSLog("Insufficient audio for diarization: \(note.id)")
            // Not a failure - just skip diarization for short audio
            if let store {
                await MainActor.run {
                    if var n = store[note.id] {
                        n.diarizationCompleted = true
                        n.diarizationFailed = false
                        n.speakerCount = 1
                        store.update(n)
                    }
                }
            }
        } catch {
            NSLog("Diarization failed for note \(note.id): \(error)")
            if let store {
                await MainActor.run {
                    if var n = store[note.id] {
                        n.diarizationFailed = true
                        n.diarizationCompleted = false
                        store.update(n)
                    }
                }
            }
        }
    }
}

// MARK: - Speaker-Aware Enhancement

/// Enhanced version of enqueueEnhancement that uses diarization data
public func enqueueSpeakerAwareEnhancement(for note: Note, in store: NoteStore) {
    Task { @MainActor in
        var fresh = note
        fresh.enhancementFailed = nil
        store.update(fresh)
    }

    Task.detached(priority: .utility) { [weak store] in
        #if canImport(UIKit)
        let backgroundTaskID = await UIApplication.shared.beginBackgroundTask(withName: "SpeakerAwareEnhancement-\(note.id)") {
            Task {
                await LLMEngine.shared.forceCancelOperations()
            }
        }
        #endif

        defer {
            #if canImport(UIKit)
            Task {
                await UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
            #endif
        }

        guard await PostProcessTracker.shared.start(note.id) else {
            NSLog("Enhancement for note \(note.id) already in progress")
            return
        }

        defer {
            Task {
                await PostProcessTracker.shared.finish(note.id)
            }
        }

        do {
            // Check if we have diarization data
            let hasDiarization = note.diarizedWords != nil && !(note.diarizedWords?.isEmpty ?? true)
            let hasMultipleSpeakers = (note.speakerCount ?? 1) > 1

            if hasDiarization && hasMultipleSpeakers {
                // Use speaker-aware processing
                NSLog("Using speaker-aware enhancement for note \(note.id)")
                try await runSpeakerAwareEnhancement(for: note, store: store)
            } else {
                // Fall back to standard processing
                NSLog("Using standard enhancement for note \(note.id)")
                try await runStandardEnhancement(for: note, store: store)
            }

            // Unload LLM after processing
            await LLMEngine.shared.unload()

        } catch {
            NSLog("Enhancement failed for note \(note.id): \(error)")
            if let store {
                await MainActor.run {
                    if var n = store[note.id] {
                        n.enhancementFailed = true
                        store.update(n)
                    }
                }
            }
        }
    }
}

// MARK: - Private Enhancement Functions

private func runSpeakerAwareEnhancement(for note: Note, store: NoteStore?) async throws {
    guard let diarizedWords = note.diarizedWords,
          let speakerStats = note.speakerStats else {
        // Fall back to standard if diarization data is missing
        try await runStandardEnhancement(for: note, store: store)
        return
    }

    // Generate speaker context for LLM
    let speakerContext = SpeakerLabeler.generateLLMContext(
        speakerStats: speakerStats,
        userId: note.identifiedUserId
    )

    // Format diarized transcript
    let diarizedTranscript = SpeakerLabeler.formatTranscript(
        diarizedWords: diarizedWords,
        speakerStats: speakerStats,
        userId: note.identifiedUserId
    )

    // Step 1: Clean diarized transcript
    NSLog("Cleaning diarized transcript for note \(note.id)")
    let cleaned = try await LLMEngine.shared.cleanedDiarizedTranscript(
        from: diarizedTranscript,
        speakerContext: speakerContext
    )

    if let store {
        await MainActor.run {
            if var n = store[note.id] {
                n.diarizedCleanedTranscript = cleaned
                n.cleanedTranscript = cleaned  // Also set standard field for compatibility
                store.update(n)
            }
        }
    }

    // Step 2: Generate speaker-aware summary
    NSLog("Generating speaker-aware summary for note \(note.id)")
    let summary = try await LLMEngine.shared.speakerAwareSummary(
        for: cleaned,
        speakerContext: speakerContext
    )

    if let store {
        await MainActor.run {
            if var n = store[note.id] {
                n.speakerAwareSummary = summary
                n.summary = summary  // Also set standard field
                store.update(n)
            }
        }
    }

    // Step 3: Generate speaker-aware key ideas
    NSLog("Generating speaker-aware key ideas for note \(note.id)")
    let ideas = try await LLMEngine.shared.speakerAwareKeyIdeas(
        for: cleaned,
        speakerContext: speakerContext
    )

    if let store {
        await MainActor.run {
            if var n = store[note.id] {
                n.keyIdeas = ideas
                n.enhancementFailed = false
                store.update(n)
            }
        }
    }

    NSLog("Speaker-aware enhancement complete for note \(note.id)")
}

private func runStandardEnhancement(for note: Note, store: NoteStore?) async throws {
    // Step 1: Clean transcript
    NSLog("Cleaning transcript for note \(note.id)")
    let cleaned = try await LLMEngine.shared.cleanedTranscript(from: note.transcript)

    if let store {
        await MainActor.run {
            if var n = store[note.id] {
                n.cleanedTranscript = cleaned
                store.update(n)
            }
        }
    }

    // Step 2: Generate summary
    NSLog("Generating summary for note \(note.id)")
    let summary = try await LLMEngine.shared.summary(for: cleaned)

    if let store {
        await MainActor.run {
            if var n = store[note.id] {
                n.summary = summary
                store.update(n)
            }
        }
    }

    // Step 3: Generate key ideas
    NSLog("Generating key ideas for note \(note.id)")
    let ideas = try await LLMEngine.shared.keyIdeas(for: cleaned)

    if let store {
        await MainActor.run {
            if var n = store[note.id] {
                n.keyIdeas = ideas
                n.enhancementFailed = false
                store.update(n)
            }
        }
    }

    NSLog("Standard enhancement complete for note \(note.id)")
}

// MARK: - Combined Pipeline

/// Run the complete pipeline: diarization first, then speaker-aware enhancement
public func enqueueFullDiarizationPipeline(
    for note: Note,
    in store: NoteStore,
    timeMappings: [AudioSegmentManager.TimeMapping]? = nil
) {
    Task.detached(priority: .utility) { [weak store] in
        guard let store else { return }

        // Step 1: Run diarization
        NSLog("Starting full diarization pipeline for note \(note.id)")

        #if canImport(UIKit)
        let backgroundTaskID = await UIApplication.shared.beginBackgroundTask(withName: "FullPipeline-\(note.id)") {
            Task {
                await DiarizationPipeline.shared.cancel()
                await LLMEngine.shared.forceCancelOperations()
            }
        }
        #endif

        defer {
            #if canImport(UIKit)
            Task {
                await UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
            #endif
        }

        // Run diarization synchronously in this task
        do {
            let pipeline = DiarizationPipeline.shared
            let config = DiarizationConfig.default

            let result: DiarizationResult
            if let mappings = timeMappings, !mappings.isEmpty {
                result = try await pipeline.diarizeWithTimeMapping(
                    audioURL: note.audioURL,
                    words: note.words,
                    timeMappings: mappings,
                    config: config
                )
            } else {
                result = try await pipeline.diarize(
                    audioURL: note.audioURL,
                    words: note.words,
                    config: config
                )
            }

            // Identify user
            let userIdentifier = UserIdentifier()
            let userResult = userIdentifier.identifyUser(from: result)

            // Update note with diarization
            var updatedNote: Note?
            await MainActor.run {
                if var n = store[note.id] {
                    n.diarizedWords = result.diarizedWords
                    n.speakerSegments = result.speakerSegments
                    n.speakerStats = result.speakerStats
                    n.speakerCount = result.speakerCount
                    n.identifiedUserId = userResult?.userId ?? result.identifiedUserId
                    n.diarizationCompleted = true
                    n.diarizationFailed = false
                    store.update(n)
                    updatedNote = n
                }
            }

            // Step 2: Run enhancement with diarized data
            if let noteForEnhancement = updatedNote {
                try await runSpeakerAwareOrStandardEnhancement(for: noteForEnhancement, store: store)
            }

        } catch DiarizationError.insufficientAudio {
            // Short audio - still run standard enhancement
            NSLog("Insufficient audio for diarization, using standard enhancement")
            await MainActor.run {
                if var n = store[note.id] {
                    n.diarizationCompleted = true
                    n.speakerCount = 1
                    store.update(n)
                }
            }
            if let n = await MainActor.run(body: { store[note.id] }) {
                try? await runStandardEnhancement(for: n, store: store)
            }
        } catch {
            NSLog("Full pipeline failed for note \(note.id): \(error)")
            await MainActor.run {
                if var n = store[note.id] {
                    n.diarizationFailed = true
                    n.enhancementFailed = true
                    store.update(n)
                }
            }
        }

        await LLMEngine.shared.unload()
        NSLog("Full diarization pipeline complete for note \(note.id)")
    }
}

private func runSpeakerAwareOrStandardEnhancement(for note: Note, store: NoteStore) async throws {
    let hasDiarization = note.diarizedWords != nil && !(note.diarizedWords?.isEmpty ?? true)
    let hasMultipleSpeakers = (note.speakerCount ?? 1) > 1

    if hasDiarization && hasMultipleSpeakers {
        try await runSpeakerAwareEnhancement(for: note, store: store)
    } else {
        try await runStandardEnhancement(for: note, store: store)
    }
}
