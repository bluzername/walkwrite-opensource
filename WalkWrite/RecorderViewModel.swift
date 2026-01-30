import Foundation
import AVFoundation
import Combine
import SwiftUI // Often needed for @MainActor and ObservableObject, though maybe implicit
// Assuming these types are part of the main WalkWrite module/target
// No explicit import needed if they are in the same target, but let's ensure clarity
// If these are in separate modules, specific imports would be needed.

// Import necessary types if they are not automatically available
// import WalkWrite // Explicit import removed as it's redundant within the same module

// MARK: - Recording Mode

/// Defines the recording mode for the app
public enum RecordingMode: String, Codable, CaseIterable {
    /// Traditional recording - captures all audio
    case traditional

    /// VAD-based recording - filters out silence, keeps only speech
    case vadFiltered

    public var displayName: String {
        switch self {
        case .traditional:
            return "Standard"
        case .vadFiltered:
            return "Smart (VAD)"
        }
    }

    public var description: String {
        switch self {
        case .traditional:
            return "Records all audio including silence"
        case .vadFiltered:
            return "Automatically filters out silence, keeps only speech"
        }
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {

    // MARK: - Published state
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var isPreparingModel = false
    @Published private(set) var isProcessing = false
    @Published private(set) var finishedNote: Note?
    @Published private(set) var audioLevel: Float = 0.0
    @Published var transcriptionProgress: Double = 0.0 // New property for progress

    // MARK: - VAD-specific Published State
    @Published var recordingMode: RecordingMode = .traditional
    @Published private(set) var vadSpeechProbability: Float = 0.0
    @Published private(set) var isCurrentlySpeech: Bool = false
    @Published private(set) var speechDuration: TimeInterval = 0
    @Published private(set) var silenceDuration: TimeInterval = 0
    @Published private(set) var speechSegmentCount: Int = 0
    @Published var vadConfiguration: VADConfiguration = .default

    // MARK: - Private (Traditional Recording)
    private var recorder: AVAudioRecorder?
    private var accumulatedTime: TimeInterval = 0
    private var currentSegmentStartTime: Date?
    private var timer: AnyCancellable?

    // MARK: - Private (VAD Recording)
    private var continuousRecorder: ContinuousRecorder?

    // Weak reference to persistent store so we can immediately persist raw audio
    private weak var store: NoteStore?

    func attachStore(_ store: NoteStore) {
        self.store = store
    }

    var elapsed: TimeInterval {
        if recordingMode == .vadFiltered, let continuousRecorder = continuousRecorder {
            return continuousRecorder.elapsedTime
        }
        return accumulatedTime + (currentSegmentStartTime.map { Date().timeIntervalSince($0) } ?? 0)
    }

    /// For VAD mode: returns the duration of speech detected so far
    var effectiveSpeechDuration: TimeInterval {
        if recordingMode == .vadFiltered {
            return speechDuration
        }
        return elapsed
    }

    // MARK: - Permissions
    @discardableResult
    func ensurePermission() async -> Bool {
        if await AVAudioApplication.requestRecordPermission() {
            permissionDenied = false
            return true
        } else {
            permissionDenied = true
            return false
        }
    }

    // MARK: - Recording control
    func startRecording() {
        guard !isRecording else { return } // Should not happen if UI logic is correct

        // No limits in open source version - upgrade is optional

        switch recordingMode {
        case .traditional:
            startTraditionalRecording()
        case .vadFiltered:
            startVADRecording()
        }

        // Pre-warm WhisperEngine in the background
        // This will initialize the shared instance and load the model
        // if it hasn't been done yet for this app session.
        Task.detached(priority: .background) {
            Foundation.NSLog("RecorderViewModel: Pre-warming WhisperEngine...")
            _ = await WhisperEngine.shared // Access to initialize
            Foundation.NSLog("RecorderViewModel: WhisperEngine pre-warming initiated/completed.")
        }
    }

    // MARK: - Traditional Recording

    private func startTraditionalRecording() {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
#endif

        let filename = ISO8601DateFormatter().string(from: .now) + ".wav"
        let url = AppFolders.notes.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]

        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.isMeteringEnabled = true
        recorder?.record()

        accumulatedTime = 0
        currentSegmentStartTime = .now
        isRecording = true
        isPaused = false

        startOrUpdateTimer()
    }

    // MARK: - VAD-based Recording

    private func startVADRecording() {
        // Create continuous recorder with current VAD configuration
        continuousRecorder = ContinuousRecorder(
            vadConfiguration: vadConfiguration,
            keepFullAudio: true  // Keep full audio as fallback
        )
        continuousRecorder?.delegate = self

        do {
            try continuousRecorder?.startRecording()
            isRecording = true
            isPaused = false

            // Reset VAD stats
            vadSpeechProbability = 0.0
            isCurrentlySpeech = false
            speechDuration = 0
            silenceDuration = 0
            speechSegmentCount = 0

            NSLog("RecorderViewModel: Started VAD-based recording")
        } catch {
            NSLog("RecorderViewModel: Failed to start VAD recording: \(error)")
            // Fallback to traditional recording
            recordingMode = .traditional
            startTraditionalRecording()
        }
    }

    private func startOrUpdateTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.02, on: .main, in: .common) // Increased update rate for audio level
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isRecording && !self.isPaused {
                    self.recorder?.updateMeters()
                    // The power value is in dB, from -160 (silence) to 0 (max).
                    let power = self.recorder?.averagePower(forChannel: 0) ?? -160.0
                    // Normalize to 0.0 - 1.0.
                    // Adjusted range for better sensitivity to typical voice levels.
                    let minDb: Float = -45.0 // Quieter sounds will start showing activity sooner
                    let maxDb: Float = -10.0  // Louder sounds will hit max amplitude sooner
                    
                    var normalizedLevel: Float
                    if power < minDb {
                        normalizedLevel = 0.0
                    } else if power > maxDb {
                        normalizedLevel = 1.0
                    } else {
                        normalizedLevel = (power - minDb) / (maxDb - minDb)
                    }
                    
                    // Optional: Apply a curve to make it even more responsive at lower levels
                    // For example, a square root curve (power of 0.5)
                    // self.audioLevel = pow(normalizedLevel, 0.5)
                    self.audioLevel = normalizedLevel
                }
                self.objectWillChange.send() // For elapsed time and other UI updates
            }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        switch recordingMode {
        case .traditional:
            guard let recorder = recorder, let segmentStartTime = currentSegmentStartTime else { return }
            recorder.pause()
            accumulatedTime += Date().timeIntervalSince(segmentStartTime)
            currentSegmentStartTime = nil

        case .vadFiltered:
            continuousRecorder?.pauseRecording()
        }

        isPaused = true
        audioLevel = 0.0 // Reset audio level on pause
        vadSpeechProbability = 0.0
        isCurrentlySpeech = false
        self.objectWillChange.send() // Ensure UI updates for isPaused state
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }

        switch recordingMode {
        case .traditional:
            guard let recorder = recorder else { return }
            recorder.record() // AVAudioRecorder resumes with record()
            currentSegmentStartTime = .now
            startOrUpdateTimer() // Restart timer with metering

        case .vadFiltered:
            do {
                try continuousRecorder?.resumeRecording()
            } catch {
                NSLog("RecorderViewModel: Failed to resume VAD recording: \(error)")
            }
        }

        isPaused = false
    }

    func stopRecording() {
        guard isRecording else { return }

        switch recordingMode {
        case .traditional:
            stopTraditionalRecording()
        case .vadFiltered:
            stopVADRecording()
        }
    }

    private func stopTraditionalRecording() {
        guard let recorder = recorder else { return }
        audioLevel = 0.0 // Reset audio level on stop

        if !isPaused, let segmentStartTime = currentSegmentStartTime {
            accumulatedTime += Date().timeIntervalSince(segmentStartTime)
        }
        currentSegmentStartTime = nil

        recorder.stop()
        timer?.cancel()

        let duration = accumulatedTime // Use the accurately tracked accumulated time
        let audioURL = recorder.url

        self.recorder = nil
        self.isRecording = false
        self.isPaused = false
        self.accumulatedTime = 0

        processRecordedAudio(url: audioURL, duration: duration)
    }

    private func stopVADRecording() {
        guard let continuousRecorder = continuousRecorder else {
            isRecording = false
            isPaused = false
            return
        }

        // Reset UI state
        audioLevel = 0.0
        vadSpeechProbability = 0.0
        isCurrentlySpeech = false

        do {
            let audioURL = try continuousRecorder.stopRecording()
            let stats = continuousRecorder.getStats()

            // Use speech duration as the effective duration for VAD mode
            let duration = stats.speechDuration > 0 ? stats.speechDuration : stats.totalRecordingDuration

            self.continuousRecorder = nil
            self.isRecording = false
            self.isPaused = false

            NSLog("RecorderViewModel: VAD recording stopped. Speech: \(stats.speechDuration)s, Total: \(stats.totalRecordingDuration)s, Segments: \(stats.segmentCount)")

            processRecordedAudio(url: audioURL, duration: duration)
        } catch {
            NSLog("RecorderViewModel: Failed to stop VAD recording: \(error)")
            self.continuousRecorder = nil
            self.isRecording = false
            self.isPaused = false
        }
    }

    private func processRecordedAudio(url audioURL: URL, duration: TimeInterval) {
        // Immediately persist a placeholder note so the user never loses their recording
        let placeholder = Note(createdAt: Date(), // Explicit Date()
                               duration: duration,
                               audioURL: audioURL,
                               transcript: "",
                               words: [])
        let placeholderID = placeholder.id
        store?.add(placeholder)

        isPreparingModel = true

        // Run the heavy transcription work off the MainActor so that the UI
        // can update and show the "Preparing…" message while Core ML compiles
        // the encoder on first launch.
        Task.detached(priority: .userInitiated) { [weak self, audioURL, duration, placeholderID] in
            guard let self else { return }

            await MainActor.run {
                self.isProcessing = true
                self.transcriptionProgress = 0.0 // Reset progress
            }

            var transcript = ""
            var words: [WordStamp] = []

            do {
                // Assign to temporary local constants first
                let (localTranscript, localWords) = try await WhisperEngine.shared.transcribe(audioFileURL: audioURL) { progress in
                    Task { @MainActor in
                        // This closure only captures `self`
                        self.transcriptionProgress = progress
                    }
                }
                // Update the task-scoped variables
                transcript = localTranscript
                words = localWords
            } catch WhisperError.transcriptionInterrupted {
                NSLog("RecorderViewModel: Transcription was interrupted.")
                // UI reset and user notification will be handled below
                // transcript and words will remain empty or partially filled if desired
            } catch {
                NSLog("RecorderViewModel: Transcription failed with error: \(error)")
                // Handle other errors (e.g., model load, audio read)
                // transcript and words will remain empty
            }

            // WhisperEngine.shared.release() is now called internally by WhisperEngine's defer block
            // await WhisperEngine.shared.release() // This call might be redundant now
            await Task.yield()

            // Capture transcript and words as immutable constants before passing to MainActor context
            let finalTranscript = transcript
            let finalWords = words

            await MainActor.run {
                self.isProcessing = false
                self.isPreparingModel = false // Ensure this is also reset

                if finalTranscript.isEmpty && finalWords.isEmpty {
                    // Transcription likely failed or was interrupted significantly
                    // Keep the placeholder or update with minimal info
                    // Optionally, inform the user more directly here
                    NSLog("RecorderViewModel: Transcription resulted in empty content. Placeholder remains or is minimally updated.")
                    // Reset progress if it wasn't fully reset (e.g. error before loop start)
                    self.transcriptionProgress = 0.0
                    // Potentially remove the placeholder if it's truly unusable or notify user
                    // For now, we'll let the placeholder be updated with empty transcript
                }

                let note = Note(id: placeholderID,
                                createdAt: Date(), // Explicit Date(), ideally original placeholder's date
                                duration: duration,
                                audioURL: audioURL,
                                transcript: finalTranscript, // Use captured constant
                                words: finalWords)           // Use captured constant
                self.finishedNote = note // This might trigger UI even if transcript is empty

                // Update the note in the persistent store (replace placeholder)
                self.store?.update(note)

                // LLM post-processing is no longer automatically triggered here.
                // It should be triggered manually via manuallyRunPostProcessing(for:)
            }
        }
    }

    // MARK: – LLM post-processing

    /// Manually triggers the enhancement pipeline for a given note.
    /// This should be called based on user action (e.g., tapping a button).
    /// It delegates to the shared `enqueueEnhancement` helper.
    func manuallyRunPostProcessing(for note: Note) {
        // Ensure we have a transcript before attempting enhancement
        guard !note.transcript.isEmpty, let store = self.store else {
            NSLog("RecorderViewModel: Cannot run post-processing for note \(note.id) - transcript is empty or store is nil.")
            return
        }
        NSLog("RecorderViewModel: Manually triggering post-processing for note \(note.id)")
        // Delegate to the existing enqueue logic (assuming it handles background tasks appropriately)
        enqueueEnhancement(for: note, in: store)
    }

    // MARK: – Transcription via whisper.cpp (runs on a background actor)
    // This method is no longer directly called for transcription initiation.
    // The new WhisperEngine.transcribe(audioFileURL:progressHandler:) is used.
    // Keeping readPCM16WaveFile as it might be a useful utility, or remove if confirmed unused.

    // Helper: load WAV samples into Float array (Potentially unused for transcription flow now)
    // If WhisperEngine handles all audio reading, this can be removed or kept as a general utility.
    // For now, let's keep it commented out or marked for review.
    /*
    private static func readPCM16WaveFile(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { return [] }
        var out: [Float] = []
        out.reserveCapacity((data.count - 44) / 2)
        data.withUnsafeBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            var idx = 44
            while idx + 1 < data.count {
                let value = UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8)
                let intSample = Int16(bitPattern: value)
                out.append(Float(intSample) / 32768.0)
                idx += 2
            }
        }
        return out
    }
    */
}

