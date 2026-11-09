import Foundation
import Testing
@testable import KeyDance

struct AudioSpectrumTests {
    private func tone(frequency: Double, sampleRate: Double = 48_000,
                      offset: Int, count: Int = 480) -> [Float] {
        (0..<count).map { index in
            Float(0.15 * sin(2 * Double.pi * frequency * Double(offset + index) / sampleRate))
        }
    }

    private func values(_ spectrum: AudioSpectrum) -> [Double] {
        [spectrum.low, spectrum.mid, spectrum.high, spectrum.level]
    }

    @Test func steadySineTonesFavorTheirExpectedFrequencyBands() {
        let cases: [(frequency: Double, band: Int)] = [(80, 0), (1_000, 1), (8_000, 2)]
        for item in cases {
            var analyzer = AudioSpectrumAnalyzer()
            var spectrum = AudioSpectrum.silent
            // Preserve the phase across blocks; restarting each block would
            // introduce artificial broadband edges, especially for the 80 Hz tone.
            for block in 0..<200 {
                spectrum = analyzer.process(tone(frequency: item.frequency, offset: block * 480),
                                            sampleRate: 48_000)
            }
            let bands = [spectrum.low, spectrum.mid, spectrum.high]
            #expect(values(spectrum).allSatisfy { $0.isFinite && (0...1).contains($0) })
            #expect(spectrum.level > 0.75)
            for other in bands.indices where other != item.band {
                #expect(bands[item.band] > bands[other] + 0.05,
                        "A steady tone must favor its own band, not merely produce a nonzero meter.")
            }
        }
    }

    @Test func silenceReleasesSmoothlyAndNonfiniteSamplesCannotPoisonTheAnalyzer() {
        var analyzer = AudioSpectrumAnalyzer()
        let silence = [Float](repeating: 0, count: 480)
        #expect(analyzer.process(silence, sampleRate: 48_000) == .silent)
        var active = AudioSpectrum.silent
        for block in 0..<100 {
            active = analyzer.process(tone(frequency: 1_000, offset: block * 480), sampleRate: 48_000)
        }
        var tail = active
        for _ in 0..<20 { tail = analyzer.process(silence, sampleRate: 48_000) }
        #expect(tail.level > 0 && tail.level < active.level,
                "Silence should fade a running meter rather than abruptly clear it or leave it stuck.")
        for _ in 0..<400 { tail = analyzer.process(silence, sampleRate: 48_000) }
        #expect(tail == .silent)

        let malformed: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let sanitized = analyzer.process(malformed, sampleRate: 48_000)
        #expect(values(sanitized).allSatisfy { $0.isFinite && (0...1).contains($0) })
        for _ in 0..<400 { tail = analyzer.process(silence, sampleRate: 48_000) }
        #expect(tail == .silent, "Invalid samples must not contaminate later filter state.")
    }

    @Test func changingSampleRateDiscardsPreviousFilterAndEnvelopeState() {
        var changed = AudioSpectrumAnalyzer()
        for block in 0..<100 {
            _ = changed.process(tone(frequency: 80, offset: block * 480), sampleRate: 48_000)
        }
        #expect(changed.process([Float](repeating: 0, count: 441), sampleRate: 44_100) == .silent,
                "Changing the rate must clear both crossover history and the previous meter envelope.")

        var fresh = AudioSpectrumAnalyzer()
        for block in 0..<30 {
            let samples = tone(frequency: 1_000, sampleRate: 44_100, offset: block * 441, count: 441)
            #expect(changed.process(samples, sampleRate: 44_100) == fresh.process(samples, sampleRate: 44_100),
                    "After the rate change, subsequent audio must match a fresh analyzer at that rate.")
        }
    }

    @Test func processorSnapshotsFadeEvenWhenAudioCallbacksStop() {
        let processor = AudioSpectrumProcessor()
        #expect(processor.snapshot() == .silent)
        for block in 0..<100 {
            processor.receive(tone(frequency: 1_000, offset: block * 480), sampleRate: 48_000)
        }
        let beforeLastCallback = ProcessInfo.processInfo.systemUptime
        processor.receive(tone(frequency: 1_000, offset: 100 * 480), sampleRate: 48_000)
        let afterLastCallback = ProcessInfo.processInfo.systemUptime
        let active = processor.snapshot(at: beforeLastCallback)
        #expect(active.level > 0.75)

        // Advance only the snapshot clock: no silence buffers or wall-clock
        // sleeps can accidentally provide the release being tested here.
        let fading = processor.snapshot(at: afterLastCallback + 0.6)
        #expect(fading.level > 0 && fading.level < active.level * 0.3,
                "A missing callback must produce a declining tail before settling to silence.")
        #expect(values(fading).allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(processor.snapshot(at: afterLastCallback + 0.6) == fading,
                "Reading a snapshot must not mutate the mailbox or add extra decay.")
        #expect(processor.snapshot(at: afterLastCallback + 3) == .silent)
        processor.reset()
        #expect(processor.snapshot() == .silent)
    }

    @Test func amplitudeOnsetsProduceBeatsThatSettleUnderContinuingAudio() {
        for frequency in [80.0, 1_000.0] {
            var analyzer = AudioSpectrumAnalyzer()
            var offset = 0
            let blockSize = 2_048
            func processTone(gain: Float) -> AudioSpectrum {
                let samples = tone(frequency: frequency, offset: offset, count: blockSize).map { $0 * gain }
                offset += blockSize
                let spectrum = analyzer.process(samples, sampleRate: 48_000)
                #expect((values(spectrum) + [spectrum.beat]).allSatisfy { $0.isFinite && (0...1).contains($0) })
                return spectrum
            }

            // The actual capture-sized blocks do not contain an integer number
            // of bass cycles. Steady input must not mistake their changing phase
            // for repeated strong attacks.
            var steadyPeak = 0.0
            var steadyLevel = 0.0
            for block in 0..<80 {
                let spectrum = processTone(gain: 0.2) // Amplitude 0.03.
                if block >= 60 { steadyPeak = max(steadyPeak, spectrum.beat) }
                steadyLevel = spectrum.level
            }
            #expect(steadyPeak < 0.08, "A settled, constant-amplitude tone must not keep flashing.")

            // Keep frequency and phase continuous; change only the amplitude.
            var onsetPeak = 0.0
            for _ in 0..<2 { onsetPeak = max(onsetPeak, processTone(gain: 1).beat) }
            #expect(onsetPeak > steadyPeak + 0.35,
                    "A fivefold amplitude increase should produce a clear beat within two capture blocks.")

            var sustainedPeak = 0.0
            var sustainedLevel = 0.0
            for block in 0..<80 {
                let spectrum = processTone(gain: 1) // Continue at amplitude 0.15.
                if block >= 60 { sustainedPeak = max(sustainedPeak, spectrum.beat) }
                sustainedLevel = spectrum.level
            }
            #expect(sustainedLevel > steadyLevel + 0.15,
                    "The sound remains louder while its one-time onset response settles.")
            #expect(sustainedPeak < 0.08 && sustainedPeak < onsetPeak * 0.2)

            var silentTail = AudioSpectrum.silent
            let silence = [Float](repeating: 0, count: blockSize)
            for _ in 0..<100 {
                silentTail = analyzer.process(silence, sampleRate: 48_000)
                #expect((values(silentTail) + [silentTail.beat]).allSatisfy { $0.isFinite && (0...1).contains($0) })
            }
            #expect(silentTail.beat == 0 && silentTail == .silent)
        }
    }

    @Test func displayFramesSmoothOneAudioTargetAndReleaseItWithoutNewPCM() {
        var motion = AudioSpectrumMotion()
        let target = AudioSpectrum(low: 0.8, mid: 0.6, high: 0.4, level: 0.9, beat: 1)
        let targetValues = values(target) + [target.beat]
        let frameDuration = 1.0 / 60
        var previous = motion.advance(towards: target, elapsed: frameDuration)
        for (value, destination) in zip(values(previous) + [previous.beat], targetValues) {
            #expect(value > 0 && value < destination, "The first display frame must interpolate, not jump to the PCM target.")
        }

        // Hold exactly the same captured spectrum while eight more display
        // frames elapse. No audio callback is needed to continue the motion.
        for _ in 0..<8 {
            let next = motion.advance(towards: target, elapsed: frameDuration)
            for (before, after) in zip(values(previous) + [previous.beat], values(next) + [next.beat]) {
                #expect(after > before)
            }
            previous = next
        }
        for (value, destination) in zip(values(motion.value) + [motion.value.beat], targetValues) {
            #expect(value > destination * 0.85 && value <= destination,
                    "By 150 ms, the response must be clearly visible without overshooting its target.")
        }

        let beforeInvalidTime = motion.value
        let invalidTime = motion.advance(towards: .silent, elapsed: .nan)
        #expect(invalidTime == beforeInvalidTime)
        #expect((values(invalidTime) + [invalidTime.beat]).allSatisfy { $0.isFinite })

        let firstRelease = motion.advance(towards: .silent, elapsed: frameDuration)
        for (before, after) in zip(values(previous) + [previous.beat], values(firstRelease) + [firstRelease.beat]) {
            #expect(after > 0 && after < before, "Silence starts a release instead of instantly clearing the display.")
        }
        previous = firstRelease
        for _ in 0..<90 {
            let next = motion.advance(towards: .silent, elapsed: frameDuration)
            for (before, after) in zip(values(previous) + [previous.beat], values(next) + [next.beat]) {
                #expect(after.isFinite && after >= 0 && after <= before)
            }
            previous = next
        }
        #expect(motion.value == .silent)
    }

    @Test func shortCaptureBlocksKeepBassSteadyAndReactToAnOnsetImmediately() {
        for frequency in [40.0, 80.0, 1_000.0] {
            var analyzer = AudioSpectrumAnalyzer()
            let blockSize = 512
            var offset = 0
            var settledBeat = 0.0
            for block in 0..<320 {
                let input = tone(frequency: frequency, offset: offset, count: blockSize).map { $0 * 0.2 }
                offset += blockSize
                let result = analyzer.process(input, sampleRate: 48_000)
                if block > 280 { settledBeat = max(settledBeat, result.beat) }
            }
            #expect(settledBeat < 0.08, "Partial bass cycles must not create false strong beats in small capture blocks.")
            let onset = analyzer.process(tone(frequency: frequency, offset: offset, count: blockSize), sampleRate: 48_000)
            #expect(onset.beat > 0.45, "An actual amplitude onset should be visible within the first 10.7 ms analysis block.")
            var motion = AudioSpectrumMotion()
            let firstFrame = motion.advance(towards: onset, elapsed: 1.0 / 60)
            #expect(firstFrame.beat > 0.4, "Display interpolation must preserve the first frame's beat response.")
        }
    }

    @Test func loudMusicRetainsHeadroomAndDetectsAnotherKick() {
        for frequency in [80.0, 1_000.0] {
            var analyzer = AudioSpectrumAnalyzer()
            var offset = 0
            func block(amplitude: Float) -> AudioSpectrum {
                let input = tone(frequency: frequency, offset: offset, count: 512).map { $0 * (amplitude / 0.15) }
                offset += 512
                return analyzer.process(input, sampleRate: 48_000)
            }
            var before = AudioSpectrum.silent
            for _ in 0..<320 { before = block(amplitude: 0.4) }
            #expect(before.level < 0.95 && before.beat < 0.08)
            var onset = 0.0
            for _ in 0..<4 { onset = max(onset, block(amplitude: 0.8).beat) }
            #expect(onset > 0.35, "A six-decibel rise in loud music must remain a visible onset.")
            var after = AudioSpectrum.silent
            for _ in 0..<160 { after = block(amplitude: 0.8) }
            #expect(after.level > before.level + 0.04 && after.level < 1,
                    "Loud playback needs room to rise instead of pinning every band at full scale.")
            #expect(after.beat < 0.08)
        }
    }

    @Test func fastLightAndCalmContourHaveIndependentResponses() throws {
        var motion = AudioSpectrumMotion()
        let target = AudioSpectrum(low: 0.8, mid: 0.6, high: 0.4, level: 0.9, beat: 1)
        let first = motion.advance(towards: target, elapsed: 1.0 / 60)
        let shape = try #require(first.contour)
        #expect(first.beat > 0.95, "Smoothing the shape must not delay the first colored beat response.")
        #expect(shape.beat < 0.1 && shape.low < first.low * 0.25,
                "The first display frame should start moving gently instead of snapping to the audio peak.")
        for _ in 0..<60 { _ = motion.advance(towards: target, elapsed: 1.0 / 60) }
        let settled = try #require(motion.value.contour)
        #expect(settled.low > target.low * 0.9 && settled.beat > 0.9,
                "Calm motion must still reach a sustained musical shape rather than remain damped away.")
        for _ in 0..<180 { _ = motion.advance(towards: .silent, elapsed: 1.0 / 60) }
        #expect(motion.value == .silent, "Both fast light and the contour's inertia must eventually settle.")
    }

    @Test func delayedPresentationDoesNotCatchUpWithALargeShapeJump() throws {
        for elapsed in [0.1, 0.3, 2.0] {
            var motion = AudioSpectrumMotion()
            let frame = motion.advance(towards: AudioSpectrum(low: 1, mid: 1, high: 1, level: 1, beat: 1),
                                       elapsed: elapsed)
            let shape = try #require(frame.contour)
            #expect([shape.low, shape.mid, shape.high, shape.level, shape.beat].allSatisfy { $0 < 0.05 },
                    "A stalled UI must resume with one gentle shape step, not replay all missed motion at once.")
            #expect(frame.beat > 0.95)
        }
    }
}
