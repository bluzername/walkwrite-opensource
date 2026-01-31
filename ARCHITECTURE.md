# WalkWrite Architecture Document

## Version History

| Version | Date | Phase | Description |
|---------|------|-------|-------------|
| 1.0 | 2025-01-30 | Phase 1 | VAD-based continuous recording |
| 2.0 | 2025-01-30 | Phase 2 | Speaker diarization complete |

---

## Table of Contents

1. [Overview](#overview)
2. [System Architecture](#system-architecture)
3. [Phase 1: VAD Foundation](#phase-1-vad-foundation)
4. [Phase 2: Speaker Diarization](#phase-2-speaker-diarization)
5. [Data Flow](#data-flow)
6. [Data Models](#data-models)
7. [Component Reference](#component-reference)
8. [Testing Strategy](#testing-strategy)

---

## Overview

WalkWrite is a privacy-focused iOS voice note app that processes audio entirely on-device. The upgrade adds:

1. **VAD-based Recording** - Filters silence in real-time, keeping only speech
2. **Speaker Diarization** - Identifies different speakers and assigns words to them
3. **User Identification** - Designates the most consistent speaker as "the user"
4. **Speaker-Aware LLM** - Provides speaker context for intelligent summaries

### Design Principles

- **Privacy First**: All processing happens on-device
- **Protocol-Based**: Enables testing and future model swaps
- **Actor Isolation**: Thread-safe async operations
- **Progressive Enhancement**: Each phase builds on the previous

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              USER INTERFACE                                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │ RecorderSheet   │  │ NoteDetailView  │  │ NotesListView   │             │
│  │ - Mode picker   │  │ - Transcript    │  │ - Note list     │             │
│  │ - VAD stats     │  │ - Speaker view  │  │ - Search        │             │
│  │ - Controls      │  │ - Playback      │  │                 │             │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘             │
└───────────┼─────────────────────┼─────────────────────┼─────────────────────┘
            │                     │                     │
            ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            VIEW MODELS                                       │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     RecorderViewModel                                │    │
│  │  @Published recordingMode: RecordingMode                            │    │
│  │  @Published vadSpeechProbability: Float                             │    │
│  │  @Published speechDuration: TimeInterval                            │    │
│  │  @Published speechSegmentCount: Int                                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          RECORDING LAYER (Phase 1)                           │
│                                                                              │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐        │
│  │ ContinuousRec.  │────▶│ EnergyBasedVAD  │────▶│ VADStateMachine │        │
│  │ (AVAudioEngine) │     │ (RMS+ZCR+SF)    │     │ (Speech detect) │        │
│  └────────┬────────┘     └─────────────────┘     └────────┬────────┘        │
│           │                                               │                  │
│           ▼                                               ▼                  │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                    AudioSegmentManager                           │        │
│  │  - Circular buffer (5s history)                                 │        │
│  │  - Speech segment extraction                                    │        │
│  │  - Time mapping (concatenated ↔ original)                       │        │
│  │  - WAV export                                                   │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TRANSCRIPTION LAYER                                   │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                      WhisperEngine                               │        │
│  │  - whisper.cpp (Large-v3-turbo, Q5_0)                           │        │
│  │  - 30-second chunked processing                                 │        │
│  │  - Word-level timestamps (WordStamp)                            │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                       DIARIZATION LAYER (Phase 2)                            │
│                                                                              │
│  ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐        │
│  │ SpeakerEmbed.   │────▶│ SpeakerCluster  │────▶│ WordSpeaker     │        │
│  │ Engine          │     │ (AHC/Spectral)  │     │ Assigner        │        │
│  └─────────────────┘     └─────────────────┘     └─────────────────┘        │
│           │                      │                       │                   │
│           ▼                      ▼                       ▼                   │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                    DiarizationPipeline                           │        │
│  │  Input: Audio + WordStamps                                      │        │
│  │  Output: [DiarizedWord] with speaker IDs                        │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     USER IDENTIFICATION (Phase 3)                            │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                      UserIdentifier                              │        │
│  │  - Calculates speaker statistics                                │        │
│  │  - Identifies user by speaking time/consistency                 │        │
│  │  - Labels speakers (User, Speaker 2, etc.)                      │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        LLM ENHANCEMENT LAYER                                 │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                        LLMEngine                                 │        │
│  │  - Qwen-3 0.6B via MLX Swift                                    │        │
│  │  - Speaker-aware prompts                                        │        │
│  │  - Cleaned transcript, summary, key ideas                       │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PERSISTENCE LAYER                                   │
│  ┌─────────────────────────────────────────────────────────────────┐        │
│  │                        NoteStore                                 │        │
│  │  - JSON-backed storage                                          │        │
│  │  - In-memory cache                                              │        │
│  │  - Atomic writes                                                │        │
│  └─────────────────────────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: VAD Foundation

### Components

#### VADProtocol.swift

Defines the protocol and core types for voice activity detection.

```swift
// Core protocol - allows swapping VAD implementations
public protocol VADProtocol: AnyObject, Sendable {
    var configuration: VADConfiguration { get }
    func processSamples(_ samples: [Float]) -> Float  // Returns speech probability
    func processFrame(_ samples: [Float], timestamp: TimeInterval) -> VADFrame
    func reset()
    func updateConfiguration(_ config: VADConfiguration)
}

// Configuration with presets
public struct VADConfiguration: Codable, Sendable {
    var speechThreshold: Float      // 0.5 default
    var silenceThreshold: Float     // 0.35 default
    var minSpeechDuration: TimeInterval  // 0.25s
    var minSilenceDuration: TimeInterval // 0.3s

    static let `default`, aggressive, permissive: VADConfiguration
}

// State machine for segment detection
public final class VADStateMachine: @unchecked Sendable {
    enum State { case idle, inSpeech, inSilence }
    func processFrame(_ frame: VADFrame) -> SpeechSegment?
    func finalize(at: TimeInterval) -> SpeechSegment?
}
```

#### EnergyBasedVAD.swift

Energy-based VAD using three acoustic features:

| Feature | Description | Speech Characteristics |
|---------|-------------|----------------------|
| RMS Energy | Root mean square amplitude | Higher during speech |
| Zero-Crossing Rate | Sign changes per sample | 0.02-0.15 for speech |
| Spectral Flatness | Geometric/arithmetic mean ratio | Lower (more tonal) for speech |

```swift
public final class EnergyBasedVAD: VADProtocol {
    // Adaptive noise floor tracking
    private var noiseFloor: Float = 0.001

    // Feature extraction using Accelerate framework
    private func calculateRMS(_ samples: [Float]) -> Float
    private func calculateZeroCrossingRate(_ samples: [Float]) -> Float
    private func calculateSpectralFlatness(_ samples: [Float]) -> Float

    // Weighted combination: 60% energy + 25% ZCR + 15% spectral
    public func processSamples(_ samples: [Float]) -> Float
}
```

#### AudioSegmentManager.swift

Manages audio buffering and segment extraction.

```swift
public final class AudioSegmentManager: @unchecked Sendable {
    // Circular buffer (5 seconds at 16kHz)
    private var audioBuffer: [Float]
    private let maxBufferDuration: TimeInterval = 5.0

    // Time mapping for diarization
    struct TimeMapping: Codable {
        let concatenatedRange: ClosedRange<TimeInterval>
        let originalRange: ClosedRange<TimeInterval>
    }

    // Key operations
    func addSamples(_ samples: [Float], timestamp: TimeInterval)
    func extractSegment(_ segment: SpeechSegment) -> Bool
    func exportToWAV(url: URL) throws
    func originalToConcatenatedTime(_ time: TimeInterval) -> TimeInterval?
}
```

#### ContinuousRecorder.swift

Integrates AVAudioEngine with real-time VAD processing.

```swift
public final class ContinuousRecorder: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private let vad: VADProtocol
    private let vadStateMachine: VADStateMachine
    private let segmentManager: AudioSegmentManager

    // Delegate for real-time updates
    weak var delegate: ContinuousRecorderDelegate?

    // Recording lifecycle
    func startRecording() throws
    func pauseRecording()
    func resumeRecording() throws
    func stopRecording() throws -> URL  // Returns speech-only WAV
}
```

### File Structure

```
WalkWrite/
├── VAD/
│   ├── VADProtocol.swift       (286 lines) - Protocol, config, state machine
│   ├── EnergyBasedVAD.swift    (261 lines) - Acoustic feature VAD
│   ├── AudioSegmentManager.swift (330 lines) - Buffer & segment management
│   └── ContinuousRecorder.swift (496 lines) - AVAudioEngine integration
├── RecorderViewModel.swift     (Modified) - Dual-mode recording support
└── RecorderSheet.swift         (Modified) - VAD UI components
```

---

## Phase 2: Speaker Diarization

### Overview

Speaker diarization assigns each word to a specific speaker by:
1. Extracting speaker embeddings from audio segments
2. Clustering embeddings to identify unique speakers
3. Mapping word timestamps to speaker segments

### Components

#### SpeakerEmbedding.swift

Extracts acoustic features that characterize a speaker's voice.

```swift
// Speaker embedding using acoustic features
// (Can be replaced with ECAPA-TDNN CoreML model for better accuracy)
public struct SpeakerEmbedding: Codable {
    let features: [Float]  // 64-dimensional acoustic feature vector
    let timestamp: TimeInterval
    let duration: TimeInterval
}

public protocol SpeakerEmbeddingProtocol {
    func extractEmbedding(from samples: [Float], sampleRate: Double) -> [Float]
    func batchExtract(segments: [(samples: [Float], timestamp: TimeInterval)]) -> [SpeakerEmbedding]
}

public final class AcousticSpeakerEmbedding: SpeakerEmbeddingProtocol {
    // Features extracted:
    // - MFCC-like spectral features
    // - Pitch statistics
    // - Energy distribution
    // - Speaking rate indicators
}
```

#### SpeakerClusterer.swift

Groups embeddings into speaker clusters.

```swift
public struct SpeakerSegment: Codable {
    let speakerId: Int
    let timeRange: ClosedRange<TimeInterval>
    let confidence: Float
}

public final class SpeakerClusterer {
    // Agglomerative Hierarchical Clustering
    func cluster(
        embeddings: [SpeakerEmbedding],
        maxSpeakers: Int = 10,
        distanceThreshold: Float = 0.5
    ) -> [SpeakerSegment]

    // Cosine similarity for embedding comparison
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float
}
```

#### WordSpeakerAssigner.swift

Maps transcribed words to identified speakers.

```swift
public struct DiarizedWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let speakerId: Int
    let speakerConfidence: Float
}

public final class WordSpeakerAssigner {
    func assign(
        words: [WordStamp],
        speakerSegments: [SpeakerSegment]
    ) -> [DiarizedWord]

    // Finds best overlapping speaker segment for each word
    private func findBestOverlap(
        word: WordStamp,
        segments: [SpeakerSegment]
    ) -> (speakerId: Int, confidence: Float)
}
```

#### DiarizationPipeline.swift

Orchestrates the full diarization process.

```swift
public struct DiarizationResult {
    let diarizedWords: [DiarizedWord]
    let speakerSegments: [SpeakerSegment]
    let speakerCount: Int
}

public final class DiarizationPipeline {
    private let embeddingEngine: SpeakerEmbeddingProtocol
    private let clusterer: SpeakerClusterer
    private let assigner: WordSpeakerAssigner

    func diarize(
        audioURL: URL,
        words: [WordStamp],
        config: DiarizationConfig
    ) async throws -> DiarizationResult
}
```

### Algorithm Details

#### Embedding Extraction

For each 1.5-second window (with 0.5s step):
1. Extract spectral features (simplified MFCC)
2. Calculate pitch statistics
3. Compute energy distribution
4. Combine into 64-dimensional vector

#### Clustering

Agglomerative Hierarchical Clustering (AHC):
1. Start with each embedding as its own cluster
2. Iteratively merge closest clusters (cosine distance)
3. Stop when distance exceeds threshold or max speakers reached
4. Assign speaker IDs to merged clusters

#### Word Assignment

For each word with timestamp [start, end]:
1. Find all speaker segments that overlap
2. Calculate overlap percentage for each
3. Assign to speaker with highest overlap
4. Set confidence based on overlap quality
5. Apply smoothing to remove isolated speaker changes
6. Relabel speakers by order of appearance

### File Structure

```
WalkWrite/
├── VAD/                              # Phase 1
│   ├── VADProtocol.swift            (286 lines)
│   ├── EnergyBasedVAD.swift         (261 lines)
│   ├── AudioSegmentManager.swift    (330 lines)
│   └── ContinuousRecorder.swift     (496 lines)
├── Diarization/                      # Phase 2
│   ├── SpeakerEmbedding.swift       (485 lines) - Config, embedding, factory
│   ├── SpeakerClusterer.swift       (382 lines) - AHC clustering
│   ├── WordSpeakerAssigner.swift    (361 lines) - Word mapping, stats
│   └── DiarizationPipeline.swift    (499 lines) - Orchestration, formatting
├── RecorderViewModel.swift          (Modified) - Dual-mode support
└── RecorderSheet.swift              (Modified) - VAD UI components

WalkWriteTests/
├── VADConfigurationTests.swift      # Phase 1 tests
├── EnergyBasedVADTests.swift
├── VADStateMachineTests.swift
├── AudioSegmentManagerTests.swift
├── VADIntegrationTests.swift
├── SpeakerEmbeddingTests.swift      # Phase 2 tests
├── SpeakerClustererTests.swift
├── WordSpeakerAssignerTests.swift
└── Phase1And2IntegrationTests.swift # Cross-phase tests
```

---

## Data Flow

### Recording Flow (VAD Mode)

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Microphone   │────▶│ AVAudioEngine│────▶│ Buffer       │
│              │     │ (16kHz mono) │     │ (32ms chunks)│
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
                     ┌────────────────────────────┘
                     ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ EnergyBased  │────▶│ VADState     │────▶│ AudioSegment │
│ VAD          │     │ Machine      │     │ Manager      │
│ P(speech)    │     │ (detect seg) │     │ (buffer/map) │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
                     ┌────────────────────────────┘
                     ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Speech-only  │────▶│ WhisperEngine│────▶│ Diarization  │
│ WAV export   │     │ (transcribe) │     │ Pipeline     │
└──────────────┘     └──────────────┘     └──────┬───────┘
                                                  │
                     ┌────────────────────────────┘
                     ▼
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ User         │────▶│ LLMEngine    │────▶│ NoteStore    │
│ Identifier   │     │ (enhance)    │     │ (persist)    │
└──────────────┘     └──────────────┘     └──────────────┘
```

### Time Mapping

When VAD filters silence, timestamps must be mapped:

```
Original Recording:     |--speech--|--silence--|--speech--|--silence--|--speech--|
                        0s         3s          6s         8s         10s        12s

Concatenated Audio:     |--speech--|--speech--|--speech--|
                        0s         3s         5s         7s

Time Mappings:
  Concat [0, 3]  → Original [0, 3]
  Concat [3, 5]  → Original [6, 8]
  Concat [5, 7]  → Original [10, 12]
```

---

## Data Models

### Core Types

```swift
// Word with timing (from Whisper)
public struct WordStamp: Codable {
    let word: String
    let start: Double  // seconds
    let end: Double    // seconds
}

// Word with speaker assignment (from Diarization)
public struct DiarizedWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let speakerId: Int
    let speakerConfidence: Float
}

// Speech segment detected by VAD
public struct SpeechSegment: Identifiable, Codable {
    let id: UUID
    let startTime: TimeInterval
    var endTime: TimeInterval
    var isFinal: Bool
}

// Speaker segment from clustering
public struct SpeakerSegment: Codable {
    let speakerId: Int
    let timeRange: ClosedRange<TimeInterval>
    let confidence: Float
}

// Speaker statistics
public struct SpeakerStats: Codable {
    let speakerId: Int
    var totalSpeakingTime: TimeInterval
    var segmentCount: Int
    var wordCount: Int
    var label: String?  // "User", "Speaker 2", etc.
}
```

### Note Model (Extended)

```swift
struct Note: Identifiable, Codable {
    // Existing
    let id: UUID
    let createdAt: Date
    var duration: TimeInterval
    var audioURL: URL
    var transcript: String
    var words: [WordStamp]
    var cleanedTranscript: String?
    var summary: String?
    var keyIdeas: [String]?
    var enhancementFailed: Bool?

    // Phase 1: VAD metadata
    var originalRecordingDuration: TimeInterval?
    var speechDuration: TimeInterval?
    var vadSegments: [SpeechSegment]?

    // Phase 2: Diarization data
    var diarizedWords: [DiarizedWord]?
    var speakerSegments: [SpeakerSegment]?
    var speakerStats: [SpeakerStats]?
    var speakerCount: Int?

    // Phase 3: User identification
    var identifiedUserId: Int?
    var diarizedCleanedTranscript: String?
    var speakerAwareSummary: String?
}
```

---

## Component Reference

### Phase 1 Components

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| VADConfiguration | VADProtocol.swift | 50 | VAD settings and presets |
| VADFrame | VADProtocol.swift | 20 | Single frame analysis result |
| VADStateMachine | VADProtocol.swift | 100 | Speech segment detection |
| VADProtocol | VADProtocol.swift | 30 | Abstraction for VAD implementations |
| EnergyBasedVAD | EnergyBasedVAD.swift | 261 | Acoustic feature VAD |
| AudioSegmentManager | AudioSegmentManager.swift | 330 | Buffer and segment management |
| ContinuousRecorder | ContinuousRecorder.swift | 496 | Real-time recording with VAD |
| RecordingMode | RecorderViewModel.swift | 30 | Traditional vs VAD mode enum |

### Phase 2 Components

| Component | File | Lines | Purpose |
|-----------|------|-------|---------|
| DiarizationConfig | SpeakerEmbedding.swift | 60 | Diarization settings and presets |
| SpeakerEmbedding | SpeakerEmbedding.swift | 30 | Embedding data structure |
| SpeakerEmbeddingProtocol | SpeakerEmbedding.swift | 20 | Abstraction for embedding engines |
| AcousticSpeakerEmbedding | SpeakerEmbedding.swift | 350 | 64-dim acoustic feature extraction |
| SpeakerSegment | SpeakerClusterer.swift | 40 | Speaker time segment |
| SpeakerClusterer | SpeakerClusterer.swift | 340 | AHC clustering algorithm |
| DiarizedWord | WordSpeakerAssigner.swift | 50 | Word with speaker assignment |
| WordSpeakerAssigner | WordSpeakerAssigner.swift | 220 | Maps words to speakers |
| SpeakerStats | WordSpeakerAssigner.swift | 30 | Speaker statistics |
| SpeakerStatsCalculator | WordSpeakerAssigner.swift | 60 | Computes speaker metrics |
| DiarizationResult | DiarizationPipeline.swift | 45 | Complete diarization output |
| DiarizationPipeline | DiarizationPipeline.swift | 310 | Orchestrates full pipeline |
| DiarizedTranscriptFormatter | DiarizationPipeline.swift | 100 | Formats diarized output |

---

## Testing Strategy

### Test Categories

1. **Unit Tests** - Individual component testing
2. **Integration Tests** - Cross-component interaction
3. **Phase Tests** - Full pipeline for each phase
4. **Regression Tests** - Ensure previous phases still work

### Phase 1 Tests

| Test File | Tests | Purpose |
|-----------|-------|---------|
| VADConfigurationTests | 8 | Configuration validation |
| EnergyBasedVADTests | 15 | Speech/silence detection |
| VADStateMachineTests | 18 | State transitions |
| AudioSegmentManagerTests | 14 | Buffering and export |
| VADIntegrationTests | 10 | Full VAD pipeline |

### Phase 2 Tests

| Test File | Tests | Purpose |
|-----------|-------|---------|
| SpeakerEmbeddingTests | 12 | Embedding extraction, similarity |
| SpeakerClustererTests | 14 | Clustering accuracy, edge cases |
| WordSpeakerAssignerTests | 18 | Word assignment, smoothing, relabeling |
| Phase1And2IntegrationTests | 9 | VAD → Diarization pipeline integration |

### Test Data

- Synthetic audio with known characteristics
- Multi-speaker test scenarios
- Edge cases (single speaker, many speakers, overlapping speech)

---

## Future Considerations

### Model Upgrades

The acoustic-based implementations can be replaced with ML models:

| Component | Current | Future |
|-----------|---------|--------|
| VAD | Energy-based | Silero VAD (CoreML) |
| Speaker Embedding | Acoustic features | ECAPA-TDNN (CoreML) |
| Clustering | AHC | Spectral + refinement |

### Performance Optimizations

- Batch processing for embeddings
- GPU acceleration via Metal
- Memory-efficient streaming

### Additional Features

- Speaker voice profiles (cross-session)
- Real-time diarization display
- Speaker-specific playback
- Export with speaker annotations

---

*This document is updated as each phase is implemented.*
