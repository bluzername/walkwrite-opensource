import Foundation
import Accelerate

/// Energy-based Voice Activity Detection
///
/// Uses a combination of:
/// - RMS (Root Mean Square) energy
/// - Zero-crossing rate
/// - Spectral flatness approximation
///
/// This provides a reasonable VAD without requiring ML models.
/// Can be replaced with Silero VAD for better accuracy.
public final class EnergyBasedVAD: VADProtocol, @unchecked Sendable {

    // MARK: - Properties

    public private(set) var configuration: VADConfiguration
    private let lock = NSLock()

    // Adaptive threshold tracking
    private var noiseFloor: Float = 0.001
    private var signalPeak: Float = 0.1
    private var adaptationRate: Float = 0.01

    // Smoothing for speech probability
    private var smoothedProbability: Float = 0.0
    private let smoothingFactor: Float = 0.7

    // Constants
    private let sampleRate: Float = 16000.0
    private let minNoiseFloor: Float = 0.0001
    private let maxNoiseFloor: Float = 0.05

    // MARK: - Initialization

    public init(configuration: VADConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - VADProtocol

    public func processSamples(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }

        // Calculate features
        let rmsEnergy = calculateRMS(samples)
        let zeroCrossingRate = calculateZeroCrossingRate(samples)
        let spectralFlatness = calculateSpectralFlatness(samples)

        // Update adaptive thresholds
        updateAdaptiveThresholds(rmsEnergy: rmsEnergy)

        // Calculate individual probabilities
        let energyProb = calculateEnergyProbability(rmsEnergy)
        let zcrProb = calculateZCRProbability(zeroCrossingRate)
        let spectralProb = calculateSpectralProbability(spectralFlatness)

        // Combine probabilities with weights
        // Energy is most important, ZCR helps distinguish speech from noise
        let combinedProb = energyProb * 0.6 + zcrProb * 0.25 + spectralProb * 0.15

        // Apply smoothing to reduce rapid fluctuations
        lock.lock()
        smoothedProbability = smoothingFactor * smoothedProbability + (1.0 - smoothingFactor) * combinedProb
        let result = smoothedProbability
        lock.unlock()

        return result
    }

    public func processFrame(_ samples: [Float], timestamp: TimeInterval) -> VADFrame {
        let probability = processSamples(samples)
        let isSpeech = probability >= configuration.speechThreshold
        let duration = TimeInterval(samples.count) / TimeInterval(sampleRate)

        return VADFrame(
            speechProbability: probability,
            isSpeech: isSpeech,
            timestamp: timestamp,
            duration: duration
        )
    }

    public func reset() {
        lock.lock()
        noiseFloor = 0.001
        signalPeak = 0.1
        smoothedProbability = 0.0
        lock.unlock()
    }

    public func updateConfiguration(_ config: VADConfiguration) {
        lock.lock()
        configuration = config
        lock.unlock()
    }

    // MARK: - Feature Extraction

    /// Calculate Root Mean Square energy
    private func calculateRMS(_ samples: [Float]) -> Float {
        var sumOfSquares: Float = 0
        vDSP_svesq(samples, 1, &sumOfSquares, vDSP_Length(samples.count))
        let meanSquare = sumOfSquares / Float(samples.count)
        return sqrt(meanSquare)
    }

    /// Calculate Zero-Crossing Rate
    /// Speech typically has ZCR between 0.02-0.2, noise tends to be higher or lower
    private func calculateZeroCrossingRate(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0.0 }

        var crossings: Int = 0
        for i in 1..<samples.count {
            if (samples[i] >= 0 && samples[i-1] < 0) ||
               (samples[i] < 0 && samples[i-1] >= 0) {
                crossings += 1
            }
        }

