import Foundation
import Accelerate

// MARK: - Diarization Configuration

/// Configuration for speaker diarization
public struct DiarizationConfig: Codable, Sendable {
    /// Size of the analysis window in seconds
    public var windowSize: TimeInterval

    /// Step size between windows in seconds (overlap = windowSize - windowStep)
    public var windowStep: TimeInterval

    /// Minimum segment duration to consider for embedding
    public var minSegmentDuration: TimeInterval

    /// Maximum number of speakers to detect
    public var maxSpeakers: Int

    /// Distance threshold for clustering (lower = more clusters)
    public var clusteringThreshold: Float

    /// Sample rate expected for audio
    public var sampleRate: Double

    public static let `default` = DiarizationConfig(
        windowSize: 1.5,
        windowStep: 0.75,
        minSegmentDuration: 0.5,
        maxSpeakers: 10,
        clusteringThreshold: 0.4,
        sampleRate: 16000.0
    )

    /// For conversations with few speakers
    public static let fewSpeakers = DiarizationConfig(
        windowSize: 2.0,
        windowStep: 1.0,
        minSegmentDuration: 0.5,
        maxSpeakers: 4,
        clusteringThreshold: 0.35,
        sampleRate: 16000.0
    )

    /// For meetings with many speakers
    public static let manySpeakers = DiarizationConfig(
        windowSize: 1.0,
        windowStep: 0.5,
        minSegmentDuration: 0.3,
        maxSpeakers: 15,
        clusteringThreshold: 0.5,
        sampleRate: 16000.0
    )

    public init(
        windowSize: TimeInterval = 1.5,
        windowStep: TimeInterval = 0.75,
        minSegmentDuration: TimeInterval = 0.5,
        maxSpeakers: Int = 10,
        clusteringThreshold: Float = 0.4,
        sampleRate: Double = 16000.0
    ) {
        self.windowSize = windowSize
        self.windowStep = windowStep
        self.minSegmentDuration = minSegmentDuration
        self.maxSpeakers = maxSpeakers
        self.clusteringThreshold = clusteringThreshold
        self.sampleRate = sampleRate
    }
}

// MARK: - Speaker Embedding

/// Represents a speaker embedding extracted from an audio segment
public struct SpeakerEmbedding: Codable, Sendable {
    /// The embedding vector (acoustic features)
    public let features: [Float]

    /// Start time of the segment this embedding was extracted from
    public let timestamp: TimeInterval

    /// Duration of the segment
    public let duration: TimeInterval

    /// Dimension of the embedding
    public var dimension: Int {
        features.count
    }

    public init(features: [Float], timestamp: TimeInterval, duration: TimeInterval) {
        self.features = features
        self.timestamp = timestamp
        self.duration = duration
    }
}

// MARK: - Speaker Embedding Protocol

/// Protocol for speaker embedding extraction
public protocol SpeakerEmbeddingProtocol: AnyObject, Sendable {
    /// Extract a single embedding from audio samples
    func extractEmbedding(from samples: [Float], sampleRate: Double) -> [Float]

    /// Extract embeddings from multiple segments
    func batchExtract(segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)],
                      sampleRate: Double) -> [SpeakerEmbedding]

    /// The dimension of embeddings produced by this extractor
    var embeddingDimension: Int { get }
}

// MARK: - Acoustic Speaker Embedding

/// Extracts speaker embeddings using acoustic features
///
/// This is a simplified embedding that uses:
/// - Mel-frequency cepstral coefficients (MFCC-like features)
/// - Pitch statistics (fundamental frequency characteristics)
/// - Energy distribution (speaking intensity patterns)
/// - Temporal dynamics (rate and rhythm indicators)
///
/// Can be replaced with a neural embedding model (ECAPA-TDNN) for better accuracy.
public final class AcousticSpeakerEmbedding: SpeakerEmbeddingProtocol, @unchecked Sendable {

    // MARK: - Properties

    public let embeddingDimension: Int = 64

