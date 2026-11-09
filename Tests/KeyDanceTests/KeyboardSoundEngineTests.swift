import AVFoundation
import Foundation
import Testing
@testable import KeyDance

/// Production cache, event queue, and mixer; no audio device or user preferences.
@Suite(.serialized)
@MainActor
struct KeyboardSoundEngineTests {
    private func engine(_ style: KeyboardSoundStyle = .red, volume: Double = 1) -> KeyboardSoundEngine {
        let result = KeyboardSoundEngine(audioDeviceEnabled: false)
        result.style = style; result.volume = volume; result.start()
        return result
    }
    private func energy(_ samples: [Float]) -> Double {
        samples.reduce(0) { $0 + Double($1) * Double($1) }
    }
    private func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }
    private func correlation(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        var aa = 0.0, bb = 0.0, ab = 0.0
        for index in 0..<count {
            let av = Double(a[index]), bv = Double(b[index])
            aa += av * av; bb += bv * bv; ab += av * bv
        }
        return ab / sqrt(max(1e-20, aa * bb))
    }
    private func tap(_ style: KeyboardSoundStyle, key: UInt16) -> [Float] {
        let e = engine(style)
        e.noteOn(keyCode: key)
        var pcm = e.renderForVerification(frames: 1_920)
        e.noteOff(keyCode: key)
        pcm += e.renderForVerification(frames: 12_000)
        e.stop()
        return pcm
    }

    @Test func silenceAndMutedStartupAreExactAndStopCannotReplayOldKeys() {
        let e = KeyboardSoundEngine(audioDeviceEnabled: false)
        e.noteOn(keyCode: 0)
        #expect(e.renderForVerification(frames: 512).allSatisfy { $0 == 0 })
        #expect(e.heldKeyCount == 0)
        e.volume = 0; e.start()
        e.noteOn(keyCode: 0); e.noteOff(keyCode: 0)
        #expect(e.renderForVerification(frames: 8_192).allSatisfy { $0 == 0 })
        #expect(e.diagnostics.attacks == 1 && e.diagnostics.releases == 1)
        e.volume = 1; e.noteOn(keyCode: 49)
        #expect(energy(e.renderForVerification(frames: 1_024)) > 0)
        e.stop()
        #expect(!e.isRunning && e.heldKeyCount == 0 && e.diagnostics.activeVoices == 0)
        #expect(e.renderForVerification(frames: 512).allSatisfy { $0 == 0 })
        e.start()
        #expect(e.renderForVerification(frames: 8_192).allSatisfy { $0 == 0 })
        e.stop()
    }

    @Test func everyPresetAndKeyFamilyHasImmediateFiniteTransientAndSilentTail() {
        for style in KeyboardSoundStyle.allCases {
            for key: UInt16 in [0, 49, 36, 51, 48, 56] {
                let e = engine(style)
                e.noteOn(keyCode: key)
                let onset = e.renderForVerification(frames: 96)
                #expect(energy(onset) > 1e-8, "Each key must begin within the first 2ms of rendered PCM.")
                e.noteOff(keyCode: key)
                let tail = e.renderForVerification(frames: 24_000)
                let finite = tail.allSatisfy(\.isFinite)
                #expect(finite)
                #expect(peak(onset + tail) <= 0.420001)
                #expect(tail.suffix(4_800).allSatisfy { $0 == 0 })
                #expect(e.diagnostics.attacks == 1 && e.diagnostics.releases == 1)
                #expect(e.diagnostics.activeVoices == 0)
                e.stop()
            }
        }
    }

    @Test func presetsFamiliesAndActuationVariantsAreAudiblyDifferentPCM() {
        let styles = KeyboardSoundStyle.allCases.map { tap($0, key: 0) }
        for i in styles.indices {
            for j in styles.indices where i < j {
                #expect(abs(correlation(styles[i], styles[j])) < 0.92)
            }
        }
        for style in KeyboardSoundStyle.allCases {
            let ordinary = tap(style, key: 0)
            for key: UInt16 in [49, 36, 51] {
                #expect(abs(correlation(ordinary, tap(style, key: key))) < 0.92)
            }
            let e = engine(style)
            e.noteOn(keyCode: 0)
            let first = e.renderForVerification(frames: 8_192)
            e.noteOff(keyCode: 0); _ = e.renderForVerification(frames: 8_192)
            e.noteOn(keyCode: 0)
            let second = e.renderForVerification(frames: 8_192)
            if [.panda, .macbookPro, .hermes, .mahjongTiles, .woodDesk].contains(style) || !style.isRecorded {
                #expect(first != second)
            } else {
                #expect(first == second, "One real recording of this physical key must not be pitch-shifted into fake variants.")
            }
            e.stop()
        }
        #expect(tap(.panda, key: 0) == tap(.panda, key: 48), "Holy Panda has no dedicated Tab recording; the UI describes its generic fallback.")
        // Red's attack should contain less sample-to-sample high-frequency energy
        // than blue. This catches accidentally assigning every preset one clip.
        func roughness(_ pcm: [Float]) -> Double {
            var value = 0.0
            for i in stride(from: 2, to: min(1_920, pcm.count), by: 2) {
                let delta = Double(pcm[i] - pcm[i - 2]); value += delta * delta
            }
            return value / max(1e-20, energy(Array(pcm.prefix(1_920))))
        }
        #expect(roughness(styles[1]) > roughness(styles[0]) * 1.2)
    }

    @Test func physicalRepeatAndUnknownReleaseAreBitExactNoOps() {
        let reference = engine(.brown), repeated = engine(.brown)
        reference.noteOn(keyCode: 0); repeated.noteOn(keyCode: 0)
        for _ in 0..<50 { repeated.noteOn(keyCode: 0); repeated.noteOff(keyCode: 11) }
        #expect(reference.renderForVerification(frames: 4_800) == repeated.renderForVerification(frames: 4_800))
        reference.noteOff(keyCode: 0); repeated.noteOff(keyCode: 0); repeated.noteOff(keyCode: 0)
        #expect(reference.renderForVerification(frames: 8_192) == repeated.renderForVerification(frames: 8_192))
        #expect(repeated.diagnostics.attacks == 1 && repeated.diagnostics.releases == 1)
        #expect(repeated.heldKeyCount == 0)
        reference.stop(); repeated.stop()
    }

    @Test func immediateCapsTapPreservesAttackThenAddsReturnWithoutCancellingIt() {
        let down = engine(.blue), tap = engine(.blue)
        down.noteOn(keyCode: 57)
        tap.noteOn(keyCode: 57); tap.noteOff(keyCode: 57)
        #expect(down.renderForVerification(frames: 576) == tap.renderForVerification(frames: 576))
        let onlyDown = down.renderForVerification(frames: 3_000)
        let downAndUp = tap.renderForVerification(frames: 3_000)
        #expect(onlyDown != downAndUp)
        #expect(energy(downAndUp) > 0)
        #expect(tap.diagnostics.attacks == 1 && tap.diagnostics.releases == 1)
        #expect(tap.heldKeyCount == 0)
        down.stop(); tap.stop()
    }

    @Test func previewUsesNaturalSeventyMillisecondPressWhilePhysicalTapRemainsImmediate() {
        let down = engine(.panda), preview = engine(.panda)
        down.noteOn(keyCode: 49); preview.preview(keyCode: 49)
        #expect(down.renderForVerification(frames: 3_360) == preview.renderForVerification(frames: 3_360))
        let held = down.renderForVerification(frames: 4_800)
        let returned = preview.renderForVerification(frames: 4_800)
        #expect(held != returned)
        #expect(preview.heldKeyCount == 0)
        #expect(preview.diagnostics.attacks == 1 && preview.diagnostics.releases == 1)
        down.stop(); preview.stop()
    }

    @Test func previewDoesNotOwnOrReleasePhysicalKeyAndResetDoesNotSynthesizeUps() {
        let e = engine(.mahjong)
        e.noteOn(keyCode: 49); _ = e.renderForVerification(frames: 512)
        e.preview(keyCode: 49)
        #expect(e.heldKeyCount == 1)
        _ = e.renderForVerification(frames: 4_800)
        #expect(e.diagnostics.attacks == 2 && e.diagnostics.releases == 1)
        e.noteOff(keyCode: 49); _ = e.renderForVerification(frames: 4_800)
        #expect(e.heldKeyCount == 0 && e.diagnostics.releases == 2)
        e.noteOn(keyCode: 0); _ = e.renderForVerification(frames: 128)
        let releases = e.diagnostics.releases
        e.releaseAll(); let tail = e.renderForVerification(frames: 4_800)
        #expect(e.diagnostics.releases == releases)
        #expect(e.heldKeyCount == 0 && e.diagnostics.activeVoices == 0)
        #expect(tail.dropFirst(480).allSatisfy { $0 == 0 })
        e.noteOff(keyCode: 0)
        #expect(e.renderForVerification(frames: 2_048).allSatisfy { $0 == 0 })
        e.stop()
    }

    @Test func resetCancelsPendingReturnAndQueuedAttackBeforeItCanSound() {
        let e = engine(.blue)
        e.preview(keyCode: 49)
        _ = e.renderForVerification(frames: 96)
        e.releaseAll()
        let afterReset = e.renderForVerification(frames: 4_800)
        #expect(afterReset.dropFirst(480).allSatisfy { $0 == 0 })
        e.noteOn(keyCode: 0); e.releaseAll()
        #expect(e.renderForVerification(frames: 4_800).allSatisfy { $0 == 0 })
        e.stop()
    }

    @Test func simultaneousAndFastInputStayWithinFixedPolyphonyAndHeadroom() {
        let e = engine(.mahjong)
        for key: UInt16 in 0..<128 { e.noteOn(keyCode: key); e.noteOff(keyCode: key) }
        var maximum = peak(e.renderForVerification(frames: 9_600))
        #expect(e.diagnostics.attacks == 128 && e.diagnostics.releases == 128)
        #expect(e.diagnostics.maximumActiveVoices <= KeyboardSoundEngine.maximumVoices)
        #expect(e.diagnostics.droppedEvents == 0)
        for i in 0..<250 {
            let code = UInt16(i % 50)
            e.noteOn(keyCode: code); e.noteOff(keyCode: code)
            let pcm = e.renderForVerification(frames: 960)
            let finite = pcm.allSatisfy(\.isFinite)
            #expect(finite)
            maximum = max(maximum, peak(pcm))
        }
        #expect(maximum < 0.420001)
        #expect(e.diagnostics.attacks == 378 && e.diagnostics.releases == 378)
        #expect(e.diagnostics.maximumActiveVoices <= KeyboardSoundEngine.maximumVoices)
        #expect(e.diagnostics.droppedEvents == 0)
        #expect(e.heldKeyCount == 0)
        #expect(e.renderForVerification(frames: 24_000).suffix(4_800).allSatisfy { $0 == 0 })
        e.stop()
    }

    @Test func allRecordedPacksAreVerifiedAndMappedWithoutSynthesizedFallback() {
        let e = engine(.panda)
        var hashes = Set<String>()
        for style in KeyboardSoundStyle.allCases where style.isRecorded {
            let info = e.recordingInfo(for: style)
            #expect(info != nil)
            #expect((info?.mappedKeyCount ?? 0) >= 100)
            let oneShot = [.hermes, .mahjongTiles, .woodDesk].contains(style)
            #expect((info?.clipCount ?? 0) >= (oneShot ? 8 : 12))
            if oneShot {
                #expect(info?.separateReleaseKeyCount == 0)
            } else {
                #expect((info?.separateReleaseKeyCount ?? 0) > 0)
            }
            if let info { hashes.insert(info.sha256) }
        }
        #expect(hashes.count == KeyboardSoundStyle.allCases.filter(\.isRecorded).count)
        #expect(e.recordingInfo(for: .mahjong) == nil)
        #expect(!KeyboardSoundStyle.mahjong.isRecorded)
        e.stop()
    }

    @Test func allVerifiedHiFiPacksPreserveKeyRolesAndPlayAlternatePCM() throws {
        for style in KeyboardSoundStyle.allCases {
            let original = engine(style)
            let polished = engine(style)
            polished.quality = .hiFi
            defer { original.stop(); polished.stop() }
            #expect(polished.supportsHiFi(for: style) == style.isRecorded)
            let dry = try #require(original.loudnessProfile(for: style))
            let clean = try #require(polished.loudnessProfile(for: style, quality: .hiFi))
            let comparison = (clean.measuredRMS * Double(clean.gain)) / (dry.measuredRMS * Double(dry.gain))
            #expect((0.85...1.18).contains(comparison), "Playback levels should stay comparable when switching versions.")
            for key: UInt16 in [0, 49, 36, 51, 48, 56] {
                #expect(original.hasIndependentRelease(keyCode: key) == polished.hasIndependentRelease(keyCode: key))
                original.noteOn(keyCode: key); polished.noteOn(keyCode: key)
                let a = original.renderForVerification(frames: 96)
                let b = polished.renderForVerification(frames: 96)
                #expect(energy(b) > 1e-8)
                original.noteOff(keyCode: key); polished.noteOff(keyCode: key)
                let cleanTail = polished.renderForVerification(frames: 24_000)
                let dryTail = original.renderForVerification(frames: 24_000)
                #expect(cleanTail.suffix(4_800).allSatisfy { $0 == 0 })
                #expect((a == b && dryTail == cleanTail) != style.isRecorded)
            }
        }
    }

    @Test func changingRecordingQualityKeepsHeldKeyAndItsOriginalRelease() {
        let reference = engine(.blue), switched = engine(.blue)
        defer { reference.stop(); switched.stop() }
        reference.noteOn(keyCode: 0); switched.noteOn(keyCode: 0)
        #expect(reference.renderForVerification(frames: 4_800) == switched.renderForVerification(frames: 4_800))
        switched.quality = .hiFi
        #expect(switched.isRunning && switched.heldKeyCount == 1)
        reference.noteOff(keyCode: 0); switched.noteOff(keyCode: 0)
        #expect(reference.renderForVerification(frames: 8_192) == switched.renderForVerification(frames: 8_192))
        reference.noteOn(keyCode: 0); switched.noteOn(keyCode: 0)
        #expect(reference.renderForVerification(frames: 4_800) != switched.renderForVerification(frames: 4_800))
    }

    @Test func missingOrCorruptRecordingFailsClosedButExplicitSyntheticPresetStillWorks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let e = KeyboardSoundEngine(audioDeviceEnabled: false, recordingResourceURL: folder)
        e.start(); e.noteOn(keyCode: 0)
        #expect(!e.isRunning && e.errorMessage != nil)
        #expect(e.renderForVerification(frames: 4_800).allSatisfy { $0 == 0 })
        #expect(e.diagnostics.attacks == 0)
        e.style = .mahjong; e.start(); e.noteOn(keyCode: 0)
        #expect(e.isRunning && e.errorMessage == nil)
        #expect(energy(e.renderForVerification(frames: 4_800)) > 0)
        e.style = .red
        #expect(!e.isRunning && e.errorMessage != nil)
        #expect(e.renderForVerification(frames: 4_800).allSatisfy { $0 == 0 })
        e.stop()
        let pair: [String: Any] = ["down": [0], "up": []]
        let pack: [String: Any] = ["sampleRate": 48_000, "channels": 2, "file": "red/samples.wav",
            "sha256": String(repeating: "0", count: 64), "frames": 4,
            "clips": [["startFrame": 0, "frames": 4]], "keys": ["0": pair], "fallback": pair]
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("red"), withIntermediateDirectories: true)
        try Data("corrupted audio".utf8).write(to: folder.appendingPathComponent("red/samples.wav"))
        try JSONSerialization.data(withJSONObject: ["schema": 1, "sampleRate": 48_000, "packs": ["red": pack]])
            .write(to: folder.appendingPathComponent("manifest.json"))
        let corrupt = KeyboardSoundEngine(audioDeviceEnabled: false, recordingResourceURL: folder)
        corrupt.start(); corrupt.noteOn(keyCode: 0)
        #expect(!corrupt.isRunning && corrupt.errorMessage != nil)
        #expect(corrupt.recordingInfo(for: .red) == nil)
        #expect(corrupt.renderForVerification(frames: 4_800).allSatisfy { $0 == 0 })
        corrupt.stop()
    }

    @Test func ambiguousRecordedReleaseRemainsOneShotAndDoesNotInventAnUpSound() {
        let reference = engine(.topre), released = engine(.topre)
        #expect(!released.hasIndependentRelease(keyCode: 57))
        reference.noteOn(keyCode: 57)
        released.noteOn(keyCode: 57); released.noteOff(keyCode: 57)
        #expect(reference.renderForVerification(frames: 12_000) == released.renderForVerification(frames: 12_000))
        #expect(released.diagnostics.attacks == 1 && released.diagnostics.releases == 1)
        reference.stop(); released.stop()
    }

    @Test func everyRecordedPackKeepsSimultaneousStereoVoicesWithinHeadroom() {
        for style in KeyboardSoundStyle.allCases where style.isRecorded {
            let e = engine(style)
            for key: UInt16 in 0..<128 { e.noteOn(keyCode: key); e.noteOff(keyCode: key) }
            let pcm = e.renderForVerification(frames: 24_000)
            let finite = pcm.allSatisfy(\.isFinite)
            #expect(finite)
            #expect(peak(pcm) < 0.420001)
            #expect(e.diagnostics.attacks == 128 && e.diagnostics.releases == 128)
            #expect(e.diagnostics.maximumActiveVoices <= KeyboardSoundEngine.maximumVoices)
            #expect(e.diagnostics.droppedEvents == 0)
            #expect(pcm.suffix(4_800).allSatisfy { $0 == 0 })
            e.stop()
        }
    }

    @Test func recordedDownAndUpVariantsKeepTheirSourceKeyIdentity() throws {
        let root = try #require(KeyboardSoundEngine.recordingResourcesURL)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let manifest = try #require(object as? [String: Any])
        let packs = try #require(manifest["packs"] as? [String: [String: Any]])
        for (style, pack) in packs {
            let clips = try #require(pack["clips"] as? [[String: Any]])
            let keys = try #require(pack["keys"] as? [String: [String: Any]])
            let fallback = try #require(pack["fallback"] as? [String: Any])
            for pair in Array(keys.values) + [fallback] {
                let down = try #require(pair["down"] as? [Int])
                let up = try #require(pair["up"] as? [Int])
                if up.isEmpty { continue }
                if style == "panda" { #expect(up.count == 1); continue }
                #expect(down.count == up.count)
                for index in 0..<min(down.count, up.count) {
                    let first = try #require(clips[down[index]]["provenance"] as? [String: Any])
                    let second = try #require(clips[up[index]]["provenance"] as? [String: Any])
                    #expect(first["sourceKey"] as? String == second["sourceKey"] as? String)
                    #expect(first["method"] as? String == "two-contacts-with-quiet-gap")
                    #expect(second["method"] as? String == "two-contacts-with-quiet-gap")
                }
            }
        }
    }

    @Test func realKeyCancelsQueuedPreviewBeforeItCanOverlapTyping() {
        let e = engine(.panda)
        e.preview(keyCode: 49)
        e.noteOn(keyCode: 0)
        _ = e.renderForVerification(frames: 4_800)
        #expect(e.diagnostics.attacks == 1 && e.diagnostics.releases == 0)
        #expect(e.heldKeyCount == 1)
        e.noteOff(keyCode: 0); _ = e.renderForVerification(frames: 8_192)
        #expect(e.diagnostics.releases == 1 && e.heldKeyCount == 0)
        e.stop()
    }

    @Test func physicalTypingCancelsFuturePreviewNotesWithoutReleasingHeldKeys() async {
        let e = engine(.panda)
        e.noteOn(keyCode: 49); _ = e.renderForVerification(frames: 512)
        e.previewSequence()
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            _ = e.renderForVerification(frames: 512)
            if e.diagnostics.attacks >= 2 { break }
        }
        #expect(e.diagnostics.attacks >= 2)
        #expect(e.heldKeyCount == 1)
        e.noteOn(keyCode: 0)
        _ = e.renderForVerification(frames: 4_800)
        let afterPhysical = e.diagnostics.attacks
        try? await Task.sleep(nanoseconds: 1_300_000_000)
        _ = e.renderForVerification(frames: 8_192)
        #expect(e.diagnostics.attacks == afterPhysical)
        #expect(e.heldKeyCount == 2)
        e.noteOff(keyCode: 0); e.noteOff(keyCode: 49)
        _ = e.renderForVerification(frames: 8_192)
        #expect(e.heldKeyCount == 0)
        e.stop()
    }

    @Test func stopStyleChangeAndResetCancelPreviewSequence() async {
        for operation in 0..<3 {
            let e = engine(.panda)
            e.previewSequence()
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 10_000_000)
                _ = e.renderForVerification(frames: 512)
                if e.diagnostics.attacks > 0 { break }
            }
            #expect(e.diagnostics.attacks > 0)
            if operation == 0 { e.stop() }
            else if operation == 1 { e.style = .red }
            else { e.releaseAll() }
            let count = e.diagnostics.attacks
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            let pcm = e.renderForVerification(frames: 8_192)
            #expect(e.diagnostics.attacks == count)
            #expect(pcm.suffix(4_800).allSatisfy { $0 == 0 })
            #expect(e.heldKeyCount == 0)
            e.stop()
        }
    }
}

