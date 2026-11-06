import Foundation

/// A shared, gentle phrase level prevents a new arrangement from producing a
/// sudden volume jump. This is RMS matching, not a perceptual loudness claim.
enum MusicPhraseAudio {
    static func prepare(samples: [Float], sampleRate: Double = 48_000) throws -> PreparedMusicPhrase {
        guard !samples.isEmpty, samples.count.isMultiple(of: 2), samples.allSatisfy(\.isFinite) else {
            throw PreparedMusicPhrase.PreparationError.invalidStereoSamples
        }
        var energy = 0.0, peak = 0.0
        for sample in samples { let value = Double(sample); energy += value * value; peak = max(peak, abs(value)) }
        let rms = sqrt(energy / Double(samples.count))
        guard rms > 0.000001 else { throw PreparedMusicPhrase.PreparationError.silentAudio }
        let gain = Float(min(2, 0.60 / peak, 0.055 / rms))
        let leveled = samples.map { $0 * gain }
        return try PreparedMusicPhrase.prepare(samples: leveled, sampleRate: sampleRate)
    }
}