    // FFT parameters
    private let fftSize: Int = 512
    private let hopSize: Int = 160  // 10ms at 16kHz
    private let numMelBins: Int = 26
    private let numMFCC: Int = 13

    // Mel filterbank (computed once)
    private lazy var melFilterbank: [[Float]] = computeMelFilterbank()

    private let lock = NSLock()

    // MARK: - Initialization

    public init() {}

    // MARK: - SpeakerEmbeddingProtocol

    public func extractEmbedding(from samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count >= fftSize else {
            return [Float](repeating: 0, count: embeddingDimension)
        }

        // Extract features
        let spectralFeatures = extractSpectralFeatures(samples, sampleRate: sampleRate)
        let pitchFeatures = extractPitchFeatures(samples, sampleRate: sampleRate)
        let energyFeatures = extractEnergyFeatures(samples)
        let temporalFeatures = extractTemporalFeatures(samples, sampleRate: sampleRate)

        // Combine into embedding vector
        var embedding: [Float] = []
        embedding.append(contentsOf: spectralFeatures)   // 32 features
        embedding.append(contentsOf: pitchFeatures)      // 12 features
        embedding.append(contentsOf: energyFeatures)     // 12 features
        embedding.append(contentsOf: temporalFeatures)   // 8 features

        // Ensure correct dimension (pad or truncate if needed)
        if embedding.count < embeddingDimension {
            embedding.append(contentsOf: [Float](repeating: 0, count: embeddingDimension - embedding.count))
        } else if embedding.count > embeddingDimension {
            embedding = Array(embedding.prefix(embeddingDimension))
        }

        // L2 normalize the embedding
        return l2Normalize(embedding)
    }

    public func batchExtract(segments: [(samples: [Float], timestamp: TimeInterval, duration: TimeInterval)],
                             sampleRate: Double) -> [SpeakerEmbedding] {
        return segments.map { segment in
            let features = extractEmbedding(from: segment.samples, sampleRate: sampleRate)
            return SpeakerEmbedding(
                features: features,
                timestamp: segment.timestamp,
                duration: segment.duration
            )
        }
    }

    // MARK: - Feature Extraction

    /// Extract spectral features (simplified MFCC-like)
    private func extractSpectralFeatures(_ samples: [Float], sampleRate: Double) -> [Float] {
        var features: [Float] = []

        // Calculate spectrogram
        let numFrames = max(1, (samples.count - fftSize) / hopSize + 1)
        var melSpectrogram: [[Float]] = []

        for frameIdx in 0..<min(numFrames, 50) {  // Limit frames for efficiency
            let start = frameIdx * hopSize
            let end = min(start + fftSize, samples.count)
            let frame = Array(samples[start..<end])

            // Apply window and compute magnitude spectrum
            let spectrum = computeMagnitudeSpectrum(frame)

            // Apply mel filterbank
            let melEnergies = applyMelFilterbank(spectrum)
            melSpectrogram.append(melEnergies)
        }

        guard !melSpectrogram.isEmpty else {
            return [Float](repeating: 0, count: 32)
        }

        // Compute statistics over mel spectrogram
        for bin in 0..<numMelBins {
            let binValues = melSpectrogram.map { $0[bin] }
            let mean = binValues.reduce(0, +) / Float(binValues.count)
            features.append(mean)
        }

        // Add delta features (first derivative approximation)
        if melSpectrogram.count > 1 {
            for bin in 0..<min(6, numMelBins) {
                let binValues = melSpectrogram.map { $0[bin] }
                var delta: Float = 0
                for i in 1..<binValues.count {
                    delta += abs(binValues[i] - binValues[i-1])
                }
                features.append(delta / Float(binValues.count - 1))
            }
        } else {
            features.append(contentsOf: [Float](repeating: 0, count: 6))
        }

        return Array(features.prefix(32))
    }