@Suite(.serialized)
@MainActor
struct KeyboardSoundSwitchingAndLatencyTests {
    private func engine(_ style: KeyboardSoundStyle = .panda, volume: Double = 1) -> KeyboardSoundEngine {
        let e = KeyboardSoundEngine(audioDeviceEnabled: false)
        e.style = style; e.volume = volume; e.start()
        return e
    }
    private func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }
    private func energy(_ samples: [Float]) -> Double { samples.reduce(0) { $0 + Double($1) * Double($1) } }

    @Test func doubleVolumeIsExactlyTwiceOldMaximumAndStillBoundedUnderOverload() {
        let normal = engine(), boosted = engine(volume: 2)
        for key: UInt16 in [0, 49, 36, 51, 48, 57] { normal.noteOn(keyCode: key); boosted.noteOn(keyCode: key) }
        let one = normal.renderForVerification(frames: 12_000), two = boosted.renderForVerification(frames: 12_000)
        #expect(two == one.map { $0 * 2 })
        #expect(peak(two) < 0.840001)
        #expect(energy(two) > energy(one) * 3.999)
        for e in [normal, boosted] { e.stop() }
        let e = engine(.blue, volume: 2)
        for key: UInt16 in 0..<128 { e.noteOn(keyCode: key); e.noteOff(keyCode: key) }
        let burst = e.renderForVerification(frames: 24_000)
        #expect(burst.allSatisfy(\.isFinite) && peak(burst) < 0.840001)
        #expect(e.diagnostics.maximumActiveVoices <= 24 && e.diagnostics.droppedEvents == 0)
        e.stop()
    }

    @Test func rapidBigKeysDoNotWaitForPriorTailOrKeyUpAndTimingIsMeasured() {
        let e = engine(.red, volume: 2)
        var expected: UInt64 = 0
        for _ in 0..<20 {
            for key: UInt16 in [49, 36, 51, 48, 57, 56, 60, 76, 117] {
                e.noteOn(keyCode: key); expected += 1
                let pcm = e.renderForVerification(frames: 96)
                #expect(energy(pcm) > 1e-8)
                #expect(e.diagnostics.attacks == expected)
                e.noteOff(keyCode: key)
                _ = e.renderForVerification(frames: 384)
            }
        }
        #expect(e.diagnostics.releases == expected && e.heldKeyCount == 0)
        #expect(e.diagnostics.renderedAttacksWithTiming == expected)
        #expect(e.diagnostics.maximumQueueSeconds >= e.diagnostics.meanQueueSeconds)
        #expect(e.diagnostics.meanQueueSeconds >= 0 && e.diagnostics.maximumRenderFrames == 384)
        #expect(e.diagnostics.droppedEvents == 0)
        e.stop()
    }


    @Test func everyPresetSwitchImmediatelySelectsItsOwnAttackAndReleasePCM() {
        for target in KeyboardSoundStyle.allCases {
            let switched = engine(target == .blue ? .red : .blue)
            let reference = engine(target)
            // Keep variant histories equal, including Panda/Mahjong. A real
            // selection must also clear a physical key held in the old preset.
            for e in [switched, reference] { e.noteOn(keyCode: 0); _ = e.renderForVerification(frames: 96) }
            switched.style = target; reference.releaseAll()
            #expect(switched.style == target && switched.isRunning && switched.heldKeyCount == 0)
            #expect(switched.errorMessage == nil)
            // Old transient gets its existing click-free 5 ms fade, never a
            // newly synthesized return. Then every sample must be the target.
            _ = switched.renderForVerification(frames: 512)
            _ = reference.renderForVerification(frames: 512)
            for key: UInt16 in [0, 49, 36, 51, 48] {
                switched.noteOn(keyCode: key); reference.noteOn(keyCode: key)
                let actual = switched.renderForVerification(frames: 3_360)
                let expected = reference.renderForVerification(frames: 3_360)
                #expect(actual == expected, "Wrong attack bank after selecting \(target.rawValue), key \(key)")
                #expect(energy(actual) > 0)
                switched.noteOff(keyCode: key); reference.noteOff(keyCode: key)
                #expect(switched.renderForVerification(frames: 24_000) == reference.renderForVerification(frames: 24_000),
                        "Wrong release bank after selecting \(target.rawValue), key \(key)")
            }
            #expect(switched.diagnostics.releases == 5, "Selection must not invent an up for the old held key.")
            switched.stop(); reference.stop()
        }
    }

    @Test func selectingEveryPresetDiscardsPreviouslyQueuedBlueKeysAndPreview() {
        for target in KeyboardSoundStyle.allCases {
            let switched = engine(target == .blue ? .red : .blue), reference = engine(target)
            // None of these commands has reached the renderer. They must not
            // survive a preset change or consume voices in the selected bank.
            for e in [switched, reference] {
                e.noteOn(keyCode: 0); e.noteOff(keyCode: 0); e.preview(keyCode: 49)
            }
            switched.style = target; reference.releaseAll()
            switched.noteOn(keyCode: 49); reference.noteOn(keyCode: 49)
            #expect(switched.renderForVerification(frames: 12_000) == reference.renderForVerification(frames: 12_000))
            #expect(switched.diagnostics.attacks == 1 && switched.diagnostics.releases == 0)
            #expect(switched.heldKeyCount == 1)
            switched.noteOff(keyCode: 49); reference.noteOff(keyCode: 49)
            #expect(switched.renderForVerification(frames: 24_000) == reference.renderForVerification(frames: 24_000))
            #expect(switched.diagnostics.releases == 1 && switched.heldKeyCount == 0)
            switched.stop(); reference.stop()
        }
    }
}

