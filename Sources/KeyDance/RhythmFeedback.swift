import Foundation
import Combine

enum RhythmVisualStyle: String, CaseIterable, Identifiable, Sendable {
    case energy, pulse, burst
    var id: String { rawValue }
    var title: String {
        switch self {
        case .energy: return L("能量条")
        case .pulse: return L("脉冲")
        case .burst: return L("键阵爆破")
        }
    }
}

/// The visual vocabulary follows physical keys, never the text being entered.
enum RhythmKeyKind: Equatable {
    case character, space, returnKey, delete, navigation, modifier
}

struct RhythmKeyProfile: Equatable {
    let code: UInt16
    let kind: RhythmKeyKind
    let impact: Double
    let hue: Double
    let lane: Double
    let frequency: Double

    init(code: UInt16) {
        self.code = code
        let location = Self.positions[code] ?? (Double(code % 13) / 12, 0.5)
        lane = location.0
        frequency = 2.5 + location.1 * 3.5 + Double(code % 5) * 0.29
        switch code {
        case 49: kind = .space; impact = 1; hue = 0.48
        case 36, 76: kind = .returnKey; impact = 0.74; hue = 0.75
        case 51, 117: kind = .delete; impact = 0.42; hue = 0.93
        case 48, 53, 114...116, 118...126:
            kind = .navigation; impact = 0.34; hue = 0.58
        case 54...63: kind = .modifier; impact = 0.27; hue = 0.66
        default: kind = .character; impact = 0.24; hue = 0.43 + location.0 * 0.27
        }
    }

    private static let positions: [UInt16: (Double, Double)] = {
        var result: [UInt16: (Double, Double)] = [:]
        for (rowIndex, row) in KeyLayout.rows.enumerated() {
            let width = row.reduce(0.0) { $0 + $1.width }
            var x = 0.0
            for key in row {
                result[key.code] = ((x + key.width / 2) / width, Double(rowIndex) / 4)
                x += key.width
            }
        }
        return result
    }()
}

struct RhythmPulse: Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let profile: RhythmKeyProfile
    let strength: Double
    /// The typing energy spent on this accent; fixed for its entire animation.
    let accentCharge: Double
    var lifetime: Double { profile.kind == .space ? 1.35 : 1.05 }
}

struct RhythmKeyBurst: Equatable {
    static let duration = 0.38
    let keys: [RhythmPulse]
    let strike: RhythmPulse
}

/// Bounded, clock-driven state: rendering and audio never share a timer or queue.
struct RhythmDynamics {
    static let maximumPulses = 24
    static let maximumQueuedKeys = 10
    static let settleDelay = 6.4
    static let maximumPulseLight = 1.25
    private static let keyHoldDuration = 2.2
    private static let keyFadeDuration = 0.75
    private(set) var pulses: [RhythmPulse] = []
    private(set) var queuedKeys: [RhythmPulse] = []
    private(set) var keyBurst: RhythmKeyBurst?
    private(set) var combo = 0
    private(set) var lastHit: TimeInterval?
    private var storedEnergy = 0.0
    private var sequence = 0
    private(set) var cadence = 0.0
    private var recentHits: [TimeInterval] = []
    private var motionPhase = 0.0
    private var motionSpeed = 2.1
    private var targetMotionSpeed = 2.1
    private var visualEnergyBase = 0.0
    private var storedMeterTarget = 0.0
    private var meterCarry = 0.0
    private var meterHoldDuration = 0.28
    private(set) var highEntryTime: TimeInterval?
    private var highHoldUntil: TimeInterval?
    private var highLevelCarry = 0.0
    private var storedAccentCharge = 0.0
    private var lastChargeUpdate: TimeInterval?
    private var recentCharacterHits: [TimeInterval] = []

    func energy(at time: TimeInterval) -> Double {
        guard let lastHit, time.isFinite else { return 0 }
        return storedEnergy * exp(-max(0, time - lastHit) / 0.38)
    }

    /// Only recent ordinary typing charges the next Space or Return. Keeping
    /// its own clock prevents navigation, modifiers and accents from pumping it.
    func accentCharge(at time: TimeInterval) -> Double {
        guard let lastChargeUpdate, time.isFinite else { return 0 }
        return storedAccentCharge * exp(-max(0, time - lastChargeUpdate) / 0.6)
    }

    /// A continuous low-pass envelope: subsequent keys raise the target without resetting the body.
    func visualEnergy(at time: TimeInterval) -> Double {
        guard let lastHit, time.isFinite else { return 0 }
        let dt = max(0, time - lastHit)
        let attack = exp(-dt / 0.045), release = exp(-dt / 0.38)
        return min(1, max(0, visualEnergyBase * attack + storedEnergy * 0.38 / (0.38 - 0.045) * (release - attack)))
    }