    /// Extract pitch-related features
    private func extractPitchFeatures(_ samples: [Float], sampleRate: Double) -> [Float] {
        var features: [Float] = []

        // Estimate pitch using autocorrelation
        let pitches = estimatePitch(samples, sampleRate: sampleRate)

        if pitches.isEmpty {
            return [Float](repeating: 0, count: 12)
        }

        // Pitch statistics
        let mean = pitches.reduce(0, +) / Float(pitches.count)
        features.append(mean / 500.0)  // Normalize to typical range

        // Standard deviation
        let variance = pitches.map { pow($0 - mean, 2) }.reduce(0, +) / Float(pitches.count)
        features.append(sqrt(variance) / 100.0)

        // Min/max
        features.append((pitches.min() ?? 0) / 500.0)
        features.append((pitches.max() ?? 0) / 500.0)

        // Pitch range
        features.append(((pitches.max() ?? 0) - (pitches.min() ?? 0)) / 300.0)

        // Quartiles
        let sorted = pitches.sorted()
        features.append(sorted[sorted.count / 4] / 500.0)
        features.append(sorted[sorted.count / 2] / 500.0)
        features.append(sorted[3 * sorted.count / 4] / 500.0)

        // Pitch variation (jitter-like)
        var jitter: Float = 0
        for i in 1..<pitches.count {
            jitter += abs(pitches[i] - pitches[i-1])
        }
        features.append(jitter / Float(pitches.count) / 50.0)

        // Voiced ratio
        let voicedCount = pitches.filter { $0 > 50 && $0 < 500 }.count
        features.append(Float(voicedCount) / Float(pitches.count))

        // Pad to 12 features
        while features.count < 12 {
            features.append(0)
        }

        return Array(features.prefix(12))
    }

    /// Extract energy-related features
    private func extractEnergyFeatures(_ samples: [Float]) -> [Float] {
        var features: [Float] = []

        // Frame-level energy
        let frameSize = 400  // 25ms at 16kHz
        let frameStep = 160  // 10ms
        var frameEnergies: [Float] = []

        var idx = 0
        while idx + frameSize <= samples.count {
            let frame = Array(samples[idx..<(idx + frameSize)])
            var energy: Float = 0
            vDSP_svesq(frame, 1, &energy, vDSP_Length(frame.count))
            frameEnergies.append(log(max(energy, 1e-10)))
            idx += frameStep
        }

        guard !frameEnergies.isEmpty else {
            return [Float](repeating: 0, count: 12)
        }

        // Energy statistics
        let mean = frameEnergies.reduce(0, +) / Float(frameEnergies.count)
        features.append(mean / 10.0)  // Normalize

        let variance = frameEnergies.map { pow($0 - mean, 2) }.reduce(0, +) / Float(frameEnergies.count)
        features.append(sqrt(variance) / 5.0)

        features.append((frameEnergies.min() ?? 0) / 10.0)
        features.append((frameEnergies.max() ?? 0) / 10.0)
        features.append(((frameEnergies.max() ?? 0) - (frameEnergies.min() ?? 0)) / 10.0)

        // Energy contour features
        let sorted = frameEnergies.sorted()
        features.append(sorted[sorted.count / 4] / 10.0)
        features.append(sorted[sorted.count / 2] / 10.0)
        features.append(sorted[3 * sorted.count / 4] / 10.0)

        // Energy dynamics (shimmer-like)
        var shimmer: Float = 0
        for i in 1..<frameEnergies.count {
            shimmer += abs(frameEnergies[i] - frameEnergies[i-1])
        }
        features.append(shimmer / Float(frameEnergies.count) / 2.0)

        // Low/high energy ratio
        let threshold = mean
        let lowCount = frameEnergies.filter { $0 < threshold }.count
        features.append(Float(lowCount) / Float(frameEnergies.count))

        // Energy rise/fall ratio
        var rises = 0
        var falls = 0
        for i in 1..<frameEnergies.count {
            if frameEnergies[i] > frameEnergies[i-1] { rises += 1 }
            else { falls += 1 }
        }
        features.append(Float(rises) / Float(max(falls, 1)))

        // Pad to 12
        while features.count < 12 {
            features.append(0)
        }

        return Array(features.prefix(12))
    }

