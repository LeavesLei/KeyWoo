import Foundation

struct RemapInput: Equatable, Sendable {
    enum Kind: Sendable { case down, up, tap }
    var kind: Kind
    var keyCode: UInt16
    let physicalCode: UInt16
    var modifiers: RemapModifiers
    var isRepeat: Bool
    var isInjected: Bool
    init(_ kind: Kind, keyCode: UInt16, modifiers: RemapModifiers = [],
         isRepeat: Bool = false, isInjected: Bool = false, physicalCode: UInt16? = nil) {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers
        self.isRepeat = isRepeat; self.isInjected = isInjected
        self.physicalCode = physicalCode ?? keyCode
    }
}

enum RemapOutput: Equatable, Sendable {
    case key(code: UInt16, isDown: Bool, isRepeat: Bool, modifiers: RemapModifiers)
    case media(RemapMediaAction, isDown: Bool)
}

struct RemapDecision: Equatable, Sendable {
    var suppressOriginal: Bool = false
    /// nil means leave even the flags untouched (e.g. our own injected events).
    var passthroughModifiers: RemapModifiers?
    var outputs: [RemapOutput] = []
}

/// A deterministic keyboard state machine with no clocks, OS calls, file access,
/// characters, or timers. A key-up releases the binding chosen at key-down even
/// after modifiers/layers change. Synthetic ownership is reference-counted so
/// two physical keys mapped to the same output cannot release each other.
struct RemapStateMachine {
    private struct HeldAction {
        var action: RemapAction
        var modifierCodes: [UInt16]
        var consumedModifiers: RemapModifiers
    }
    private enum Binding {
        case passthrough
        case blocked
        case layer(UUID, RemapLayerKey.Mode)
        case action(HeldAction)
    }
    private(set) var profile: RemapProfile
    private(set) var activeLayerIDs: [UUID] = []
    private(set) var physicalHeld = Set<UInt16>()
    private var bindings: [UInt16: Binding] = [:]
    private var outputCounts: [UInt16: Int] = [:]
    private var physicalModifiers: RemapModifiers = []
    private var blockedUntilUp = Set<UInt16>()
    private var capsOverride: Bool?
    private var observedCaps = false
    private var observedAnyFlags = false
    private var toggledLayerIDs = Set<UUID>()

    init(profile: RemapProfile) { self.profile = profile }
    var heldOutputKeys: Set<UInt16> { Set(outputCounts.keys) }
    var suppressedPhysicalModifierKeyCodes: Set<UInt16> {
        var result = blockedUntilUp.filter { !RemapModifiers.forKeyCode($0).isEmpty }
        for (code, binding) in bindings where !RemapModifiers.forKeyCode(code).isEmpty {
            if case .passthrough = binding {} else { result.insert(code) }
        }
        return result
    }

    /// Seed keys already held before a tap/reconfiguration without generating
    /// artificial presses. Consumed keys stay quarantined until a real release.
    mutating func seedPhysicalModifiers(_ keys: Set<UInt16>) {
        seedPhysicalKeys(keys.filter { !RemapModifiers.forKeyCode($0).isEmpty })
    }
    mutating func seedPhysicalKeys(_ keys: Set<UInt16>) {
        for code in keys where code != 57 && bindings[code] == nil && !blockedUntilUp.contains(code) {
            physicalHeld.insert(code); bindings[code] = .passthrough
        }
    }

    mutating func modifiersForPassthrough(_ incoming: RemapModifiers) -> RemapModifiers {
        physicalModifiers = incoming
        return outputModifiers()
    }

