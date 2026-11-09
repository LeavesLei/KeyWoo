import Foundation

/// Normalized energies used by the renderer. No audio samples are retained here.
struct AudioSpectrum: Equatable, Sendable {
    let low: Double
    let mid: Double
    let high: Double
    let level: Double
    let beat: Double
    let contour: AudioContour?
    static let silent = AudioSpectrum(low: 0, mid: 0, high: 0, level: 0)

    init(low: Double, mid: Double, high: Double, level: Double, beat: Double = 0, contour: AudioContour? = nil) {
        func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        self.low = bounded(low)
        self.mid = bounded(mid)
        self.high = bounded(high)
        self.level = bounded(level)
        self.beat = bounded(beat)
        self.contour = contour
    }

    func scaled(by gain: Double) -> AudioSpectrum {
        AudioSpectrum(low: low * gain, mid: mid * gain, high: high * gain, level: level * gain,
                      beat: beat * gain, contour: contour?.scaled(by: gain))
    }
}

/// Three crossover bands track bass, body and treble with attack/release smoothing.
struct AudioSpectrumAnalyzer {
    private var dc = 0.0
    private var bass = 0.0
    private var body = 0.0
    private var lowPower = 0.0
    private var midPower = 0.0
    private var highPower = 0.0
    private var totalPower = 0.0
    private var rate = 0.0
    private var averageBass = 0.0
    private var averageLevel = 0.0
    private var smoothed = AudioSpectrum.silent

    mutating func process(_ samples: [Float], sampleRate: Double) -> AudioSpectrum {
        guard sampleRate.isFinite, sampleRate >= 8_000, !samples.isEmpty else { return .silent }
        if rate != sampleRate {
            self = AudioSpectrumAnalyzer()
            rate = sampleRate
        }
        let dcWeight = 1 - exp(-2 * .pi * 30 / sampleRate)
        let bassWeight = 1 - exp(-2 * .pi * 220 / sampleRate)
        let bodyWeight = 1 - exp(-2 * .pi * 2_200 / sampleRate)
        // Keep energy history across small capture blocks. Bass cycles must not
        // turn into false beats merely because a callback ends mid-cycle.
        let lowPowerWeight = 1 - exp(-1 / (sampleRate * 0.018))
        let midPowerWeight = 1 - exp(-1 / (sampleRate * 0.010))
        let highPowerWeight = 1 - exp(-1 / (sampleRate * 0.006))
        let totalPowerWeight = 1 - exp(-1 / (sampleRate * 0.008))
        for sample in samples {
            let input = sample.isFinite ? min(8, max(-8, Double(sample))) : 0
            dc += dcWeight * (input - dc)
            let signal = input - dc
            bass += bassWeight * (signal - bass)
            body += bodyWeight * (signal - body)
            let middle = body - bass
            let treble = signal - body
            lowPower += lowPowerWeight * (bass * bass - lowPower)
            midPower += midPowerWeight * (middle * middle - midPower)
            highPower += highPowerWeight * (treble * treble - highPower)
            totalPower += totalPowerWeight * (signal * signal - totalPower)
        }
        let count = Double(samples.count)
        func level(_ power: Double) -> Double {
            let db = 10 * log10(max(1e-12, power))
            // Preserve quiet detail, then leave headroom all the way to 0 dB.
            // The short quadratic knee joins both positive slopes smoothly;
            // louder music no longer flattens all bands at the old -14 dB cap.
            let value: Double
            if db <= -30.4 { value = (db + 62) / 48 }
            else if db >= -26.4 { value = 0.70 + (db + 28.4) * (0.30 / 28.4) }
            else {
                let delta = db + 30.4
                value = (31.6 / 48) + delta / 48 + (0.30 / 28.4 - 1.0 / 48) * delta * delta / 8
            }
            return min(1, max(0, value))
        }
        func onsetLevel(_ power: Double) -> Double {
            // Beat novelty has its own uncapped scale. Visual headroom must not
            // make a kick less responsive or hide a rise in already-loud music.
            max(0, (10 * log10(max(1e-12, power)) + 62) / 48)
        }
        let duration = count / sampleRate
        func follow(_ current: Double, _ target: Double, attack: Double = 0.012, release: Double = 0.18) -> Double {
            let weight = 1 - exp(-duration / (target > current ? attack : release))
            let value = current + weight * (target - current)
            return value < 0.0005 ? 0 : value
        }
        let bassLevel = level(lowPower)
        let totalLevel = level(totalPower)
        // An onset is a rise above the recent music, rather than simply loud
        // playback. Constant tones settle, while a new kick can lift the light.
        let bassOnset = onsetLevel(lowPower)
        let totalOnset = onsetLevel(totalPower)
        let novelty = max(bassOnset - averageBass, (totalOnset - averageLevel) * 0.8)
        let beat = min(1, max(0, (novelty - 0.025) * 8))
        let averageWeight = 1 - exp(-duration / 0.35)
        averageBass += averageWeight * (bassOnset - averageBass)
        averageLevel += averageWeight * (totalOnset - averageLevel)
        smoothed = AudioSpectrum(
            low: follow(smoothed.low, bassLevel),
            mid: follow(smoothed.mid, level(midPower)),
            high: follow(smoothed.high, level(highPower)),
            level: follow(smoothed.level, totalLevel),
            beat: follow(smoothed.beat, beat, attack: 0.005, release: 0.13))
        return smoothed
    }
}

