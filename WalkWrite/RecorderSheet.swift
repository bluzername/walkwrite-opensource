import SwiftUI
import AVFoundation
#if canImport(StoreKit)
import StoreKit
#endif

/// Full-screen sheet that records audio and runs Whisper transcription.
struct RecorderSheet: View {
    @Environment(NoteStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = RecorderViewModel()

#if canImport(UIKit)
    @State private var showUpgrade = false
#endif
    @State private var showVADSettings = false

    var body: some View {
        VStack(spacing: 32) {
            // Status Text
            Group {
                if vm.permissionDenied {
                    Text("Microphone access denied.\nEnable it in Settings.")
                        .multilineTextAlignment(.center)
                } else if vm.isRecording && vm.isPaused {
                    Text("Paused")
                        .font(.title3)
                } else if vm.isPreparingModel {
                    Text("Local AI is transcribing")
                        .multilineTextAlignment(.center)
                        .font(.title3)
                } else if vm.isProcessing {
                    Text("Transcribing…")
                        .multilineTextAlignment(.center)
                        .font(.title3)
                } else {
                    VStack(spacing: 8) {
                        Text("Ready")
                        // Recording Mode Picker (only shown before recording)
                        if !vm.isRecording {
                            RecordingModePicker(mode: $vm.recordingMode)
                                .padding(.top, 8)
                        }
                    }
                }
            }

            // Time Display
            if !vm.isPreparingModel {
                VStack(spacing: 4) {
                    Text(vm.elapsed.mmSS)
                        .font(.system(size: 48, weight: .medium, design: .rounded))

                    // VAD stats during recording in VAD mode
                    if vm.isRecording && vm.recordingMode == .vadFiltered {
                        VADStatsView(
                            speechDuration: vm.speechDuration,
                            isCurrentlySpeech: vm.isCurrentlySpeech,
                            segmentCount: vm.speechSegmentCount
                        )
                    }
                }
            }

            // Audio Level Indicator with VAD overlay
            ZStack {
                AudioLevelIndicatorView(audioLevel: vm.audioLevel)

                // VAD speech indicator overlay
                if vm.isRecording && vm.recordingMode == .vadFiltered {
                    VADIndicatorOverlay(
                        isSpeech: vm.isCurrentlySpeech,
                        probability: vm.vadSpeechProbability
                    )
                }
            }
            .padding(.vertical) // Add some space around it

            if vm.isRecording {
                HStack(spacing: 40) {
                    // Pause/Resume Button
                    Button {
                        if vm.isPaused {
                            vm.resumeRecording()
                        } else {
                            vm.pauseRecording()
                        }
                    } label: {
                        Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 32))
                            .frame(width: 60, height: 60)
                            .foregroundStyle(.white)
                            .background(Color.gray)
                            .clipShape(Circle())
                    }
                    .disabled(vm.isProcessing || vm.isPreparingModel) // Disable if processing/preparing

                    // Stop Button
                    RecordButton(isRecording: true) { // Always show stop icon when recording
                        Task { vm.stopRecording() }
                    }
                    .disabled(vm.isProcessing || vm.isPreparingModel) // Disable if processing/preparing
                }
            } else {
                // Start Button
                RecordButton(isRecording: false) {
                    Task { vm.startRecording() }
                }
                .disabled(vm.permissionDenied || vm.isProcessing || vm.isPreparingModel)
            }

            if vm.isProcessing {
                ProgressView(value: vm.transcriptionProgress)
                    .padding(.horizontal) // Add some horizontal padding
            } else if vm.isPreparingModel {
                ProgressView()
            }
        }
        .padding()
        // Prevent the user from swiping down while a recording or processing is in progress
        .interactiveDismissDisabled(vm.isRecording || vm.isPreparingModel || vm.isProcessing) // Keep this logic, pausing is still an active recording session
        .task {
            vm.attachStore(store)
            let granted = await vm.ensurePermission()
            if granted {
                // No limits in open source version - always allow recording
                vm.startRecording()
            }
        }
#if canImport(UIKit)
        .sheet(isPresented: $showUpgrade) {
            UpgradeSheet().environment(PurchaseManager.shared)
        }
#endif
        .onChange(of: vm.finishedNote) { _, newValue in
            if newValue != nil {
                dismiss()
            }
        }
    }

    private func canRecordMore() -> Bool {
        // No limits in open source version - always allow recording
        return true
    }
}

// MARK: - Recording Mode Picker

struct RecordingModePicker: View {
    @Binding var mode: RecordingMode

    var body: some View {
        VStack(spacing: 8) {
            Picker("Recording Mode", selection: $mode) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 250)

            Text(mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - VAD Stats View

struct VADStatsView: View {
    let speechDuration: TimeInterval
    let isCurrentlySpeech: Bool
    let segmentCount: Int

    var body: some View {
        HStack(spacing: 16) {
            // Speech duration
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .foregroundStyle(isCurrentlySpeech ? .green : .secondary)
                Text(speechDuration.mmSS)
                    .font(.caption)
                    .monospacedDigit()
            }

            // Segment count
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .foregroundStyle(.secondary)
                Text("\(segmentCount)")
                    .font(.caption)
                    .monospacedDigit()
            }

            // Speech status indicator
            Circle()
                .fill(isCurrentlySpeech ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 0.15), value: isCurrentlySpeech)
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - VAD Indicator Overlay

struct VADIndicatorOverlay: View {
    let isSpeech: Bool
    let probability: Float

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                // Speech probability indicator
                ZStack {
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                        .frame(width: 40, height: 40)

                    Circle()
                        .trim(from: 0, to: CGFloat(probability))
                        .stroke(
                            isSpeech ? Color.green : Color.orange,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.1), value: probability)

                    Image(systemName: isSpeech ? "mic.fill" : "mic.slash")
                        .font(.system(size: 14))
                        .foregroundStyle(isSpeech ? .green : .gray)
                }
                .padding(8)
            }
        }
    }
}

// MARK: - VAD Settings Sheet

struct VADSettingsSheet: View {
    @Binding var configuration: VADConfiguration
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech Sensitivity")
                            .font(.subheadline)
                        Slider(value: Binding(
                            get: { Double(configuration.speechThreshold) },
                            set: { configuration.speechThreshold = Float($0) }
                        ), in: 0.3...0.8, step: 0.05)
                        Text("Higher = requires clearer speech")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Minimum Speech Duration")
                            .font(.subheadline)
                        Slider(value: $configuration.minSpeechDuration, in: 0.1...1.0, step: 0.05)
                        Text("\(configuration.minSpeechDuration, specifier: "%.2f")s - Speech shorter than this is discarded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Silence Duration to End Segment")
                            .font(.subheadline)
                        Slider(value: $configuration.minSilenceDuration, in: 0.2...2.0, step: 0.1)
                        Text("\(configuration.minSilenceDuration, specifier: "%.1f")s - How long to wait before ending a speech segment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("VAD Settings")
                } footer: {
                    Text("These settings control how speech is detected and filtered from silence.")
                }

                Section {
                    Button("Reset to Defaults") {
                        configuration = .default
                    }

                    Button("Use Aggressive Settings") {
                        configuration = .aggressive
                    }

                    Button("Use Permissive Settings") {
                        configuration = .permissive
                    }
                } header: {
                    Text("Presets")
                }
            }
            .navigationTitle("VAD Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
