import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import KeyDance

struct KeyboardPhysicalEventTests {
    private func ordinary(_ type: CGEventType, code: UInt16, at timestamp: UInt64,
                          flags: CGEventFlags = [], repeating: Bool = false) throws -> CGEvent {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp))
        event.type = type; event.flags = flags; event.timestamp = timestamp
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return event
    }
    private func media(_ nativeCode: UInt16 = 16, phase: Int = 0xA,
                       repeating: Bool = false, at timestamp: UInt64 = 100) throws -> CGEvent {
        let native = try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, subtype: 8,
            data1: (Int(nativeCode) << 16) | (phase << 8) | (repeating ? 1 : 0), data2: -1))
        let event = try #require(native.cgEvent)
        event.timestamp = timestamp
        return event
    }

    @Test func physicalMediaPressIsOneTapAndDoesNotInventASpacePress() throws {
        for native: UInt16 in [0, 1, 2, 3, 7, 16, 17, 18, 19, 20, 21, 22] {
            let down = try media(native)
            let input = try #require(KeyboardPhysicalEvent(type: down.type, event: down))
            #expect(input.kind == .auxiliaryTap)
            #expect(input.code == RemapMediaAction.auxiliaryCode(for: native))
            #expect(input.code != 49)
            #expect(KeyLayout.label(for: input.code) == L(RemapMediaAction.forNativeKeyType(native)!.title))
            var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
            let first = gate.transition(for: input, filter: &filter)
            let duplicate = gate.transition(for: input, filter: &filter)
            #expect(first == .tap && duplicate == nil && filter.heldKeys.isEmpty)
            let repeatEvent = try media(native, repeating: true, at: 101)
            let up = try media(native, phase: 0xB, at: 102)
            #expect(KeyboardPhysicalEvent(type: repeatEvent.type, event: repeatEvent) == nil)
            #expect(KeyboardPhysicalEvent(type: up.type, event: up) == nil)
        }
    }

    @Test func generatedMediaAndKeyOutputsNeverBecomePhysicalFeedback() throws {
        for output in [RemapOutput.media(.playPause, isDown: true), .media(.playPause, isDown: false),
                       .key(code: 49, isDown: true, isRepeat: false, modifiers: .fn)] {
            let event = try #require(RemapEventCodec.outputEvent(output, source: nil))
            #expect(RemapEventMarker.isInjected(event))
            #expect(KeyboardPhysicalEvent(type: event.type, event: event) == nil)
            if let native = NSEvent(cgEvent: event) { #expect(KeyboardPhysicalEvent(nativeEvent: native) == nil) }
        }
    }

    @Test func consumedFnSpaceKeepsBothPhysicalPressesAndIgnoresSynthesizedMedia() throws {
        var state = RemapStateMachine(profile: RemapProfile(name: "Test", rules: [
            .init(trigger: .init(keyCode: 49, modifiers: .fn), action: .media(.playPause))
        ]))
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        var presses: [UInt16] = []
        let fn = try ordinary(.flagsChanged, code: 63, at: 100, flags: .maskSecondaryFn)
        let spaceDown = try ordinary(.keyDown, code: 49, at: 200, flags: .maskSecondaryFn)
        let spaceUp = try ordinary(.keyUp, code: 49, at: 300, flags: .maskSecondaryFn)
        let fnUp = try ordinary(.flagsChanged, code: 63, at: 400)
        let decision = state.process(.init(.down, keyCode: 49, modifiers: .fn))
        #expect(decision.suppressOriginal && decision.outputs == [.media(.playPause, isDown: true)])
        // Fn reaches the passive listener; the swallowed Space uses the bridge.
        // All four pass through the same production decoder/admission/filter.
        for event in [fn, spaceDown, spaceUp, fnUp] {
            let input = try #require(KeyboardPhysicalEvent(type: event.type, event: event))
            if gate.transition(for: input, filter: &filter) == .down { presses.append(input.code) }
        }
        #expect(presses == [63, 49])
        #expect(filter.heldKeys.isEmpty)
        let output = try #require(RemapEventCodec.outputEvent(decision.outputs[0], source: nil))
        #expect(KeyboardPhysicalEvent(type: output.type, event: output) == nil)
    }

    @Test func delayedDuplicateDownAfterReleaseCannotSoundOrCountAgain() throws {
        let down = try ordinary(.keyDown, code: 49, at: 100)
        let up = try ordinary(.keyUp, code: 49, at: 200)
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        var transitions: [KeyboardPressFilter.Transition] = []
        // Works for either passive-first or bridge-first, including when an
        // entire duplicate pair arrives after the first source's release.
        for event in [down, up, down, up, down, up] {
            let input = try #require(KeyboardPhysicalEvent(type: event.type, event: event))
            if let edge = gate.transition(for: input, filter: &filter) { transitions.append(edge) }
        }
        #expect(transitions == [.down, .up] && filter.heldKeys.isEmpty)
    }

    @Test func fnCanStayHeldAcrossManySpacePressesWithDuplicatesAndRepeats() {
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        let fn = KeyboardPhysicalEvent(kind: .flagsChanged, code: 63, flags: 0x800000, timestamp: 1)
        #expect(gate.transition(for: fn, filter: &filter) == .down)
        var attacks = 0
        for index in 0..<50 {
            let start = UInt64(index * 3 + 10)
            let down = KeyboardPhysicalEvent(kind: .down, code: 49, flags: 0x800000, timestamp: start)
            let repeated = KeyboardPhysicalEvent(kind: .down, code: 49, flags: 0x800000, isRepeat: true, timestamp: start + 1)
            let up = KeyboardPhysicalEvent(kind: .up, code: 49, flags: 0x800000, timestamp: start + 2)
            for input in [down, down, repeated, up, down, up] {
                if gate.transition(for: input, filter: &filter) == .down { attacks += 1 }
            }
        }
        #expect(attacks == 50 && filter.heldKeys == [63])
        #expect(gate.transition(for: .init(kind: .flagsChanged, code: 63, timestamp: 200), filter: &filter) == .up)
        #expect(filter.heldKeys.isEmpty)
    }

    @Test func distinctEdgesAtTheSameTimestampReleaseButDuplicateCopiesDoNotReplay() {
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        let down = KeyboardPhysicalEvent(kind: .down, code: 49, timestamp: 100)
        let up = KeyboardPhysicalEvent(kind: .up, code: 49, timestamp: 100)
        #expect(gate.transition(for: down, filter: &filter) == .down)
        #expect(gate.transition(for: up, filter: &filter) == .up)
        #expect(gate.transition(for: down, filter: &filter) == nil)
        #expect(gate.transition(for: up, filter: &filter) == nil)
        let fnDown = KeyboardPhysicalEvent(kind: .flagsChanged, code: 63, flags: 0x800000, timestamp: 200)
        let fnUp = KeyboardPhysicalEvent(kind: .flagsChanged, code: 63, timestamp: 200)
        #expect(gate.transition(for: fnDown, filter: &filter) == .down)
        #expect(gate.transition(for: fnUp, filter: &filter) == .up)
        #expect(gate.transition(for: fnDown, filter: &filter) == nil)
        #expect(filter.heldKeys.isEmpty)
    }

    @Test func earlierOriginalDownIsNotDiscardedBecauseARepeatArrivedFirst() {
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        let repeated = KeyboardPhysicalEvent(kind: .down, code: 49, isRepeat: true, timestamp: 200)
        let original = KeyboardPhysicalEvent(kind: .down, code: 49, timestamp: 100)
        let up = KeyboardPhysicalEvent(kind: .up, code: 49, timestamp: 300)
        #expect(gate.transition(for: repeated, filter: &filter) == nil)
        #expect(gate.transition(for: original, filter: &filter) == .down)
        #expect(gate.transition(for: up, filter: &filter) == .up)
        #expect(gate.transition(for: original, filter: &filter) == nil)
        #expect(filter.heldKeys.isEmpty)
    }

    @Test func resetBoundaryRejectsQueuedOldBridgeAndFreshInputStillWorks() {
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        gate.reset(ignoringEventsBefore: 300)
        let old = KeyboardPhysicalEvent(kind: .down, code: 49, timestamp: 200)
        let fresh = KeyboardPhysicalEvent(kind: .down, code: 49, timestamp: 400)
        #expect(gate.transition(for: old, filter: &filter) == nil)
        #expect(gate.transition(for: fresh, filter: &filter) == .down)
        #expect(filter.heldKeys == [49])
    }

    @Test @MainActor func physicalMediaAndConsumedSpaceProducePCMExactlyOnce() throws {
        let engine = KeyboardSoundEngine(audioDeviceEnabled: false)
        engine.style = .blue; engine.start()
        defer { engine.stop() }
        var gate = KeyboardPhysicalEventGate(), filter = KeyboardPressFilter()
        var counts: [UInt16: Int] = [:]
        let down = try ordinary(.keyDown, code: 49, at: 100, flags: .maskSecondaryFn)
        let up = try ordinary(.keyUp, code: 49, at: 200)
        let media = try media(at: 300)
        for event in [down, up, down, up, media, media] {
            let input = try #require(KeyboardPhysicalEvent(type: event.type, event: event))
            switch gate.transition(for: input, filter: &filter) {
            case .down:
                counts[input.code, default: 0] += 1; engine.noteOn(keyCode: input.code)
            case .up: engine.noteOff(keyCode: input.code)
            case .tap:
                counts[input.code, default: 0] += 1
                engine.noteOn(keyCode: input.code); engine.noteOff(keyCode: input.code)
            case nil: break
            }
        }
        let pcm = engine.renderForVerification(frames: 12_000)
        #expect(pcm.allSatisfy(\.isFinite) && pcm.contains { abs($0) > 0.0001 })
        #expect(counts == [49: 1, RemapMediaAction.playPause.triggerCode: 1])
        #expect(engine.diagnostics.attacks == 2 && engine.diagnostics.releases == 2)
        #expect(engine.heldKeyCount == 0)
    }
}