    /// Extract temporal/rhythm features
    private func extractTemporalFeatures(_ samples: [Float], sampleRate: Double) -> [Float] {
        var features: [Float] = []

        // Zero crossing rate statistics
        var zcrValues: [Float] = []
        let frameSize = 400
        let frameStep = 160

        var idx = 0
        while idx + frameSize <= samples.count {
            let frame = Array(samples[idx..<(idx + frameSize)])
            var crossings = 0
            for i in 1..<frame.count {
                if (frame[i] >= 0 && frame[i-1] < 0) || (frame[i] < 0 && frame[i-1] >= 0) {
                    crossings += 1
                }
            }
            zcrValues.append(Float(crossings) / Float(frame.count))
            idx += frameStep
        }

        guard !zcrValues.isEmpty else {
            return [Float](repeating: 0, count: 8)
        }

        // ZCR statistics
        let mean = zcrValues.reduce(0, +) / Float(zcrValues.count)
        features.append(mean * 10.0)

        let variance = zcrValues.map { pow($0 - mean, 2) }.reduce(0, +) / Float(zcrValues.count)
        features.append(sqrt(variance) * 10.0)

        // Speaking rate indicator (based on energy modulation)
        var energies: [Float] = []
        idx = 0
        while idx + frameSize <= samples.count {
            let frame = Array(samples[idx..<(idx + frameSize)])
            var energy: Float = 0
            vDSP_svesq(frame, 1, &energy, vDSP_Length(frame.count))
            energies.append(energy)
            idx += frameStep
        }

        // Count energy peaks (syllable-like)
        var peakCount = 0
        let energyThreshold = energies.reduce(0, +) / Float(energies.count) * 1.5
        for i in 1..<(energies.count - 1) {
            if energies[i] > energyThreshold &&
               energies[i] > energies[i-1] &&
               energies[i] > energies[i+1] {
                peakCount += 1
            }
        }
        let duration = Float(samples.count) / Float(sampleRate)
        features.append(Float(peakCount) / duration)  // Peaks per second

        // Pause detection (low energy regions)
        var pauseFrames = 0
        let pauseThreshold = energies.reduce(0, +) / Float(energies.count) * 0.1
        for energy in energies {
            if energy < pauseThreshold {
                pauseFrames += 1
            }
        }
        features.append(Float(pauseFrames) / Float(energies.count))

        // Rhythm regularity (variance of inter-peak intervals)
        var peakIndices: [Int] = []
        for i in 1..<(energies.count - 1) {
            if energies[i] > energyThreshold &&
               energies[i] > energies[i-1] &&
               energies[i] > energies[i+1] {
                peakIndices.append(i)
            }
        }

        if peakIndices.count > 1 {
            var intervals: [Float] = []
            for i in 1..<peakIndices.count {
                intervals.append(Float(peakIndices[i] - peakIndices[i-1]))
            }
            let meanInterval = intervals.reduce(0, +) / Float(intervals.count)
            let intervalVariance = intervals.map { pow($0 - meanInterval, 2) }.reduce(0, +) / Float(intervals.count)
            features.append(meanInterval / 10.0)
            features.append(sqrt(intervalVariance) / 5.0)
        } else {
            features.append(0)
            features.append(0)
        }

        // Duration normalized
        features.append(min(1.0, duration / 3.0))

        // Pad to 8
        while features.count < 8 {
            features.append(0)
        }

        return Array(features.prefix(8))
    }

    // MARK: - Helper Methods

    /// Compute magnitude spectrum using FFT
    private func computeMagnitudeSpectrum(_ frame: [Float]) -> [Float] {
        // Pad to FFT size
        var paddedFrame = frame
        if paddedFrame.count < fftSize {
            paddedFrame.append(contentsOf: [Float](repeating: 0, count: fftSize - paddedFrame.count))
        }

        // Apply Hanning window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(paddedFrame, 1, window, 1, &paddedFrame, 1, vDSP_Length(fftSize))

        // Compute FFT (simplified - using squared magnitudes)
        var squared = [Float](repeating: 0, count: fftSize)
        vDSP_vsq(paddedFrame, 1, &squared, 1, vDSP_Length(fftSize))

        // Return first half (positive frequencies)
        let numBins = fftSize / 2 + 1
        return Array(squared.prefix(numBins))
    }