@Suite(.serialized)
@MainActor
struct KeyboardSoundExpansionTests {
    private func engine(_ style: KeyboardSoundStyle, volume: Double) -> KeyboardSoundEngine {
        let engine = KeyboardSoundEngine(audioDeviceEnabled: false)
        engine.style = style; engine.volume = volume; engine.start()
        return engine
    }
    private func energy(_ samples: [Float]) -> Double { samples.reduce(0) { $0 + Double($1) * Double($1) } }

    @Test func sixteenHundredPercentLiftsQuietContactsAndBoundsAllPresetsAtExtremeDensity() {
        #expect(KeyboardSoundEngine.maximumVolume == 16)
        for style in KeyboardSoundStyle.allCases {
            let two = engine(style, volume: 2), four = engine(style, volume: 4), maximum = engine(style, volume: 16)
            two.noteOn(keyCode: 0); four.noteOn(keyCode: 0); maximum.noteOn(keyCode: 0)
            let old = two.renderForVerification(frames: 12_000), louder = four.renderForVerification(frames: 12_000)
            let loudest = maximum.renderForVerification(frames: 12_000)
            #expect(energy(louder) > energy(old) * 1.8, "400% must actually increase quiet-key output.")
            #expect(louder.allSatisfy { $0.isFinite && abs($0) < 0.981 })
            #expect(energy(loudest) > energy(louder) * 4, "1600% must at least double the tap RMS for \(style.rawValue).")
            #expect(loudest.allSatisfy { $0.isFinite && abs($0) < 0.980001 })
            two.stop(); four.stop(); maximum.stop()
            let dense = engine(style, volume: 16)
            for key: UInt16 in 0..<128 { dense.noteOn(keyCode: key); dense.noteOff(keyCode: key) }
            var pcm = dense.renderForVerification(frames: 512)
            var peak = pcm.map { abs($0) }.max() ?? 0
            for i in 0..<160 {
                let key = UInt16([0, 1, 2, 49, 36, 51, 48, 57][i % 8])
                dense.noteOn(keyCode: key); dense.noteOff(keyCode: key)
                pcm = dense.renderForVerification(frames: 480)
                #expect(pcm.allSatisfy { $0.isFinite && abs($0) < 0.980001 })
                peak = max(peak, pcm.map { abs($0) }.max() ?? 0)
            }
            #expect(peak > 0.1 && peak < 0.980001)
            #expect(dense.diagnostics.attacks == 288 && dense.diagnostics.releases == 288)
            #expect(dense.diagnostics.maximumActiveVoices <= 24 && dense.diagnostics.droppedEvents == 0)
            #expect(dense.heldKeyCount == 0)
            #expect(dense.renderForVerification(frames: 48_000).suffix(9_600).allSatisfy { $0 == 0 })
            dense.stop()
        }
    }

