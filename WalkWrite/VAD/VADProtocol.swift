import Foundation
import AVFoundation

// MARK: - VAD Configuration

/// Configuration for Voice Activity Detection
public struct VADConfiguration: Codable, Sendable {
    /// Probability threshold above which audio is considered speech (0.0 - 1.0)
    public var speechThreshold: Float

    /// Probability threshold below which audio is considered silence (0.0 - 1.0)
    public var silenceThreshold: Float

    /// Minimum duration of speech to consider it valid (seconds)
    public var minSpeechDuration: TimeInterval

    /// Minimum duration of silence before ending a speech segment (seconds)
    public var minSilenceDuration: TimeInterval

    /// Size of the analysis window in samples (at 16kHz)
    public var windowSizeSamples: Int

    /// Step size between analysis windows in samples
    public var windowStepSamples: Int

    public static let `default` = VADConfiguration(
        speechThreshold: 0.5,
        silenceThreshold: 0.35,
        minSpeechDuration: 0.25,
        minSilenceDuration: 0.3,
        windowSizeSamples: 512,  // 32ms at 16kHz
        windowStepSamples: 256   // 16ms step
    )

    /// More aggressive filtering - requires clearer speech
    public static let aggressive = VADConfiguration(
        speechThreshold: 0.6,
        silenceThreshold: 0.4,
        minSpeechDuration: 0.3,
        minSilenceDuration: 0.5,
        windowSizeSamples: 512,
        windowStepSamples: 256
    )

    /// More permissive - captures more audio including quieter speech
    public static let permissive = VADConfiguration(
        speechThreshold: 0.4,
        silenceThreshold: 0.25,
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.2,
        windowSizeSamples: 512,
        windowStepSamples: 256
    )

    public init(
        speechThreshold: Float = 0.5,
        silenceThreshold: Float = 0.35,
        minSpeechDuration: TimeInterval = 0.25,
        minSilenceDuration: TimeInterval = 0.3,
        windowSizeSamples: Int = 512,
        windowStepSamples: Int = 256
    ) {
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceDuration = minSilenceDuration
        self.windowSizeSamples = windowSizeSamples
        self.windowStepSamples = windowStepSamples
    }
}

// MARK: - VAD Result

/// Result of a single VAD analysis frame
public struct VADFrame: Sendable {
    /// Probability that this frame contains speech (0.0 - 1.0)
    public let speechProbability: Float

    /// Whether this frame is classified as speech based on threshold
    public let isSpeech: Bool

    /// Timestamp of this frame relative to start of analysis
    public let timestamp: TimeInterval

    /// Duration of this frame in seconds
    public let duration: TimeInterval

    public init(speechProbability: Float, isSpeech: Bool, timestamp: TimeInterval, duration: TimeInterval) {
        self.speechProbability = speechProbability
        self.isSpeech = isSpeech
        self.timestamp = timestamp
        self.duration = duration
    }
}

// MARK: - VAD State

/// Represents the current state of the VAD
public enum VADState: Sendable {
    case idle
    case inSpeech(startTime: TimeInterval)
    case inSilence(speechStartTime: TimeInterval, silenceStartTime: TimeInterval)
}

// MARK: - Speech Segment

/// A detected speech segment with timing information
public struct SpeechSegment: Identifiable, Codable, Sendable {
    public let id: UUID
    public let startTime: TimeInterval
    public var endTime: TimeInterval
    public var isFinal: Bool

    public var duration: TimeInterval {
        endTime - startTime
    }

    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, isFinal: Bool = false) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.isFinal = isFinal
    }
}

// MARK: - VAD Protocol

/// Protocol for Voice Activity Detection implementations
public protocol VADProtocol: AnyObject, Sendable {
    /// The current configuration
    var configuration: VADConfiguration { get }

    /// Process a buffer of audio samples and return speech probability
    /// - Parameter samples: Audio samples (16kHz, mono, Float32)
    /// - Returns: Speech probability (0.0 - 1.0)
    func processSamples(_ samples: [Float]) -> Float