    mutating func process(_ input: RemapInput) -> RemapDecision {
        // Checking before changing any state is essential for recursion safety.
        guard !input.isInjected else { return RemapDecision() }
        let incomingCaps = input.modifiers.contains(.capsLock)
        let priorCaps = capsOverride ?? (observedAnyFlags ? observedCaps
            : (input.keyCode == 57 && input.kind == .tap ? !incomingCaps : incomingCaps))
        observedCaps = incomingCaps; observedAnyFlags = true
        physicalModifiers = input.modifiers
        let code = input.keyCode
        if blockedUntilUp.contains(code) {
            if input.kind == .up || input.kind == .tap { blockedUntilUp.remove(code) }
            return decision(suppress: true)
        }
        if input.kind == .up {
            physicalHeld.remove(code)
            guard let binding = bindings.removeValue(forKey: code) else { return decision(suppress: false) }
            switch binding {
            case .passthrough:
                // A real key can share an output with a remapped key. Its up
                // must not release the synthetic owner that is still holding it.
                return decision(suppress: outputCounts[code] != nil)
            case .blocked: return decision(suppress: true)
            case .layer(let id, let mode):
                if mode == .hold && !toggledLayerIDs.contains(id) && !bindings.values.contains(where: {
                    if case .layer(id, .hold) = $0 { return true }; return false
                }) { activeLayerIDs.removeAll { $0 == id } }
                return decision(suppress: true)
            case .action(let held):
                return decision(suppress: true, outputs: finish(held))
            }
        }

        if let binding = bindings[code] {
            switch binding {
            case .passthrough: return decision(suppress: false)
            case .action(let held):
                if input.isRepeat, case let .key(outputCode, _) = held.action,
                   RemapModifiers.forKeyCode(outputCode).isEmpty {
                    return decision(suppress: true, outputs: [.key(code: outputCode, isDown: true,
                        isRepeat: true, modifiers: outputModifiers(removing: held.consumedModifiers))])
                }
                return decision(suppress: true)
            default: return decision(suppress: true)
            }
        }
        // Starting/reconfiguring while a key is already repeating must not
        // manufacture a new shortcut or a new modifier press.
        if input.isRepeat { return decision(suppress: false) }
        if input.kind == .down { physicalHeld.insert(code) }

        if let layerKey = profile.layerKeys.first(where: { $0.keyCode == code }) {
            if code == 57 { capsOverride = false }
            if layerKey.mode == .toggle {
                if toggledLayerIDs.remove(layerKey.layerID) != nil {
                    if !bindings.values.contains(where: {
                        if case .layer(layerKey.layerID, .hold) = $0 { return true }; return false
                    }) { activeLayerIDs.removeAll { $0 == layerKey.layerID } }
                } else {
                    toggledLayerIDs.insert(layerKey.layerID)
                    if !activeLayerIDs.contains(layerKey.layerID) { activeLayerIDs.append(layerKey.layerID) }
                }
            } else if !activeLayerIDs.contains(layerKey.layerID) {
                activeLayerIDs.append(layerKey.layerID)
            }
            if input.kind != .tap { bindings[code] = .layer(layerKey.layerID, layerKey.mode) }
            return decision(suppress: true)
        }

        // A modifier key's own flag is excluded from its trigger. Thus mapping
        // Right Option does not require the nonsensical Option+Right Option.
        let triggerFlags = visiblePhysicalModifiers.subtracting(RemapModifiers.forKeyCode(code))
        let layers: [UUID?] = activeLayerIDs.reversed().map(Optional.some) + [nil]
        var matchedRule: RemapRule?
        for layer in layers {
            if let found = profile.rules.first(where: { $0.isEnabled && $0.trigger.layerID == layer
                && $0.trigger.keyCode == code && $0.trigger.matches(triggerFlags) }) {
                matchedRule = found; break
            }
        }
        let rule = matchedRule
        guard let rule else {
            if code == 57 && input.kind == .tap && capsOverride != nil { capsOverride = !priorCaps }
            if input.kind != .tap { bindings[code] = .passthrough }
            return decision(suppress: false)
        }
        if code == 57 && input.kind == .tap { capsOverride = priorCaps }
        if rule.action == .disabled {
            if input.kind != .tap { bindings[code] = .blocked }
            return decision(suppress: true)
        }
        // Install a placeholder before deriving flags: mapped physical modifiers
        // must not leak their original meaning into their replacement events.
        bindings[code] = .blocked
        let held = makeHeld(rule)
        var outputs = begin(held)
        if input.kind == .tap {
            bindings.removeValue(forKey: code)
            outputs += finish(held)
        } else { bindings[code] = .action(held) }
        return decision(suppress: true, outputs: outputs)
    }

    /// Keep swallowed physical downs quarantined until release when editing an
    /// active configuration. They cannot acquire a second meaning midway through.
    mutating func replaceProfile(_ profile: RemapProfile) -> [RemapOutput] {
        let outputs = releaseAll()
        self.profile = profile
        capsOverride = nil; observedAnyFlags = false
        return outputs
    }

    mutating func releaseAll() -> [RemapOutput] {
        var outputs: [RemapOutput] = []
        for (code, binding) in bindings {
            if case .passthrough = binding {} else { blockedUntilUp.insert(code) }
        }
        // Keys before modifiers. Modifiers are released once, regardless of how
        // many source keys owned them. Physical modifiers remain in the flags.
        let keys = outputCounts.keys.sorted()
        for code in keys where RemapModifiers.forKeyCode(code).isEmpty {
            outputCounts.removeValue(forKey: code)
            if !isVisiblePhysicalKeyHeld(code) {
                outputs.append(.key(code: code, isDown: false, isRepeat: false, modifiers: outputModifiers()))
            }
        }
        for code in keys where !RemapModifiers.forKeyCode(code).isEmpty {
            outputCounts.removeValue(forKey: code)
            if !isVisiblePhysicalKeyHeld(code) {
                outputs.append(.key(code: code, isDown: false, isRepeat: false, modifiers: outputModifiers()))
            }
        }
        for binding in bindings.values {
            if case .action(let held) = binding, case .media(let media) = held.action {
                outputs.append(.media(media, isDown: false))
            }
        }
        // Unmapped physical keys are still down in the target application. Keep
        // their ownership until up, including the opposite side of a modifier.
        bindings = bindings.filter { if case .passthrough = $0.value { return true }; return false }
        physicalHeld.formIntersection(Set(bindings.keys))
        activeLayerIDs.removeAll()
        toggledLayerIDs.removeAll()
        return outputs
    }

