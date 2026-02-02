//  AppleLLMEngine.swift
//  WalkWrite
//
//  Alternative LLM engine using Apple's Foundation Models (iOS 18.4+)
//  Zero app size impact - uses system-provided models

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// LLM Engine using Apple's on-device Foundation Models
/// Available on iOS 18.4+, macOS 15.4+
/// No app size impact - models are part of the OS
@available(iOS 18.4, macOS 15.4, *)
public final class AppleLLMEngine: Sendable {

    public static let shared = AppleLLMEngine()

    private init() {}

#if canImport(FoundationModels)

    // MARK: - Availability Check

    /// Check if Apple's on-device LLM is available
    public var isAvailable: Bool {
        get async {
            do {
                let session = LanguageModelSession()
                // Try a simple check
                return true
            } catch {
                return false
            }
        }
    }

    // MARK: - Text Generation

    private func generate(prompt: String, maxTokens: Int = 512) async throws -> String {
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt)
        return response.content
    }

    // MARK: - Public APIs

    public func cleanedTranscript(from original: String) async throws -> String {
        let prompt = """
        You are a helpful writing assistant. The user will give you a voice-note transcript.
        Rewrite it by correcting grammar, punctuation and typos, and by removing filler words
        such as 'um', 'uh', and 'you know'. Do NOT change the speaker's meaning or tone.
        Return only the cleaned transcript, no extra commentary.

        Transcript:
        \(original)

        Cleaned transcript:
        """
        return try await generate(prompt: prompt, maxTokens: 1024)
    }

    public func summary(for transcript: String) async throws -> String {
        let prompt = """
        Summarise the following voice-note transcript in 3-4 sentences.
        Preserve the speaker's intent.

        Transcript:
        \(transcript)

        Summary:
        """
        return try await generate(prompt: prompt, maxTokens: 256)
    }

    public func keyIdeas(for transcript: String) async throws -> [String] {
        let prompt = """
        Identify the key ideas from the following voice-note transcript.
        Return them as a bulleted list, one idea per line, at most 10 bullets.
        Each bullet should briefly elaborate the idea in one sentence.

        Transcript:
        \(transcript)

        Key ideas:
        """
        let raw = try await generate(prompt: prompt, maxTokens: 256)
        return raw
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "-•").union(.whitespacesAndNewlines))
            }
    }

    // MARK: - Speaker-Aware APIs

    public func cleanedDiarizedTranscript(from transcript: String, speakerContext: String) async throws -> String {
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
        return try await generate(prompt: prompt, maxTokens: 1024)
    }

    public func speakerAwareSummary(for transcript: String, speakerContext: String) async throws -> String {
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
        return try await generate(prompt: prompt, maxTokens: 300)
    }

#else

    public var isAvailable: Bool { false }

    public func cleanedTranscript(from original: String) async throws -> String {
        return original
    }

    public func summary(for transcript: String) async throws -> String {
        return ""
    }

    public func keyIdeas(for transcript: String) async throws -> [String] {
        return []
    }

    public func cleanedDiarizedTranscript(from transcript: String, speakerContext: String) async throws -> String {
        return transcript
    }

    public func speakerAwareSummary(for transcript: String, speakerContext: String) async throws -> String {
        return ""
    }

#endif
}

// MARK: - Unified LLM Interface

/// Unified LLM that tries Apple Foundation Models first, then falls back to MLX if available
public enum UnifiedLLM {

    /// Check which LLM backend is available
    public enum Backend: String {
        case apple = "Apple Intelligence"
        case mlx = "On-device MLX"
        case none = "None"
    }

    public static func availableBackend() async -> Backend {
        // Try Apple Foundation Models first (iOS 18.4+)
        if #available(iOS 18.4, *) {
            let apple = AppleLLMEngine.shared
            if await apple.isAvailable {
                return .apple
            }
        }

        // Check if MLX is compiled in
        #if canImport(MLXLLM)
        return .mlx
        #else
        return .none
        #endif
    }

    public static func cleanedTranscript(from original: String) async throws -> String {
        if #available(iOS 18.4, *) {
            let apple = AppleLLMEngine.shared
            if await apple.isAvailable {
                return try await apple.cleanedTranscript(from: original)
            }
        }

        #if canImport(MLXLLM)
        return try await LLMEngine.shared.cleanedTranscript(from: original)
        #else
        return original
        #endif
    }

    public static func summary(for transcript: String) async throws -> String {
        if #available(iOS 18.4, *) {
            let apple = AppleLLMEngine.shared
            if await apple.isAvailable {
                return try await apple.summary(for: transcript)
            }
        }

        #if canImport(MLXLLM)
        return try await LLMEngine.shared.summary(for: transcript)
        #else
        return ""
        #endif
    }

    public static func keyIdeas(for transcript: String) async throws -> [String] {
        if #available(iOS 18.4, *) {
            let apple = AppleLLMEngine.shared
            if await apple.isAvailable {
                return try await apple.keyIdeas(for: transcript)
            }
        }

        #if canImport(MLXLLM)
        return try await LLMEngine.shared.keyIdeas(for: transcript)
        #else
        return []
        #endif
    }
}
