import Foundation

enum DJAction: String, Equatable, Sendable {
    case none, push, pull, sweep, lift, hold

    static func forKeyCode(_ keyCode: UInt16) -> Self {
        switch keyCode {
        case 49: return .push
        case 36, 76: return .lift
        case 51, 117: return .pull
        case 48, 57: return .sweep
        case 56, 60: return .hold
        default: return .none
        }
    }

    fileprivate var baselineWeight: Double {
        switch self {
        case .none: return 0
        case .push: return 0.70
        case .pull: return 0.62
        case .sweep: return 0.58
        case .lift: return 0.82
        case .hold: return 0.56
        }
    }
}

/// Musical roles use physical key codes only, never the text being entered.
enum KeyGestureRole: Equatable, Sendable {
    case typing, separator, phrase, editing

    static func forKeyCode(_ keyCode: UInt16) -> Self {
        switch keyCode {
        case 48, 49, 57: return .separator
        case 36, 76: return .phrase
        case 51, 117, 53, 123...126: return .editing
        default: return .typing
        }
    }

    /// Command, Control, Option, arrows, Escape, and character keys are silent.
    static func isPerformanceKey(_ keyCode: UInt16) -> Bool {
        DJAction.forKeyCode(keyCode) != .none
    }
}

/// Call once for every filtered physical press, including silent character keys.
/// Only large keys perform; all keys teach cadence. This value stores intervals
/// and coarse boundary counts, never text, key history, or delayed events.
struct ContentChangePolicy: Sendable {
    struct Decision: Equatable, Sendable {
        let role: KeyGestureRole
        let shouldChangeContent: Bool
        let feedbackWeight: Double
        let action: DJAction
        /// Immediate gesture length in seconds, not a scheduling delay.
        let duration: Double

        init(role: KeyGestureRole, shouldChangeContent: Bool, feedbackWeight: Double,
             action: DJAction = .none, duration: Double = 0.24) {
            self.role = role
            self.shouldChangeContent = shouldChangeContent
            self.feedbackWeight = feedbackWeight
            self.action = action
            self.duration = duration
        }

        /// Auditions share the whitelist but never train cadence or cue counters.
        static func preview(keyCode: UInt16) -> Self {
            let action = DJAction.forKeyCode(keyCode)
            return Self(role: .forKeyCode(keyCode),
                        shouldChangeContent: action == .push || action == .lift,
                        feedbackWeight: action.baselineWeight, action: action)
        }
    }

    static func isPerformanceKey(_ keyCode: UInt16) -> Bool {
        KeyGestureRole.isPerformanceKey(keyCode)
    }

    private var lastInput: TimeInterval?
    private var lastPerformance: TimeInterval?
    private var inputInterval = 0.20
    private var performanceInterval = 0.60
    private var pauseBoostPending = true
    private var lastContentChange: TimeInterval?
    private var wordWindowStarted: TimeInterval?
    private var hasTypingSinceSpace = false
    private var completedWordBoundaries = 0

    mutating func receive(keyCode: UInt16, timestamp: TimeInterval) -> Decision {
        let role = KeyGestureRole.forKeyCode(keyCode)
        let action = DJAction.forKeyCode(keyCode)
        guard timestamp.isFinite, lastInput.map({ timestamp >= $0 }) ?? true else {
            // Preserve the last good clocks so malformed time cannot bypass a
            // cue limit. A large key still provides immediate gesture feedback.
            return Decision(role: role, shouldChangeContent: false,
                            feedbackWeight: action.baselineWeight, action: action)
        }
        if let previous = lastInput {
            let gap = timestamp - previous
            if gap >= 1.5 {
                pauseBoostPending = true
                inputInterval = 0.30
                resetWordWindow()
            } else {
                inputInterval = inputInterval * 0.70 + Self.clamp(gap, 0.035, 1.2) * 0.30
            }
        }
        lastInput = timestamp

        if action == .none {
            if Self.isCharacterKey(keyCode) {
                hasTypingSinceSpace = true
                if wordWindowStarted == nil { wordWindowStarted = timestamp }
            } else if role == .editing {
                resetWordWindow()
            }
            return Decision(role: role, shouldChangeContent: false, feedbackWeight: 0)
        }

        if let previous = lastPerformance {
            let gap = timestamp - previous
            performanceInterval = gap >= 3 ? 0.90
                : performanceInterval * 0.65 + Self.clamp(gap, 0.14, 1.5) * 0.35
        }
        lastPerformance = timestamp
        let duration = Self.clamp(0.12 + inputInterval * 0.30 + performanceInterval * 0.12, 0.14, 0.46)
        let typingDensity = Self.clamp((0.25 - inputInterval) / 0.20, 0, 1)
        let performanceDensity = Self.clamp((0.65 - performanceInterval) / 0.50, 0, 1)
        let attenuation = 1 - 0.32 * typingDensity - 0.15 * performanceDensity
        let weight = min(0.95, action.baselineWeight * attenuation * (pauseBoostPending ? 1.22 : 1))
        pauseBoostPending = false

        var changesContent = false
        switch keyCode {
        case 36, 76:
            changesContent = lastContentChange.map { timestamp >= $0 + 2.0 } ?? true
            resetWordWindow()
        case 49:
            if hasTypingSinceSpace {
                completedWordBoundaries = min(3, completedWordBoundaries + 1)
                hasTypingSinceSpace = false
            }
            let windowOldEnough = wordWindowStarted.map { timestamp >= $0 + 3.0 } ?? false
            let cooldownElapsed = lastContentChange.map { timestamp >= $0 + 3.0 } ?? true
            changesContent = completedWordBoundaries >= 3 && windowOldEnough && cooldownElapsed
            if changesContent { resetWordWindow() }
        case 48, 57, 51, 117:
            resetWordWindow()
        default: break // Shift sustains a gesture without creating a phrase.
        }
        if changesContent { lastContentChange = timestamp }
        return Decision(role: role, shouldChangeContent: changesContent,
                        feedbackWeight: weight, action: action, duration: duration)
    }

    mutating func reset() { self = ContentChangePolicy() }

    private mutating func resetWordWindow() {
        wordWindowStarted = nil
        hasTypingSinceSpace = false
        completedWordBoundaries = 0
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    /// Identifies only a physical typing group between spaces. No characters are
    /// decoded, and these groups are not presented as a textual word count.
    private static func isCharacterKey(_ code: UInt16) -> Bool {
        if code <= 50 { return code != 36 && code != 48 && code != 49 }
        switch code {
        case 65, 67, 69, 75, 78, 81...89, 91, 92: return true
        default: return false
        }
    }
}
