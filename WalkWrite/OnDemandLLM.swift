//  OnDemandLLM.swift
//  WalkWrite
//
//  Downloads LLM model on first use instead of bundling
//  Reduces app size from ~4GB to ~200MB

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages on-demand LLM model downloading
public actor OnDemandModelManager {

    public static let shared = OnDemandModelManager()

    // MARK: - Model Configuration

    /// Available models with their download sizes
    public enum ModelVariant: String, CaseIterable {
        case qwen3_0_6B = "Qwen/Qwen3-0.6B-MLX"           // ~600MB
        case qwen3_1_7B = "Qwen/Qwen3-1.7B-MLX-4bit"      // ~1GB (quantized)
        case smollm2_360m = "HuggingFaceTB/SmolLM2-360M"  // ~360MB

        public var displayName: String {
            switch self {
            case .qwen3_0_6B: return "Qwen 3 (0.6B) - Fast"
            case .qwen3_1_7B: return "Qwen 3 (1.7B) - Better quality"
            case .smollm2_360m: return "SmolLM2 (360M) - Fastest"
            }
        }

        public var estimatedSize: String {
            switch self {
            case .qwen3_0_6B: return "~600 MB"
            case .qwen3_1_7B: return "~1 GB"
            case .smollm2_360m: return "~360 MB"
            }
        }
    }

    // MARK: - State

    public enum DownloadState: Sendable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case failed(Error)
    }

    private var downloadState: DownloadState = .notDownloaded
    private var currentVariant: ModelVariant?

    // MARK: - Paths

    private var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("LLMModels", isDirectory: true)
    }

    private func modelPath(for variant: ModelVariant) -> URL {
        modelsDirectory.appendingPathComponent(variant.rawValue.replacingOccurrences(of: "/", with: "_"))
    }

    // MARK: - Public API

    public func isModelDownloaded(_ variant: ModelVariant = .qwen3_0_6B) -> Bool {
        let path = modelPath(for: variant)
        let configPath = path.appendingPathComponent("config.json")
        return FileManager.default.fileExists(atPath: configPath.path)
    }

    public func getDownloadState() -> DownloadState {
        return downloadState
    }

    public func downloadModel(
        variant: ModelVariant = .qwen3_0_6B,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        guard !isModelDownloaded(variant) else {
            downloadState = .downloaded
            return
        }

        downloadState = .downloading(progress: 0)
        currentVariant = variant

        // Create models directory
        try FileManager.default.createDirectory(
            at: modelsDirectory,
            withIntermediateDirectories: true
        )

        let destination = modelPath(for: variant)

        // Use huggingface-cli or URLSession to download
        // For now, provide instructions
        downloadState = .failed(OnDemandError.notImplemented)
        throw OnDemandError.notImplemented
    }

    public func deleteModel(_ variant: ModelVariant) throws {
        let path = modelPath(for: variant)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        downloadState = .notDownloaded
    }

    public func getModelPath(_ variant: ModelVariant = .qwen3_0_6B) -> URL? {
        guard isModelDownloaded(variant) else { return nil }
        return modelPath(for: variant)
    }
}

public enum OnDemandError: Error, LocalizedError {
    case notImplemented
    case downloadFailed(String)
    case modelNotFound

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "On-demand download requires manual setup. See instructions below."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .modelNotFound:
            return "Model not found. Please download first."
        }
    }
}

// MARK: - Settings View for Model Management

#if canImport(SwiftUI)
import SwiftUI

struct LLMModelSettingsView: View {
    @State private var selectedVariant: OnDemandModelManager.ModelVariant = .qwen3_0_6B
    @State private var isDownloaded = false
    @State private var showInstructions = false

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $selectedVariant) {
                    ForEach(OnDemandModelManager.ModelVariant.allCases, id: \.self) { variant in
                        VStack(alignment: .leading) {
                            Text(variant.displayName)
                            Text(variant.estimatedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(variant)
                    }
                }

                if isDownloaded {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Model downloaded")
                    }
                } else {
                    Button("Download Instructions") {
                        showInstructions = true
                    }
                }
            } header: {
                Text("AI Model")
            } footer: {
                Text("Smaller models are faster but less accurate. Models are downloaded separately to keep app size small.")
            }

            if isDownloaded {
                Section {
                    Button("Delete Model", role: .destructive) {
                        Task {
                            try? await OnDemandModelManager.shared.deleteModel(selectedVariant)
                            await checkDownloadStatus()
                        }
                    }
                }
            }
        }
        .navigationTitle("AI Settings")
        .task {
            await checkDownloadStatus()
        }
        .onChange(of: selectedVariant) { _, _ in
            Task { await checkDownloadStatus() }
        }
        .sheet(isPresented: $showInstructions) {
            ModelDownloadInstructionsView(variant: selectedVariant)
        }
    }

    private func checkDownloadStatus() async {
        isDownloaded = await OnDemandModelManager.shared.isModelDownloaded(selectedVariant)
    }
}

struct ModelDownloadInstructionsView: View {
    let variant: OnDemandModelManager.ModelVariant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Manual Model Download")
                        .font(.title2)
                        .bold()

                    Text("To keep the app small, AI models are downloaded separately.")

                    GroupBox("Option 1: Apple Intelligence (Recommended)") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("If you have iOS 18.4+ with Apple Intelligence enabled:")
                            Text("• No download needed")
                            Text("• Uses Apple's built-in models")
                            Text("• Zero storage impact")
                        }
                        .font(.subheadline)
                    }

                    GroupBox("Option 2: Download via Computer") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("1. On your Mac, install huggingface-cli:")
                            Text("   pip install huggingface_hub")
                                .font(.system(.caption, design: .monospaced))

                            Text("2. Download the model:")
                            Text("   huggingface-cli download \(variant.rawValue)")
                                .font(.system(.caption, design: .monospaced))

                            Text("3. Transfer to iPhone via Files app")
                        }
                        .font(.subheadline)
                    }

                    GroupBox("Model Info") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Model: \(variant.displayName)")
                            Text("Size: \(variant.estimatedSize)")
                            Text("Source: Hugging Face")
                        }
                        .font(.subheadline)
                    }
                }
                .padding()
            }
            .navigationTitle("Download Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#endif
