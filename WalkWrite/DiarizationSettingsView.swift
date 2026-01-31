import SwiftUI

// MARK: - Diarization Settings

/// User preferences for diarization
public struct DiarizationSettings: Codable {
    /// Whether to automatically run diarization on VAD recordings
    public var autoRunDiarization: Bool = true

    /// Whether to automatically run speaker-aware LLM enhancement
    public var autoRunSpeakerAwareEnhancement: Bool = true

    /// Maximum number of speakers to detect
    public var maxSpeakers: Int = 6

    /// Clustering sensitivity (lower = more conservative, fewer speakers)
    public var clusteringThreshold: Float = 0.5

    /// Whether to show speaker labels in transcript by default
    public var showSpeakerLabelsByDefault: Bool = true

    /// User identification method
    public var userIdentificationMethod: UserIdentificationMethod = .automatic

    public init() {}

    public static let `default` = DiarizationSettings()
}

/// Methods for identifying the user
public enum UserIdentificationMethod: String, Codable, CaseIterable {
    case automatic = "automatic"
    case firstSpeaker = "first_speaker"
    case mostSpeakingTime = "most_speaking_time"
    case manual = "manual"

    public var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .firstSpeaker:
            return "First Speaker"
        case .mostSpeakingTime:
            return "Most Speaking Time"
        case .manual:
            return "Manual Selection"
        }
    }

    public var description: String {
        switch self {
        case .automatic:
            return "Uses multiple signals to identify you"
        case .firstSpeaker:
            return "Assumes you speak first"
        case .mostSpeakingTime:
            return "Assumes you speak the most"
        case .manual:
            return "Select yourself in each recording"
        }
    }
}

// MARK: - Settings Storage

/// Manages persistence of diarization settings
public class DiarizationSettingsManager: ObservableObject {
    public static let shared = DiarizationSettingsManager()

    @Published public var settings: DiarizationSettings {
        didSet {
            save()
        }
    }

    private let userDefaults = UserDefaults.standard
    private let storageKey = "diarization_settings"

    private init() {
        if let data = userDefaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(DiarizationSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = .default
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    public func reset() {
        settings = .default
    }
}

// MARK: - Settings View

/// Settings view for diarization options
struct DiarizationSettingsView: View {
    @ObservedObject var manager = DiarizationSettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // Automatic Processing Section
                Section {
                    Toggle("Auto-detect speakers", isOn: $manager.settings.autoRunDiarization)

                    Toggle("Auto-generate speaker-aware summaries", isOn: $manager.settings.autoRunSpeakerAwareEnhancement)
                        .disabled(!manager.settings.autoRunDiarization)
                } header: {
                    Text("Automatic Processing")
                } footer: {
                    Text("When enabled, speaker detection runs automatically after transcription for Smart (VAD) recordings.")
                }

                // Speaker Detection Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Maximum Speakers")
                        Picker("Maximum Speakers", selection: $manager.settings.maxSpeakers) {
                            ForEach(2...10, id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Clustering Sensitivity")
                            Spacer()
                            Text(sensitivityLabel)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: $manager.settings.clusteringThreshold,
                            in: 0.3...0.7,
                            step: 0.05
                        )
                        Text("Lower = more conservative (fewer speakers)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Speaker Detection")
                }

                // User Identification Section
                Section {
                    Picker("Identification Method", selection: $manager.settings.userIdentificationMethod) {
                        ForEach(UserIdentificationMethod.allCases, id: \.self) { method in
                            VStack(alignment: .leading) {
                                Text(method.displayName)
                            }
                            .tag(method)
                        }
                    }

                    Text(manager.settings.userIdentificationMethod.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("User Identification")
                } footer: {
                    Text("How to identify which speaker is 'you' in multi-speaker recordings.")
                }

                // Display Section
                Section {
                    Toggle("Show speaker labels by default", isOn: $manager.settings.showSpeakerLabelsByDefault)
                } header: {
                    Text("Display")
                }

                // Reset Section
                Section {
                    Button("Reset to Defaults") {
                        manager.reset()
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Speaker Detection")
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

    private var sensitivityLabel: String {
        let value = manager.settings.clusteringThreshold
        if value < 0.4 {
            return "Conservative"
        } else if value > 0.6 {
            return "Sensitive"
        } else {
            return "Balanced"
        }
    }
}

// MARK: - Combined Settings View

/// Combined settings view for VAD and Diarization
struct RecordingSettingsView: View {
    @Binding var vadConfiguration: VADConfiguration
    @ObservedObject var diarizationManager = DiarizationSettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // VAD Settings Section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speech Sensitivity")
                            .font(.subheadline)
                        Slider(value: Binding(
                            get: { Double(vadConfiguration.speechThreshold) },
                            set: { vadConfiguration.speechThreshold = Float($0) }
                        ), in: 0.3...0.8, step: 0.05)
                        Text("Higher = requires clearer speech")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Minimum Speech Duration")
                            .font(.subheadline)
                        Slider(value: $vadConfiguration.minSpeechDuration, in: 0.1...1.0, step: 0.05)
                        Text("\(vadConfiguration.minSpeechDuration, specifier: "%.2f")s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Silence Duration")
                            .font(.subheadline)
                        Slider(value: $vadConfiguration.minSilenceDuration, in: 0.2...2.0, step: 0.1)
                        Text("\(vadConfiguration.minSilenceDuration, specifier: "%.1f")s to end segment")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Voice Activity Detection")
                }

                // VAD Presets
                Section {
                    Button("Default Settings") {
                        vadConfiguration = .default
                    }
                    Button("Aggressive (less silence)") {
                        vadConfiguration = .aggressive
                    }
                    Button("Permissive (more tolerant)") {
                        vadConfiguration = .permissive
                    }
                } header: {
                    Text("VAD Presets")
                }

                // Diarization Link
                Section {
                    Toggle("Auto-detect speakers", isOn: $diarizationManager.settings.autoRunDiarization)

                    NavigationLink {
                        DiarizationSettingsView()
                    } label: {
                        Text("Speaker Detection Settings")
                    }
                } header: {
                    Text("Speaker Detection")
                } footer: {
                    Text("Speaker detection identifies different voices in your recordings.")
                }
            }
            .navigationTitle("Recording Settings")
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

// MARK: - Previews

#Preview("Diarization Settings") {
    DiarizationSettingsView()
}

#Preview("Combined Settings") {
    RecordingSettingsView(vadConfiguration: .constant(.default))
}