    /// Apply mel filterbank to spectrum
    private func applyMelFilterbank(_ spectrum: [Float]) -> [Float] {
        var melEnergies = [Float](repeating: 0, count: numMelBins)

        for (binIdx, filter) in melFilterbank.enumerated() {
            var energy: Float = 0
            let minLen = min(filter.count, spectrum.count)
            for i in 0..<minLen {
                energy += filter[i] * spectrum[i]
            }
            melEnergies[binIdx] = log(max(energy, 1e-10))
        }

        return melEnergies
    }

    /// Compute mel filterbank weights
    private func computeMelFilterbank() -> [[Float]] {
        let sampleRate: Float = 16000
        let numBins = fftSize / 2 + 1
        let melLow: Float = 0
        let melHigh = 2595 * log10(1 + sampleRate / 2 / 700)

        // Mel center frequencies
        var melCenters = [Float]()
        for i in 0...(numMelBins + 1) {
            let mel = melLow + Float(i) * (melHigh - melLow) / Float(numMelBins + 1)
            let hz = 700 * (pow(10, mel / 2595) - 1)
            melCenters.append(hz)
        }

        // Convert to FFT bin indices
        let binFreqs = melCenters.map { Int($0 / sampleRate * Float(fftSize)) }

        // Create triangular filters
        var filterbank: [[Float]] = []
        for i in 0..<numMelBins {
            var filter = [Float](repeating: 0, count: numBins)

            let left = binFreqs[i]
            let center = binFreqs[i + 1]
            let right = binFreqs[i + 2]

            // Rising slope
            for j in left..<center where j < numBins {
                filter[j] = Float(j - left) / Float(max(center - left, 1))
            }

            // Falling slope
            for j in center..<right where j < numBins {
                filter[j] = Float(right - j) / Float(max(right - center, 1))
            }

            filterbank.append(filter)
        }

        return filterbank
    }

    /// Estimate pitch using autocorrelation
    private func estimatePitch(_ samples: [Float], sampleRate: Double) -> [Float] {
        let frameSize = 800  // 50ms
        let frameStep = 400  // 25ms
        let minPeriod = Int(sampleRate / 500)  // 500 Hz max
        let maxPeriod = Int(sampleRate / 50)   // 50 Hz min

        var pitches: [Float] = []

        var idx = 0
        while idx + frameSize <= samples.count {
            let frame = Array(samples[idx..<(idx + frameSize)])

            // Compute autocorrelation
            var maxCorr: Float = 0
            var bestPeriod = 0

            for period in minPeriod..<min(maxPeriod, frame.count / 2) {
                var corr: Float = 0
                for i in 0..<(frame.count - period) {
                    corr += frame[i] * frame[i + period]
                }

                if corr > maxCorr {
                    maxCorr = corr
                    bestPeriod = period
                }
            }

            if bestPeriod > 0 && maxCorr > 0.3 {
                let pitch = Float(sampleRate) / Float(bestPeriod)
                if pitch > 50 && pitch < 500 {
                    pitches.append(pitch)
                }
            }

            idx += frameStep
        }

        return pitches
    }

    /// L2 normalize a vector
    private func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumOfSquares)

        guard norm > 1e-10 else { return vector }

        var normalized = [Float](repeating: 0, count: vector.count)
        var normVal = norm
        vDSP_vsdiv(vector, 1, &normVal, &normalized, 1, vDSP_Length(vector.count))

        return normalized
    }
}

// MARK: - Factory

/// Factory for creating speaker embedding extractors
public enum SpeakerEmbeddingFactory {
    /// Create the default acoustic-based extractor
    public static func createDefault() -> SpeakerEmbeddingProtocol {
        return AcousticSpeakerEmbedding()
    }
}