        // Normalize by number of samples to get rate
        return Float(crossings) / Float(samples.count - 1)
    }

    /// Calculate spectral flatness approximation
    /// Uses a simplified approach based on sample variance distribution
    /// Speech has more tonal content (less flat), noise is more flat
    private func calculateSpectralFlatness(_ samples: [Float]) -> Float {
        guard samples.count >= 16 else { return 0.5 }

        // Split into small segments and calculate energy variation
        let segmentSize = 16
        let numSegments = samples.count / segmentSize
        guard numSegments > 1 else { return 0.5 }

        var segmentEnergies: [Float] = []
        segmentEnergies.reserveCapacity(numSegments)

        for i in 0..<numSegments {
            let start = i * segmentSize
            let end = min(start + segmentSize, samples.count)
            let segment = Array(samples[start..<end])
            var energy: Float = 0
            vDSP_svesq(segment, 1, &energy, vDSP_Length(segment.count))
            segmentEnergies.append(energy / Float(segment.count))
        }

        // Calculate geometric and arithmetic means
        let arithmeticMean = segmentEnergies.reduce(0, +) / Float(segmentEnergies.count)

        // For geometric mean, use log-sum-exp for numerical stability
        let logEnergies = segmentEnergies.map { log(max($0, 1e-10)) }
        let logGeometricMean = logEnergies.reduce(0, +) / Float(logEnergies.count)
        let geometricMean = exp(logGeometricMean)

        // Spectral flatness = geometric mean / arithmetic mean
        // Close to 1 = flat (noise-like), close to 0 = tonal (speech-like)
        guard arithmeticMean > 1e-10 else { return 0.5 }
        return min(1.0, geometricMean / arithmeticMean)
    }

    // MARK: - Adaptive Thresholds

    private func updateAdaptiveThresholds(rmsEnergy: Float) {
        lock.lock()
        defer { lock.unlock() }

        // Slow adaptation for noise floor (only update during silence)
        if rmsEnergy < noiseFloor * 2.0 {
            noiseFloor = noiseFloor * (1.0 - adaptationRate) + rmsEnergy * adaptationRate
            noiseFloor = max(minNoiseFloor, min(maxNoiseFloor, noiseFloor))
        }

        // Track signal peaks
        if rmsEnergy > signalPeak {
            signalPeak = rmsEnergy
        } else {
            // Slow decay of peak
            signalPeak = signalPeak * 0.9995
        }
    }

    // MARK: - Probability Calculations

    /// Calculate speech probability based on energy
    private func calculateEnergyProbability(_ rmsEnergy: Float) -> Float {
        lock.lock()
        let currentNoiseFloor = noiseFloor
        let currentSignalPeak = signalPeak
        lock.unlock()

        // Signal-to-noise ratio based probability
        let snr = rmsEnergy / max(currentNoiseFloor, minNoiseFloor)

        // Map SNR to probability using sigmoid-like function
        // SNR of 2 -> ~0.5 probability
        // SNR of 5 -> ~0.9 probability
        let snrDb = 20.0 * log10(max(snr, 0.001))
        let threshold = 6.0 as Float  // dB above noise floor for speech
        let slope = 0.3 as Float

        let probability = 1.0 / (1.0 + exp(-slope * (snrDb - threshold)))

        return min(1.0, max(0.0, probability))
    }

    /// Calculate speech probability based on zero-crossing rate
    private func calculateZCRProbability(_ zcr: Float) -> Float {
        // Speech typically has ZCR between 0.02-0.15
        // Silence has very low ZCR
        // High frequency noise has higher ZCR

        // Ideal speech ZCR range
        let idealMin: Float = 0.02
        let idealMax: Float = 0.15

        if zcr < idealMin {
            // Too low - likely silence or very low frequency
            return zcr / idealMin * 0.5
        } else if zcr <= idealMax {
            // In ideal range - high probability
            return 0.7 + 0.3 * (1.0 - abs(zcr - 0.08) / 0.08)
        } else {
            // Too high - likely noise
            let excess = (zcr - idealMax) / idealMax
            return max(0.0, 0.7 - excess * 0.5)
        }
    }

    /// Calculate speech probability based on spectral flatness
    private func calculateSpectralProbability(_ flatness: Float) -> Float {
        // Speech has low spectral flatness (more tonal)
        // Noise has high spectral flatness (more flat)

        // flatness < 0.3 -> likely speech
        // flatness > 0.7 -> likely noise

        if flatness < 0.3 {
            return 0.8 + 0.2 * (0.3 - flatness) / 0.3
        } else if flatness < 0.6 {
            return 0.5 + 0.3 * (0.6 - flatness) / 0.3
        } else {
            return max(0.0, 0.5 * (1.0 - flatness) / 0.4)
        }
    }
}

// MARK: - VAD Factory

/// Factory for creating VAD instances
public enum VADFactory {
    /// Create the default VAD implementation
    public static func createDefault(configuration: VADConfiguration = .default) -> VADProtocol {
        return EnergyBasedVAD(configuration: configuration)
    }

    /// Create an energy-based VAD
    public static func createEnergyBased(configuration: VADConfiguration = .default) -> EnergyBasedVAD {
        return EnergyBasedVAD(configuration: configuration)
    }
}
