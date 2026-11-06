import Foundation
import Testing
@testable import KeyDance

struct RemapStateMachineTests {
    private func machine(_ rules: [RemapRule], layers: [RemapLayer] = [], keys: [RemapLayerKey] = []) -> RemapStateMachine {
        RemapStateMachine(profile: RemapProfile(name: "test", layers: layers, layerKeys: keys, rules: rules))
    }
    private func keyRule(_ source: UInt16, _ target: UInt16, modifiers: RemapModifiers = [],
                         output: RemapModifiers = [], extras: Bool = false) -> RemapRule {
        RemapRule(trigger: .init(keyCode: source, modifiers: modifiers, allowsExtraModifiers: extras),
                  action: .key(code: target, modifiers: output))
    }

    @Test func mappedDownRepeatAndUpRetainOneOutputIdentity() {
        var state = machine([keyRule(0, 11)])
        let down = state.process(.init(.down, keyCode: 0))
        #expect(down.suppressOriginal)
        #expect(down.outputs == [.key(code: 11, isDown: true, isRepeat: false, modifiers: [])])
        let duplicate = state.process(.init(.down, keyCode: 0))
        #expect(duplicate.outputs.isEmpty)
        for _ in 0..<50 {
            let repeated = state.process(.init(.down, keyCode: 0, isRepeat: true))
            #expect(repeated.outputs == [.key(code: 11, isDown: true, isRepeat: true, modifiers: [])])
        }
        let up = state.process(.init(.up, keyCode: 0))
        #expect(up.suppressOriginal)
        #expect(up.outputs == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])])
        #expect(state.heldOutputKeys.isEmpty)
    }

    @Test func globalMediaChordFiresOnceAndReleasesAfterModifiersChange() {
        var state = machine([.init(trigger: .init(keyCode: 49, modifiers: [.fn]), action: .media(.playPause))])
        let down = state.process(.init(.down, keyCode: 49, modifiers: [.fn]))
        #expect(down.outputs == [.media(.playPause, isDown: true)])
        for _ in 0..<100 {
            let repeated = state.process(.init(.down, keyCode: 49, modifiers: [], isRepeat: true))
            #expect(repeated.suppressOriginal && repeated.outputs.isEmpty)
        }
        let up = state.process(.init(.up, keyCode: 49))
        #expect(up.outputs == [.media(.playPause, isDown: false)])
    }

    @Test func exactChordDoesNotConsumeAdditionalModifiers() {
        var state = machine([keyRule(49, 36, modifiers: [.control])])
        let decision = state.process(.init(.down, keyCode: 49, modifiers: [.control, .shift]))
        #expect(!decision.suppressOriginal && decision.outputs.isEmpty)
    }

    @Test func bareRemapCanPreserveExtraModifiersForShortcuts() {
        var state = machine([keyRule(0, 11, extras: true)])
        let decision = state.process(.init(.down, keyCode: 0, modifiers: [.shift, .command]))
        #expect(decision.outputs == [.key(code: 11, isDown: true, isRepeat: false, modifiers: [.shift, .command])])
    }

