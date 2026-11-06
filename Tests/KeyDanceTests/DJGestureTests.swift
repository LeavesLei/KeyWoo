import Foundation
import Testing
@testable import KeyDance

/// Actual PCM through the production DSP; no model, device, or user settings.
@Suite(.serialized)
struct DJGestureTests {
    private let rate = 48_000.0
    private let actions: [DJAction] = [.push, .pull, .sweep, .lift, .hold]

    private func sample(_ frame: Int) -> (Float, Float) {
        let time = Double(frame) / rate
        return (Float(0.12 * sin(2 * .pi * 173.3 * time) + 0.03 * sin(2 * .pi * 997.1 * time)),
                Float(0.11 * sin(2 * .pi * 173.3 * time + 0.3) + 0.025 * sin(2 * .pi * 1_223.3 * time)))
    }

    @Test func zeroSourceStaysSilentAndZeroDepthIsBitExactForEveryAction() {
        var silent = true, identical = true, counted = true
        for action in actions {
            let silence = WholeMusicGesture(sampleRate: rate)
            let bypass = WholeMusicGesture(sampleRate: rate)
            bypass.depth = 0
            silence.noteOn(heldCount: 1, strength: 1, action: action, duration: 0.24)
            bypass.noteOn(heldCount: 1, strength: 1, action: action, duration: 0.24)
            for frame in 0..<24_000 {
                let zero = silence.process(left: 0, right: 0)
                if zero.0 != 0 || zero.1 != 0 { silent = false }
                let input = sample(frame)
                let output = bypass.process(left: input.0, right: input.1)
                if input.0.bitPattern != output.0.bitPattern || input.1.bitPattern != output.1.bitPattern { identical = false }
            }
            if silence.attackCount != 1 || bypass.attackCount != 1 { counted = false }
        }
        #expect(silent)
        #expect(identical)
        #expect(counted)
    }

    @Test func gesturesChangeExistingPCMImmediatelyThenReturnToTheUnmodifiedMusic() {
        let onset = 9_600, release = 24_000, tail = 110_400, end = 120_000
        for action in actions {
            let gesture = WholeMusicGesture(sampleRate: rate)
            gesture.depth = 0.45
            var prefixExact = true, tailExact = true, finite = true
            var firstChange: Int?
            var inputPeak: Float = 0, outputPeak: Float = 0
            for frame in 0..<end {
                if frame == onset {
                    gesture.noteOn(heldCount: action == .hold ? 1 : 0,
                                   strength: 0.8, action: action, duration: 0.24)
                }
                if frame == release { gesture.noteOff(heldCount: 0) }
                let input = sample(frame)
                let output = gesture.process(left: input.0, right: input.1)
                let equal = input.0.bitPattern == output.0.bitPattern && input.1.bitPattern == output.1.bitPattern
                if frame < onset && !equal { prefixExact = false }
                if frame >= tail && !equal { tailExact = false }
                if frame >= onset && firstChange == nil && max(abs(input.0 - output.0), abs(input.1 - output.1)) > 0.000001 {
                    firstChange = frame - onset
                }
                finite = finite && output.0.isFinite && output.1.isFinite
                inputPeak = max(inputPeak, abs(input.0), abs(input.1))
                outputPeak = max(outputPeak, abs(output.0), abs(output.1))
            }
            #expect(prefixExact)
            #expect(tailExact)
            #expect(finite)
            #expect(firstChange != nil && (firstChange ?? Int.max) < 960,
                    "The existing PCM must change within 20ms; this is not a hardware latency measurement.")
            #expect(outputPeak <= inputPeak * 1.25)
            #expect(gesture.attackCount == 1)
        }
    }

    @Test func sweepActuallyDarkensThenReopensHighFrequencyMusic() {
        let gesture = WholeMusicGesture(sampleRate: rate)
        gesture.depth = 1
        var darkEnergy = 0.0, lightEnergy = 0.0
        let onset = 9_600
        for frame in 0..<33_600 {
            if frame == onset { gesture.noteOn(heldCount: 0, strength: 1, action: .sweep, duration: 0.4) }
            let input = Float(0.12 * sin(2 * .pi * 6_000 * Double(frame) / rate))
            let output = gesture.process(left: input, right: input)
            // Equal-length windows around the first and third quarter of the
            // sweep, using the same steady source rather than diagnostic labels.
            if (13_920..<14_880).contains(frame) { darkEnergy += Double(output.0) * Double(output.0) }
            if (23_520..<24_480).contains(frame) { lightEnergy += Double(output.0) * Double(output.0) }
        }
        #expect(lightEnergy > 0.001)
        #expect(darkEnergy < lightEnergy * 0.64, "The dark portion must reduce actual high-frequency PCM, not merely report a sweep action.")
    }

    @Test func denseOpposingTapeActionsKeepStereoTogetherAndResetCannotReplayOldMusic() {
        let tape = StereoDJGesture(sampleRate: rate)
        var finite = true, stereoError: Float = 0, inputPeak: Float = 0, outputPeak: Float = 0
        for frame in 0..<48_000 {
            if frame.isMultiple(of: 960) {
                tape.trigger(action: (frame / 960).isMultiple(of: 2) ? .push : .pull,
                             duration: 0.14, strength: 1, gentle: false)
            }
            let input = sample(frame).0
            let output = tape.process(left: input, right: -input, depth: 1, held: false)
            finite = finite && output.0.isFinite && output.1.isFinite
            stereoError = max(stereoError, abs(output.0 + output.1))
            inputPeak = max(inputPeak, abs(input))
            outputPeak = max(outputPeak, abs(output.0), abs(output.1))
        }
        #expect(finite)
        #expect(stereoError < 0.000001)
        #expect(outputPeak <= inputPeak + 0.000001)
        #expect(tape.maximumObservedSlew > 0)
        #expect(tape.maximumObservedSlew <= 0.040000001)
        tape.reset()
        tape.trigger(action: .pull, duration: 0.24, strength: 1, gentle: false)
        var resetIsSilent = true
        for _ in 0..<12_000 {
            let output = tape.process(left: 0, right: 0, depth: 1, held: false)
            if output.0 != 0 || output.1 != 0 { resetIsSilent = false }
        }
        #expect(resetIsSilent)
    }
}
