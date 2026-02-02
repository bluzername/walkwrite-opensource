# WalkWrite Build Configurations

## Full Build (with LLM)
- Includes: MLX, MLXLLM, Whisper
- Size: ~4-8GB (Debug), ~2-3GB (Release)
- Features: Full transcription + AI summaries

## Lite Build (Transcription Only)
- Includes: Whisper only
- Size: ~200-500MB
- Features: Transcription, VAD, Diarization, Speaker ID

## How to Create Lite Build

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
