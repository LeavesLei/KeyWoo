import Foundation
import Testing
@testable import KeyDance

private final class RhythmDefaults: UserDefaults {
    private var values: [String: Any]
    init(_ values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "KeyWooRhythmTests-\(UUID().uuidString)")!
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
}

/// Uses isolated stores and disabled input/audio devices; these checks never
/// display a floating panel or read/write the user's preferences or counts.
struct RhythmIntegrationTests {
    @MainActor private func fixture(_ defaults: UserDefaults = RhythmDefaults(), musicModeAvailable: Bool = false) throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooRhythmTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = AppModel(defaults: defaults,
                             statistics: StatisticsStore(storageURL: root.appendingPathComponent("statistics.json")),
                             music: LocalMusicStore(directory: root.appendingPathComponent("Music")),
                             audioEngine: SoundEngine(audioDeviceEnabled: false),
                             keyboardAudioEngine: KeyboardSoundEngine(audioDeviceEnabled: false),
                             startsKeyboardMonitor: false, musicModeAvailable: musicModeAvailable,
                             remapController: RemapController(store: RemapStore(url: root.appendingPathComponent("remap.json"))))
        return (model, root)
    }

    @Test @MainActor func optInDoesNotChangeAudioSettingsOrPhysicalCounts() throws {
        let (model, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(!model.rhythmEnabled)
        let volume = model.keyboardVolume
        let preset = model.keyboardSoundStyle
        model.receiveKey(0)
        model.releaseKey(0)
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        model.rhythmEnabled = true
        model.receiveKey(49)
        model.receiveKey(49)
        #expect(model.rhythmFeedback.dynamics.pulses.count == 1)
        #expect(model.rhythmFeedback.dynamics.pulses.last?.profile.code == 49)
        #expect(model.sessionTotal == 2)
        #expect(model.heldKeys == [49])
        model.releaseKey(49)
        model.receiveKey(49)
        #expect(model.rhythmFeedback.dynamics.pulses.count == 2)
        #expect(model.sessionTotal == 3)
        #expect(model.keyboardVolume == volume && model.keyboardSoundStyle == preset)
    }

    @Test @MainActor func disablingAndMasterPauseClearAnimationAndRejectNewPulses() throws {
        let (model, root) = try fixture(RhythmDefaults(["rhythmEnabled": true]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.receiveKey(49)
        #expect(model.rhythmFeedback.isAnimating)
        model.rhythmEnabled = false
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(!model.rhythmFeedback.isAnimating)
        model.releaseKey(49)
        model.receiveKey(36)
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        model.releaseKey(36)
        model.rhythmEnabled = true
        model.receiveKey(0)
        model.isEnabled = false
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(!model.rhythmFeedback.isAnimating)
        #expect(model.heldKeys.isEmpty)
        let count = model.sessionTotal
        model.receiveKey(49)
        model.previewKey(49)
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(model.sessionTotal == count)
        model.isEnabled = true
        model.receiveKey(49)
        #expect(model.rhythmFeedback.dynamics.pulses.count == 1)
    }

    @Test @MainActor func monitorResetClearsVisualStateWithoutRecountingTheRelease() throws {
        let (model, root) = try fixture(RhythmDefaults(["rhythmEnabled": true]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.receiveKey(49)
        // Secure input, permission/focus loss and sleep use this same callback.
        // This tests its integration, not an actual system secure-input session.
        model.monitor.onReset?()
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(!model.rhythmFeedback.isAnimating)
        #expect(model.heldKeys.isEmpty)
        model.releaseKey(49)
        #expect(model.sessionTotal == 1)
        model.receiveKey(49)
        #expect(model.sessionTotal == 2)
        #expect(model.rhythmFeedback.dynamics.pulses.count == 1)
    }

    @Test @MainActor func auditionDoesNotCountOrReleasePhysicalKeys() throws {
        let (model, root) = try fixture(RhythmDefaults(["rhythmEnabled": true]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.receiveKey(0)
        model.previewKey(49)
        model.previewKey(36)
        #expect(model.sessionTotal == 1 && model.heldKeys == [0])
        #expect(model.rhythmFeedback.dynamics.pulses.map { $0.profile.code } == [0, 49, 36])
        model.shutdown()
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(!model.rhythmFeedback.isAnimating)
    }

    @Test @MainActor func musicModeStillGivesOrdinaryKeysVisualFeedback() throws {
        let (model, root) = try fixture(RhythmDefaults(["rhythmEnabled": true, "experienceMode": "music"]), musicModeAvailable: true)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.receiveKey(0)
        #expect(model.feedbackPulses.isEmpty, "The ordinary key is still excluded from musical gestures.")
        #expect(model.rhythmFeedback.dynamics.pulses.last?.profile.code == 0)
        #expect(model.sessionTotal == 1)
    }

    @Test @MainActor func visualDemoNeverCountsAndCancellationPreventsDelayedPulses() async throws {
        let (model, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.receiveKey(0)
        model.previewRhythm()
        #expect(model.rhythmEnabled)
        try await Task.sleep(for: .milliseconds(40))
        #expect(!model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(model.sessionTotal == 1 && model.heldKeys == [0])
        model.rhythmEnabled = false
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.rhythmFeedback.dynamics.pulses.isEmpty)
        #expect(!model.rhythmFeedback.isAnimating)
        #expect(model.sessionTotal == 1 && model.heldKeys == [0])
        model.isEnabled = false
        model.previewRhythm()
        #expect(!model.rhythmEnabled, "A preview must not override the master pause.")
        model.rhythmClickThrough = true
        model.resetRhythmPosition()
        #expect(!model.rhythmClickThrough, "Reset provides a way to recover an unclickable widget.")
    }

    @Test @MainActor func visualPreferencesRestoreAndIntensityIsValidated() throws {
        let defaults = RhythmDefaults(["rhythmIntensity": Double.nan])
        let (model, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(model.rhythmIntensity == 1)
        model.rhythmEnabled = true
        model.rhythmClickThrough = true
        model.rhythmIntensity = 1.3
        let (restored, restoredRoot) = try fixture(defaults)
        defer { restored.shutdown(); try? FileManager.default.removeItem(at: restoredRoot) }
        #expect(restored.rhythmEnabled && restored.rhythmClickThrough)
        #expect(restored.rhythmIntensity == 1.3 && restored.rhythmFeedback.intensity == 1.3)
        model.rhythmIntensity = 20
        #expect(model.rhythmIntensity == 1.5)
        model.rhythmIntensity = -3
        #expect(model.rhythmIntensity == 0.4)
        model.rhythmIntensity = .infinity
        #expect(model.rhythmIntensity == 1)
    }

    @Test @MainActor func visualStyleRestoresSafelyWithoutChangingAudioOrInputState() throws {
        let defaults = RhythmDefaults(["rhythmStyle": "unknown", "rhythmEnabled": true])
        let (model, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(model.rhythmStyle == .energy && model.rhythmFeedback.visualStyle == .energy)
        #expect(model.rhythmFlashes && model.rhythmFeedback.flashesEnabled)
        model.receiveKey(0)
        let volume = model.keyboardVolume
        let sound = model.keyboardSoundStyle
        let running = model.keyboardAudio.isRunning
        let pulses = model.rhythmFeedback.dynamics.pulses
        let sampleTime = try #require(model.rhythmFeedback.dynamics.lastHit) + 0.15
        let meter = model.rhythmFeedback.dynamics.meterEnergy(at: sampleTime)
        model.rhythmStyle = .pulse
        model.rhythmFlashes = false
        #expect(model.rhythmFeedback.visualStyle == .pulse)
        #expect(!model.rhythmFeedback.flashesEnabled)
        #expect(model.sessionTotal == 1 && model.heldKeys == [0])
        #expect(model.keyboardVolume == volume && model.keyboardSoundStyle == sound)
        #expect(model.keyboardAudio.isRunning == running)
        #expect(model.rhythmFeedback.dynamics.pulses == pulses)
        #expect(model.rhythmFeedback.dynamics.meterEnergy(at: sampleTime) == meter)
        let (restored, restoredRoot) = try fixture(defaults)
        defer { restored.shutdown(); try? FileManager.default.removeItem(at: restoredRoot) }
        #expect(restored.rhythmStyle == .pulse && restored.rhythmFeedback.visualStyle == .pulse)
        #expect(!restored.rhythmFlashes && !restored.rhythmFeedback.flashesEnabled)
    }

    @Test func spaceIsStrongestAndReturnIsSecondWithDistinctLetterProfiles() throws {
        func pulse(_ code: UInt16) throws -> RhythmPulse {
            var dynamics = RhythmDynamics()
            dynamics.receiveKey(code, at: 10)
            return try #require(dynamics.pulses.last)
        }
        let space = try pulse(49), enter = try pulse(36), keypadEnter = try pulse(76), letter = try pulse(0)
        #expect(space.strength > enter.strength && enter.strength > letter.strength)
        #expect(enter.strength == keypadEnter.strength)
        #expect(space.profile.kind == .space && enter.profile.kind == .returnKey)
        let otherLetter = try pulse(37)
        #expect(letter.profile.lane != otherLetter.profile.lane)
        #expect(letter.profile.frequency != otherLetter.profile.frequency || letter.profile.hue != otherLetter.profile.hue)
    }

    @Test func fasterTypingBuildsEnergyButIdleAndHeavyInputStayBounded() {
        var slow = RhythmDynamics(), fast = RhythmDynamics()
        for index in 0..<8 {
            slow.receiveKey(0, at: Double(index))
            fast.receiveKey(0, at: Double(index) * 0.07)
        }
        #expect(fast.energy(at: 0.49) > slow.energy(at: 7))
        #expect(fast.combo > slow.combo)
        for index in 0..<2_000 { fast.receiveKey(49, at: 1 + Double(index) * 0.001) }
        #expect(fast.pulses.count <= 24)
        #expect((0...1).contains(fast.energy(at: 3)))
        #expect(fast.energy(at: 20) < 0.001)
        fast.receiveKey(0, at: 20)
        #expect(fast.combo == 1)
        fast.reset()
        #expect(fast.pulses.isEmpty && fast.combo == 0 && fast.lastHit == nil)
        #expect(fast.energy(at: 20) == 0)
    }

    @Test func spaceFollowedByLettersKeepsTheShockwaveAndContinuousOrbitPhase() throws {
        var dynamics = RhythmDynamics()
        dynamics.receiveKey(49, at: 10)
        let originalSpace = try #require(dynamics.pulses.first)
        // Compare the orbit's position rather than its raw phase, because a
        // 2π wrap is visually continuous. Each letter arrives during the wave.
        for (index, code) in [UInt16(0), 1, 2, 3, 4, 5, 38, 40, 37].enumerated() {
            let time = 10.08 + Double(index) * 0.11
            let phaseBefore = dynamics.phase(at: time)
            let energyBefore = dynamics.visualEnergy(at: time)
            let speedBefore = (phaseBefore - dynamics.phase(at: time - 0.00001)) / 0.00001
            dynamics.receiveKey(code, at: time)
            let phaseAfter = dynamics.phase(at: time)
            let speedAfter = (dynamics.phase(at: time + 0.00001) - phaseAfter) / 0.00001
            #expect(abs(sin(phaseBefore) - sin(phaseAfter)) < 1e-10)
            #expect(abs(cos(phaseBefore) - cos(phaseAfter)) < 1e-10)
            #expect(abs(energyBefore - dynamics.visualEnergy(at: time)) < 1e-10,
                    "A letter must not pop or collapse the ongoing core animation.")
            #expect(abs(speedBefore - speedAfter) < 0.001,
                    "Cadence changes ease the existing orbit velocity instead of snapping it.")
            #expect(dynamics.pulses.first { $0.id == originalSpace.id } == originalSpace,
                    "Ordinary keys must layer onto the still-visible space wave, without replacing or restarting it.")
        }
        #expect(dynamics.pulses.count == 10)
        #expect(dynamics.pulses.last?.profile.code == 37)
    }

    @Test func repeatedSpaceKeepsCoreBoundedAndNormalizesTheAccumulatedLight() {
        var sparse = RhythmDynamics(), dense = RhythmDynamics()
        sparse.receiveKey(49, at: 10)
        dense.receiveKey(49, at: 10)
        for index in 1...200 {
            let time = 10 + Double(index) * 0.003
            let before = dense.visualEnergy(at: time)
            dense.receiveKey(49, at: time)
            #expect(abs(before - dense.visualEnergy(at: time)) < 1e-10)
            #expect((0...1).contains(dense.visualEnergy(at: time + 0.001)))
        }
        #expect(sparse.pulseOpacityScale(at: 10.04) == 1,
                "An isolated space keeps its full accent strength.")
        #expect(dense.pulseOpacityScale(at: 10.64) < 0.1,
                "Overlapping space rings share a light budget instead of multiplying brightness.")
        #expect(dense.pulses.count == RhythmDynamics.maximumPulses)
        for index in 0...200 {
            let time = 10.6 + Double(index) * 0.01
            #expect((0...1).contains(dense.visualEnergy(at: time)))
            #expect((0...1).contains(dense.pulseOpacityScale(at: time)))
        }
        #expect(dense.visualEnergy(at: 30) < 0.000001)
    }

    @Test func longTypingKeepsTheSpectrumContinuousAcrossMultipleOrbitCycles() {
        var dynamics = RhythmDynamics()
        dynamics.receiveKey(49, at: 10)
        var largestPhase = 0.0
        let codes: [UInt16] = [0, 1, 2, 3, 49, 36]
        for index in 1...100 {
            let time = 10 + Double(index) * 0.08
            let before = dynamics.phase(at: time)
            dynamics.receiveKey(codes[index % codes.count], at: time)
            let after = dynamics.phase(at: time)
            largestPhase = max(largestPhase, after)
            // The core spectrum uses a non-integer harmonic. Wrapping only the
            // orbit phase by 2π would jump these bars while leaving the ring unchanged.
            #expect(abs(sin(before * 2.3) - sin(after * 2.3)) < 1e-10)
            #expect(abs(cos(before * 2.3) - cos(after * 2.3)) < 1e-10)
        }
        #expect(largestPhase > 4 * .pi, "Exercise multiple cycles, not just the first space wave.")
    }

    @Test func theSameLettersTypedFasterChargeAStrongerFollowingSpace() throws {
        func accent(spacing: Double) throws -> RhythmPulse {
            var dynamics = RhythmDynamics()
            for (index, code) in [UInt16(0), 1, 2, 3, 4, 5, 38, 40].enumerated() {
                dynamics.receiveKey(code, at: Double(index) * spacing)
            }
            dynamics.receiveKey(49, at: 7 * spacing + 0.08)
            return try #require(dynamics.pulses.last)
        }
        let fast = try accent(spacing: 0.08), slow = try accent(spacing: 0.7)
        #expect(fast.accentCharge > slow.accentCharge + 0.5)
        #expect(fast.strength > slow.strength + 0.4)
        #expect(fast.strength <= 1.85)
    }

    @Test func anAccentSpendsChargeWithoutResettingTheBodyOrPreviousPulses() throws {
        var dynamics = RhythmDynamics()
        for index in 0..<8 { dynamics.receiveKey(UInt16(index), at: Double(index) * 0.08) }
        let previous = try #require(dynamics.pulses.last)
        let bodyBefore = dynamics.visualEnergy(at: 0.64)
        let phaseBefore = dynamics.phase(at: 0.64)
        dynamics.receiveKey(49, at: 0.64)
        let firstSpace = try #require(dynamics.pulses.last)
        #expect(firstSpace.accentCharge > 0.5)
        #expect(dynamics.accentCharge(at: 0.64) == 0)
        #expect(abs(bodyBefore - dynamics.visualEnergy(at: 0.64)) < 1e-10)
        #expect(abs(phaseBefore - dynamics.phase(at: 0.64)) < 1e-10)
        #expect(dynamics.pulses.contains(previous))
        dynamics.receiveKey(49, at: 0.72)
        let secondSpace = try #require(dynamics.pulses.last)
        #expect(secondSpace.accentCharge == 0 && secondSpace.strength == 1,
                "Spaces cannot recharge one another, even when cadence remains high.")
        dynamics.receiveKey(0, at: 0.8)
        #expect(dynamics.accentCharge(at: 0.8) > 0)
        #expect(dynamics.pulses.contains(firstSpace), "Following letters cannot alter the captured accent.")
    }

    @Test func nonCharacterKeysNeitherChargeNorInflateTheNextCharactersCharge() throws {
        var dynamics = RhythmDynamics(), ordinary = RhythmDynamics()
        let keys: [UInt16] = [56, 55, 48, 51, 123, 36, 49]
        for index in 0..<100 {
            let time = Double(index) * 0.01
            dynamics.receiveKey(keys[index % keys.count], at: time)
            #expect(dynamics.accentCharge(at: time) == 0)
            #expect(dynamics.pulses.last?.accentCharge == 0)
        }
        dynamics.receiveKey(0, at: 1)
        ordinary.receiveKey(0, at: 1)
        #expect(dynamics.accentCharge(at: 1) == ordinary.accentCharge(at: 1))
        dynamics.receiveKey(49, at: 1.08)
        ordinary.receiveKey(49, at: 1.08)
        #expect(dynamics.pulses.last?.strength == ordinary.pulses.last?.strength)
    }

    @Test func chargeDecaysDuringIdleAndReturnRetainsItsSecondaryAccent() throws {
        var history = RhythmDynamics()
        for index in 0..<8 { history.receiveKey(UInt16(index), at: Double(index) * 0.08) }
        var space = history, enter = history, keypadEnter = history, idle = history
        space.receiveKey(49, at: 0.64)
        enter.receiveKey(36, at: 0.64)
        keypadEnter.receiveKey(76, at: 0.64)
        let spacePulse = try #require(space.pulses.last)
        let returnPulse = try #require(enter.pulses.last)
        #expect(spacePulse.accentCharge == returnPulse.accentCharge)
        #expect(spacePulse.strength > returnPulse.strength)
        #expect(keypadEnter.pulses.last?.strength == returnPulse.strength)
        #expect(enter.accentCharge(at: 0.64) == 0)
        #expect(idle.accentCharge(at: 4) < 0.01)
        idle.receiveKey(49, at: 4)
        let idlePulse = try #require(idle.pulses.last)
        #expect(idlePulse.strength < 1.01)
        history.reset()
        #expect(history.accentCharge(at: 0.64) == 0)
    }

    @Test func sustainedFastTypingCannotOverchargeAnAccent() throws {
        var dynamics = RhythmDynamics()
        for index in 0..<2_000 {
            let time = Double(index) * 0.001
            dynamics.receiveKey(UInt16(index % 8), at: time)
            #expect((0...1).contains(dynamics.accentCharge(at: time)))
        }
        #expect(dynamics.accentCharge(at: 1.999) > 0.95)
        dynamics.receiveKey(49, at: 2)
        let pulse = try #require(dynamics.pulses.last)
        #expect(pulse.accentCharge > 0.95 && pulse.accentCharge <= 1)
        #expect(pulse.strength > 1.8 && pulse.strength <= 1.85)
        #expect(dynamics.accentCharge(at: 2) == 0)
        #expect(dynamics.pulses.count == RhythmDynamics.maximumPulses)
        #expect((0...1).contains(dynamics.visualEnergy(at: 2.04)))
    }

    @Test func energyMeterRisesSmoothlyAndRemainsContinuousAtEachKey() {
        var dynamics = RhythmDynamics()
        dynamics.receiveKey(0, at: 10)
        #expect(dynamics.meterEnergy(at: 10) == 0, "A hit starts the attack without a visible fill jump.")
        #expect(dynamics.meterEnergy(at: 10.1) > 0)
        let codes: [UInt16] = [1, 49, 2, 36, 51, 56, 123]
        for (index, code) in codes.enumerated() {
            let time = 10.12 + Double(index) * 0.12
            let before = dynamics.meterEnergy(at: time)
            dynamics.receiveKey(code, at: time)
            #expect(abs(before - dynamics.meterEnergy(at: time)) < 1e-10)
        }
        #expect(dynamics.meterEnergy(at: .nan) == 0)
    }

    @Test func energyMeterBuildsFasterWithFastTypingAndFallsSlowlyWhenTypingStops() {
        var fast = RhythmDynamics(), sparse = RhythmDynamics()
        for index in 0..<8 {
            fast.receiveKey(UInt16(index), at: Double(index) * 0.08)
            sparse.receiveKey(UInt16(index), at: Double(index) * 0.9)
        }
        let fastPeak = fast.meterEnergy(at: 0.56 + 0.15)
        let sparsePeak = sparse.meterEnergy(at: 6.3 + 0.15)
        #expect(fastPeak > sparsePeak * 2.5)
        let shortlyAfter = fast.meterEnergy(at: 0.56 + 0.45)
        #expect(shortlyAfter > fastPeak * 0.5, "A short pause between words must not empty the bar.")
        #expect(shortlyAfter < fastPeak)
        #expect(fast.meterEnergy(at: 0.56 + 1.4) < shortlyAfter)
        #expect(fast.meterEnergy(at: 0.56 + RhythmDynamics.settleDelay) < 0.01,
                "The bar should be visually settled before frame updates pause.")
    }

    @Test func spaceAndReturnSpendChargeWithoutEmptyingTheAccumulatedMeter() {
        var history = RhythmDynamics()
        for index in 0..<8 { history.receiveKey(UInt16(index), at: Double(index) * 0.08) }
        let before = history.meterEnergy(at: 0.64)
        #expect(before > 0.2)
        for code in [UInt16(49), 36, 76] {
            var dynamics = history
            dynamics.receiveKey(code, at: 0.64)
            #expect(dynamics.accentCharge(at: 0.64) == 0)
            #expect(abs(dynamics.meterEnergy(at: 0.64) - before) < 1e-10)
            #expect(dynamics.meterEnergy(at: 0.74) > history.meterEnergy(at: 0.74),
                    "The accent adds to the continuing meter even though its separate charge is spent.")
        }
    }

    @Test func allKeyKindsContributeToABoundedMeterAndResetClearsIt() {
        for code in [UInt16(0), 49, 36, 51, 56, 123] {
            var isolated = RhythmDynamics()
            isolated.receiveKey(code, at: 0)
            #expect(isolated.meterEnergy(at: 0.1) > 0)
        }
        var dense = RhythmDynamics()
        for index in 0..<2_000 {
            let time = Double(index) * 0.001
            dense.receiveKey(UInt16(index % 8), at: time)
            #expect((0...1).contains(dense.meterEnergy(at: time)))
        }
        #expect(dense.meterEnergy(at: 2) > 0.9)
        for index in 0..<100 {
            #expect((0...1).contains(dense.meterEnergy(at: 2 + Double(index) * 0.05)))
        }
        dense.reset()
        #expect(dense.meterEnergy(at: 2) == 0 && dense.meterEnergy(at: 10) == 0)
    }

    @Test func ordinaryTypingWithinTheGracePeriodCanFillTheWholeMeter() {
        var dynamics = RhythmDynamics()
        for index in 0..<13 { dynamics.receiveKey(UInt16(index % 8), at: Double(index) * 0.22) }
        let finalHit = 12 * 0.22
        #expect(dynamics.isHighEnergy(at: finalHit))
        #expect(dynamics.meterEnergy(at: finalHit + 0.3) > 0.98,
                "A sustained ordinary typing pace must fill the bar rather than plateau halfway.")
        #expect(dynamics.highEnergyLevel(at: finalHit + 0.3) > 0.7)
    }

    @Test func highEnergyEntryAndHoldExpirationRemainVisuallyContinuous() throws {
        var dynamics = RhythmDynamics()
        var entered = false
        for index in 0..<20 {
            let time = Double(index) * 0.16
            let meterBefore = dynamics.meterEnergy(at: time)
            let emphasisBefore = dynamics.highEnergyLevel(at: time)
            dynamics.receiveKey(UInt16(index % 8), at: time)
            #expect(abs(dynamics.meterEnergy(at: time) - meterBefore) < 1e-10)
            #expect(abs(dynamics.highEnergyLevel(at: time) - emphasisBefore) < 1e-10)
            entered = entered || dynamics.isHighEnergy(at: time)
        }
        #expect(entered)
        let finalHit = try #require(dynamics.lastHit)
        let holdEnd = finalHit + 1.4
        #expect(dynamics.isHighEnergy(at: holdEnd - 0.000001))
        #expect(!dynamics.isHighEnergy(at: holdEnd + 0.000001))
        #expect(abs(dynamics.meterEnergy(at: holdEnd - 0.000001) - dynamics.meterEnergy(at: holdEnd + 0.000001)) < 0.00001)
        #expect(abs(dynamics.highEnergyLevel(at: holdEnd - 0.000001) - dynamics.highEnergyLevel(at: holdEnd + 0.000001)) < 0.00001)
        #expect(dynamics.meterEnergy(at: holdEnd + 0.15) > 0.9, "The full bar releases gradually after its hold.")
        #expect(dynamics.meterEnergy(at: holdEnd + 2) < 0.2)
        #expect(dynamics.highEnergyLevel(at: holdEnd + 2) < 0.03)
    }

    @Test func continuingKeysMaintainHighEnergyAndStoppingEventuallySettles() throws {
        var dynamics = RhythmDynamics()
        for index in 0..<20 { dynamics.receiveKey(UInt16(index % 8), at: Double(index) * 0.16) }
        let entry = try #require(dynamics.highEntryTime)
        for _ in 0..<8 {
            let time = try #require(dynamics.lastHit) + 1.2
            #expect(dynamics.isHighEnergy(at: time))
            #expect(dynamics.meterEnergy(at: time) > 0.99)
            dynamics.receiveKey(0, at: time)
            #expect(dynamics.highEntryTime == entry, "Ongoing typing extends the hold without restarting the entry effect.")
        }
        let finalHit = try #require(dynamics.lastHit)
        #expect(!dynamics.isHighEnergy(at: finalHit + 1.5))
        #expect(dynamics.highEnergyLevel(at: finalHit + 1.5) > 0.7)
        #expect(dynamics.meterEnergy(at: finalHit + RhythmDynamics.settleDelay) < 0.01)
        #expect(dynamics.highEnergyLevel(at: finalHit + RhythmDynamics.settleDelay) < 0.001)
    }

    @Test func reenteringHighEnergyDuringItsFadeDoesNotJumpAndResetClearsIt() throws {
        var dynamics = RhythmDynamics()
        for index in 0..<20 { dynamics.receiveKey(UInt16(index % 8), at: Double(index) * 0.16) }
        let time = try #require(dynamics.lastHit) + 1.42
        #expect(!dynamics.isHighEnergy(at: time))
        let meterBefore = dynamics.meterEnergy(at: time)
        let emphasisBefore = dynamics.highEnergyLevel(at: time)
        dynamics.receiveKey(0, at: time)
        #expect(dynamics.isHighEnergy(at: time))
        #expect(abs(dynamics.meterEnergy(at: time) - meterBefore) < 1e-10)
        #expect(abs(dynamics.highEnergyLevel(at: time) - emphasisBefore) < 1e-10)
        for index in 0..<100 {
            #expect((0...1).contains(dynamics.highEnergyLevel(at: time + Double(index) * 0.1)))
        }
        #expect(!dynamics.isHighEnergy(at: .nan) && dynamics.highEnergyLevel(at: .nan) == 0)
        dynamics.reset()
        #expect(dynamics.highEntryTime == nil && !dynamics.isHighEnergy(at: time))
        #expect(dynamics.highEnergyLevel(at: time) == 0 && dynamics.meterEnergy(at: time) == 0)
    }

    @Test func burstQueueKeepsTenKeysAndAccentsAtomicallyReleaseItsSnapshot() throws {
        var dynamics = RhythmDynamics()
        let codes: [UInt16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 45, 46, 43]
        for (index, code) in codes.enumerated() {
            dynamics.receiveKey(code, at: Double(index) * 0.05, tracksKeyQueue: true)
        }
        #expect(dynamics.queuedKeys.map { $0.profile.code } == Array(codes.suffix(10)))
        let queued = dynamics.queuedKeys
        dynamics.receiveKey(49, at: 0.75, tracksKeyQueue: true)
        let spaceBurst = try #require(dynamics.keyBurst)
        #expect(dynamics.queuedKeys.isEmpty)
        #expect(spaceBurst.keys == queued && spaceBurst.strike.profile.code == 49)
        dynamics.receiveKey(49, at: 0.8, tracksKeyQueue: true)
        #expect(dynamics.keyBurst?.strike.id == spaceBurst.strike.id,
                "An empty accent must not interrupt the previous group while it is flying.")
        dynamics.receiveKey(0, at: 0.85, tracksKeyQueue: true)
        #expect(dynamics.queuedKeys.map { $0.profile.code } == [0])
        #expect(dynamics.keyBurst?.keys == queued)
        dynamics.receiveKey(36, at: 0.9, tracksKeyQueue: true)
        let returnBurst = try #require(dynamics.keyBurst)
        #expect(dynamics.queuedKeys.isEmpty)
        #expect(returnBurst.keys.map { $0.profile.code } == [0])
        #expect(returnBurst.strike.profile.code == 36 && returnBurst.strike.id != spaceBurst.strike.id)
    }

    @Test func idleBurstQueueFadesAndExpiredKeysCannotReappearInANewGroup() throws {
        var dynamics = RhythmDynamics()
        dynamics.receiveKey(0, at: 0, tracksKeyQueue: true)
        let first = try #require(dynamics.queuedKeys.first)
        dynamics.receiveKey(1, at: 1, tracksKeyQueue: true)
        let second = try #require(dynamics.queuedKeys.last)
        let fading = RhythmDynamics.keyOpacity(first, at: 2.5)
        #expect(fading > 0 && fading < 1)
        #expect(RhythmDynamics.keyOpacity(second, at: 2.5) == 1)
        #expect(dynamics.queueOpacity(at: 2.5) == 1)
        dynamics.receiveKey(2, at: 2.5, tracksKeyQueue: true)
        #expect(dynamics.queuedKeys.map { $0.profile.code } == [0, 1, 2])
        let preservedFirst = try #require(dynamics.queuedKeys.first)
        #expect(RhythmDynamics.keyOpacity(preservedFirst, at: 2.5) == fading,
                "A new key must preserve the older key's fading progress rather than relighting it.")
        let latestFading = dynamics.queueOpacity(at: 5)
        #expect(latestFading > 0 && latestFading < 1)
        #expect(dynamics.queueOpacity(at: 5.6) == 0)
        var expired = dynamics
        expired.receiveKey(49, at: 6, tracksKeyQueue: true)
        #expect(expired.queuedKeys.isEmpty && expired.keyBurst?.keys.isEmpty != false,
                "Space must not revive a row that has already faded away.")
        dynamics.receiveKey(3, at: 3.1, tracksKeyQueue: true)
        #expect(dynamics.queuedKeys.map { $0.profile.code } == [1, 2, 3],
                "A new key removes only fully faded entries while retaining younger keys.")
    }

    @Test @MainActor func burstBufferExistsOnlyInItsStyleAndClearsAtLifecycleBoundaries() throws {
        let (model, root) = try fixture(RhythmDefaults(["rhythmEnabled": true]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.receiveKey(0)
        model.releaseKey(0)
        #expect(model.rhythmFeedback.dynamics.queuedKeys.isEmpty)
        model.rhythmStyle = .burst
        model.receiveKey(1)
        model.releaseKey(1)
        #expect(model.rhythmFeedback.dynamics.queuedKeys.map { $0.profile.code } == [1])
        model.isEnabled = false
        #expect(model.rhythmFeedback.dynamics.queuedKeys.isEmpty && model.rhythmFeedback.dynamics.keyBurst == nil)
        model.isEnabled = true
        model.receiveKey(2)
        model.monitor.onReset?()
        #expect(model.rhythmFeedback.dynamics.queuedKeys.isEmpty && model.rhythmFeedback.dynamics.keyBurst == nil)
        model.receiveKey(3)
        model.releaseKey(3)
        model.receiveKey(49)
        model.releaseKey(49)
        #expect(model.rhythmFeedback.dynamics.keyBurst != nil)
        model.receiveKey(4)
        model.releaseKey(4)
        let count = model.sessionTotal
        let sound = model.keyboardSoundStyle
        model.rhythmStyle = .pulse
        #expect(model.rhythmFeedback.dynamics.queuedKeys.isEmpty && model.rhythmFeedback.dynamics.keyBurst == nil)
        #expect(model.sessionTotal == count && model.keyboardSoundStyle == sound)
        model.receiveKey(5)
        #expect(model.rhythmFeedback.dynamics.queuedKeys.isEmpty)
    }
}