/// Interpolates capture blocks on the display clock, including frames that have
/// no new audio callback. This avoids turning a clear beat into a stepped jump.
struct AudioSpectrumMotion {
    private(set) var value = AudioSpectrum.silent
    private var contourMotion = AudioContourMotion()

    mutating func advance(towards target: AudioSpectrum, elapsed: TimeInterval) -> AudioSpectrum {
        let duration = elapsed.isFinite ? min(0.1, max(0, elapsed)) : 0
        func follow(_ current: Double, _ next: Double, attack: Double = 0.008, release: Double = 0.075) -> Double {
            let weight = 1 - exp(-duration / (next > current ? attack : release))
            let result = current + (next - current) * weight
            return result < 0.0005 ? 0 : result
        }
        let contour = contourMotion.advance(towards: target, elapsed: elapsed)
        let next = AudioSpectrum(low: follow(value.low, target.low), mid: follow(value.mid, target.mid),
                                 high: follow(value.high, target.high), level: follow(value.level, target.level),
                                 beat: follow(value.beat, target.beat, attack: 0.004, release: 0.055))
        value = next == .silent && contour == .silent ? .silent
            : AudioSpectrum(low: next.low, mid: next.mid, high: next.high, level: next.level,
                            beat: next.beat, contour: contour)
        return value
    }
}

/// Geometry has its own response. `beat` is the perceptual beat drive (the power
/// curve is applied before smoothing), so the painter must not exponentiate it
/// again. Fast spectrum values remain available for immediate colored light.
struct AudioContour: Equatable, Sendable {
    let low: Double
    let mid: Double
    let high: Double
    let level: Double
    let beat: Double
    static let silent = AudioContour(low: 0, mid: 0, high: 0, level: 0, beat: 0)

    init(low: Double, mid: Double, high: Double, level: Double, beat: Double) {
        func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
        self.low = bounded(low); self.mid = bounded(mid); self.high = bounded(high)
        self.level = bounded(level); self.beat = bounded(beat)
    }

    func scaled(by gain: Double) -> AudioContour {
        AudioContour(low: low * gain, mid: mid * gain, high: high * gain, level: level * gain, beat: beat * gain)
    }
}

private struct ContourChannel {
    private(set) var position = 0.0
    private var velocity = 0.0

    mutating func advance(to target: Double, duration: Double, beat: Bool = false) -> Double {
        guard duration > 0 else { return position }
        let steps = max(1, Int(ceil(duration * 240)))
        let step = duration / Double(steps)
        let speedLimit = beat ? 4.3 : 1.8
        let accelerationLimit = beat ? 48.0 : 18.0
        for _ in 0..<steps {
            let response = target > position ? (beat ? 0.045 : 0.090) : (beat ? 0.100 : 0.200)
            let omega = 2 / response
            let force = omega * omega * (target - position) - 2 * omega * velocity
            let acceleration = min(accelerationLimit, max(-accelerationLimit, force))
            velocity = min(speedLimit, max(-speedLimit, velocity + acceleration * step))
            position += velocity * step
            if position < 0 { position = 0; velocity = max(0, velocity) }
            if position > 1 { position = 1; velocity = min(0, velocity) }
        }
        if target == 0 && position < 0.0005 && abs(velocity) < 0.003 {
            position = 0; velocity = 0
        }
        return position
    }
}

private struct AudioContourMotion {
    private var low = ContourChannel()
    private var mid = ContourChannel()
    private var high = ContourChannel()
    private var level = ContourChannel()
    private var beat = ContourChannel()

    mutating func advance(towards target: AudioSpectrum, elapsed: TimeInterval) -> AudioContour {
        // A stalled main loop must not replay a large jump on its first frame.
        let duration = elapsed.isFinite ? min(1.0 / 60, max(0, elapsed)) : 0
        let perceptualBeat = pow(target.beat, 0.70)
        // Preserve small musical accents after smoothing without increasing the
        // strongest pulse or speeding up its shape response.
        let shapedBeat = perceptualBeat * (1.7 - 0.7 * perceptualBeat)
        return AudioContour(low: low.advance(to: target.low, duration: duration),
                            mid: mid.advance(to: target.mid, duration: duration),
                            high: high.advance(to: target.high, duration: duration),
                            level: level.advance(to: target.level, duration: duration),
                            beat: beat.advance(to: shapedBeat, duration: duration, beat: true))
    }
}

/// A bounded mailbox bridges the serial audio queue and a presentation timer.
final class AudioSpectrumProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer = AudioSpectrumAnalyzer()
    private var spectrum = AudioSpectrum.silent
    private var lastUpdate: TimeInterval?

    func receive(_ samples: [Float], sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        spectrum = analyzer.process(samples, sampleRate: sampleRate)
        lastUpdate = ProcessInfo.processInfo.systemUptime
    }

    func snapshot(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> AudioSpectrum {
        lock.lock()
        defer { lock.unlock() }
        guard let lastUpdate else { return .silent }
        let gain = exp(-max(0, time - lastUpdate - 0.12) / 0.32)
        return gain < 0.0005 ? .silent : spectrum.scaled(by: gain)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        analyzer = AudioSpectrumAnalyzer()
        spectrum = .silent
        lastUpdate = nil
    }
}
