import Foundation

/// Short keyboard contacts need a transient measure rather than programme LUFS.
/// The ITU-R BS.1770 48 kHz K-weighting filters are used only for measurement;
/// the audible samples remain untouched. This is not a certified LUFS meter.
/// Coefficients: https://www.itu.int/rec/R-REC-BS.1770
enum KeyboardLoudness {
    struct Measurement: Sendable {
        let energy: Double
        let peak: Double
        var transientRMS: Double = 0
    }

    struct Profile: Sendable {
        let measuredRMS: Double
        let sourcePeak: Double
        let gain: Float
    }

    // Fixed units make existing presets independent of future additions.
    static let targetRMS = 0.015
    static let maximumGain = 4.0
    static let peakHeadroom = 0.90

    /// 64% ordinary typing and 36% large/control keys, without language-specific
    /// key frequencies. Each physical key and every variant retain their level.
    static let calibrationKeys: [(key: UInt16, weight: Double)] = {
        let ordinary: [UInt16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16,
                                 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30,
                                 31, 32, 33, 34, 35, 37, 38, 40, 41, 43, 45, 46, 47]
        return ordinary.map { ($0, 0.64 / Double(ordinary.count)) }
            + [(49, 0.12), (36, 0.08), (51, 0.08), (48, 0.04), (56, 0.04)]
    }()

    private struct Filter {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        mutating func apply(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
        static var shelf: Self { Self(b0: 1.53512485958697, b1: -2.69169618940638,
            b2: 1.19839281085285, a1: -1.69065929318241, a2: 0.73248077421585) }
        static var highpass: Self { Self(b0: 1, b1: -2, b2: 1,
            a1: -1.99004745483398, a2: 0.99007225036621) }
    }

    /// Whole-contact energy prevents a long ring/sweep being boosted like a
    /// very short click. Peak 50 ms energy separately measures the transient.
    /// Fixed windows include silence, so trimming or padding a file cannot
    /// accidentally change its calibration. Startup/tooling only.
    static func measure(samples: UnsafePointer<Float>, frames: Int, channels: Int) -> Measurement {
        guard frames > 0, channels == 1 || channels == 2 else { return Measurement(energy: 0, peak: 0) }
        var shelves = [Filter.shelf, Filter.shelf], highpasses = [Filter.highpass, Filter.highpass]
        let window = 2_400
        var ring = [Double](repeating: 0, count: window)
        var sum = 0.0, maximum = 0.0, total = 0.0, peak = 0.0
        for frame in 0..<(frames + window) {
            var power = 0.0
            for channel in 0..<channels {
                let x = frame < frames ? Double(samples[frame * channels + channel]) : 0
                guard x.isFinite else { return Measurement(energy: 0, peak: 0) }
                peak = max(peak, abs(x))
                let weighted = highpasses[channel].apply(shelves[channel].apply(x))
                power += weighted * weighted / Double(channels)
            }
            sum += power - ring[frame % window]
            ring[frame % window] = power
            maximum = max(maximum, sum)
            total += power
        }
        return Measurement(energy: total / 9_600, peak: peak, transientRMS: sqrt(maximum / Double(window)))
    }

    static func profile(energy: Double, peak: Double) -> Profile {
        guard energy.isFinite, energy > 1e-16, peak.isFinite, peak > 1e-8 else {
            return Profile(measuredRMS: 0, sourcePeak: 0, gain: 1)
        }
        let rms = sqrt(energy)
        let gain = min(maximumGain, targetRMS / rms, peakHeadroom / peak)
        return Profile(measuredRMS: rms, sourcePeak: peak, gain: Float(max(0.05, gain)))
    }
}
