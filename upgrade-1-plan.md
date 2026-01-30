# WalkWrite Upgrade Plan: VAD + Speaker Diarization

## Executive Summary

This document outlines a comprehensive plan to upgrade WalkWrite with three major new capabilities:

1. **Continuous VAD-based Recording** - Record indefinitely while automatically filtering out non-speech segments
2. **Speaker Diarization** - Identify and label different speakers in transcriptions
3. **User Identification** - Designate the most consistent speaker as "user" and provide this context to the LLM

---

## Table of Contents

1. [Current Architecture Overview](#current-architecture-overview)
2. [Target Architecture](#target-architecture)
3. [Technical Approach](#technical-approach)
4. [Data Model Changes](#data-model-changes)
5. [Implementation Phases](#implementation-phases)
6. [Testing Strategy](#testing-strategy)
7. [Usability Considerations](#usability-considerations)
8. [Risk Assessment & Mitigations](#risk-assessment--mitigations)
9. [Dependencies & Resources](#dependencies--resources)
10. [Success Criteria](#success-criteria)

---

## Current Architecture Overview

### Existing Pipeline
```
Recording (16kHz WAV) → Whisper Transcription → Optional LLM Enhancement → Storage
```

### Key Components
- **RecorderViewModel**: Manages AVAudioRecorder, pause/resume, audio metering
- **WhisperEngine**: Chunked (30s) transcription via whisper.cpp with word timestamps
- **LLMEngine**: Qwen-3 0.6B via MLX for cleaning, summarization, key ideas
- **NoteStore**: JSON-backed persistence with partial result updates
- **Note Model**: Contains transcript, word timestamps, LLM-enhanced content

### Current Limitations
- No Voice Activity Detection (only visual audio level metering)
- No speaker differentiation
- Single speaker assumption in LLM prompts
- Fixed recording duration (user-initiated stop)

---

## Target Architecture

### New Pipeline
```
Continuous Recording → Real-time VAD → Speech Segments Only
                                           ↓
                            Whisper Transcription (with timestamps)
                                           ↓
                            Speaker Diarization (assign words to speakers)
                                           ↓
                            User Identification (most consistent speaker)
                                           ↓
                            Speaker-Aware LLM Enhancement
                                           ↓
                            Multi-Speaker Note Storage
```

### High-Level Architecture Diagram
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           RECORDING LAYER                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐                   │
│  │ AVAudioEngine │───▶│ VAD Engine   │───▶│ Segment      │                   │
│  │ (Tap Buffer)  │    │ (Silero/etc) │    │ Aggregator   │                   │
│  └──────────────┘    └──────────────┘    └──────────────┘                   │
│                             │                    │                           │
│                    Discard silence      Keep speech segments                 │
│                                                  │                           │
│                                    ┌─────────────▼─────────────┐            │
│                                    │ Audio Buffer Manager      │            │
│                                    │ (concatenate speech only) │            │
│                                    └───────────────────────────┘            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         TRANSCRIPTION LAYER                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐                                                        │
│  │ WhisperEngine    │  Existing chunked transcription                        │
│  │ (word timestamps)│  Output: [(word, start, end), ...]                     │
│  └──────────────────┘                                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DIARIZATION LAYER                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐       │
│  │ Speaker Embedding │───▶│ Clustering       │───▶│ Word-to-Speaker  │       │
│  │ Extraction        │    │ Algorithm        │    │ Assignment       │       │
│  │ (pyannote/etc)    │    │ (spectral/HDBSCAN)│   │                  │       │
│  └──────────────────┘    └──────────────────┘    └──────────────────┘       │
│                                                                              │
│                              ┌──────────────────┐                            │
│                              │ User Identification│                           │
│                              │ (most speaking time)│                          │
│                              └──────────────────┘                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         LLM ENHANCEMENT LAYER                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  New prompts with speaker context:                                           │
│  - "You are analyzing a conversation. Speaker 1 (User) said: ..."           │
│  - "Summarize this conversation between the user and N other speakers"      │
│  - "Extract key ideas, noting which speaker contributed each"               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Technical Approach

### 1. Voice Activity Detection (VAD)

#### Option A: Silero VAD (Recommended)
- **Model**: Silero VAD v4 (ONNX format, ~2MB)
- **Performance**: Highly accurate, very lightweight, designed for real-time
- **Latency**: ~1ms per 30ms audio frame
- **iOS Integration**: Via ONNX Runtime or CoreML conversion

**Implementation Strategy**:
```swift
// New component: VADEngine.swift
actor VADEngine {
    private var model: ONNXModel // or CoreML model
    private var state: VADState  // LSTM hidden state

    // Process 30ms chunks, return speech probability
    func process(audioBuffer: AVAudioPCMBuffer) async -> Float

    // Configurable thresholds
    var speechThreshold: Float = 0.5
    var silenceThreshold: Float = 0.35
    var minSpeechDuration: TimeInterval = 0.25
    var minSilenceDuration: TimeInterval = 0.3
}
```

#### Option B: WebRTC VAD
- Simpler, built into many audio libraries
- Less accurate than Silero but battle-tested
- Available via open-source implementations

#### Option C: Apple's Sound Analysis Framework
- Built-in iOS capability (SoundAnalysis framework)
- Can detect speech vs non-speech
- Less configurable but native integration

**Recommendation**: Start with Silero VAD via CoreML conversion for best accuracy/performance balance.

### 2. Continuous Recording Architecture

#### Audio Capture Changes
Replace `AVAudioRecorder` with `AVAudioEngine` for real-time buffer access:

```swift
// New component: ContinuousRecorder.swift
class ContinuousRecorder {
    private let audioEngine = AVAudioEngine()
    private let vadEngine = VADEngine()
    private var speechBuffer: [Float] = []
    private var currentSegment: AudioSegment?

    // States
    enum State {
        case idle
        case recording
        case inSpeech
        case inSilence
    }

    func startRecording() {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 480, format: format) { buffer, time in
            Task {
                await self.processBuffer(buffer, time: time)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) async {
        let speechProbability = await vadEngine.process(buffer)

        if speechProbability > vadEngine.speechThreshold {
            // Accumulate speech
            appendToSpeechBuffer(buffer)
            extendCurrentSegment(time)
        } else if speechProbability < vadEngine.silenceThreshold {
            // Potential end of speech
            if silenceDurationExceedsThreshold() {
                finalizeCurrentSegment()
            }
        }
    }
}
```

#### Segment Management
```swift
struct AudioSegment {
    let id: UUID
    var startTime: TimeInterval    // Original recording time
    var endTime: TimeInterval
    var audioData: Data            // Raw PCM
    var isFinal: Bool
}

class SegmentAggregator {
    private var segments: [AudioSegment] = []

    // Combine segments with small gaps (likely same utterance)
    func mergeAdjacentSegments(maxGap: TimeInterval = 0.5)

    // Export final WAV with only speech portions
    func exportConcatenatedAudio() -> URL

    // Maintain time mapping for diarization
    func originalTimeMapping() -> [(segmentTime: Range<TimeInterval>, originalTime: Range<TimeInterval>)]
}
```

### 3. Speaker Diarization

#### Approach: Embedding-Based Clustering

**Step 1: Speaker Embedding Extraction**
Use a pre-trained speaker embedding model to extract voice characteristics.

**Model Options**:
1. **pyannote/embedding** - State-of-the-art, used by most diarization systems
2. **SpeechBrain ECAPA-TDNN** - Excellent accuracy, available in ONNX
3. **Resemblyzer** - Simpler, good for basic use cases
4. **Apple's SoundAnalysis** - Can provide basic speaker features

**Recommended**: ECAPA-TDNN converted to CoreML

```swift
// New component: SpeakerEmbeddingEngine.swift
actor SpeakerEmbeddingEngine {
    private var model: CoreMLModel

    // Extract 192-dimensional embedding from audio segment
    func extractEmbedding(from audio: AVAudioPCMBuffer) async -> [Float]

    // Process multiple segments efficiently
    func batchExtract(segments: [AudioSegment]) async -> [[Float]]
}
```

**Step 2: Segmentation Strategy**

Divide audio into analysis windows for embedding extraction:

```swift
struct DiarizationConfig {
    let windowSize: TimeInterval = 1.5      // Analysis window
    let windowStep: TimeInterval = 0.5      // Overlap/step
    let minSegmentDuration: TimeInterval = 0.5
}
```

**Step 3: Clustering Algorithm**

```swift
// New component: SpeakerClusterer.swift
class SpeakerClusterer {
    // Option 1: Agglomerative Hierarchical Clustering (AHC)
    // - Works well with unknown number of speakers
    // - Uses cosine distance between embeddings

    // Option 2: Spectral Clustering
    // - Better for complex speaker interactions
    // - Requires estimating number of speakers

    // Option 3: HDBSCAN
    // - Handles noise well
    // - Good for varying speaker densities

    func cluster(embeddings: [[Float]],
                 timestamps: [Range<TimeInterval>]) -> [SpeakerSegment]
}

struct SpeakerSegment {
    let speakerId: Int          // 0, 1, 2, ...
    let timeRange: Range<TimeInterval>
    let confidence: Float
}
```

**Step 4: Word-to-Speaker Assignment**

```swift
// Extend WhisperEngine output
struct DiarizedWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let speakerId: Int
    let speakerConfidence: Float
}

class WordSpeakerAssigner {
    func assign(words: [WordStamp],
                speakerSegments: [SpeakerSegment]) -> [DiarizedWord] {
        words.map { word in
            // Find overlapping speaker segment
            let segment = findBestOverlap(word: word, segments: speakerSegments)
            return DiarizedWord(
                word: word.word,
                start: word.start,
                end: word.end,
                speakerId: segment.speakerId,
                speakerConfidence: segment.confidence
            )
        }
    }
}
```

### 4. User Identification

**Strategy**: The "user" is the person who speaks most consistently (most total speaking time).

```swift
// New component: UserIdentifier.swift
struct SpeakerStats {
    let speakerId: Int
    var totalSpeakingTime: TimeInterval
    var segmentCount: Int
    var averageSegmentLength: TimeInterval
    var firstAppearance: TimeInterval
    var lastAppearance: TimeInterval
}

class UserIdentifier {
    func identify(diarizedWords: [DiarizedWord]) -> (userId: Int, stats: [SpeakerStats]) {
        var statsMap: [Int: SpeakerStats] = [:]

        // Aggregate stats per speaker
        for word in diarizedWords {
            // Update speaking time, segment count, etc.
        }

        // Primary criterion: Most total speaking time
        // Secondary: Most segments (consistency)
        // Tertiary: First to speak (often the primary recorder)

        let userId = statsMap.values
            .sorted { $0.totalSpeakingTime > $1.totalSpeakingTime }
            .first?.speakerId ?? 0

        return (userId, Array(statsMap.values))
    }
}
```

**Alternative Strategies** (configurable):
1. First speaker to appear
2. Speaker with most segments
3. Manual user designation (tap to mark as "me")
4. Persistent voice profile matching across sessions

### 5. Speaker-Aware LLM Enhancement

#### Updated Prompts

```swift
// LLMEngine.swift modifications

func cleanedTranscript(diarizedTranscript: String, speakerCount: Int, userId: Int) async throws -> String {
    let prompt = """
    You are cleaning a transcript of a conversation between \(speakerCount) people.
    Speaker \(userId) is the User (the person who made this recording).

    Instructions:
    - Fix grammar and punctuation
    - Remove filler words (um, uh, like, you know)
    - Preserve the [Speaker N]: labels
    - Keep the conversation structure intact

    Transcript:
    \(diarizedTranscript)

    Cleaned transcript:
    """
    return try await generate(prompt: prompt)
}

func summary(cleanedTranscript: String, speakerCount: Int, userId: Int) async throws -> String {
    let prompt = """
    Summarize this conversation in 3-4 sentences.
    This is a recording made by Speaker \(userId) (the User).
    There are \(speakerCount) total speakers.

    Focus on:
    - What the User discussed or learned
    - Key points raised by other speakers
    - The overall outcome or conclusion

    Transcript:
    \(cleanedTranscript)

    Summary:
    """
    return try await generate(prompt: prompt)
}

func keyIdeas(cleanedTranscript: String, speakerCount: Int, userId: Int) async throws -> [String] {
    let prompt = """
    Extract key ideas from this conversation.
    The User is Speaker \(userId).

    For each idea, note:
    - The key point
    - Who raised it (User, Speaker 2, etc.)
    - Brief elaboration

    Format as bullet points.

    Transcript:
    \(cleanedTranscript)

    Key ideas:
    """
    // Parse response into structured key ideas
}
```

#### Transcript Formatting

```swift
func formatDiarizedTranscript(words: [DiarizedWord], userId: Int) -> String {
    var result = ""
    var currentSpeaker = -1

    for word in words {
        if word.speakerId != currentSpeaker {
            if !result.isEmpty { result += "\n" }
            let label = word.speakerId == userId ? "User" : "Speaker \(word.speakerId + 1)"
            result += "[\(label)]: "
            currentSpeaker = word.speakerId
        }
        result += word.word + " "
    }

    return result
}
```

---

## Data Model Changes

### Updated Note Model

```swift
struct Note: Identifiable, Codable {
    // Existing fields
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

    // NEW: Diarization data
    var diarizedWords: [DiarizedWord]?
    var speakerStats: [SpeakerStats]?
    var identifiedUserId: Int?
    var speakerCount: Int?

    // NEW: VAD metadata
    var originalRecordingDuration: TimeInterval?  // Before VAD filtering
    var speechDuration: TimeInterval?             // After VAD filtering
    var vadSegments: [TimeRange]?                 // For UI visualization

    // NEW: Speaker-aware enhanced content
    var diarizedCleanedTranscript: String?
    var speakerAwareSummary: String?
    var speakerAwareKeyIdeas: [SpeakerKeyIdea]?
}

struct DiarizedWord: Codable, Hashable {
    let word: String
    let start: Double
    let end: Double
    let speakerId: Int
    let speakerConfidence: Float
}

struct SpeakerStats: Codable {
    let speakerId: Int
    var totalSpeakingTime: TimeInterval
    var segmentCount: Int
    var wordCount: Int
    var label: String?  // User-provided name, e.g., "John"
}

struct SpeakerKeyIdea: Codable {
    let idea: String
    let speakerId: Int
    let elaboration: String
}

struct TimeRange: Codable {
    let start: Double
    let end: Double
}
```

### Migration Strategy

```swift
// Version the data model
struct NoteV2: Codable {
    // New structure
}

// Migration on load
func migrateIfNeeded(data: Data) -> [Note] {
    // Try V2 first
    if let v2 = try? JSONDecoder().decode([NoteV2].self, from: data) {
        return v2.map { $0.toNote() }
    }

    // Fallback to V1
    if let v1 = try? JSONDecoder().decode([NoteV1].self, from: data) {
        return v1.map { $0.upgraded() }
    }

    return []
}
```

---

## Implementation Phases

### Phase 1: VAD Foundation (Week 1-2)

**Goals**:
- Integrate VAD model
- Replace AVAudioRecorder with AVAudioEngine
- Implement real-time speech detection
- Basic segment management

**Tasks**:
1. [ ] Research and select VAD model (Silero recommended)
2. [ ] Convert VAD model to CoreML
3. [ ] Create `VADEngine.swift` actor
4. [ ] Create `ContinuousRecorder.swift` with AVAudioEngine
5. [ ] Implement segment accumulation and export
6. [ ] Update `RecorderViewModel` to use new recording system
7. [ ] Add VAD sensitivity settings to UI
8. [ ] Unit tests for VAD detection accuracy

**Deliverables**:
- Working VAD that filters silence during recording
- Audio export contains only speech segments
- Basic UI showing VAD activity

### Phase 2: Diarization Integration (Week 3-4)

**Goals**:
- Speaker embedding extraction
- Clustering algorithm implementation
- Word-to-speaker assignment

**Tasks**:
1. [ ] Research speaker embedding models
2. [ ] Convert embedding model to CoreML
3. [ ] Create `SpeakerEmbeddingEngine.swift`
4. [ ] Implement sliding window segmentation
5. [ ] Create `SpeakerClusterer.swift` with AHC
6. [ ] Implement word-to-speaker assignment
7. [ ] Update transcription pipeline to include diarization
8. [ ] Test with multi-speaker recordings

**Deliverables**:
- Working diarization post-transcription
- Speaker labels assigned to all words
- Reasonable accuracy on 2-4 speaker conversations

### Phase 3: User Identification & LLM Integration (Week 5-6)

**Goals**:
- Implement user identification algorithm
- Update LLM prompts for speaker awareness
- Enhance note model with new data

**Tasks**:
1. [ ] Create `UserIdentifier.swift`
2. [ ] Update `Note` model with diarization fields
3. [ ] Implement data migration
4. [ ] Update `LLMEngine` prompts
5. [ ] Create speaker-formatted transcript generation
6. [ ] Test LLM output quality with speaker context
7. [ ] Handle edge cases (single speaker, many speakers)

**Deliverables**:
- Automatic user identification
- Speaker-aware LLM summaries and key ideas
- Backward-compatible data model

### Phase 4: UI/UX Enhancements (Week 7-8)

**Goals**:
- Display speaker information in UI
- Speaker color coding
- Interactive speaker labels

**Tasks**:
1. [ ] Design speaker visualization components
2. [ ] Color-coded transcript view by speaker
3. [ ] Speaker timeline visualization
4. [ ] Speaker statistics view
5. [ ] Manual speaker label editing
6. [ ] VAD activity indicator during recording
7. [ ] Settings for VAD and diarization options

**Deliverables**:
- Rich speaker-aware transcript display
- Intuitive speaker identification UI
- Configurable settings

### Phase 5: Testing & Optimization (Week 9-10)

**Goals**:
- Comprehensive testing
- Performance optimization
- Memory management
- Edge case handling

**Tasks**:
1. [ ] Unit tests for all new components
2. [ ] Integration tests for full pipeline
3. [ ] Performance profiling and optimization
4. [ ] Memory usage optimization
5. [ ] Battery usage testing
6. [ ] Test with various audio conditions
7. [ ] Test with different speaker counts
8. [ ] Stress testing (long recordings)

**Deliverables**:
- 90%+ test coverage on new code
- Acceptable performance metrics
- Documented limitations

### Phase 6: Polish & Release (Week 11-12)

**Goals**:
- Bug fixes
- Documentation
- Release preparation

**Tasks**:
1. [ ] Address bugs from testing
2. [ ] Code documentation
3. [ ] User documentation updates
4. [ ] App Store description updates
5. [ ] Feature flags for gradual rollout
6. [ ] Beta testing
7. [ ] Final release

---

## Testing Strategy

### Unit Tests

```swift
// VADEngineTests.swift
class VADEngineTests: XCTestCase {
    func testSpeechDetection() async {
        // Load known speech audio
        // Verify speech probability > threshold
    }

    func testSilenceDetection() async {
        // Load silence audio
        // Verify speech probability < threshold
    }

    func testMixedAudio() async {
        // Load audio with speech and silence
        // Verify correct segment boundaries
    }

    func testNoiseRobustness() async {
        // Test with background noise
    }
}

// SpeakerEmbeddingTests.swift
class SpeakerEmbeddingTests: XCTestCase {
    func testEmbeddingExtraction() async {
        // Verify embedding dimensions
        // Verify consistency for same speaker
    }

    func testDifferentSpeakers() async {
        // Verify embeddings are distinct for different speakers
    }
}

// SpeakerClustererTests.swift
class SpeakerClustererTests: XCTestCase {
    func testTwoSpeakers() {
        // Verify correct cluster count
    }

    func testSingleSpeaker() {
        // Verify no false splits
    }

    func testManySpeakers() {
        // Test with 4+ speakers
    }
}

// UserIdentifierTests.swift
class UserIdentifierTests: XCTestCase {
    func testMostTalkativeSpeaker() {
        // Verify correct identification
    }

    func testEqualSpeakers() {
        // Test tiebreaker logic
    }
}
```

### Integration Tests

```swift
// FullPipelineTests.swift
class FullPipelineTests: XCTestCase {
    func testRecordingToTranscription() async {
        // Record → VAD → Export → Transcribe → Diarize → User ID
    }

    func testEnhancementWithDiarization() async {
        // Full pipeline including LLM enhancement
    }
}
```

### Test Audio Corpus

Create test fixtures covering:
1. Single speaker, clear audio
2. Single speaker, noisy background
3. Two speakers, turn-taking
4. Two speakers, overlapping
5. Three+ speakers, meeting style
6. Long silence gaps
7. Music/non-speech audio
8. Mixed languages (future consideration)

### Performance Benchmarks

| Metric | Target | Measurement Method |
|--------|--------|-------------------|
| VAD latency | < 5ms per frame | Time `process()` call |
| Embedding extraction | < 100ms per second of audio | Batch processing time |
| Clustering | < 1s for 5min recording | Full clustering time |
| Memory (VAD) | < 50MB | Instruments profiling |
| Memory (Diarization) | < 200MB additional | Instruments profiling |
| Battery (recording) | < 10% per hour | Device testing |

### Accuracy Metrics

| Metric | Target | Dataset |
|--------|--------|---------|
| VAD precision | > 95% | Mixed speech/silence corpus |
| VAD recall | > 98% | Speech shouldn't be lost |
| Diarization DER | < 15% | CALLHOME-style test set |
| User ID accuracy | > 90% | Multi-speaker test set |

---

## Usability Considerations

### Recording Experience

1. **Visual Feedback**
   - Real-time VAD indicator (speech detected vs silence)
   - Waveform shows only speech being captured
   - Timer shows both elapsed and speech time
   - Color coding: green = speech, gray = discarded

2. **Confidence Indicators**
   - Show VAD confidence level
   - Indicate when speech is uncertain

3. **Manual Override**
   - Button to force-include current audio
   - Setting to disable VAD temporarily

### Transcript Display

1. **Speaker Visualization**
   - Color-coded speaker labels
   - Consistent colors across the app
   - Speaker avatars/icons

2. **Interactive Elements**
   - Tap speaker label to see stats
   - Drag to merge speakers (if misidentified)
   - Long-press to manually relabel

3. **Playback Integration**
   - Current speaker highlighted during playback
   - Jump to specific speaker's segments
   - Filter playback by speaker

### Settings & Customization

```
Settings:
├── Recording
│   ├── VAD Sensitivity (slider: Less → More aggressive)
│   ├── Minimum Speech Duration (0.25s - 1.0s)
│   ├── Silence Threshold (0.3s - 2.0s)
│   └── Keep Original Audio (toggle)
│
├── Diarization
│   ├── Enable Speaker Detection (toggle)
│   ├── Maximum Speakers (2-10)
│   └── Clustering Sensitivity
│
└── User Identification
    ├── Auto-identify User (toggle)
    └── User Identification Method
        ├── Most Speaking Time (default)
        ├── First Speaker
        └── Manual Selection
```

### Edge Case Handling

| Scenario | Handling |
|----------|----------|
| Only silence recorded | Show warning, offer to retry |
| Single speaker detected | Skip diarization UI, normal mode |
| Too many speakers (>10) | Merge into "Others" category |
| Overlapping speech | Assign to dominant speaker, mark uncertain |
| Very short recording | Skip diarization, too little data |
| Recording interrupted | Save partial, mark incomplete |

### Accessibility

1. VoiceOver support for speaker labels
2. High contrast mode for speaker colors
3. Haptic feedback for VAD activity
4. Audio cues for speaker changes (optional)

---

## Risk Assessment & Mitigations

### Technical Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| VAD model too large for iOS | High | Low | Use quantized Silero (~2MB) |
| Embedding model memory usage | High | Medium | Batch processing, aggressive unloading |
| Diarization inaccurate | Medium | Medium | Fallback to single-speaker mode |
| Real-time processing too slow | High | Low | Buffer and batch process |
| Background audio causes issues | Medium | Medium | Improve VAD robustness |

### User Experience Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Users confused by speaker labels | Medium | Medium | Clear onboarding, simple defaults |
| Wrong speaker identified as user | High | Medium | Easy manual correction, confidence display |
| Speech accidentally discarded | High | Low | Conservative VAD defaults, undo option |
| Battery drain concerns | Medium | Medium | Optimize, show battery usage |

### Performance Risks

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Memory pressure | High | Medium | Sequential processing, aggressive cleanup |
| App crashes during long recording | High | Low | Periodic saves, crash recovery |
| Slow diarization | Medium | Medium | Background processing, progress UI |

---

## Dependencies & Resources

### Models to Integrate

1. **VAD**: Silero VAD v4
   - Source: https://github.com/snakers4/silero-vad
   - Format: ONNX → CoreML conversion needed
   - Size: ~2MB

2. **Speaker Embedding**: ECAPA-TDNN or WeSpeaker
   - Source: SpeechBrain or WeSpeaker projects
   - Format: ONNX → CoreML conversion needed
   - Size: ~20-40MB

### Libraries

1. **ONNX Runtime** (if not using CoreML)
   - Swift wrapper available
   - Consider CoreML conversion instead for better iOS integration

2. **Accelerate Framework** (Apple)
   - For vector math in clustering
   - Already included in iOS

3. **No new SPM dependencies required** (preferably)
   - Avoid adding weight to the app

### Development Resources

- Test device with sufficient storage
- Multi-speaker test recordings
- Access to speaker diarization benchmarks
- CoreML Tools for model conversion

---

## Success Criteria

### MVP (Minimum Viable Product)

- [ ] VAD successfully filters silence during recording
- [ ] Diarization distinguishes 2-3 speakers with >80% accuracy
- [ ] User correctly identified in >85% of recordings
- [ ] LLM summaries mention speakers appropriately
- [ ] No significant increase in app crashes
- [ ] Recording battery usage < 15% per hour

### Full Release

- [ ] VAD works reliably across noise conditions
- [ ] Diarization handles 2-6 speakers with <15% DER
- [ ] User identification >90% accurate
- [ ] UI clearly shows speaker information
- [ ] Manual speaker correction available
- [ ] Settings allow customization
- [ ] Performance within acceptable limits
- [ ] Comprehensive test coverage
- [ ] User documentation updated

### Stretch Goals

- [ ] Speaker voice profile persistence (recognize across recordings)
- [ ] Real-time diarization during playback
- [ ] Speaker-specific playback mode
- [ ] Export with speaker annotations
- [ ] Speaker statistics dashboard

---

## Appendix

### A. Useful References

1. **Silero VAD**: https://github.com/snakers4/silero-vad
2. **pyannote-audio**: https://github.com/pyannote/pyannote-audio
3. **SpeechBrain**: https://speechbrain.github.io/
4. **Diarization Error Rate**: https://github.com/nryant/dscore

### B. Sample Audio Processing Code

```swift
// Convert audio format for VAD processing
func convertTo16kHzMono(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    ) else { return nil }

    guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
        return nil
    }

    let ratio = format.sampleRate / buffer.format.sampleRate
    let outputFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

    guard let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: outputFrames
    ) else { return nil }

    var error: NSError?
    converter.convert(to: outputBuffer, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
    }

    return outputBuffer
}
```

### C. Cosine Similarity for Embeddings

```swift
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return 0 }

    var dotProduct: Float = 0
    var normA: Float = 0
    var normB: Float = 0

    vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
    vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
    vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

    let denominator = sqrt(normA) * sqrt(normB)
    return denominator > 0 ? dotProduct / denominator : 0
}
```

---

## Revision History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2025-01-30 | Claude | Initial plan |

---

*This document will be updated as the implementation progresses and new learnings emerge.*
