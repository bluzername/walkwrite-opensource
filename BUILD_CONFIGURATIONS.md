# WalkWrite Build Configurations

## Size Comparison

| Build Type | Size | AI Summaries |
|------------|------|--------------|
| Full (bundled MLX) | 4-8 GB | ✅ Always available |
| Lite (no MLX) | 200-500 MB | ❌ Disabled |
| **Apple Intelligence** | **200-500 MB** | **✅ iOS 18.4+** |
| On-Demand Download | 200-500 MB + download | ✅ After download |

## Recommended: Apple Intelligence (iOS 18.4+)

**Zero app size impact** - uses Apple's built-in on-device LLM.

### Setup
1. Remove MLX packages (see below)
2. The app automatically uses `AppleLLMEngine.swift` on iOS 18.4+
3. Users need Apple Intelligence enabled on their device

### Code Flow
```swift
// UnifiedLLM automatically picks the best backend:
// 1. Apple Foundation Models (if iOS 18.4+ & available)
// 2. MLX (if compiled in)
// 3. Passthrough (if nothing available)

let summary = try await UnifiedLLM.summary(for: transcript)
```

---

## How to Create Lite Build (Remove MLX)

### Step 1: Remove MLX Packages
1. Open WalkWrite.xcodeproj in Xcode
2. Click on WalkWrite project in navigator
3. Go to "Package Dependencies" tab
4. Select and remove:
   - mlx-swift
   - mlx-swift-examples
5. Click "Remove" to confirm

### Step 2: Clean and Rebuild
1. Product → Clean Build Folder (Cmd+Shift+K)
2. Delete DerivedData:
   ```bash
   rm -rf ~/Library/Developer/Xcode/DerivedData/WalkWrite-*
   ```
3. Build (Cmd+B)

### Step 3: Verify Size
1. Product → Archive
2. Distribute App → Development
3. Check .ipa size (should be ~100-200MB)

## What Works Without MLXLLM

| Feature | Full | Lite |
|---------|------|------|
| Recording | ✅ | ✅ |
| VAD Mode | ✅ | ✅ |
| Whisper Transcription | ✅ | ✅ |
| Speaker Diarization | ✅ | ✅ |
| User Identification | ✅ | ✅ |
| Speaker Visualization | ✅ | ✅ |
| Clean Transcript | ✅ | ❌ (returns original) |
| Summary | ✅ | ❌ (returns empty) |
| Key Ideas | ✅ | ❌ (returns empty) |

## Code Design

The code uses conditional compilation:
```swift
#if canImport(MLXLLM)
import MLXLLM
// LLM code here
#else
return original  // Passthrough
#endif
```

This means removing the package is safe - no code changes needed.

## Alternative: On-Device LLM via API

If you want AI features without the size, consider:
1. Using OpenAI/Anthropic API (requires network)
2. Using Apple's on-device ML (smaller models)
3. Downloading LLM model on first launch (not bundled)
