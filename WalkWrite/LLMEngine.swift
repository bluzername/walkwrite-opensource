//  LLMEngine.swift
//  WalkWrite

import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

enum LLMError: Error {
    case modelNotFound
    case failedToLoadModel
    case generationFailed
    case generationCancelledOrInBackground // New error case
}

@globalActor
public actor LLMActor { // Made public
    public static let shared = LLMActor() // Made public
}

/// Singleton wrapper around Qwen-3 0.6B running through MLX-Swift.
/// Heavy model loading happens lazily on first use and is isolated to the
/// `LLMActor` so we never block the main thread.
@LLMActor
public final class LLMEngine { // Made public

    // MARK: – Public access
    public static let shared = LLMEngine() // Made public

    // MARK: – Private state
   #if canImport(MLXLLM)
       private var container: ModelContainer?
       private var isCancelling: Bool = false
       private var forceCancelled: Bool = false // Added for explicit cancellation
   #endif

       private init() {
   #if canImport(UIKit)
           NotificationCenter.default.addObserver(
               forName: UIApplication.didReceiveMemoryWarningNotification,
               object: nil,
               queue: nil) { [weak self] _ in
                   Task { await self?.unload() }
           }
           NotificationCenter.default.addObserver(
               forName: UIApplication.willResignActiveNotification,
               object: nil,
               queue: nil) { [weak self] _ in
                   Task { await self?.handleAppWillResignActive() }
           }
           NotificationCenter.default.addObserver(
               forName: UIApplication.didBecomeActiveNotification,
               object: nil,
               queue: nil) { [weak self] _ in
                   Task { await self?.handleAppDidBecomeActive() }
           }
   #endif
       }

    #if canImport(UIKit)
        private func handleAppWillResignActive() async {
            NSLog("LLMEngine: App will resign active. Setting cancellation flag.")
            #if canImport(MLXLLM)
            self.isCancelling = true
            #endif
        }

        private func handleAppDidBecomeActive() async {
            NSLog("LLMEngine: App did become active. Resetting cancellation flags.")
            #if canImport(MLXLLM)
            self.isCancelling = false
            self.forceCancelled = false // Reset forceCancelled as well
            #endif
        }
    #endif

#if canImport(MLXLLM)
    // Method to allow explicit cancellation, e.g., from background task expiration
    public func forceCancelOperations() { // Already public, ensure class is public
        self.forceCancelled = true
        self.isCancelling = true // Also set the existing flag for broader effect
        NSLog("LLMEngine: forceCancelOperations called. forceCancelled = \(self.forceCancelled), isCancelling = \(self.isCancelling)")
    }
#endif



    // Free the loaded model to release GPU/CPU memory. Safe to call if no
    // generation is in progress.
    func unload() async {
#if canImport(MLXLLM)
        container = nil
        // Shrink MLX buffer cache further to encourage immediate release.
        MLX.GPU.set(cacheLimit: 8 * 1024 * 1024)
#endif
    }

    // MARK: – Model loading

#if canImport(MLXLLM)
    private func ensureLoaded() async throws {
        if container != nil { return }

        // Reduce GPU memory pressure; setting a very small cache effectively
        // discourages large GPU allocations which mitigates Metal background
        // execution restrictions.
        MLX.GPU.set(cacheLimit: 4 * 1024 * 1024)
        // Uncomment to hard-cap total GPU allocations (requires Increased Memory Limit entitlement).
        // MLX.GPU.set(memoryLimit: 1600 * 1024 * 1024)

        // Try blue-folder reference first; if that fails, fall back to bundle root
        let modelDir: URL
        if let dir = Bundle.main.url(forResource: "QwenModel", withExtension: nil) {
            modelDir = dir
        } else if let cfg = Bundle.main.url(forResource: "config", withExtension: "json") {
            // When individual files are copied, config.json will be at bundle root.
            modelDir = cfg.deletingLastPathComponent()
        } else {
            throw LLMError.modelNotFound
        }

        let config = ModelConfiguration(directory: modelDir)

        // Qwen3 uses model_type "qwen3" which is built-in; no extra registration needed.
        // Accessing shared factory, assuming it's not async based on error
        let factory = LLMModelFactory.shared
        container = try await factory.loadContainer(configuration: config)
    }
#endif

