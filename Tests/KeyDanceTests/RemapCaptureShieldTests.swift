import Testing
@testable import KeyDance

struct RemapCaptureShieldTests {
    @Test func completingCommandQRecordingStillConsumesRepeatsAndMatchingUps() {
        var shield = RemapCaptureShield()
        let command = shield.shouldSuppress(.init(.down, keyCode: 55, modifiers: [.command]), isCapturing: true)
        let q = shield.shouldSuppress(.init(.down, keyCode: 12, modifiers: [.command]), isCapturing: true)
        #expect(command && q)
        for _ in 0..<50 {
            let repeated = shield.shouldSuppress(.init(.down, keyCode: 12, modifiers: [.command], isRepeat: true), isCapturing: false)
            #expect(repeated)
        }
        let qUp = shield.shouldSuppress(.init(.up, keyCode: 12, modifiers: [.command]), isCapturing: false)
        let cmdUp = shield.shouldSuppress(.init(.up, keyCode: 55), isCapturing: false)
        #expect(qUp && cmdUp && !shield.isDraining)
        let newQ = shield.shouldSuppress(.init(.down, keyCode: 12), isCapturing: false)
        #expect(!newQ)
    }

    @Test func focusLossCannotTurnAnOldSwallowedHoldIntoPermanentBlockedKey() {
        var shield = RemapCaptureShield()
        _ = shield.shouldSuppress(.init(.down, keyCode: 0), isCapturing: true)
        // The up occurred in another application, then a new press returns here.
        let newDown = shield.shouldSuppress(.init(.down, keyCode: 0), isCapturing: false)
        #expect(!newDown && !shield.isDraining)
    }

    @Test func drainingRecordedKeyDoesNotSwallowUnrelatedKeys() {
        var shield = RemapCaptureShield()
        _ = shield.shouldSuppress(.init(.down, keyCode: 0), isCapturing: true)
        let other = shield.shouldSuppress(.init(.down, keyCode: 1), isCapturing: false)
        #expect(!other && shield.heldKeys == [0])
    }

    @Test func transientCapsCaptureNeedsNoInventedRelease() {
        var shield = RemapCaptureShield()
        let suppressed = shield.shouldSuppress(.init(.tap, keyCode: 57), isCapturing: true)
        #expect(suppressed && !shield.isDraining)
    }
}
