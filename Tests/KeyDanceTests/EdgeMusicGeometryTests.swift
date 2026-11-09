import Foundation
import Testing
@testable import KeyDance

struct EdgeMusicGeometryTests {
    private func regions(_ spectrum: AudioSpectrum, time: Double = 0, keyboard: Double = 0,
                         reducedMotion: Bool = false, intensity: Double = 1.5,
                         keyboardEnergy: Double? = nil) -> [EdgeMusicGeometry.Region] {
        EdgeMusicGeometry.regions(spectrum: spectrum, time: time, intensity: intensity,
                                  keyboardDrive: keyboard, reducedMotion: reducedMotion,
                                  keyboardEnergy: keyboardEnergy)
    }

    /// An area/opacity proxy, not a pixel-brightness measurement. Shared screen
    /// width factors cancel when comparing the two regions or sound levels.
    private func visibility(_ region: EdgeMusicGeometry.Region) -> Double {
        region.bodyOpacity * region.radiusX * region.bodyHeight
            + region.crestOpacity * region.crestRadiusX * region.crestHeight
    }

    private struct SpectrumFrame {
        let time: Double
        let spectrum: AudioSpectrum
    }

    /// A deterministic capture/display timeline using continuous-phase carriers.
    /// A display frame can consume only audio blocks whose callbacks have ended.
    private func capturedFrames(duration: Double, silenceAt: Double? = nil,
                                bassGain: (Double) -> Double) -> [SpectrumFrame] {
        let sampleRate = 48_000.0
        let blockSize = 512
        var analyzer = AudioSpectrumAnalyzer()
        var motion = AudioSpectrumMotion()
        var target = AudioSpectrum.silent
        var nextSample = 0
        var frames: [SpectrumFrame] = []
        for frame in 1...Int(duration * 60) {
            let displayTime = Double(frame) / 60
            while Double(nextSample + blockSize) / sampleRate <= displayTime + 1e-12 {
                let samples = (0..<blockSize).map { index -> Float in
                    let time = Double(nextSample + index) / sampleRate
                    if let silenceAt, time >= silenceAt { return 0 }
                    let bass = 0.18 * bassGain(time) * sin(2 * Double.pi * 80 * time)
                    let body = 0.075 * sin(2 * Double.pi * 1_000 * time)
                    let treble = 0.045 * sin(2 * Double.pi * 8_000 * time)
                    return Float(bass + body + treble)
                }
                target = analyzer.process(samples, sampleRate: sampleRate)
                nextSample += blockSize
            }
            let spectrum = motion.advance(towards: target, elapsed: 1.0 / 60)
            frames.append(SpectrumFrame(time: displayTime, spectrum: spectrum))
        }
        return frames
    }