    @Test func invalidVolumesStaySilentAndChangingBoostDoesNotCreateSoundWithoutKeys() {
        for volume in [Double.nan, .infinity, -.infinity, -10] {
            let e = engine(.laser, volume: volume)
            e.noteOn(keyCode: 0); e.noteOff(keyCode: 0)
            #expect(e.renderForVerification(frames: 12_000).allSatisfy { $0 == 0 })
            e.stop()
        }
        let e = engine(.bubble, volume: 0)
        for volume in [1.0, 2, 2.001, 4, 100, 0] {
            e.volume = volume
            #expect(e.renderForVerification(frames: 512).allSatisfy { $0 == 0 })
        }
        #expect(e.diagnostics.attacks == 0)
        e.stop()

        let maximum = engine(.woodDesk, volume: 16), over = engine(.woodDesk, volume: 100)
        maximum.noteOn(keyCode: 49); over.noteOn(keyCode: 49)
        #expect(maximum.renderForVerification(frames: 12_000) == over.renderForVerification(frames: 12_000))
        maximum.stop(); over.stop()
    }

    @Test func preallocatedOfflineRendererIsBitExactWithArrayConveniencePath() {
        let a = engine(.typewriter, volume: 4), b = engine(.typewriter, volume: 4)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { left.deallocate(); right.deallocate(); a.stop(); b.stop() }
        for i in 0..<80 {
            if i % 8 == 0 { a.noteOn(keyCode: 49); b.noteOn(keyCode: 49) }
            if i % 8 == 4 { a.noteOff(keyCode: 49); b.noteOff(keyCode: 49) }
            let expected = a.renderForVerification(frames: 512)
            b.renderIntoForVerification(frames: 512, left: left, right: right)
            for frame in 0..<512 { #expect(left[frame] == expected[frame * 2] && right[frame] == expected[frame * 2 + 1]) }
        }
        #expect(a.diagnostics.attacks == b.diagnostics.attacks)
        #expect(a.diagnostics.renderedFrames == b.diagnostics.renderedFrames)
    }
}

@Suite(.serialized)
@MainActor
struct KeyboardSynthesisExportTests {
    @Test func exportedFloatSamplesMatchNativeCacheAndHaveIndependentReturnGestures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyboard-synthesis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try KeyboardSoundEngine.exportSynthesizedResources(to: root)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("synthetic-manifest.json")))
        let manifest = try #require(object as? [String: Any])
        let packs = try #require(manifest["packs"] as? [String: [String: Any]])
        #expect(packs.count == KeyboardSoundStyle.allCases.filter(\.usesNativeFoley).count)
        var hashes = Set<String>()
        for style in KeyboardSoundStyle.allCases where style.usesNativeFoley {
            let pack = try #require(packs[style.rawValue])
            let entries = try #require(pack["clips"] as? [[String: Any]])
            #expect(entries.count == 36)
            #expect(pack["recorded"] as? Bool == false)
            hashes.insert(try #require(pack["sha256"] as? String))
            let file = try AVAudioFile(forReading: root.appendingPathComponent(try #require(pack["file"] as? String)))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: pcm)
            let channels = try #require(pcm.floatChannelData)
            let e = KeyboardSoundEngine(audioDeviceEnabled: false, normalizationEnabled: false)
            e.style = style; e.volume = 1; e.start()
            // Key F has the ordinary family and the historical centered dry pan.
            e.noteOn(keyCode: 3)
            let down = e.renderForVerification(frames: 12_000)
            e.noteOff(keyCode: 3)
            let up = e.renderForVerification(frames: 12_000)
            for (index, actual) in [(0, down), (3, up)] {
                let start = try #require(entries[index]["startFrame"] as? Int)
                let count = try #require(entries[index]["frames"] as? Int)
                let expected = (0..<count).flatMap { [channels[0][start + $0], channels[1][start + $0]] }
                #expect(Array(actual.prefix(count * 2)) == expected)
                #expect(actual.dropFirst(count * 2).allSatisfy { $0 == 0 })
            }
            #expect(down != up)
            #expect(up.contains { abs($0) > 0.001 })
            #expect(e.diagnostics.attacks == 1 && e.diagnostics.releases == 1)
            e.stop()
        }
        #expect(hashes.count == packs.count)
    }
}