    /// A single continuous meter integrates every physical hit. Its slower
    /// release bridges words; spending accent charge never empties this meter.
    func meterEnergy(at time: TimeInterval) -> Double {
        guard let lastHit, time.isFinite else { return 0 }
        let dt = max(0, time - lastHit)
        let heldTime = min(dt, meterHoldDuration)
        let heldValue = storedMeterTarget + (meterCarry - storedMeterTarget) * exp(-heldTime / 0.10)
        guard dt > meterHoldDuration else { return min(1, max(0, heldValue)) }
        let tail = dt - meterHoldDuration
        let attack = exp(-tail / 0.10), release = exp(-tail / 0.85)
        return min(1, max(0, heldValue * attack + storedMeterTarget * 0.85 / (0.85 - 0.10) * (release - attack)))
    }

    private func meterTarget(at time: TimeInterval) -> Double {
        guard let lastHit else { return 0 }
        return storedMeterTarget * exp(-max(0, time - lastHit - meterHoldDuration) / 0.85)
    }

    func isHighEnergy(at time: TimeInterval) -> Bool {
        guard time.isFinite, let highEntryTime, let highHoldUntil else { return false }
        return time >= highEntryTime && time <= highHoldUntil
    }

    /// The visual emphasis fades independently of the logical high-energy flag,
    /// so reaching full energy or letting its hold expire never causes a flash jump.
    func highEnergyLevel(at time: TimeInterval) -> Double {
        guard time.isFinite, highEntryTime != nil, let lastHit, let highHoldUntil else { return 0 }
        let dt = max(0, time - lastHit)
        let remainingHold = max(0, highHoldUntil - lastHit)
        let heldTime = min(dt, remainingHold)
        let heldLevel = 1 - (1 - highLevelCarry) * exp(-heldTime / 0.18)
        return min(1, max(0, heldLevel * exp(-max(0, dt - remainingHold) / 0.5)))
    }

    func phase(at time: TimeInterval) -> Double {
        guard let lastHit, time.isFinite else { return 0 }
        let dt = min(60, max(0, time - lastHit))
        return motionPhase + targetMotionSpeed * dt + (motionSpeed - targetMotionSpeed) * 0.2 * (1 - exp(-dt / 0.2))
    }

    private func speed(at time: TimeInterval) -> Double {
        guard let lastHit else { return motionSpeed }
        return targetMotionSpeed + (motionSpeed - targetMotionSpeed) * exp(-max(0, time - lastHit) / 0.2)
    }

    func pulseOpacityScale(at time: TimeInterval) -> Double {
        let light = pulses.reduce(0.0) { total, pulse in
            let age = max(0, time - pulse.time)
            let envelope = pow(max(0, 1 - age / pulse.lifetime), 2) * min(1, age / 0.025)
            return total + envelope * pulse.strength
        }
        return min(1, Self.maximumPulseLight / max(0.001, light))
    }

    func queueOpacity(at time: TimeInterval) -> Double {
        guard let lastKey = queuedKeys.last else { return 0 }
        return Self.keyOpacity(lastKey, at: time)
    }

    static func keyOpacity(_ key: RhythmPulse, at time: TimeInterval) -> Double {
        guard time.isFinite else { return 0 }
        let fade = max(0, time - key.time - keyHoldDuration) / keyFadeDuration
        let progress = min(1, fade)
        return 1 - progress * progress * (3 - 2 * progress)
    }

