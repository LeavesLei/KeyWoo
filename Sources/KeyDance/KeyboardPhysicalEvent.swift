import AppKit
import CoreGraphics

/// A short-lived physical edge shared by the passive monitor and remap filter.
/// Carries key positions and flags only, never characters or entered text.
struct KeyboardPhysicalEvent: Sendable {
    enum Kind: Hashable, Sendable { case down, up, flagsChanged, auxiliaryTap }
    let kind: Kind
    let code: UInt16
    let flags: UInt64
    let isRepeat: Bool
    let timestamp: UInt64

    init(kind: Kind, code: UInt16, flags: UInt64 = 0, isRepeat: Bool = false, timestamp: UInt64) {
        self.kind = kind; self.code = code; self.flags = flags
        self.isRepeat = isRepeat; self.timestamp = timestamp
    }

    init?(type: CGEventType, event: CGEvent) {
        guard !RemapEventMarker.isInjected(event) else { return nil }
        if type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue) {
            guard let native = NSEvent(cgEvent: event),
                  let input = RemapInputDecoder().decodeAuxiliary(native),
                  input.kind == .down, !input.isRepeat else { return nil }
            // Consumer keys have no pollable Quartz held state. Like the remap
            // backend, use one transient tap per fresh press, never OS repeats.
            self.init(kind: .auxiliaryTap, code: input.physicalCode, flags: event.flags.rawValue,
                      timestamp: event.timestamp)
            return
        }
        let kind: Kind
        switch type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .flagsChanged
        default: return nil
        }
        self.init(kind: kind, code: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                  flags: event.flags.rawValue,
                  isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                  timestamp: event.timestamp)
    }

    init?(nativeEvent: NSEvent) {
        guard let event = nativeEvent.cgEvent else { return nil }
        self.init(type: event.type, event: event)
    }
}

/// Stores only the newest timestamp per physical key, not an input history.
/// Passive taps and the remap worker can deliver the same original edge in
/// either order. A held-key filter alone fails when a delayed duplicate down
/// arrives after the matching up; timestamp admission prevents that replay.
struct KeyboardPhysicalEventGate {
    private struct Edge: Hashable {
        let kind: KeyboardPhysicalEvent.Kind
        let modifierFlags: UInt64
    }
    private struct Latest {
        var timestamp: UInt64
        var edges: Set<Edge>
    }
    private var latest: [UInt16: Latest] = [:]
    private var minimumTimestamp: UInt64 = 0

    mutating func reset(ignoringEventsBefore timestamp: UInt64) {
        latest.removeAll(keepingCapacity: true)
        minimumTimestamp = timestamp
    }

    mutating func transition(for event: KeyboardPhysicalEvent, filter: inout KeyboardPressFilter) -> KeyboardPressFilter.Transition? {
        // A repeat is not a physical edge and must not advance admission past
        // an original down still being delivered by the other event source.
        guard !event.isRepeat, admit(event) else { return nil }
        switch event.kind {
        case .auxiliaryTap: return .tap
        case .down: return filter.transition(kind: .keyDown, code: event.code, flags: event.flags, isRepeat: event.isRepeat)
        case .up: return filter.transition(kind: .keyUp, code: event.code, flags: event.flags)
        case .flagsChanged: return filter.transition(kind: .flagsChanged, code: event.code, flags: event.flags)
        }
    }

    private mutating func admit(_ event: KeyboardPhysicalEvent) -> Bool {
        guard event.timestamp >= minimumTimestamp else { return false }
        let edge = Edge(kind: event.kind, modifierFlags: event.kind == .flagsChanged ? event.flags : 0)
        if var previous = latest[event.code] {
            guard event.timestamp >= previous.timestamp else { return false }
            if event.timestamp == previous.timestamp {
                guard previous.edges.insert(edge).inserted else { return false }
                latest[event.code] = previous
                return true
            }
        }
        latest[event.code] = Latest(timestamp: event.timestamp, edges: [edge])
        return true
    }
}