    private func expectSmoothHeights(_ frames: [SpectrumFrame], intensity: Double, maxStep: Double) {
        let geometry = frames.map { regions($0.spectrum, time: $0.time, intensity: intensity) }
            .filter { $0.count == 2 }
        for side in 0..<2 {
            // Test the final geometry, including the baseline band response;
            // smoothing only the beat channel must not hide another source of jumps.
            for heights in [geometry.map { $0[side].crestHeight }, geometry.map { $0[side].bodyHeight }] {
                let deltas = zip(heights.dropFirst(), heights).map { later, earlier in later - earlier }
                let largestStep = deltas.map { abs($0) }.max() ?? 0
                let largestAcceleration = zip(deltas.dropFirst(), deltas)
                    .map { later, earlier in abs(later - earlier) }.max() ?? 0
                #expect(largestStep <= maxStep, "The final wave must not jump several points in one display frame.")
                #expect(largestAcceleration <= 1.5,
                        "A rapid change in direction must ease through intermediate velocities.")
            }
        }
    }

    @Test func musicStaysOnBothSidesAndSilenceDrawsNothing() {
        #expect(regions(.silent).isEmpty)
        for time in [0.0, 2.5, 8, 50] {
            let visible = regions(AudioSpectrum(low: 1, mid: 1, high: 1, level: 1, beat: 1), time: time)
            #expect(visible.count == 2)
            #expect(visible[0].centerX + visible[0].radiusX < 0.36)
            #expect(visible[1].centerX - visible[1].radiusX > 0.64)
            #expect(visible[0].crestX + visible[0].crestRadiusX < 0.36)
            #expect(visible[1].crestX - visible[1].crestRadiusX > 0.64)
            for region in visible {
                let dimensions = [region.centerX, region.radiusX, region.bodyHeight, region.bodyOpacity,
                                  region.crestX, region.crestRadiusX, region.crestHeight, region.crestOpacity,
                                  region.hue, region.shoulder]
                #expect(dimensions.allSatisfy { $0.isFinite && $0 >= 0 })
                #expect((0...1).contains(region.bodyOpacity) && (0...1).contains(region.crestOpacity))
                let combinedOpacity = 1 - (1 - region.bodyOpacity) * (1 - region.crestOpacity)
                #expect(combinedOpacity < 0.85,
                        "Even maximum music input must leave transparency instead of becoming an opaque block.")
            }
        }
    }

    @Test func beatReleaseKeepsBothAnchorsStillWhileLightSoftens() {
        let stages = [1.0, 0.6, 0.25, 0.05].map {
            regions(AudioSpectrum(low: 0.9, mid: 0.6, high: 0.4, level: 0.85, beat: $0))
        }
        for (before, after) in zip(stages, stages.dropFirst()) {
            for side in 0..<2 {
                #expect(after[side].centerX == before[side].centerX && after[side].crestX == before[side].crestX,
                        "Fast beat changes must not throw light sideways across the desktop.")
                #expect(after[side].crestOpacity <= before[side].crestOpacity,
                        "A capped peak may stay level briefly, but a releasing beat must not brighten.")
            }
        }
        for side in 0..<2 {
            #expect(stages[3][side].crestOpacity < stages[0][side].crestOpacity,
                    "Across the full release the light must soften, even if the first frames hit a cap.")
        }
        let later = regions(AudioSpectrum(low: 0.9, mid: 0.6, high: 0.4, level: 0.85, beat: 1), time: 11)
        #expect(later[0].crestX == stages[0][0].crestX && later[1].centerX == stages[0][1].centerX)
    }

    @Test func typingKeepsPriorityAndReducedMotionHoldsTheGeometryStill() {
        let spectrum = AudioSpectrum(low: 0.8, mid: 0.5, high: 0.4, level: 0.8, beat: 0.9)
        let music = regions(spectrum)
        let typing = regions(spectrum, keyboard: 1)
        for side in 0..<2 {
            #expect(typing[side].bodyOpacity <= music[side].bodyOpacity)
            #expect(typing[side].crestOpacity <= music[side].crestOpacity)
            #expect(visibility(typing[side]) < visibility(music[side]),
                    "Typing must reduce the music layer's visual weight to preserve the keyboard accent.")
            #expect(typing[side].crestX == music[side].crestX)
        }
        let still = regions(spectrum, reducedMotion: true)
        let later = regions(spectrum.scaled(by: 0.3), time: 10, reducedMotion: true)
        for side in 0..<2 {
            #expect(still[side].centerX == later[side].centerX && still[side].crestX == later[side].crestX)
            #expect(still[side].radiusX == later[side].radiusX && still[side].crestRadiusX == later[side].crestRadiusX)
            #expect(still[side].bodyHeight == later[side].bodyHeight && still[side].crestHeight == later[side].crestHeight)
            #expect(still[side].shoulder == later[side].shoulder)
        }
    }

    @Test func equalLoudnessBassAndTrebleReverseTheDominantSide() {
        let bass = regions(AudioSpectrum(low: 0.9, mid: 0.15, high: 0.08, level: 0.8, beat: 0.35))
        let treble = regions(AudioSpectrum(low: 0.08, mid: 0.15, high: 0.9, level: 0.8, beat: 0.35))
        let middle = regions(AudioSpectrum(low: 0.08, mid: 0.9, high: 0.08, level: 0.8, beat: 0.35))
        #expect(visibility(bass[0]) > visibility(bass[1]) * 1.25,
                "Bass must favor the left shape even when both sides share the same total loudness and beat.")
        #expect(visibility(treble[1]) > visibility(treble[0]) * 1.25,
                "Treble must reverse the visible balance, not merely change the hue of mirrored blobs.")
        #expect(visibility(middle[1]) > visibility(middle[0]) * 1.25)
        #expect(bass[0].bodyHeight > bass[1].bodyHeight)
        #expect(treble[1].bodyHeight > treble[0].bodyHeight)
        for side in 0..<2 {
            #expect(bass[side].centerX == treble[side].centerX && bass[side].crestX == treble[side].crestX,
                    "Spectral changes reshape each side without relocating it.")
        }
    }

    @Test func quietAndStrongVersionsOfTheSameSpectrumRemainVisiblyDifferent() {
        let strongSpectrum = AudioSpectrum(low: 0.85, mid: 0.65, high: 0.75, level: 0.85, beat: 0.65)
        let strong = regions(strongSpectrum)
        let quiet = regions(strongSpectrum.scaled(by: 0.25))
        for side in 0..<2 {
            #expect(visibility(quiet[side]) > 0, "Quiet audio remains subtly visible.")
            #expect(visibility(strong[side]) > visibility(quiet[side]) * 3,
                    "Sound levels must differ clearly without relying only on hitting an opacity cap.")
            #expect(strong[side].bodyHeight > quiet[side].bodyHeight)
            #expect(strong[side].centerX == quiet[side].centerX && strong[side].crestX == quiet[side].crestX)
        }
    }

    @Test func capturedBassAndTrebleTonesReverseTheVisibleBalance() {
        let sampleRate = 48_000.0
        let blockSize = 512
        for (frequency, dominantSide) in [(80.0, 0), (8_000.0, 1)] {
            var analyzer = AudioSpectrumAnalyzer()
            var spectrum = AudioSpectrum.silent
            // Continuous phase across real capture-sized blocks avoids adding
            // artificial broadband edges at each callback boundary.
            for block in 0..<200 {
                let samples = (0..<blockSize).map { index in
                    Float(0.15 * sin(2 * Double.pi * frequency * Double(block * blockSize + index) / sampleRate))
                }
                spectrum = analyzer.process(samples, sampleRate: sampleRate)
            }
            let visible = regions(spectrum)
            #expect(visible.count == 2)
            #expect(visibility(visible[dominantSide]) > visibility(visible[1 - dominantSide]) * 1.1,
                    "The analyzed frequency bands must produce the intended side emphasis, including crossover leakage and loudness mapping.")
        }
    }

    @Test func repeatedModestBassBeatsLiftAndReleaseTheShapeOnTheDisplayClock() throws {
        let warmup = 2.0
        let beatPeriod = 0.5 // 120 BPM.
        let beatCount = 8
        let duration = warmup + Double(beatCount) * beatPeriod
        let boost = pow(10.0, 3.0 / 20.0) // A modest +3 dB amplitude change.
        let captured = capturedFrames(duration: duration) { time in
            let musicTime = time - warmup
            guard musicTime >= 0, musicTime < Double(beatCount) * beatPeriod else { return 1 }
            let phase = musicTime.truncatingRemainder(dividingBy: beatPeriod)
            guard phase < 0.09 else { return 1 }
            // Short ramps avoid a broadband click without restarting the carriers.
            let envelope = min(1, min(phase / 0.004, (0.09 - phase) / 0.010))
            return 1 + (boost - 1) * envelope
        }.filter { $0.time >= warmup - 0.1 }
        expectSmoothHeights(captured, intensity: 1, maxStep: 3)
        expectSmoothHeights(captured, intensity: 1.5, maxStep: 4)
        var frames: [(time: Double, height: Double)] = []
        for frame in captured {
            let visible = regions(frame.spectrum, time: frame.time, intensity: 1)
            try #require(visible.count == 2)
            #expect(abs(visible[0].centerX - 0.16) < 1e-10 && abs(visible[0].crestX - 0.16) < 1e-10)
            #expect(abs(visible[1].centerX - 0.84) < 1e-10 && abs(visible[1].crestX - 0.84) < 1e-10)
            frames.append((frame.time, visible[0].crestHeight))
        }

        for beat in 0..<beatCount {
            let onset = warmup + Double(beat) * beatPeriod
            let baseline = try #require(frames.last { $0.time <= onset + 1e-10 })
            let attack = frames.filter { $0.time > onset && $0.time <= onset + 0.18 }
            let peak = try #require(attack.max { $0.height < $1.height })
            let tail = frames.filter { $0.time >= onset + 0.38 && $0.time <= onset + 0.48 }
            try #require(!tail.isEmpty)
            let tailHeight = tail.map { $0.height }.reduce(0, +) / Double(tail.count)
            let lift = peak.height - baseline.height
            #expect(lift >= 6,
                    "Every +3 dB bass beat must visibly reshape the wave, including beats after the initial onset.")
            #expect(tailHeight <= peak.height - lift * 0.35,
                    "The wave must recover between beats instead of accumulating into one stationary high shape.")
        }
    }

    @Test func strongMusicKeepsShapeHeadroomEvenWhenOpacityIsCapped() {
        for intensity in [1.0, 1.5] {
            let stages = [(0.78, 0.15), (0.81, 0.6), (0.84, 1.0), (0.84, 0.15)].map { band, beat in
                regions(AudioSpectrum(low: band, mid: band, high: band, level: band, beat: beat),
                        intensity: intensity)
            }
            for side in 0..<2 {
                #expect(stages[1][side].crestHeight > stages[0][side].crestHeight)
                #expect(stages[2][side].crestHeight > stages[1][side].crestHeight)
                #expect(stages[2][side].crestHeight - stages[3][side].crestHeight >= 6,
                        "At sustained high loudness, a beat must still raise and release the contour even if alpha has reached its cap.")
                #expect(stages[3][side].crestHeight > stages[0][side].crestHeight + 0.5,
                        "A louder sustained band must retain shape headroom rather than clamp the entire region.")
                for stage in stages {
                    #expect(stage[side].centerX == stages[0][side].centerX && stage[side].crestX == stages[0][side].crestX)
                }
            }
        }
    }

    @Test func oneCaptureSpikeStaysSmallerThanASustainedAccentAndSettlesWithoutRebounds() throws {
        // Align the spike to exactly one callback, after more than two seconds
        // of steady music. Both fixtures have the same +12 dB peak and carriers.
        let onset = Double(192 * 512) / 48_000
        let stop = onset + 1.5
        let boost = pow(10.0, 12.0 / 20.0)
        func capture(accentDuration: Double) -> [SpectrumFrame] {
            capturedFrames(duration: stop + 3, silenceAt: stop) { time in
                time >= onset && time < onset + accentDuration ? boost : 1
            }.filter { $0.time >= onset - 0.1 }
        }
        let short = capture(accentDuration: 512.0 / 48_000)
        let sustained = capture(accentDuration: 0.09)
        for frames in [short, sustained] {
            expectSmoothHeights(frames, intensity: 1, maxStep: 3)
            expectSmoothHeights(frames, intensity: 1.5, maxStep: 4)
        }

        func heights(_ frames: [SpectrumFrame], side: Int) -> [(time: Double, height: Double)] {
            frames.compactMap { frame in
                let visible = regions(frame.spectrum, time: frame.time, intensity: 1)
                guard visible.count == 2 else { return nil }
                return (frame.time, visible[side].crestHeight)
            }
        }
        for side in 0..<2 {
            let shortHeights = heights(short, side: side)
            let longHeights = heights(sustained, side: side)
            let baseline = try #require(shortHeights.last { $0.time <= onset })
            let shortPeak = try #require(shortHeights.filter { $0.time > onset && $0.time < onset + 0.6 }
                .max { $0.height < $1.height })
            let longPeak = try #require(longHeights.filter { $0.time > onset && $0.time < onset + 0.6 }
                .max { $0.height < $1.height })
            let shortLift = shortPeak.height - baseline.height
            let longLift = longPeak.height - baseline.height
            #expect(shortLift > 0 && shortLift < longLift * 0.85,
                    "One anomalous capture block should not move the wave as much as a sustained accent at the same peak level.")

            var lowest = shortPeak.height
            var largestRebound = 0.0
            for frame in shortHeights where frame.time > shortPeak.time && frame.time < onset + 1.25 {
                lowest = min(lowest, frame.height)
                largestRebound = max(largestRebound, frame.height - lowest)
            }
            #expect(largestRebound <= 0.75,
                    "Ignore subpixel variation, but a single spike must not keep bouncing after its main peak.")
            let recovered = shortHeights.filter { $0.time >= onset + 1 && $0.time <= onset + 1.25 }
            try #require(!recovered.isEmpty)
            #expect(recovered.allSatisfy { abs($0.height - baseline.height) <= 1 },
                    "After the spike passes, steady music must recover its previous shape.")
        }

        for frames in [short, sustained] {
            func weight(_ frame: SpectrumFrame) -> Double {
                regions(frame.spectrum, time: frame.time, intensity: 1).map { visibility($0) }.reduce(0, +)
            }
            let activePeak = frames.filter { $0.time < stop }.map { weight($0) }.max() ?? 0
            let faded = frames.filter { $0.time >= stop + 1.5 && $0.time <= stop + 1.7 }
            #expect(activePeak > 0 && !faded.isEmpty)
            #expect(faded.allSatisfy { weight($0) < activePeak * 0.05 },
                    "Smoothing geometry must not keep the music light visible after playback stops.")
            let last = try #require(frames.last)
            #expect(last.spectrum == .silent && regions(last.spectrum).isEmpty)
        }
    }

    @Test func stalledDisplayFramesDoNotReplayALargeGeometryJump() {
        let steady = AudioSpectrum(low: 0.72, mid: 0.68, high: 0.65, level: 0.75, beat: 0)
        let accent = AudioSpectrum(low: 0.95, mid: 0.9, high: 0.85, level: 0.95, beat: 1)
        var settled = AudioSpectrumMotion()
        for _ in 0..<180 { _ = settled.advance(towards: steady, elapsed: 1.0 / 60) }

        for gap in [0.1, 0.3] {
            var motion = settled
            var time = 0.0
            var frames = [SpectrumFrame(time: time, spectrum: motion.value)]
            // The first frame after a main-loop stall must remain small even
            // though the fast brightness target has changed during the gap.
            for frame in 0..<70 {
                let elapsed = frame == 0 || frame == 35 ? gap : 1.0 / 60
                time += elapsed
                let target = frame < 35 ? accent : steady
                frames.append(SpectrumFrame(time: time, spectrum: motion.advance(towards: target, elapsed: elapsed)))
            }
            expectSmoothHeights(frames, intensity: 1, maxStep: 3)
            expectSmoothHeights(frames, intensity: 1.5, maxStep: 4)
            let initial = regions(frames[0].spectrum, intensity: 1)
            let moving = regions(frames[20].spectrum, intensity: 1)
            #expect(moving[0].crestHeight > initial[0].crestHeight + 6,
                    "Preventing a catch-up jump must not freeze the contour on subsequent normal frames.")
        }
    }

    @Test func sustainedTypingSoftensOnlyTheVerticalMusicAccent() {
        let steady = AudioSpectrum(low: 0.8, mid: 0.65, high: 0.6, level: 0.8, beat: 0)
        let accent = AudioSpectrum(low: 0.8, mid: 0.65, high: 0.6, level: 0.8, beat: 0.85)
        let base = regions(steady, keyboardEnergy: 0)
        let baseTyping = regions(steady, keyboardEnergy: 1)
        let solo = regions(accent, keyboardEnergy: 0)
        let typing = regions(accent, keyboardEnergy: 1)
        for side in 0..<2 {
            #expect(baseTyping[side].crestHeight == base[side].crestHeight)
            #expect(baseTyping[side].bodyHeight == base[side].bodyHeight)
            let soloLift = solo[side].crestHeight - base[side].crestHeight
            let typingLift = typing[side].crestHeight - baseTyping[side].crestHeight
            #expect(typingLift > soloLift * 0.60 && typingLift < soloLift * 0.85,
                    "Sustained typing should soften the music's vertical accent without removing its rhythm.")
            #expect(typing[side].centerX == solo[side].centerX && typing[side].crestX == solo[side].crestX)
            #expect(typing[side].radiusX == solo[side].radiusX && typing[side].crestRadiusX == solo[side].crestRadiusX)
            #expect(typing[side].shoulder == solo[side].shoulder && typing[side].hue == solo[side].hue)
            #expect(typing[side].bodyOpacity <= solo[side].bodyOpacity && typing[side].crestOpacity <= solo[side].crestOpacity)
        }
    }
}
