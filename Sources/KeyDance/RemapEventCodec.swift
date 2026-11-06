import AppKit
import CoreGraphics

enum RemapEventMarker {
    // "KWREMAP1". Shared by the passive physical monitor and active backend.
    static let value: Int64 = 0x4B5752454D415031
    static func isInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == value
    }
}

enum RemapEventCodec {
    static let auxiliaryEventMask = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue

    static let modifierDeviceMasks: [UInt16: UInt64] = [
        59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10,
        58: 0x20, 61: 0x40, 62: 0x2000
    ]
    /// AppKit's Function flag also identifies function/navigation keys. On these
    /// positions the bit alone is not evidence that the physical Fn key is held.
    /// JIS Eisu/Kana are non-text input-mode keys; JIS Yen/underscore/keypad comma
    /// are deliberately excluded so a genuine Fn flag on them is preserved.
    static let intrinsicFunctionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        105, 107, 113, 106, 64, 79, 80, 90,
        114, 115, 116, 117, 119, 121, 123, 124, 125, 126, 102, 104
    ]
    private static let numericPadKeyCodes: Set<UInt16> = [
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 95,
        123, 124, 125, 126
    ]
    private static let masks: [(RemapModifiers, UInt64, UInt64, UInt64)] = [
        (.shift, 0x00020000, 0x00000006, 0x00000002),
        (.control, 0x00040000, 0x00002001, 0x00000001),
        (.option, 0x00080000, 0x00000060, 0x00000020),
        (.command, 0x00100000, 0x00000018, 0x00000008),
        (.fn, 0x00800000, 0, 0),
        (.capsLock, 0x00010000, 0, 0)
    ]
    static func modifiers(from flags: CGEventFlags) -> RemapModifiers {
        masks.reduce(into: RemapModifiers()) { value, entry in
            if flags.rawValue & entry.1 != 0 { value.insert(entry.0) }
        }
    }
    static func flags(_ modifiers: RemapModifiers, preserving original: CGEventFlags = [],
                      keyCode: UInt16? = nil, heldModifierKeys: Set<UInt16>? = nil,
                      suppressedPhysicalKeys: Set<UInt16> = []) -> CGEventFlags {
        var raw = original.rawValue
        let suppressedBits = suppressedPhysicalKeys.reduce(UInt64(0)) { $0 | (modifierDeviceMasks[$1] ?? 0) }
        let syntheticBits = (heldModifierKeys ?? []).reduce(UInt64(0)) { $0 | (modifierDeviceMasks[$1] ?? 0) }
        for (modifier, independent, device, preferred) in masks {
            let existingDevice = (raw & device & ~suppressedBits) | (syntheticBits & device)
            raw &= ~(independent | device)
            if modifiers.contains(modifier) {
                raw |= independent
                raw |= existingDevice == 0 ? preferred : existingDevice
            }
        }
        if let keyCode, intrinsicFunctionKeyCodes.contains(keyCode), original.contains(.maskSecondaryFn) {
            // Do not erase a special-key classification when removing a genuine
            // Fn modifier from pass-through input. New F/navigation outputs also
            // need their intrinsic flag even without a physical Fn being held.
            raw |= CGEventFlags.maskSecondaryFn.rawValue
        }
        return CGEventFlags(rawValue: raw)
    }
    static func outputEvent(_ output: RemapOutput, source: CGEventSource?,
                            physicalFlags: CGEventFlags = [], heldModifierKeys: Set<UInt16>? = nil,
                            suppressedPhysicalKeys: Set<UInt16> = []) -> CGEvent? {
        let event: CGEvent?
        switch output {
        case let .key(code, isDown, isRepeat, modifiers):
            event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: isDown)
            if !RemapModifiers.forKeyCode(code).isEmpty { event?.type = .flagsChanged }
            var intrinsic = physicalFlags.subtracting([.maskSecondaryFn, .maskNumericPad, .maskHelp])
            if intrinsicFunctionKeyCodes.contains(code) { intrinsic.insert(.maskSecondaryFn) }
            if numericPadKeyCodes.contains(code) { intrinsic.insert(.maskNumericPad) }
            var held = heldModifierKeys
            // Standalone event construction can still encode the requested side.
            // The live projector supplies complete shared ownership for chords.
            if held == nil, !RemapModifiers.forKeyCode(code).isEmpty {
                held = isDown ? [code] : []
            }
            event?.flags = flags(modifiers, preserving: intrinsic, keyCode: code,
                                heldModifierKeys: held, suppressedPhysicalKeys: suppressedPhysicalKeys)
            event?.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        case let .media(action, isDown):
            // Public IOKit ev_keymap.h key types + IOLLEvent.h auxiliary-key
            // systemDefined event. The target media app still decides its action.
            let state = isDown ? 0xA : 0xB
            event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                context: nil, subtype: 8, data1: (Int(action.nativeKeyType) << 16) | (state << 8), data2: -1)?.cgEvent
        }
        event?.setIntegerValueField(.eventSourceUserData, value: RemapEventMarker.value)
        return event
    }

    /// Project the actual ordered transition, not merely its final flags. This
    /// preserves both left/right sides through multi-modifier chords and release.
    static func outputEvents(_ outputs: [RemapOutput], source: CGEventSource?,
                             physicalFlags: CGEventFlags, finalHeldKeys: Set<UInt16>,
                             suppressedPhysicalKeys: Set<UInt16>) -> [CGEvent] {
        var modifiers = finalHeldKeys.filter { !RemapModifiers.forKeyCode($0).isEmpty }
        for output in outputs.reversed() {
            if case let .key(code, down, repeated, _) = output,
               !repeated, !RemapModifiers.forKeyCode(code).isEmpty {
                if down { modifiers.remove(code) } else { modifiers.insert(code) }
            }
        }
        var events: [CGEvent] = []
        for output in outputs {
            if case let .key(code, down, repeated, _) = output,
               !repeated, !RemapModifiers.forKeyCode(code).isEmpty {
                if down { modifiers.insert(code) } else { modifiers.remove(code) }
            }
            if let event = outputEvent(output, source: source, physicalFlags: physicalFlags,
                heldModifierKeys: modifiers, suppressedPhysicalKeys: suppressedPhysicalKeys) {
                events.append(event)
            }
        }
        return events
    }
}