// MARK: - ContinuousRecorderDelegate

extension RecorderViewModel: ContinuousRecorderDelegate {

    nonisolated func continuousRecorder(_ recorder: ContinuousRecorder, didDetectSpeechSegment segment: SpeechSegment) {
        Task { @MainActor in
            self.speechSegmentCount += 1
            NSLog("RecorderViewModel: Speech segment detected #\(self.speechSegmentCount): \(segment.duration)s")
        }
    }

    nonisolated func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateAudioLevel level: Float) {
        Task { @MainActor in
            self.audioLevel = level
        }
    }

    nonisolated func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateVADState isSpeech: Bool, probability: Float) {
        Task { @MainActor in
            self.vadSpeechProbability = probability
            self.isCurrentlySpeech = isSpeech
        }
    }

    nonisolated func continuousRecorder(_ recorder: ContinuousRecorder, didUpdateStats stats: AudioSegmentManager.RecordingStats) {
        Task { @MainActor in
            self.speechDuration = stats.speechDuration
            self.silenceDuration = stats.silenceDuration
            self.speechSegmentCount = stats.segmentCount
            self.objectWillChange.send()
        }
    }

    nonisolated func continuousRecorder(_ recorder: ContinuousRecorder, didEncounterError error: Error) {
        Task { @MainActor in
            NSLog("RecorderViewModel: ContinuousRecorder error: \(error)")
            // Could show an alert or handle the error appropriately
        }
    }
}
