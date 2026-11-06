import Foundation
import Testing
@testable import KeyDance

@Suite(.serialized)
@MainActor
struct KeyboardLoudnessTests {
    private func measure(_ pcm: [Float], channels: Int = 1) -> KeyboardLoudness.Measurement {
        pcm.withUnsafeBufferPointer { KeyboardLoudness.measure(samples: $0.baseAddress!, frames: pcm.count / channels, channels: channels) }
    }

    @Test func measurementIgnoresPaddingAndStereoDuplicationAndTracksLinearGain() {
        let click: [Float] = (0..<4_800).map { frame in
            Float(0.12 * exp(-Double(frame) / 800) * sin(Double(frame) * 2 * .pi * 1_200 / 48_000))
        }
        let original = measure(click)
        let padded = measure(click + [Float](repeating: 0, count: 9_600))
        let stereo = measure(click.flatMap { [$0, $0] }, channels: 2)
        let boosted = measure(click.map { $0 * 2 })
        #expect(abs(padded.energy - original.energy) < 1e-12)
        #expect(abs(stereo.energy - original.energy) < 1e-12)
        #expect(abs(boosted.energy / original.energy - 4) < 1e-10)
        #expect(boosted.peak == original.peak * 2)
        let long = click + click + click
        #expect(measure(long).energy > original.energy, "A long ring must not receive the gain of a tiny click with the same peak.")
        for value in [Double.nan, .infinity, -1, 0] {
            #expect(KeyboardLoudness.profile(energy: value, peak: 0.2).gain == 1)
        }
    }

    @Test func oneLinearGainPreservesDownUpBigKeyAndStereoRatiosWithoutAddingOnsetDelay() throws {
        for style in KeyboardSoundStyle.allCases {
            let raw = KeyboardSoundEngine(audioDeviceEnabled: false, normalizationEnabled: false)
            let normalized = KeyboardSoundEngine(audioDeviceEnabled: false)
            raw.style = style; normalized.style = style
            // Below the limiter knee: compare every actual output sample to
            // the same uniform gain, including real return strokes and tails.
            raw.volume = 0.1; normalized.volume = 0.1; raw.start(); normalized.start()
            let gain = try #require(normalized.loudnessProfile(for: style)).gain
            #expect(gain.isFinite && gain > 0 && gain <= 4)
            // Eight real alternates exist in some recorded packs. Exercise a
            // full cycle as well as every large-key family (not only synth's 3).
            for key: UInt16 in [0, 0, 0, 0, 0, 0, 0, 0, 3, 49, 36, 51, 48, 56] {
                for down in [true, false] {
                    if down { raw.noteOn(keyCode: key); normalized.noteOn(keyCode: key) }
                    else { raw.noteOff(keyCode: key); normalized.noteOff(keyCode: key) }
                    let before = raw.renderForVerification(frames: 1_024)
                    let after = normalized.renderForVerification(frames: 1_024)
                    var maxError: Float = 0
                    for i in before.indices { maxError = max(maxError, abs(after[i] - before[i] * gain)) }
                    #expect(maxError < 2e-7, "Uniform preset gain must preserve the recording for \(style.rawValue), key \(key).")
                    #expect(before.firstIndex(where: { $0 != 0 }) == after.firstIndex(where: { $0 != 0 }))
                }
            }
            let beforeTail = raw.renderForVerification(frames: 24_000)
            let afterTail = normalized.renderForVerification(frames: 24_000)
            var tailError: Float = 0
            for i in beforeTail.indices { tailError = max(tailError, abs(afterTail[i] - beforeTail[i] * gain)) }
            #expect(tailError < 2e-7)
            #expect(afterTail.suffix(4_800).allSatisfy { $0 == 0 })
            #expect(raw.diagnostics.attacks == normalized.diagnostics.attacks)
            #expect(normalized.diagnostics.droppedEvents == 0)
            raw.stop(); normalized.stop()
        }
    }

    @Test func sameTypingSequenceIsCloserAcrossAllPresets() {
        // This different key sequence and timing is not the calibration corpus.
        let keys: [UInt16] = [14, 0, 35, 49, 31, 4, 49, 51, 36, 48, 56, 45]
        var before: [Double] = [], after: [Double] = []
        for style in KeyboardSoundStyle.allCases {
            for normalized in [false, true] {
                let engine = KeyboardSoundEngine(audioDeviceEnabled: false, normalizationEnabled: normalized)
                engine.style = style; engine.volume = 1; engine.start()
                var pcm: [Float] = []
                for key in keys {
                    engine.noteOn(keyCode: key); pcm += engine.renderForVerification(frames: 2_880)
                    engine.noteOff(keyCode: key); pcm += engine.renderForVerification(frames: 4_800)
                }
                pcm += engine.renderForVerification(frames: 24_000)
                let score = 10 * log10(measure(pcm, channels: 2).energy)
                if normalized { after.append(score) } else { before.append(score) }
                engine.stop()
            }
        }
        let beforeSpread = before.max()! - before.min()!
        let afterSpread = after.max()! - after.min()!
        #expect(afterSpread < beforeSpread * 0.4)
        #expect(afterSpread < 4.5, "Preset changes should not make the same passage jump dramatically in level.")
    }
}
