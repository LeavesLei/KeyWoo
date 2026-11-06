import AppKit
import CoreGraphics
import Testing
@testable import KeyDance

struct RemapEventCodecTests {
    @Test func outputEventsCarryMarkerWithoutPostingAnyEvents() throws {
        let output: RemapOutput = .key(code: 8, isDown: true, isRepeat: false, modifiers: [.command])
        let created = RemapEventCodec.outputEvent(output, source: nil)
        let event = try #require(created)
        #expect(RemapEventMarker.isInjected(event))
        #expect(event.type == .keyDown)
        #expect(event.getIntegerValueField(.keyboardEventKeycode) == 8)
        #expect(event.flags.contains(.maskCommand))
    }
    @Test func mediaEventEncodesPairedSystemDefinedKeys() throws {
        let decoder = RemapInputDecoder()
        for action in RemapMediaAction.allCases {
            let downEvent = RemapEventCodec.outputEvent(.media(action, isDown: true), source: nil)
            let upEvent = RemapEventCodec.outputEvent(.media(action, isDown: false), source: nil)
            let down = try #require(downEvent)
            let up = try #require(upEvent)
            #expect(RemapEventMarker.isInjected(down) && RemapEventMarker.isInjected(up))
            let nativeDown = try #require(NSEvent(cgEvent: down))
            let nativeUp = try #require(NSEvent(cgEvent: up))
            #expect(nativeDown.type == .systemDefined && nativeDown.subtype.rawValue == 8)
            #expect((nativeDown.data1 >> 16) & 0xFFFF == Int(action.nativeKeyType))
            #expect((nativeDown.data1 >> 8) & 0xff == 0xA)
            #expect((nativeUp.data1 >> 8) & 0xff == 0xB)
            #expect(decoder.decodeAuxiliary(nativeDown) == RemapInput(.down, keyCode: action.triggerCode))
            #expect(decoder.decodeAuxiliary(nativeUp) == RemapInput(.up, keyCode: action.triggerCode))
        }
    }
    @Test func consumerAliasesDecodeWithoutConfusingFunctionClassificationForFn() throws {
        func event(_ type: Int, phase: Int = 0xA, repeatBit: Int = 0, subtype: Int16 = 8) throws -> NSEvent {
            try #require(NSEvent.otherEvent(with: .systemDefined, location: .zero,
                modifierFlags: [.function], timestamp: 0, windowNumber: 0, context: nil, subtype: subtype,
                data1: (type << 16) | (phase << 8) | repeatBit, data2: -1))
        }
        var decoder = RemapInputDecoder()
        let fast = try event(19, repeatBit: 1)
        #expect(decoder.decodeAuxiliary(fast) == RemapInput(.down, keyCode: RemapMediaAction.nextTrack.triggerCode,
            isRepeat: true, physicalCode: RemapMediaAction.auxiliaryCode(for: 19)))
        _ = decoder.decode(type: .flagsChanged, code: 63, flags: [.maskSecondaryFn], isRepeat: false)
        let rewind = try event(20)
        #expect(decoder.decodeAuxiliary(rewind) == RemapInput(.down, keyCode: RemapMediaAction.previousTrack.triggerCode,
            modifiers: .fn, physicalCode: RemapMediaAction.auxiliaryCode(for: 20)))
        let unrelated = try event(16, subtype: 7)
        let unknown = try event(100)
        let otherPhase = try event(16, phase: 0)
        #expect(decoder.decodeAuxiliary(unrelated) == nil)
        #expect(decoder.decodeAuxiliary(unknown) == nil)
        #expect(decoder.decodeAuxiliary(otherPhase) == nil)
    }
    @Test func consumerPressFiresOneBalancedShortcutAndSuppressesMatchingEdges() throws {
        let code = RemapMediaAction.nextTrack.triggerCode
        let rule = RemapRule(trigger: RemapTrigger(keyCode: code), action: .key(code: 8, modifiers: .command))
        let profile = RemapProfile(name: "Media source", rules: [rule])
        var machine = RemapStateMachine(profile: profile)
        var edges = RemapConsumerPresses()
        var outputs: [RemapOutput] = []
        func apply(_ tap: RemapInput) -> Bool {
            let decision = machine.process(tap)
            outputs += decision.outputs
            return decision.suppressOriginal
        }
        let suppressedDown = edges.handle(RemapInput(.down, keyCode: code), onPress: apply)
        #expect(suppressedDown)
        #expect(machine.heldOutputKeys.isEmpty)
        #expect(outputs == [
            .key(code: 55, isDown: true, isRepeat: false, modifiers: .command),
            .key(code: 8, isDown: true, isRepeat: false, modifiers: .command),
            .key(code: 8, isDown: false, isRepeat: false, modifiers: .command),
            .key(code: 55, isDown: false, isRepeat: false, modifiers: [])
        ])
        let pendingOutputs = machine.replaceProfile(RemapProfile(name: "Empty"))
        #expect(pendingOutputs.isEmpty)
        let suppressedRepeat = edges.handle(RemapInput(.down, keyCode: code, isRepeat: true), onPress: apply)
        let suppressedUp = edges.handle(RemapInput(.up, keyCode: code), onPress: apply)
        let passedDown = !edges.handle(RemapInput(.down, keyCode: code), onPress: apply)
        let passedUp = !edges.handle(RemapInput(.up, keyCode: code), onPress: apply)
        #expect(suppressedRepeat && suppressedUp)
        #expect(passedDown && passedUp)
        #expect(outputs.count == 4)
        let config = RemapConfiguration(profiles: [profile], activeProfileID: profile.id)
        try RemapValidation.validate(config)
        let restored = try JSONDecoder().decode(RemapConfiguration.self, from: JSONEncoder().encode(config))
        #expect(restored == config)
        #expect(RemapMediaAction.forTriggerCode(17) == nil) // Quartz T, not Next.
    }
    @Test func equivalentConsumerTriggersRetainIndependentPhysicalReleases() {
        let next = RemapMediaAction.nextTrack.triggerCode
        let fast = RemapMediaAction.auxiliaryCode(for: 19)
        var edges = RemapConsumerPresses()
        let nextDown = edges.handle(RemapInput(.down, keyCode: next)) { _ in true }
        let fastDown = edges.handle(RemapInput(.down, keyCode: next, physicalCode: fast)) { _ in true }
        let nextUp = edges.handle(RemapInput(.up, keyCode: next)) { _ in false }
        let fastRepeat = edges.handle(RemapInput(.down, keyCode: next, isRepeat: true, physicalCode: fast)) { _ in false }
        let fastUp = edges.handle(RemapInput(.up, keyCode: next, physicalCode: fast)) { _ in false }
        #expect(nextDown && fastDown && nextUp && fastRepeat && fastUp)
    }
    @Test func flagRewriteRemovesDeviceSpecificBitsAndPreservesKeypadFlag() {
        let original = CGEventFlags(rawValue: 0x80000 | 0x40 | CGEventFlags.maskNumericPad.rawValue)
        let rewritten = RemapEventCodec.flags([.command], preserving: original)
        #expect(!rewritten.contains(.maskAlternate))
        #expect(rewritten.rawValue & 0x60 == 0)
        #expect(rewritten.contains(.maskCommand) && rewritten.contains(.maskNumericPad))
    }
    @Test func leftAndRightModifiersHaveDistinctReleaseAndCapsIsTransient() {
        var decoder = RemapInputDecoder()
        decoder.reset(flags: [])
        let left = decoder.decode(type: .flagsChanged, code: 56, flags: CGEventFlags(rawValue: 0x20002), isRepeat: false)
        let right = decoder.decode(type: .flagsChanged, code: 60, flags: CGEventFlags(rawValue: 0x20006), isRepeat: false)
        let leftUp = decoder.decode(type: .flagsChanged, code: 56, flags: CGEventFlags(rawValue: 0x20004), isRepeat: false)
        #expect(left?.kind == .down && right?.kind == .down && leftUp?.kind == .up)
        let caps = decoder.decode(type: .flagsChanged, code: 57, flags: [.maskAlphaShift], isRepeat: false)
        #expect(caps?.kind == .tap)
        let duplicate = decoder.decode(type: .flagsChanged, code: 57, flags: [.maskAlphaShift], isRepeat: false)
        #expect(duplicate == nil)
    }

    @Test func intrinsicFKeysArrowsAndJISModeKeysAreNotMistakenForHeldFn() {
        var decoder = RemapInputDecoder()
        decoder.reset(flags: [.maskSecondaryFn]) // Ambiguous startup aggregate bit.
        for code: UInt16 in [122, 90, 123, 126, 102, 104] {
            let input = decoder.decode(type: .keyDown, code: code,
                flags: [.maskSecondaryFn, .maskNumericPad], isRepeat: false)
            #expect(input?.modifiers.contains(.fn) == false)
            let rewritten = RemapEventCodec.flags([], preserving: [.maskSecondaryFn, .maskNumericPad], keyCode: code)
            #expect(rewritten.contains(.maskSecondaryFn) && rewritten.contains(.maskNumericPad))
        }
    }

    @Test func fnSpaceAndJISPrintingKeyKeepReportedFnEvenWithoutPriorFnDown() {
        var decoder = RemapInputDecoder()
        decoder.reset(flags: [])
        for code: UInt16 in [49, 93, 94, 95] {
            let input = decoder.decode(type: .keyDown, code: code, flags: [.maskSecondaryFn], isRepeat: false)
            #expect(input?.modifiers.contains(.fn) == true)
        }
    }

    @Test func observedOrPhysicallySeededFnDisambiguatesFnWithFunctionKeys() {
        var decoder = RemapInputDecoder()
        decoder.reset(flags: [])
        _ = decoder.decode(type: .flagsChanged, code: 63, flags: [.maskSecondaryFn], isRepeat: false)
        let observed = decoder.decode(type: .keyDown, code: 122, flags: [.maskSecondaryFn], isRepeat: false)
        #expect(observed?.modifiers.contains(.fn) == true)
        _ = decoder.decode(type: .flagsChanged, code: 63, flags: [], isRepeat: false)
        let released = decoder.decode(type: .keyDown, code: 122, flags: [.maskSecondaryFn], isRepeat: false)
        #expect(released?.modifiers.contains(.fn) == false)
        decoder.reset(flags: [.maskSecondaryFn], fnIsPhysicallyDown: true)
        let seeded = decoder.decode(type: .keyDown, code: 90, flags: [.maskSecondaryFn], isRepeat: false)
        #expect(seeded?.modifiers.contains(.fn) == true)
    }

    @Test func emittedFunctionKeysCarryIntrinsicFlagButOrdinaryKeysDoNot() throws {
        for code: UInt16 in [122, 90, 123, 102, 104] {
            let created = RemapEventCodec.outputEvent(.key(code: code, isDown: true, isRepeat: false, modifiers: []), source: nil)
            let event = try #require(created)
            #expect(event.flags.contains(.maskSecondaryFn))
        }
        let created = RemapEventCodec.outputEvent(.key(code: 49, isDown: true, isRepeat: false, modifiers: []), source: nil)
        let ordinary = try #require(created)
        #expect(!ordinary.flags.contains(.maskSecondaryFn))
    }

    @Test func rightSideModifierOutputsUseTheirActualDeviceBits() throws {
        for (code, group, bit, unwanted): (UInt16, RemapModifiers, UInt64, UInt64) in [
            (60, .shift, 0x4, 0x2), (62, .control, 0x2000, 0x1),
            (61, .option, 0x40, 0x20), (54, .command, 0x10, 0x8)
        ] {
            let created = RemapEventCodec.outputEvent(.key(code: code, isDown: true, isRepeat: false, modifiers: group), source: nil)
            let event = try #require(created)
            #expect(event.type == .flagsChanged)
            #expect(event.flags.rawValue & bit != 0 && event.flags.rawValue & unwanted == 0)
        }
    }

    @Test func bothSyntheticModifierSidesAreProjectedAtEveryOrderedEdge() throws {
        let outputs: [RemapOutput] = [
            .key(code: 59, isDown: true, isRepeat: false, modifiers: [.control]),
            .key(code: 62, isDown: true, isRepeat: false, modifiers: [.control])
        ]
        let down = RemapEventCodec.outputEvents(outputs, source: nil, physicalFlags: [],
            finalHeldKeys: [59, 62], suppressedPhysicalKeys: [])
        #expect(down.count == 2)
        #expect(down[0].flags.rawValue & 0x2001 == 0x1)
        #expect(down[1].flags.rawValue & 0x2001 == 0x2001)
        let up = RemapEventCodec.outputEvents([
            .key(code: 59, isDown: false, isRepeat: false, modifiers: [.control]),
            .key(code: 62, isDown: false, isRepeat: false, modifiers: [])
        ], source: nil, physicalFlags: [], finalHeldKeys: [], suppressedPhysicalKeys: [])
        #expect(up.count == 2)
        #expect(up[0].flags.rawValue & 0x2001 == 0x2000)
        #expect(!up[1].flags.contains(.maskControl))
    }

    @Test func quarantinedPhysicalSideIsRemovedWhileOtherRealAndSyntheticSidesSurvive() {
        let flags = RemapEventCodec.flags([.option, .control],
            preserving: CGEventFlags(rawValue: 0x80060), keyCode: 4,
            heldModifierKeys: [62], suppressedPhysicalKeys: [61])
        #expect(flags.rawValue & 0x60 == 0x20)
        #expect(flags.rawValue & 0x2001 == 0x2000)
    }

    @Test func physicalRightControlAndSyntheticLeftControlReleaseIndependently() {
        let output: [RemapOutput] = [.key(code: 59, isDown: false, isRepeat: false, modifiers: [.control])]
        let events = RemapEventCodec.outputEvents(output, source: nil,
            physicalFlags: CGEventFlags(rawValue: 0x42000), finalHeldKeys: [], suppressedPhysicalKeys: [])
        #expect(events.count == 1)
        #expect(events[0].flags.rawValue & 0x2001 == 0x2000)
    }

    @Test func lostReleaseRecoveryAllowsTheNextFreshModifierDownWithoutResettingHeldFn() throws {
        var decoder = RemapInputDecoder()
        var state = RemapStateMachine(profile: .init(name: "test", rules: [
            .init(trigger: .init(keyCode: 61, allowsExtraModifiers: true), action: .key(code: 55, modifiers: []))
        ]))
        decoder.reset(flags: [])
        let firstInput = decoder.decode(type: .flagsChanged, code: 61, flags: CGEventFlags(rawValue: 0x80040), isRepeat: false)
        let first = try #require(firstInput)
        _ = state.process(first)
        let fnInput = decoder.decode(type: .flagsChanged, code: 63, flags: CGEventFlags(rawValue: 0x880040), isRepeat: false)
        let fnDown = try #require(fnInput)
        _ = state.process(fnDown)
        let recovered = state.releaseMissingKeys { $0 == 63 }
        decoder.releaseMissingModifiers { $0 == 63 }
        #expect(recovered == [.key(code: 55, isDown: false, isRepeat: false, modifiers: [.fn])])
        let newInput = decoder.decode(type: .flagsChanged, code: 61, flags: CGEventFlags(rawValue: 0x880040), isRepeat: false)
        let second = try #require(newInput)
        let mapped = state.process(second)
        #expect(mapped.outputs == [.key(code: 55, isDown: true, isRepeat: false, modifiers: [.command, .fn])])
        let fnF20 = decoder.decode(type: .keyDown, code: 90, flags: [.maskSecondaryFn], isRepeat: false)
        #expect(fnF20?.modifiers.contains(.fn) == true)
    }
}