    mutating func receiveKey(_ code: UInt16, at time: TimeInterval, tracksKeyQueue: Bool = false) {
        guard time.isFinite else { return }
        let time = max(lastHit ?? time, time)
        let profile = RhythmKeyProfile(code: code)
        let isAccent = profile.kind == .space || profile.kind == .returnKey
        var spentCharge = 0.0
        if profile.kind == .character {
            recentCharacterHits.removeAll { time - $0 > 0.6 }
            let characterCadence = min(1, Double(recentCharacterHits.count) / 6)
            storedAccentCharge = min(1, accentCharge(at: time) + 0.08 + characterCadence * 0.16)
            lastChargeUpdate = time
            recentCharacterHits.append(time)
            if recentCharacterHits.count > 8 { recentCharacterHits.removeFirst(recentCharacterHits.count - 8) }
        } else if isAccent {
            spentCharge = accentCharge(at: time)
            storedAccentCharge = 0
            lastChargeUpdate = time
        }
        let interval = lastHit.map { time - $0 } ?? .infinity
        combo = interval <= 0.8 ? min(9_999, combo + 1) : 1
        visualEnergyBase = visualEnergy(at: time)
        storedEnergy = min(1, energy(at: time) + 0.10 + profile.impact * 0.18)
        meterCarry = meterEnergy(at: time)
        let meterIncrement = isAccent ? 0.10 + 0.08 * spentCharge : profile.kind == .character ? 0.08 : 0.05
        let nextMeterTarget = min(1, meterTarget(at: time) + meterIncrement)
        let wasHigh = isHighEnergy(at: time)
        highLevelCarry = highEnergyLevel(at: time)
        if wasHigh || (nextMeterTarget >= 0.98 && meterCarry >= 0.72) {
            if !wasHigh { highEntryTime = time }
            highHoldUntil = time + 1.4
            meterHoldDuration = 1.4
            storedMeterTarget = 1
        } else {
            meterHoldDuration = 0.28
            storedMeterTarget = nextMeterTarget
        }
        recentHits.removeAll { time - $0 > 1 }
        recentHits.append(time)
        if recentHits.count > 16 { recentHits.removeFirst(recentHits.count - 16) }
        cadence = min(1, Double(recentHits.count - 1) / 11)
        // Integrate the prior speed before changing cadence, avoiding a phase jump.
        // Keep phase unwrapped: the spectrum uses a non-integer harmonic,
        // which would jump whenever a wrapped phase crossed 2π.
        motionPhase = phase(at: time)
        motionSpeed = speed(at: time)
        targetMotionSpeed = 1.5 + profile.frequency * 0.2 + cadence * 1.5
        lastHit = time
        sequence &+= 1
        pulses.removeAll { time - $0.time > $0.lifetime }
        let pulse = RhythmPulse(id: sequence, time: time, profile: profile,
                                strength: profile.impact * (1 + (isAccent ? spentCharge * 0.85 : cadence * 0.24)),
                                accentCharge: spentCharge)
        pulses.append(pulse)
        if pulses.count > Self.maximumPulses { pulses.removeFirst(pulses.count - Self.maximumPulses) }
        if tracksKeyQueue { updateKeyQueue(with: pulse, isAccent: isAccent) }
    }

    private mutating func updateKeyQueue(with pulse: RhythmPulse, isAccent: Bool) {
        if let keyBurst, pulse.time - keyBurst.strike.time >= RhythmKeyBurst.duration {
            self.keyBurst = nil
        }
        if isAccent {
            // An empty repeated accent should not cut off the row still in flight.
            let hasVisibleKeys = queueOpacity(at: pulse.time) > 0
            if hasVisibleKeys || keyBurst == nil {
                // Keep the original slots so pieces fly from where they were drawn.
                keyBurst = RhythmKeyBurst(keys: hasVisibleKeys ? queuedKeys : [], strike: pulse)
            }
            queuedKeys.removeAll(keepingCapacity: true)
        } else {
            queuedKeys.removeAll { Self.keyOpacity($0, at: pulse.time) == 0 }
            if queuedKeys.count == Self.maximumQueuedKeys { queuedKeys.removeFirst() }
            queuedKeys.append(pulse)
        }
    }

    mutating func clearKeyQueue() {
        queuedKeys.removeAll(keepingCapacity: true)
        keyBurst = nil
    }

    mutating func reset() {
        clearKeyQueue()
        pulses.removeAll(keepingCapacity: true)
        recentHits.removeAll(keepingCapacity: true)
        combo = 0
        lastHit = nil
        storedEnergy = 0
        cadence = 0
        motionPhase = 0
        motionSpeed = 2.1
        targetMotionSpeed = 2.1
        visualEnergyBase = 0
        storedMeterTarget = 0
        meterCarry = 0
        meterHoldDuration = 0.28
        highEntryTime = nil
        highHoldUntil = nil
        highLevelCarry = 0
        storedAccentCharge = 0
        lastChargeUpdate = nil
        recentCharacterHits.removeAll(keepingCapacity: true)
    }
}

@MainActor
final class RhythmFeedbackModel: ObservableObject {
    @Published private(set) var dynamics = RhythmDynamics()
    @Published private(set) var isAnimating = false
    @Published var visualStyle: RhythmVisualStyle = .energy {
        didSet {
            if oldValue == .burst && visualStyle != .burst { dynamics.clearKeyQueue() }
        }
    }
    @Published var flashesEnabled = true
    @Published var intensity = 1.0 {
        didSet {
            let sanitized = intensity.isFinite ? min(1.5, max(0.4, intensity)) : 1
            if sanitized != intensity { intensity = sanitized }
        }
    }
    private var settleTask: Task<Void, Never>?

    func receiveKey(_ code: UInt16, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard time.isFinite else { return }
        dynamics.receiveKey(code, at: time, tracksKeyQueue: visualStyle == .burst)
        isAnimating = true
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RhythmDynamics.settleDelay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.dynamics.reset()
            self.isAnimating = false
        }
    }

    func reset() {
        settleTask?.cancel()
        settleTask = nil
        dynamics.reset()
        isAnimating = false
    }
}