/// Pair suppression with the original physical press even if the active
/// profile changes while it is held. Repeats never start a second action.
struct RemapConsumerPresses {
    private var suppressed = Set<UInt16>()

    mutating func handle(_ edge: RemapInput, onPress: (RemapInput) -> Bool) -> Bool {
        let code = edge.physicalCode
        if edge.kind == .up { return suppressed.remove(code) != nil }
        if edge.isRepeat { return suppressed.contains(code) }
        // Treat consumer actions as taps: Quartz cannot poll their held state
        // after a dropped key-up, so a lost release must never hold a modifier.
        var tap = edge
        tap.kind = .tap
        if onPress(tap) {
            suppressed.insert(code)
            return true
        }
        suppressed.remove(code)
        return false
    }

    mutating func reset() { suppressed.removeAll() }
}

/// Separate from the music monitor because the remapper must preserve repeats.
/// Caps is represented as a transient tap; its OS lock bit is not a key release.
struct RemapInputDecoder {
    private var heldModifiers = Set<UInt16>()
    private var capsLock = false
    private static let deviceMasks: [UInt16: UInt64] = [
        59: 0x1, 56: 0x2, 60: 0x4, 55: 0x8, 54: 0x10,
        58: 0x20, 61: 0x40, 62: 0x2000, 63: 0x800000
    ]
    var heldPhysicalModifierKeyCodes: Set<UInt16> { heldModifiers }
    /// Keep the edge decoder in sync with lost-release recovery. Resetting all
    /// modifiers would erase real Fn holds; leaving a recovered key here would
    /// drop its next fresh down as a duplicate.
    mutating func releaseMissingModifiers(isPhysicallyDown: (UInt16) -> Bool) {
        heldModifiers = heldModifiers.filter(isPhysicallyDown)
    }
    mutating func reset(flags: CGEventFlags, fnIsPhysicallyDown: Bool? = nil) {
        heldModifiers = Set(Self.deviceMasks.compactMap { $0.key != 63 && flags.rawValue & $0.value != 0 ? $0.key : nil })
        // The aggregate Function bit cannot distinguish an already-held F key
        // from Fn. Seed Fn only from an authorized physical-state query; otherwise
        // keep ambiguous function-key combos conservative until flagsChanged(63).
        if fnIsPhysicallyDown == true { heldModifiers.insert(63) }
        capsLock = flags.contains(.maskAlphaShift)
    }
    func decodeAuxiliary(_ event: NSEvent) -> RemapInput? {
        guard event.type == .systemDefined, event.subtype.rawValue == 8 else { return nil }
        let data = event.data1
        let nativeType = UInt16(truncatingIfNeeded: data >> 16)
        guard let action = RemapMediaAction.forNativeKeyType(nativeType) else { return nil }
        let phase = (data >> 8) & 0xFF
        guard phase == 0xA || phase == 0xB else { return nil }
        var modifiers = RemapEventCodec.modifiers(from: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        // Auxiliary events don't necessarily carry the keyboard modifier flags.
        // Fn's aggregate bit can be the media-row classification itself.
        modifiers.remove(.fn)
        for code in heldModifiers { modifiers.formUnion(RemapModifiers.forKeyCode(code)) }
        if capsLock { modifiers.insert(.capsLock) }
        return RemapInput(phase == 0xA ? .down : .up, keyCode: action.triggerCode,
            modifiers: modifiers, isRepeat: phase == 0xA && data & 1 != 0,
            physicalCode: RemapMediaAction.auxiliaryCode(for: nativeType))
    }
    mutating func decode(type: CGEventType, code: UInt16, flags: CGEventFlags, isRepeat: Bool) -> RemapInput? {
        var modifiers = RemapEventCodec.modifiers(from: flags)
        if RemapEventCodec.intrinsicFunctionKeyCodes.contains(code) && !heldModifiers.contains(63) {
            modifiers.remove(.fn)
        }
        if type == .keyDown { return RemapInput(.down, keyCode: code, modifiers: modifiers, isRepeat: isRepeat) }
        if type == .keyUp { return RemapInput(.up, keyCode: code, modifiers: modifiers) }
        guard type == .flagsChanged else { return nil }
        if code == 57 {
            let enabled = flags.contains(.maskAlphaShift)
            guard enabled != capsLock else { return nil }
            capsLock = enabled
            return RemapInput(.tap, keyCode: code, modifiers: modifiers)
        }
        guard let mask = Self.deviceMasks[code] else { return nil }
        let down = flags.rawValue & mask != 0
        if down {
            guard heldModifiers.insert(code).inserted else { return nil }
        } else { guard heldModifiers.remove(code) != nil else { return nil } }
        return RemapInput(down ? .down : .up, keyCode: code, modifiers: modifiers)
    }
}