    /// Process a single frame and update internal state
    /// - Parameters:
    ///   - samples: Audio samples for this frame
    ///   - timestamp: Current timestamp in the recording
    /// - Returns: VAD frame result
    func processFrame(_ samples: [Float], timestamp: TimeInterval) -> VADFrame

    /// Reset the VAD state (call when starting a new recording)
    func reset()

    /// Update the configuration
    func updateConfiguration(_ config: VADConfiguration)
}

// MARK: - VAD State Machine

/// State machine that manages speech segment detection based on VAD frames
public final class VADStateMachine: @unchecked Sendable {
    private var state: VADState = .idle
    private var currentSegment: SpeechSegment?
    private var completedSegments: [SpeechSegment] = []
    private let configuration: VADConfiguration
    private let lock = NSLock()

    public init(configuration: VADConfiguration = .default) {
        self.configuration = configuration
    }

    /// Process a VAD frame and update state machine
    /// - Parameter frame: The VAD frame to process
    /// - Returns: A completed speech segment if one was finalized, nil otherwise
    public func processFrame(_ frame: VADFrame) -> SpeechSegment? {
        lock.lock()
        defer { lock.unlock() }

        var completedSegment: SpeechSegment? = nil

        switch state {
        case .idle:
            if frame.isSpeech {
                // Start new speech segment
                state = .inSpeech(startTime: frame.timestamp)
                currentSegment = SpeechSegment(
                    startTime: frame.timestamp,
                    endTime: frame.timestamp + frame.duration
                )
            }

        case .inSpeech(let speechStartTime):
            if frame.isSpeech {
                // Continue speech segment
                currentSegment?.endTime = frame.timestamp + frame.duration
            } else {
                // Potential end of speech - enter silence period
                state = .inSilence(speechStartTime: speechStartTime, silenceStartTime: frame.timestamp)
            }

        case .inSilence(let speechStartTime, let silenceStartTime):
            if frame.isSpeech {
                // Speech resumed - back to speech state
                state = .inSpeech(startTime: speechStartTime)
                currentSegment?.endTime = frame.timestamp + frame.duration
            } else {
                // Still in silence
                let silenceDuration = frame.timestamp - silenceStartTime
                if silenceDuration >= configuration.minSilenceDuration {
                    // Finalize the speech segment
                    if var segment = currentSegment {
                        let speechDuration = silenceStartTime - speechStartTime
                        if speechDuration >= configuration.minSpeechDuration {
                            segment.endTime = silenceStartTime
                            segment.isFinal = true
                            completedSegments.append(segment)
                            completedSegment = segment
                        }
                    }
                    currentSegment = nil
                    state = .idle
                }
            }
        }

        return completedSegment
    }

    /// Force finalize any in-progress segment (call when stopping recording)
    /// - Parameter currentTime: The current timestamp
    /// - Returns: The finalized segment if one was in progress
    public func finalize(at currentTime: TimeInterval) -> SpeechSegment? {
        lock.lock()
        defer { lock.unlock() }

        guard var segment = currentSegment else { return nil }

        let speechDuration: TimeInterval
        switch state {
        case .idle:
            return nil
        case .inSpeech(let startTime):
            speechDuration = currentTime - startTime
            segment.endTime = currentTime
        case .inSilence(let speechStartTime, let silenceStartTime):
            speechDuration = silenceStartTime - speechStartTime
            segment.endTime = silenceStartTime
        }

        if speechDuration >= configuration.minSpeechDuration {
            segment.isFinal = true
            completedSegments.append(segment)
            currentSegment = nil
            state = .idle
            return segment
        }

        currentSegment = nil
        state = .idle
        return nil
    }

    /// Get all completed segments
    public func getCompletedSegments() -> [SpeechSegment] {
        lock.lock()
        defer { lock.unlock() }
        return completedSegments
    }

    /// Get current in-progress segment if any
    public func getCurrentSegment() -> SpeechSegment? {
        lock.lock()
        defer { lock.unlock() }
        return currentSegment
    }

    /// Reset the state machine
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        state = .idle
        currentSegment = nil
        completedSegments = []
    }

    /// Get current state
    public func getState() -> VADState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