    @Test func chordOutputHasOrderedModifierDownAndUp() {
        var state = machine([keyRule(0, 8, output: [.command, .shift])])
        let down = state.process(.init(.down, keyCode: 0))
        #expect(down.outputs == [
            .key(code: 56, isDown: true, isRepeat: false, modifiers: [.shift]),
            .key(code: 55, isDown: true, isRepeat: false, modifiers: [.shift, .command]),
            .key(code: 8, isDown: true, isRepeat: false, modifiers: [.shift, .command])
        ])
        let up = state.process(.init(.up, keyCode: 0))
        #expect(up.outputs == [
            .key(code: 8, isDown: false, isRepeat: false, modifiers: [.shift, .command]),
            .key(code: 55, isDown: false, isRepeat: false, modifiers: [.shift]),
            .key(code: 56, isDown: false, isRepeat: false, modifiers: [])
        ])
    }

    @Test func modifierRemapChangesUnmappedKeyFlagsAndReleasesCleanly() {
        var state = machine([keyRule(61, 55)])
        let down = state.process(.init(.down, keyCode: 61, modifiers: [.option]))
        #expect(down.outputs == [.key(code: 55, isDown: true, isRepeat: false, modifiers: [.command])])
        let letter = state.process(.init(.down, keyCode: 0, modifiers: [.option]))
        #expect(!letter.suppressOriginal)
        #expect(letter.passthroughModifiers == [.command])
        let up = state.process(.init(.up, keyCode: 61))
        #expect(up.outputs == [.key(code: 55, isDown: false, isRepeat: false, modifiers: [])])
    }

    @Test func hardwareControlCanRemainHeldAcrossAnOrdinaryKey() {
        var state = machine([keyRule(59, 58)])
        let down = state.process(.init(.down, keyCode: 59, modifiers: [.control]))
        #expect(down.outputs == [.key(code: 58, isDown: true, isRepeat: false, modifiers: [.option])])
        let a = state.process(.init(.down, keyCode: 0, modifiers: [.control]))
        #expect(a.passthroughModifiers == [.option])
        #expect(state.heldOutputKeys == [58])
        let up = state.process(.init(.up, keyCode: 59))
        #expect(up.outputs == [.key(code: 58, isDown: false, isRepeat: false, modifiers: [])])
        #expect(state.heldOutputKeys.isEmpty)
    }

    @Test func holdingLayerDoesNotLeakOptionAndUnboundKeysStayTransparent() {
        let layer = RemapLayer(name: "Navigation")
        var state = machine([
            .init(trigger: .init(keyCode: 4, layerID: layer.id), action: .key(code: 123, modifiers: []))
        ], layers: [layer], keys: [.init(keyCode: 61, layerID: layer.id)])
        let held = state.process(.init(.down, keyCode: 61, modifiers: [.option]))
        #expect(held.suppressOriginal)
        let mapped = state.process(.init(.down, keyCode: 4, modifiers: [.option]))
        #expect(mapped.outputs == [.key(code: 123, isDown: true, isRepeat: false, modifiers: [])])
        let transparent = state.process(.init(.down, keyCode: 1, modifiers: [.option]))
        #expect(!transparent.suppressOriginal && transparent.passthroughModifiers == [])
        _ = state.process(.init(.up, keyCode: 61))
        #expect(state.activeLayerIDs.isEmpty)
        let releaseMapped = state.process(.init(.up, keyCode: 4))
        #expect(releaseMapped.outputs == [.key(code: 123, isDown: false, isRepeat: false, modifiers: [])])
    }

    @Test func capsLayerTogglesOnTransientPressWithoutStuckHold() {
        let layer = RemapLayer(name: "Fn")
        var state = machine([], layers: [layer], keys: [.init(keyCode: 57, layerID: layer.id, mode: .toggle)])
        let first = state.process(.init(.tap, keyCode: 57, modifiers: [.capsLock]))
        #expect(first.suppressOriginal && state.activeLayerIDs == [layer.id])
        let letter = state.process(.init(.down, keyCode: 0, modifiers: [.capsLock]))
        #expect(letter.passthroughModifiers == [])
        #expect(!state.physicalHeld.contains(57))
        _ = state.process(.init(.tap, keyCode: 57))
        #expect(state.activeLayerIDs.isEmpty)
    }

    @Test func toggleAndHoldOwnersOfSameLayerDoNotCancelEachOther() {
        let layer = RemapLayer(name: "Fn")
        var state = machine([], layers: [layer], keys: [
            .init(keyCode: 61, layerID: layer.id), .init(keyCode: 57, layerID: layer.id, mode: .toggle)
        ])
        _ = state.process(.init(.tap, keyCode: 57, modifiers: [.capsLock]))
        _ = state.process(.init(.down, keyCode: 61, modifiers: [.option, .capsLock]))
        _ = state.process(.init(.up, keyCode: 61, modifiers: [.capsLock]))
        #expect(state.activeLayerIDs == [layer.id])
        _ = state.process(.init(.down, keyCode: 61, modifiers: [.option, .capsLock]))
        _ = state.process(.init(.tap, keyCode: 57, modifiers: [.option]))
        #expect(state.activeLayerIDs == [layer.id])
        _ = state.process(.init(.up, keyCode: 61))
        #expect(state.activeLayerIDs.isEmpty)
    }

    @Test func transientCapsMediaHasExactlyOneDownAndOneUp() {
        var state = machine([.init(trigger: .init(keyCode: 57), action: .media(.playPause))])
        let result = state.process(.init(.tap, keyCode: 57, modifiers: [.capsLock]))
        #expect(result.outputs == [.media(.playPause, isDown: true), .media(.playPause, isDown: false)])
        #expect(state.physicalHeld.isEmpty && state.heldOutputKeys.isEmpty)
        let letter = state.process(.init(.down, keyCode: 0, modifiers: [.capsLock]))
        #expect(letter.passthroughModifiers == [])
        _ = state.process(.init(.up, keyCode: 0, modifiers: [.capsLock]))
        _ = state.process(.init(.tap, keyCode: 57))
        let afterSecond = state.process(.init(.down, keyCode: 0))
        #expect(afterSecond.passthroughModifiers == [])
    }

    @Test func twoSourcesShareOutputUntilBothRelease() {
        var state = machine([keyRule(0, 11), keyRule(1, 11)])
        _ = state.process(.init(.down, keyCode: 0))
        let second = state.process(.init(.down, keyCode: 1))
        #expect(second.outputs.isEmpty)
        let firstUp = state.process(.init(.up, keyCode: 0))
        #expect(firstUp.outputs.isEmpty && state.heldOutputKeys == [11])
        let lastUp = state.process(.init(.up, keyCode: 1))
        #expect(lastUp.outputs == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])])
    }

    @Test func physicalOutputKeyCannotBeReleasedByItsRemappedPartner() {
        for physicalFirst in [true, false] {
            var state = machine([keyRule(0, 11)])
            if physicalFirst { _ = state.process(.init(.down, keyCode: 11)) }
            _ = state.process(.init(.down, keyCode: 0))
            if !physicalFirst { _ = state.process(.init(.down, keyCode: 11)) }
            let mappedUp = state.process(.init(.up, keyCode: 0))
            #expect(mappedUp.outputs.isEmpty)
            let physicalUp = state.process(.init(.up, keyCode: 11))
            #expect(!physicalUp.suppressOriginal)
        }
    }

    @Test func physicalOutputReleaseCannotEndSyntheticHold() {
        var state = machine([keyRule(0, 11)])
        _ = state.process(.init(.down, keyCode: 11))
        _ = state.process(.init(.down, keyCode: 0))
        let physicalUp = state.process(.init(.up, keyCode: 11))
        #expect(physicalUp.suppressOriginal)
        let syntheticUp = state.process(.init(.up, keyCode: 0))
        #expect(syntheticUp.outputs == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])])
    }

    @Test func mappedPhysicalTargetIsNotMistakenForVisibleTargetOwnership() {
        var state = machine([keyRule(0, 11), keyRule(11, 8)])
        _ = state.process(.init(.down, keyCode: 0))
        let b = state.process(.init(.down, keyCode: 11))
        #expect(b.outputs == [.key(code: 8, isDown: true, isRepeat: false, modifiers: [])])
        let aUp = state.process(.init(.up, keyCode: 0))
        #expect(aUp.outputs == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])])
        #expect(state.heldOutputKeys == [8])
        let bUp = state.process(.init(.up, keyCode: 11))
        #expect(bUp.outputs == [.key(code: 8, isDown: false, isRepeat: false, modifiers: [])])
    }

    @Test func reconfigurationQuarantinesHeldLayerModifierFlagsUntilRelease() {
        let layer = RemapLayer(name: "navigation")
        let profile = RemapProfile(name: "test", layers: [layer], layerKeys: [.init(keyCode: 61, layerID: layer.id)])
        var state = RemapStateMachine(profile: profile)
        _ = state.process(.init(.down, keyCode: 61, modifiers: [.option]))
        _ = state.replaceProfile(profile)
        let h = state.process(.init(.down, keyCode: 4, modifiers: [.option]))
        #expect(!h.suppressOriginal && h.passthroughModifiers == [])
        #expect(state.suppressedPhysicalModifierKeyCodes == [61])
        _ = state.process(.init(.up, keyCode: 61))
        #expect(state.suppressedPhysicalModifierKeyCodes.isEmpty)
    }

    @Test func quarantiningRightOptionDoesNotLosePhysicallyHeldLeftOption() {
        let layer = RemapLayer(name: "navigation")
        let profile = RemapProfile(name: "test", layers: [layer], layerKeys: [.init(keyCode: 61, layerID: layer.id)])
        var state = RemapStateMachine(profile: profile)
        _ = state.process(.init(.down, keyCode: 58, modifiers: [.option]))
        _ = state.process(.init(.down, keyCode: 61, modifiers: [.option]))
        _ = state.replaceProfile(profile)
        let h = state.process(.init(.down, keyCode: 4, modifiers: [.option]))
        #expect(h.passthroughModifiers == [.option])
        #expect(state.physicalHeld.contains(58))
        _ = state.process(.init(.up, keyCode: 58, modifiers: [.option]))
        let next = state.process(.init(.down, keyCode: 38, modifiers: [.option]))
        #expect(next.passthroughModifiers == [])
    }

    @Test func releaseAllDoesNotReleaseRealModifierSharingItsOutputCode() {
        var state = machine([keyRule(0, 62, extras: true)])
        _ = state.process(.init(.down, keyCode: 62, modifiers: [.control]))
        let mapped = state.process(.init(.down, keyCode: 0, modifiers: [.control]))
        #expect(mapped.outputs.isEmpty)
        let reset = state.releaseAll()
        #expect(reset.isEmpty && state.heldOutputKeys.isEmpty)
        #expect(state.physicalHeld == [62])
        let physicalUp = state.process(.init(.up, keyCode: 62))
        #expect(!physicalUp.suppressOriginal)
    }

    @Test func preexistingHeldNormalKeyIsSeededAsVisibleOwnerBeforeEnablingRemap() {
        var state = machine([keyRule(0, 11)])
        state.seedPhysicalKeys([11])
        let mapped = state.process(.init(.down, keyCode: 0))
        #expect(mapped.outputs.isEmpty)
        let mappedUp = state.process(.init(.up, keyCode: 0))
        #expect(mappedUp.outputs.isEmpty)
        #expect(state.physicalHeld == [11])
        let oldPhysicalUp = state.process(.init(.up, keyCode: 11))
        #expect(!oldPhysicalUp.suppressOriginal)
    }

    @Test func lifecycleReseedingCannotRestoreAQuarantinedSourceAsPassthrough() {
        var state = machine([keyRule(0, 11)])
        _ = state.process(.init(.down, keyCode: 0))
        _ = state.releaseAll()
        state.seedPhysicalKeys([0, 59])
        #expect(state.physicalHeld == [59])
        let repeated = state.process(.init(.down, keyCode: 0, isRepeat: true))
        #expect(repeated.suppressOriginal && repeated.outputs.isEmpty)
    }

    @Test func resetReleasesKeysBeforeModifiersAndQuarantinesTheirOldSources() {
        var state = machine([keyRule(0, 8, output: [.command])])
        _ = state.process(.init(.down, keyCode: 0))
        let releases = state.releaseAll()
        #expect(releases == [.key(code: 8, isDown: false, isRepeat: false, modifiers: [.command]),
                             .key(code: 55, isDown: false, isRepeat: false, modifiers: [])])
        let repeatAfterReset = state.process(.init(.down, keyCode: 0, isRepeat: true))
        #expect(repeatAfterReset.suppressOriginal && repeatAfterReset.outputs.isEmpty)
        let oldUp = state.process(.init(.up, keyCode: 0))
        #expect(oldUp.suppressOriginal && oldUp.outputs.isEmpty)
        let newPress = state.process(.init(.down, keyCode: 0))
        #expect(newPress.outputs.count == 2)
    }

    @Test func changingRuleWhileHeldCannotProduceMismatchedKeyUp() {
        var state = machine([keyRule(0, 11)])
        _ = state.process(.init(.down, keyCode: 0))
        let releases = state.replaceProfile(RemapProfile(name: "new", rules: [keyRule(0, 8)]))
        #expect(releases == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])])
        let oldUp = state.process(.init(.up, keyCode: 0))
        #expect(oldUp.outputs.isEmpty)
        let nextDown = state.process(.init(.down, keyCode: 0))
        #expect(nextDown.outputs == [.key(code: 8, isDown: true, isRepeat: false, modifiers: [])])
    }

    @Test func lostReleaseRecoveryOnlyEndsMissingKeys() {
        var state = machine([keyRule(0, 11), keyRule(1, 8)])
        _ = state.process(.init(.down, keyCode: 0)); _ = state.process(.init(.down, keyCode: 1))
        let recovery = state.releaseMissingKeys { $0 == 1 }
        #expect(recovery == [.key(code: 11, isDown: false, isRepeat: false, modifiers: [])])
        #expect(state.heldOutputKeys == [8])
    }

    @Test func lostLeftModifierReleaseDoesNotEraseStillHeldRightModifier() {
        var state = machine([keyRule(0, 8, extras: true)])
        _ = state.process(.init(.down, keyCode: 59, modifiers: [.control]))
        _ = state.process(.init(.down, keyCode: 62, modifiers: [.control]))
        _ = state.process(.init(.down, keyCode: 0, modifiers: [.control]))
        let released = state.releaseMissingKeys { $0 == 62 }
        #expect(released == [.key(code: 8, isDown: false, isRepeat: false, modifiers: [.control])])
        #expect(state.physicalHeld == [62])
    }

    @Test func injectedEventsCannotRecurseOrChangeState() {
        var state = machine([keyRule(0, 11), keyRule(11, 0)])
        _ = state.process(.init(.down, keyCode: 0))
        let synthetic = state.process(.init(.down, keyCode: 11, isInjected: true))
        #expect(synthetic == RemapDecision())
        #expect(state.heldOutputKeys == [11] && state.physicalHeld == [0])
    }

    @Test func disabledRuleBlocksDownRepeatsAndUpWithoutOutputs() {
        var state = machine([.init(trigger: .init(keyCode: 0), action: .disabled)])
        for input in [RemapInput(.down, keyCode: 0), .init(.down, keyCode: 0, isRepeat: true), .init(.up, keyCode: 0)] {
            let decision = state.process(input)
            #expect(decision.suppressOriginal && decision.outputs.isEmpty)
        }
    }
}