    /// Only the event source can establish that a held key was physically lost.
    /// This recovers disconnects without resetting genuine holds each timer tick.
    mutating func releaseMissingKeys(isPhysicallyDown: (UInt16) -> Bool) -> [RemapOutput] {
        var outputs: [RemapOutput] = []
        let stillDown = physicalHeld.filter(isPhysicallyDown)
        var flags = physicalModifiers
        for code in physicalHeld.subtracting(stillDown) {
            let modifier = RemapModifiers.forKeyCode(code)
            if !stillDown.contains(where: { RemapModifiers.forKeyCode($0) == modifier }) { flags.subtract(modifier) }
        }
        for code in physicalHeld.subtracting(stillDown).sorted() {
            outputs += process(RemapInput(.up, keyCode: code,
                modifiers: flags)).outputs
        }
        blockedUntilUp = blockedUntilUp.filter(isPhysicallyDown)
        return outputs
    }

    private var visiblePhysicalModifiers: RemapModifiers {
        var value = physicalModifiers
        if let capsOverride {
            if capsOverride { value.insert(.capsLock) } else { value.remove(.capsLock) }
        }
        // A Caps layer is explicitly a software toggle, not the OS Caps state.
        // Its lock flag must stay filtered even after its transient event ends.
        if profile.layerKeys.contains(where: { $0.keyCode == 57 }) { value.remove(.capsLock) }
        for code in suppressedPhysicalModifierKeyCodes {
            let flag = RemapModifiers.forKeyCode(code)
            guard !flag.isEmpty else { continue }
            let otherVisible = physicalHeld.contains { other in
                guard other != code, RemapModifiers.forKeyCode(other) == flag else { return false }
                if case .passthrough? = bindings[other] { return true }
                return bindings[other] == nil
            }
            if !otherVisible { value.subtract(flag) }
        }
        return value
    }

    private func outputModifiers(removing consumed: RemapModifiers = []) -> RemapModifiers {
        var value = visiblePhysicalModifiers.subtracting(consumed)
        for code in outputCounts.keys { value.formUnion(RemapModifiers.forKeyCode(code)) }
        return value
    }
    private func decision(suppress: Bool, outputs: [RemapOutput] = []) -> RemapDecision {
        RemapDecision(suppressOriginal: suppress, passthroughModifiers: outputModifiers(), outputs: outputs)
    }
    private func makeHeld(_ rule: RemapRule) -> HeldAction {
        var modifiers: [UInt16] = []
        if case let .key(code, flags) = rule.action {
            modifiers = flags.keyCodes
            if !RemapModifiers.forKeyCode(code).isEmpty && !modifiers.contains(code) { modifiers.append(code) }
        }
        return HeldAction(action: rule.action, modifierCodes: modifiers, consumedModifiers: rule.trigger.modifiers)
    }
    private mutating func acquire(_ code: UInt16, consumed: RemapModifiers) -> RemapOutput? {
        let count = outputCounts[code, default: 0]
        outputCounts[code] = count + 1
        guard count == 0, !isVisiblePhysicalKeyHeld(code) else { return nil }
        return .key(code: code, isDown: true, isRepeat: false, modifiers: outputModifiers(removing: consumed))
    }
    private mutating func relinquish(_ code: UInt16, consumed: RemapModifiers) -> RemapOutput? {
        guard let count = outputCounts[code] else { return nil }
        if count > 1 { outputCounts[code] = count - 1; return nil }
        outputCounts.removeValue(forKey: code)
        guard !isVisiblePhysicalKeyHeld(code) else { return nil }
        return .key(code: code, isDown: false, isRepeat: false, modifiers: outputModifiers(removing: consumed))
    }
    private func isVisiblePhysicalKeyHeld(_ code: UInt16) -> Bool {
        guard physicalHeld.contains(code) else { return false }
        if case .passthrough? = bindings[code] { return true }
        return false
    }
    private mutating func begin(_ held: HeldAction) -> [RemapOutput] {
        switch held.action {
        case .disabled: return []
        case .media(let media): return [.media(media, isDown: true)]
        case .key(let code, _):
            var output = held.modifierCodes.compactMap { acquire($0, consumed: held.consumedModifiers) }
            if RemapModifiers.forKeyCode(code).isEmpty, let key = acquire(code, consumed: held.consumedModifiers) { output.append(key) }
            return output
        }
    }
    private mutating func finish(_ held: HeldAction) -> [RemapOutput] {
        switch held.action {
        case .disabled: return []
        case .media(let media): return [.media(media, isDown: false)]
        case .key(let code, _):
            var output: [RemapOutput] = []
            if RemapModifiers.forKeyCode(code).isEmpty, let key = relinquish(code, consumed: held.consumedModifiers) { output.append(key) }
            output += held.modifierCodes.reversed().compactMap { relinquish($0, consumed: held.consumedModifiers) }
            return output
        }
    }
}
