import Foundation

/// A gesture reshapes the existing stereo signal. It has no oscillator, sample
/// player, beat grid, or transport: silence in always produces silence out.
final class WholeMusicGesture {
    enum Intensity: String, CaseIterable { case gentle, expressive }
    enum Profile: String, CaseIterable { case breath, clarity, rhythm }

    var depth: Double = 0.45
    var decay: Double = 0.5 { didSet { dj.setDecay(decay) } }
    var intensity: Intensity = .expressive
    var profile: Profile = .breath
    private(set) var attackCount: UInt64 = 0
    private(set) var heldCount = 0
    private(set) var openness = 0.0
    var level: Double { max(dj.activity, max(dent * 3, heldCount > 0 ? openness : 0)) * max(0, min(1, depth)) }
    var currentGain: Double { lastGain }

    private let rate: Double
    private let openingStep: Double
    private let dentOpeningStep: Double
    private let dentClosingStep: Double
    private let warmFilterStep: Double
    private let bassFilterStep: Double
    private let dj: StereoDJGesture
    private var gateFrames: UInt64 = 4_800
    private var framesSinceAttack: UInt64 = .max / 2
    private var framesSinceRelease: UInt64 = .max / 2
    private var interval = 0.25
    private var dentTarget = 0.0
    private var dent = 0.0
    private var dentFrames = 0
    private var activationStrength = 0.0
    private var lowL = 0.0, lowR = 0.0, low2L = 0.0, low2R = 0.0
    private var bassL = 0.0, bassR = 0.0
    private var lastGain = 1.0

    init(sampleRate: Double) {
        rate = max(8_000, sampleRate)
        openingStep = 1 - exp(-1 / (rate * 0.008))
        dentOpeningStep = 1 - exp(-1 / (rate * 0.0018))
        dentClosingStep = 1 - exp(-1 / (rate * 0.028))
        warmFilterStep = 1 - exp(-2 * .pi * 1_650 / rate)
        bassFilterStep = 1 - exp(-2 * .pi * 260 / rate)
        dj = StereoDJGesture(sampleRate: rate)
    }

    func noteOn(heldCount: Int, strength: Double = 1) {
        noteOn(heldCount: heldCount, strength: strength, action: .lift, duration: 0.24)
    }

    func noteOn(heldCount: Int, strength: Double, action: DJAction, duration: Double) {
        let weight = min(1, max(0, strength))
        guard weight > 0, action != .none else { return }
        activationStrength = max(weight, activationStrength * 0.70)
        let gap = min(2, Double(framesSinceAttack) / rate)
        interval = gap > 0.65 ? 0.25 : interval * 0.72 + max(0.016, gap) * 0.28
        let density = min(1, max(0, (0.22 - interval) / 0.18))
        let length = min(0.46, max(0.14, duration))
        gateFrames = UInt64(rate * length * 0.55)
        dj.trigger(action: action, duration: length,
                   strength: weight * sqrt(max(0, min(1, depth))) * (1 - density * 0.55),
                   gentle: intensity == .gentle)
        // Each press gives the entire song a short, rounded contour. Dense
        // typing makes the contour shallower; repeated hits never add gain.
        let contour: Double
        switch action {
        case .push: contour = intensity == .expressive ? 0.12 : 0.07
        case .pull: contour = intensity == .expressive ? 0.16 : 0.09
        case .sweep: contour = 0.045
        case .lift: contour = intensity == .expressive ? 0.14 : 0.08
        case .hold: contour = 0.025
        case .none: contour = 0
        }
        dentTarget = contour * weight * (1 - density * 0.78)
        dentFrames = max(1, Int(rate * 0.006))
        framesSinceAttack = 0
        framesSinceRelease = 0
        self.heldCount = max(0, heldCount)
        attackCount &+= 1
    }

    func noteOff(heldCount: Int) {
        let value = max(0, heldCount)
        if self.heldCount > 0 && value == 0 { framesSinceRelease = 0 }
        self.heldCount = value
    }

    func releaseAll() {
        heldCount = 0
        framesSinceRelease = 0
        // This is a release, not another attack. Finish the existing contour.
    }

    func reset() {
        attackCount = 0; heldCount = 0; openness = 0
        framesSinceAttack = .max / 2; framesSinceRelease = .max / 2
        interval = 0.25; dentTarget = 0; dent = 0; dentFrames = 0; activationStrength = 0
        lowL = 0; lowR = 0; low2L = 0; low2R = 0; bassL = 0; bassR = 0; lastGain = 1
        gateFrames = UInt64(rate * 0.10)
        dj.reset()
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        let returnTime = 0.07 + max(0, min(1, decay)) * 0.16
        let opening = heldCount > 0 || framesSinceAttack < gateFrames
        if opening {
            openness += (activationStrength - openness) * openingStep
        } else {
            // No time-grid or generated pulse: the curve ends after the user's
            // actual release. A finite tail returns to the same resting state.
            openness *= 1 - (1 / (rate * returnTime))
            if framesSinceRelease > UInt64(rate * returnTime * 8) { openness = 0 }
        }
        let dentGoal = dentFrames > 0 ? dentTarget : 0
        dent += (dentGoal - dent) * (dentGoal > dent ? dentOpeningStep : dentClosingStep)
        if dentFrames > 0 { dentFrames -= 1 }
        if dent < 1e-10 { dent = 0 }
        framesSinceAttack &+= 1
        framesSinceRelease &+= 1

        let shifted = dj.process(left: left, right: right, depth: depth, held: heldCount > 0)
        let darkness = max(0, -dj.brightness)
        let filterStep = max(0.02, warmFilterStep * (1 - min(0.90, darkness * 1.5)))
        let l = Double(shifted.0), r = Double(shifted.1)
        lowL += (l - lowL) * filterStep; lowR += (r - lowR) * filterStep
        low2L += (lowL - low2L) * filterStep; low2R += (lowR - low2R) * filterStep
        bassL += (l - bassL) * bassFilterStep; bassR += (r - bassR) * bassFilterStep

        let rawDepth = max(0, min(1, depth))
        // This exact branch is also the causal QA reference: a zero response
        // setting does not modify a single input sample, even while typing.
        guard rawDepth > 0 else { lastGain = 1; return (left, right) }
        let amount = sqrt(rawDepth)
        let toneAmount: Double
        switch profile {
        case .breath: toneAmount = 0.75
        case .clarity: toneAmount = 1.0
        case .rhythm: toneAmount = 0.55
        }
        // At rest this is exactly the original music, without a persistent
        // low-pass, gain reduction or delay. Only the user's large-key gesture
        // reshapes it; sparse input is not needed to keep the song clear.
        let gain = 1 - amount * dent
        let warmth = min(0.75, amount * darkness * toneAmount)
        let clarity = max(0, dj.brightness) * amount * toneAmount
        let coloredL = l + (low2L - l) * warmth - bassL * clarity * 0.12
        let coloredR = r + (low2R - r) * warmth - bassR * clarity * 0.12
        let mid = (coloredL + coloredR) * 0.5
        let side = (coloredL - coloredR) * 0.5 * (1 + clarity * 0.12)
        lastGain = gain
        if gain == 1 && warmth == 0 && clarity == 0 { return shifted }
        return (Float((mid + side) * gain), Float((mid - side) * gain))
    }
}
