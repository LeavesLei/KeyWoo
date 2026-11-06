import CoreGraphics
import Testing
@testable import KeyDance

struct KeyboardMonitorTests {
    // Evaluate mutating filter calls before passing a value to the macro.
    private func expectTransition(_ actual: KeyboardPressFilter.Transition?, _ expected: KeyboardPressFilter.Transition?, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(actual == expected, sourceLocation: sourceLocation)
    }

    @Test func heldLetterCountsOnceAndReleasesOnce() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .keyDown, code: 0), .down)
        for _ in 0..<200 {
            expectTransition(filter.transition(kind: .keyDown, code: 0, isRepeat: true), nil)
        }
        #expect(filter.heldKeys == [0])
        expectTransition(filter.transition(kind: .keyUp, code: 0), .up)
        expectTransition(filter.transition(kind: .keyUp, code: 0), nil)
        #expect(filter.heldKeys.isEmpty)
        expectTransition(filter.transition(kind: .keyDown, code: 0), .down)
    }

    @Test func duplicateDownWithoutReleaseCannotRecountOrRetrigger() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .keyDown, code: 14), .down)
        expectTransition(filter.transition(kind: .keyDown, code: 14), nil)
        expectTransition(filter.transition(kind: .keyUp, code: 15), nil)
        expectTransition(filter.transition(kind: .keyUp, code: 14), .up)
        expectTransition(filter.transition(kind: .keyDown, code: 14), .down)
    }

    @Test func overlappingKeysReleaseIndependently() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .keyDown, code: 0), .down)
        expectTransition(filter.transition(kind: .keyDown, code: 1), .down)
        expectTransition(filter.transition(kind: .keyDown, code: 2), .down)
        expectTransition(filter.transition(kind: .keyUp, code: 1), .up)
        #expect(filter.heldKeys == [0, 2])
        expectTransition(filter.transition(kind: .keyUp, code: 0), .up)
        #expect(filter.heldKeys == [2])
        expectTransition(filter.transition(kind: .keyUp, code: 2), .up)
        #expect(filter.heldKeys.isEmpty)
    }

    @Test func bothShiftKeysCanBePressedAndReleasedIndependently() {
        var filter = KeyboardPressFilter()
        let shift = CGEventFlags.maskShift.rawValue
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: shift | 0x2), .down)
        expectTransition(filter.transition(kind: .flagsChanged, code: 60, flags: shift | 0x2 | 0x4), .down)
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: shift | 0x4), .up)
        #expect(filter.heldKeys == [60])
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: shift | 0x2 | 0x4), .down)
        expectTransition(filter.transition(kind: .flagsChanged, code: 60, flags: shift | 0x2), .up)
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: 0), .up)
        #expect(filter.heldKeys.isEmpty)
    }

    @Test func duplicateModifierStateAndUnknownFlagsAreIgnored() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .flagsChanged, code: 55, flags: 0x8), .down)
        expectTransition(filter.transition(kind: .flagsChanged, code: 55, flags: 0x8), nil)
        expectTransition(filter.transition(kind: .flagsChanged, code: 999, flags: 0x8), nil)
        expectTransition(filter.transition(kind: .flagsChanged, code: 55, flags: 0), .up)
        expectTransition(filter.transition(kind: .flagsChanged, code: 55, flags: 0), nil)
    }

    @Test func resumeSeedsHeldModifiersWithoutNewPresses() {
        var filter = KeyboardPressFilter()
        filter.reset(flags: 0x2 | 0x40)
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: 0x2 | 0x40), nil)
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: 0x40), .up)
        expectTransition(filter.transition(kind: .flagsChanged, code: 61, flags: 0), .up)
        expectTransition(filter.transition(kind: .flagsChanged, code: 56, flags: 0x2), .down)
    }

    @Test func capsLockIsTransientAndNeverLeavesAHeldVoice() {
        var filter = KeyboardPressFilter()
        let caps = CGEventFlags.maskAlphaShift.rawValue
        filter.reset(flags: caps)
        expectTransition(filter.transition(kind: .flagsChanged, code: 57, flags: caps), nil)
        expectTransition(filter.transition(kind: .flagsChanged, code: 57, flags: 0), .tap)
        expectTransition(filter.transition(kind: .flagsChanged, code: 57, flags: 0), nil)
        expectTransition(filter.transition(kind: .keyDown, code: 57), nil)
        expectTransition(filter.transition(kind: .flagsChanged, code: 57, flags: caps), .tap)
        expectTransition(filter.transition(kind: .keyUp, code: 57), nil)
        #expect(filter.heldKeys.isEmpty)
        filter.reset(flags: 0)
        expectTransition(filter.transition(kind: .flagsChanged, code: 57, flags: 0), nil)
    }

    @Test func resetDropsLostReleasesAndIgnoresAlreadyRepeatingKeys() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .keyDown, code: 0), .down)
        expectTransition(filter.transition(kind: .flagsChanged, code: 58, flags: 0x20), .down)
        // Pause, secure input, local focus loss, or sleep can hide the release.
        filter.reset(flags: 0)
        #expect(filter.heldKeys.isEmpty)
        expectTransition(filter.transition(kind: .keyUp, code: 0), nil)
        expectTransition(filter.transition(kind: .keyDown, code: 0, isRepeat: true), nil)
        expectTransition(filter.transition(kind: .flagsChanged, code: 58, flags: 0x20), .down)
        expectTransition(filter.transition(kind: .keyDown, code: 0), .down)
    }

    @Test func reconciliationReleasesOnlyLostKeysAndNeverRecounts() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .keyDown, code: 0), .down)
        expectTransition(filter.transition(kind: .keyDown, code: 1), .down)
        expectTransition(filter.transition(kind: .keyDown, code: 2), .down)
        let released = filter.releaseMissingKeys { $0 == 1 }
        #expect(released == [0, 2])
        #expect(filter.heldKeys == [1])
        expectTransition(filter.transition(kind: .keyUp, code: 2), nil)
        expectTransition(filter.transition(kind: .keyDown, code: 0, isRepeat: true), nil)
        expectTransition(filter.transition(kind: .keyUp, code: 1), .up)
    }

    @Test func longHoldSurvivesRepeatedReconciliation() {
        var filter = KeyboardPressFilter()
        expectTransition(filter.transition(kind: .keyDown, code: 49), .down)
        for _ in 0..<600 {
            let released = filter.releaseMissingKeys { $0 == 49 }
            #expect(released.isEmpty)
            #expect(filter.heldKeys == [49])
        }
        expectTransition(filter.transition(kind: .keyUp, code: 49), .up)
    }

    @Test func functionAndArrowKeysHaveNormalDownAndUpLifecycles() {
        var filter = KeyboardPressFilter()
        for code: UInt16 in [122, 123, 124, 125, 126] {
            expectTransition(filter.transition(kind: .keyDown, code: code), .down)
            expectTransition(filter.transition(kind: .keyDown, code: code, isRepeat: true), nil)
            expectTransition(filter.transition(kind: .keyUp, code: code), .up)
        }
        expectTransition(filter.transition(kind: .flagsChanged, code: 63, flags: 0x00800000), .down)
        expectTransition(filter.transition(kind: .flagsChanged, code: 63, flags: 0), .up)
        #expect(filter.heldKeys.isEmpty)
    }
}
