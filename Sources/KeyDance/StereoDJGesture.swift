import Foundation

/// A short stereo tape gesture, fed only by the existing music. Storage is
/// allocated once. The audio callback never allocates, clears the whole delay,
/// waits, or invents a sample. Both channels share the exact read position.
final class StereoDJGesture {
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private let capacity: Int, rate: Double, baseline: Double
    private let positionStep: Double, heldOpeningStep: Double
    private var wetStep: Double, heldClosingStep: Double
    private var cachedDecay = 0.5, heldOpening = 0.0
    private var write = 0, valid = 0
    private var action = DJAction.none
    private var elapsed = 1.0, duration = 0.24, strength = 0.0
    private var initialOffset = 0.0, excursion = 0.0, offset = 0.0, wet = 0.0
    private(set) var brightness = 0.0
    private(set) var activity = 0.0
    private(set) var maximumObservedSlew = 0.0

    init(sampleRate: Double) {
        rate = max(8_000, sampleRate)
        capacity = Int(ceil(rate * 0.08)) + 4
        baseline = rate * 0.018
        positionStep = 1 - exp(-1 / (rate * 0.006))
        wetStep = 1 - exp(-1 / (rate * 0.025))
        heldOpeningStep = 1 - exp(-1 / (rate * 0.020))
        heldClosingStep = 1 - exp(-1 / (rate * 0.090))
        left = .allocate(capacity: capacity); right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity); right.initialize(repeating: 0, count: capacity)
    }
    deinit { left.deallocate(); right.deallocate() }

    func setDecay(_ value: Double) {
        let value = min(1, max(0, value))
        guard value != cachedDecay else { return }
        cachedDecay = value
        wetStep = 1 - exp(-1 / (rate * (0.015 + value * 0.020)))
        heldClosingStep = 1 - exp(-1 / (rate * (0.030 + value * 0.120)))
    }

    func trigger(action: DJAction, duration: Double, strength: Double, gentle: Bool) {
        guard action != .none, strength > 0 else { return }
        let value = min(1, max(0, strength)) * (gentle ? 0.55 : 1)
        // A flurry of the same gesture merges its tape trajectory. Every press
        // still has its own immediate, smaller whole-song amplitude contour.
        if self.action == action && elapsed < self.duration * 0.55 {
            self.strength = max(self.strength, value)
            return
        }
        self.action = action; self.duration = min(0.46, max(0.14, duration))
        self.strength = value; elapsed = 0; initialOffset = offset
        // sin² trajectories have a bounded maximum derivative. At full depth
        // the nominal push/pull peak slope is about 3% / 4%; usual controls and
        // fast-event attenuation make it shallower. No reverse playback occurs.
        let seconds: Double
        switch action {
        case .push: seconds = -min(0.005, self.duration * 0.010) * value
        case .pull: seconds = min(0.007, self.duration * 0.013) * value
        default: seconds = 0
        }
        excursion = seconds * rate
    }
    func reset() {
        // Invalidate old samples instead of reallocating/zeroing an audio buffer.
        write = 0; valid = 0; action = .none; elapsed = 1; duration = 0.24
        strength = 0; initialOffset = 0; excursion = 0; offset = 0; wet = 0
        brightness = 0; activity = 0; heldOpening = 0; maximumObservedSlew = 0
    }
    func process(left inputL: Float, right inputR: Float, depth: Double, held: Bool) -> (Float, Float) {
        left[write] = inputL; right[write] = inputR
        valid = min(capacity, valid + 1)
        let active = elapsed < duration
        let phase = active ? elapsed / duration : 1
        let sine = active ? sin(.pi * phase) : 0
        let envelope = sine * sine
        let returning = active ? 0.5 + 0.5 * cos(.pi * phase) : 0
        let target = initialOffset * returning + excursion * envelope
        let previous = offset
        offset += (target - offset) * positionStep
        // Limit even an opposite-action retrigger; the read head always moves
        // forwards, within ±4% of normal playback speed.
        offset = previous + min(0.04, max(-0.04, offset - previous))
        maximumObservedSlew = max(maximumObservedSlew, abs(offset - previous))
        elapsed = min(duration, elapsed + 1 / rate)
        if phase == 1 && abs(offset) < 1e-8 { offset = 0; initialOffset = 0 }
        switch active ? action : .none {
        case .push: brightness = 0.18 * envelope * strength
        case .pull: brightness = -0.30 * envelope * strength
        case .sweep: brightness = -0.85 * sin(2 * .pi * phase) * strength
        case .lift: brightness = 0.65 * sine * strength
        case .none, .hold: brightness = 0
        }
        heldOpening += ((held ? 1.0 : 0.0) - heldOpening) * (held ? heldOpeningStep : heldClosingStep)
        if !held && heldOpening < 1e-8 { heldOpening = 0 }
        if heldOpening > 0 { brightness = max(brightness, heldOpening * 0.35) }
        activity = max(envelope * strength, heldOpening * max(0.4, strength))
        let enabled = depth > 0
        let delay = min(Double(capacity - 2), max(1, baseline + offset))
        let ready = valid > Int(ceil(delay)) + 1
        let hasTapeGesture = action == .push || action == .pull
        let targetWet = enabled && ready && hasTapeGesture ? envelope * strength * 0.45 : 0
        wet += (targetWet - wet) * wetStep
        if targetWet == 0 && wet < 1e-8 { wet = 0 }
        var result = (inputL, inputR)
        if enabled && ready && wet > 0 {
            var read = Double(write) - delay
            if read < 0 { read += Double(capacity) }
            let a = Int(read), b = (a + 1) % capacity, fraction = Float(read - Double(a))
            let l = left[a] + (left[b] - left[a]) * fraction
            let r = right[a] + (right[b] - right[a]) * fraction
            result = (inputL + (l - inputL) * Float(wet), inputR + (r - inputR) * Float(wet))
        }
        write = (write + 1) % capacity
        return result // depth zero is bit-identical, not an almost-dry blend.
    }
}