    // MARK: – Prompt helpers

#if canImport(MLXLLM)
    private func run(prompt: String, maxTokens: Int = 512) async throws -> String {
        // Initial cancellation check before any heavy work
        // Restore await as property access on actors is async
        let currentIsCancelling = self.isCancelling
        let currentForceCancelled = self.forceCancelled
        if currentIsCancelling || currentForceCancelled {
            NSLog("LLMEngine: run() called but isCancelling or forceCancelled is true. Aborting before ensureLoaded.")
            throw LLMError.generationCancelledOrInBackground
        }

        try await ensureLoaded()
        guard let container else { throw LLMError.failedToLoadModel }

        return try await container.perform { (context: ModelContext) async throws -> String in

            // --- BEGIN Background/Cancellation Check ---
            // The UIApplication.shared.applicationState check is removed to allow background execution
            // when properly wrapped by a UIBackgroundTaskIdentifier.
            // Cancellation is now primarily handled by isCancelling and forceCancelled flags.

            // Re-check cancellation flags just before starting generation, as state might have changed.
            // These are awaited directly on the actor within the actor-isolated `container.perform` closure.
            let isCancellingAtGenerationStart = await self.isCancelling
            let isForceCancelledAtGenerationStart = await self.forceCancelled
            if isCancellingAtGenerationStart || isForceCancelledAtGenerationStart {
                NSLog("LLMEngine: Cancellation flag (isCancelling or forceCancelled) is set before MLX generate. Aborting.")
                throw LLMError.generationCancelledOrInBackground
            }
            // --- END Background/Cancellation Check ---

            // Capture cancellation state *before* entering the nonisolated generate callback
            // Use the values already fetched: isCancellingAtGenerationStart, isForceCancelledAtGenerationStart
            // These are Bool, not awaitables, suitable for capture.
            let capturedShouldCancel = isCancellingAtGenerationStart || isForceCancelledAtGenerationStart

            let messages = [["role": "user", "content": prompt]]

            let promptTokens = try context.tokenizer.applyChatTemplate(messages: messages)

                let lmInput = LMInput(tokens: MLXArray(promptTokens))

                var output = ""
                var parameters = GenerateParameters()
                parameters.temperature = 0.7

                // Use callback-style generation; accumulate decoded text.
                _ = try MLXLMCommon.generate(
                    input: lmInput,
                    parameters: parameters,
                    context: context) { tokens in
                        // Use the captured boolean state inside the nonisolated closure
                        if capturedShouldCancel {
                            NSLog("LLMEngine: Captured cancellation flag true during generation. Stopping.")
                            return .stop // Signal MLX to stop generating tokens
                        }

                        guard let last = tokens.last else { return .more }
                        let piece = context.tokenizer.decode(tokens: [last])
                        output += piece
                        return .more
                    }

            // Check cancellation status *after* generation attempt
            // Re-fetch the latest state from the actor.
            let finalIsCancelling = await self.isCancelling
            let finalForceCancelled = await self.forceCancelled
            if finalIsCancelling || finalForceCancelled {
                NSLog("LLMEngine: Generation was cancelled or interrupted (isCancelling or forceCancelled after generate). Output may be partial.")
                // Throwing here ensures the caller knows the result might be incomplete
                throw LLMError.generationCancelledOrInBackground
            }

            // Remove any <think>...</think> segments entirely.

            let cleaned = output.replacingOccurrences(
                of: #"<think>[\s\S]*?<\/think>"#,
                with: "",
                options: .regularExpression)
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
#endif

    // MARK: – Public APIs

    public func cleanedTranscript(from original: String) async throws -> String { // Made public
#if canImport(MLXLLM)
        let prompt = "You are a helpful writing assistant. The user will give you a voice-note transcript. Rewrite it by correcting grammar, punctuation and typos, and by removing filler words such as 'um', 'uh', and 'you know'. Do NOT change the speaker's meaning or tone. Return only the cleaned transcript, no extra commentary.\n\nTranscript:\n\(original)\n\nCleaned transcript:"
        return try await run(prompt: prompt, maxTokens: 1024)
#else
        return original
#endif
    }

    public func summary(for transcript: String) async throws -> String { // Made public
#if canImport(MLXLLM)
        let prompt = "Summarise the following voice-note transcript in 3-4 sentences. Preserve the speaker's intent.\n\nTranscript:\n\(transcript)\n\nSummary:"
        return try await run(prompt: prompt, maxTokens: 256)
#else
        return ""
#endif
    }

    public func keyIdeas(for transcript: String) async throws -> [String] { // Made public
#if canImport(MLXLLM)
        let prompt = "Identify the key ideas from the following voice-note transcript. Return them as a bulleted list, one idea per line, at most 10 bullets. Each bullet should briefly elaborate the idea in one sentence.\n\nTranscript:\n\(transcript)\n\nKey ideas:\n-"
        let raw = try await run(prompt: prompt, maxTokens: 256)
        let bullets = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "-•").union(.whitespacesAndNewlines))
            }
        return bullets
#else
        return []
#endif
    }

    // MARK: – Speaker-Aware APIs (Phase 3)

    /// Clean a diarized transcript, preserving speaker labels
    /// - Parameters:
    ///   - transcript: The diarized transcript with speaker labels
    ///   - speakerContext: Context about the speakers (from SpeakerLabeler.generateLLMContext)
    /// - Returns: Cleaned transcript with speaker labels preserved
    public func cleanedDiarizedTranscript(from transcript: String, speakerContext: String) async throws -> String {
#if canImport(MLXLLM)
        let prompt = """
        You are a helpful writing assistant. The user will give you a voice-note transcript with multiple speakers.

        \(speakerContext)

        Rewrite the transcript by:
        1. Correcting grammar, punctuation and typos
        2. Removing filler words such as 'um', 'uh', and 'you know'
        3. PRESERVING the speaker labels exactly as they appear (e.g., [You]:, [Speaker 2]:)
        4. NOT changing the speakers' meaning or tone

        Return only the cleaned transcript with speaker labels, no extra commentary.

        Transcript:
        \(transcript)

        Cleaned transcript:
        """
        return try await run(prompt: prompt, maxTokens: 1024)
#else
        return transcript
#endif
    }

    /// Generate a speaker-aware summary
    /// - Parameters:
    ///   - transcript: The diarized transcript with speaker labels
    ///   - speakerContext: Context about the speakers
    /// - Returns: Summary that incorporates speaker perspectives
    public func speakerAwareSummary(for transcript: String, speakerContext: String) async throws -> String {
#if canImport(MLXLLM)
        let prompt = """
        Summarise the following multi-speaker voice-note transcript in 3-5 sentences.

        \(speakerContext)

        Focus on:
        1. The main topics discussed
        2. Key points made by each speaker
        3. Any decisions, action items, or conclusions reached
        4. The overall context from the recording user's perspective

        Transcript:
        \(transcript)

        Summary:
        """
        return try await run(prompt: prompt, maxTokens: 300)
#else
        return ""
#endif
    }

    /// Generate speaker-aware key ideas
    /// - Parameters:
    ///   - transcript: The diarized transcript with speaker labels
    ///   - speakerContext: Context about the speakers
    /// - Returns: Key ideas attributed to speakers where relevant
    public func speakerAwareKeyIdeas(for transcript: String, speakerContext: String) async throws -> [String] {
#if canImport(MLXLLM)
        let prompt = """
        Identify the key ideas from the following multi-speaker voice-note transcript.

        \(speakerContext)

        Return them as a bulleted list, one idea per line, at most 10 bullets.
        For each idea:
        - Briefly state the idea
        - Attribute it to the speaker(s) who raised it when relevant
        - Add one sentence of elaboration

        Transcript:
        \(transcript)

        Key ideas:
        -
        """
        let raw = try await run(prompt: prompt, maxTokens: 350)
        let bullets = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "-•").union(.whitespacesAndNewlines))
            }
        return bullets
#else
        return []
#endif
    }

    /// Analyze a conversation for action items and follow-ups
    /// - Parameters:
    ///   - transcript: The diarized transcript
    ///   - speakerContext: Context about the speakers
    /// - Returns: List of action items with assigned speakers
    public func extractActionItems(from transcript: String, speakerContext: String) async throws -> [String] {
#if canImport(MLXLLM)
        let prompt = """
        Review the following multi-speaker conversation and extract any action items, tasks, or commitments.

        \(speakerContext)

        For each action item:
        - State what needs to be done
        - Note who is responsible (if mentioned)
        - Include any deadlines or timeframes mentioned

        If no clear action items exist, return "No specific action items identified."

        Transcript:
        \(transcript)

        Action items:
        -
        """
        let raw = try await run(prompt: prompt, maxTokens: 256)

        // Handle "no action items" case
        if raw.lowercased().contains("no specific action items") ||
           raw.lowercased().contains("no action items") {
            return []
        }

        let bullets = raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "-•").union(.whitespacesAndNewlines))
            }
        return bullets
#else
        return []
#endif
    }
}
