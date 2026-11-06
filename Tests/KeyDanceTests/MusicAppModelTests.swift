import Foundation
import Testing
@testable import KeyDance

/// Every preference access stays in memory; no standard defaults domain is read
/// or written. Started-model tests inject a device-free engine, a fake player,
/// and disable keyboard monitoring, so no audio device or global tap opens.
private final class MemoryMusicDefaults: UserDefaults {
    private var values: [String: Any]
    init(_ values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "KeyWooEphemeralTests-\(UUID().uuidString)")!
    }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func double(forKey defaultName: String) -> Double { (values[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
}

private final class ControllableModelMusicPlayer: MusicPlayback {
    struct Performance {
        let key: UInt32
        let note: UInt8?
        let heldCount: Int
    }
    var duration: TimeInterval = 100
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var volume: Float = 0
    private(set) var playCalls = 0
    private(set) var pauseCalls = 0
    private(set) var stopCalls = 0
    private(set) var performances: [Performance] = []
    private(set) var activeKeys = Set<UInt32>()
    private(set) var releaseCalls: [(key: UInt32, heldCount: Int)] = []
    func prepare() -> Bool { true }
    func play() -> Bool { playCalls += 1; isPlaying = true; return true }
    func pause() { pauseCalls += 1; isPlaying = false }
    func stop() { stopCalls += 1; isPlaying = false }
    func measuredRMS() -> Double { 0 }
    func perform(key: UInt32, note: UInt8?, velocity: UInt8, richness: Double, heldCount: Int) {
        performances.append(Performance(key: key, note: note, heldCount: heldCount))
        activeKeys.insert(key)
    }
    func release(key: UInt32, heldCount: Int) { releaseCalls.append((key, heldCount)); activeKeys.remove(key) }
    func releaseInteraction() { activeKeys.removeAll() }
}

struct MusicAppModelTests {
    @MainActor private func fixture(_ defaults: UserDefaults, audioEngine: SoundEngine? = nil) throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let statistics = StatisticsStore(storageURL: root.appendingPathComponent("statistics.json"))
        let music = LocalMusicStore(directory: root.appendingPathComponent("Music"))
        return (AppModel(defaults: defaults, statistics: statistics, music: music,
                         audioEngine: audioEngine, startsKeyboardMonitor: false, musicModeAvailable: true,
                         remapController: RemapController(store: RemapStore(url: root.appendingPathComponent("remap.json")))), root)
    }

    @Test @MainActor func independentVolumesMigrateLegacyPreferenceWithoutReplacingIt() throws {
        let defaults = MemoryMusicDefaults(["volume": 0.31])
        let (model, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(model.hitVolume == 0.31)
        #expect(model.musicVolume == 0.48)
        #expect(model.selectedMusicID == "after-hours")
        model.musicVolume = 0.22
        model.hitVolume = 0.67
        model.hitSound = .wood
        #expect(model.audio.musicVolume == 0.22)
        #expect(model.audio.hitVolume == 0.67)
        #expect(defaults.double(forKey: "musicVolume") == 0.22)
        #expect(defaults.double(forKey: "hitVolume") == 0.67)
        #expect(defaults.double(forKey: "volume") == 0.31)
        #expect(defaults.string(forKey: "hitSound") == HitSound.wood.rawValue)
        #expect(!model.audio.isEnabled)
        #expect(!model.audio.isMusicPlaying)
    }

    @Test @MainActor func musicPauseKeepsStatisticsActiveAndMasterPausePreservesMusicIntent() throws {
        let defaults = MemoryMusicDefaults()
        let (model, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.toggleMusicPlayback()
        #expect(!model.musicWantsPlayback)
        #expect(model.isEnabled)
        model.receiveKey(0)
        model.receiveKey(0)
        #expect(model.sessionTotal == 1)
        #expect(model.feedbackPulses.isEmpty, "Ordinary letters are counted without musical feedback.")
        model.releaseKey(0)
        model.isEnabled = false
        model.receiveKey(1)
        model.toggleMusicPlayback()
        #expect(model.sessionTotal == 1)
        #expect(!model.musicWantsPlayback)
        #expect(model.heldKeys.isEmpty)
        #expect(model.feedbackPulses.isEmpty)
        model.isEnabled = true
        #expect(!model.musicWantsPlayback)
        model.receiveKey(1)
        model.releaseKey(1)
        #expect(model.sessionTotal == 2)
        #expect(!model.audio.isEnabled, "This test must never open the live engine.")
    }

    @Test @MainActor func feedbackIsBoundedPastInputAndDoesNotChangePhysicalCounts() throws {
        let (model, root) = try fixture(MemoryMusicDefaults())
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        for code in UInt16(0)..<UInt16(70) {
            model.receiveKey(code)
            model.receiveKey(code)
            model.releaseKey(code)
        }
        #expect(model.sessionTotal == 70)
        #expect(model.feedbackPulses.count == 7, "Only 36, 48, 49, 51, 56, 57 and 60 are big keys in this range.")
        for _ in 0..<70 {
            model.receiveKey(49)
            model.receiveKey(49)
            model.releaseKey(49)
        }
        #expect(model.sessionTotal == 140)
        #expect(model.feedbackPulses.count == 48)
        #expect(Set(model.feedbackPulses.map(\.id)).count == 48)
        #expect(model.feedbackPulses.allSatisfy { (0..<4).contains($0.lane) && (0...1).contains($0.strength) && $0.time <= Date() })
        #expect(model.heldKeys.isEmpty)
        let beforePreview = model.sessionTotal
        model.previewKey(49)
        #expect(model.sessionTotal == beforePreview)
    }

    @Test @MainActor func everyPhysicalKeyIsCountedButOnlyNineBigKeysPerformRegardlessOfLegacyModifierPreference() throws {
        let bigKeys: Set<UInt32> = [49, 36, 76, 51, 117, 48, 56, 60, 57]
        for oldModifierSetting in [false, true] {
            let player = ControllableModelMusicPlayer()
            let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
            let (model, root) = try fixture(MemoryMusicDefaults(["modifierSounds": oldModifierSetting]), audioEngine: engine)
            defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
            model.start()
            for code in UInt16(0)..<128 {
                model.monitor.onKeyDown?(code)
                model.monitor.onKeyDown?(code)
                model.monitor.onKeyUp?(code)
            }
            let eachKeyCountedOnce = (UInt16(0)..<128).allSatisfy { model.statistics.sessionCounts[$0] == 1 }
            let performedKeys = Set(player.performances.map { $0.key })
            #expect(eachKeyCountedOnce)
            #expect(model.sessionTotal == 128)
            #expect(player.performances.count == bigKeys.count)
            #expect(performedKeys == bigKeys)
            #expect(model.strikeCount == bigKeys.count)
            #expect(model.feedbackPulses.count == bigKeys.count)
            #expect(model.heldKeys.isEmpty && model.soundingHeldKeys.isEmpty)
            #expect(engine.heldKeyCount == 0 && player.activeKeys.isEmpty)
        }
    }

    @Test @MainActor func silentKeysDoNotReleaseHeldShiftOrCancelAnIndependentPreview() async throws {
        let player = ControllableModelMusicPlayer()
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let (model, root) = try fixture(MemoryMusicDefaults(["modifierSounds": false]), audioEngine: engine)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        model.receiveKey(56)
        model.previewKey(49)
        let preview = try #require(player.performances.last)
        #expect(preview.key > 65_535)
        let activeBefore = player.activeKeys
        let releasedBefore = player.releaseCalls.count
        let strikesBefore = model.strikeCount
        let pulsesBefore = model.feedbackPulses.count
        for code: UInt16 in [0, 1, 18, 27, 55, 54, 53, 123] {
            model.receiveKey(code)
            model.receiveKey(code)
            model.releaseKey(code)
        }
        model.previewKey(0)
        model.previewKey(55)
        #expect(model.sessionTotal == 9)
        #expect(player.performances.count == 2)
        #expect(player.activeKeys == activeBefore)
        #expect(player.releaseCalls.count == releasedBefore)
        #expect(model.strikeCount == strikesBefore)
        #expect(model.feedbackPulses.count == pulsesBefore)
        #expect(engine.heldKeyCount == 1)
        #expect(model.heldKeys == [56] && model.soundingHeldKeys == [56])

        // Verify the preview can finish normally; an ignored key must not have
        // cancelled its release task or stolen physical Shift ownership.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while player.activeKeys.contains(preview.key) && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.activeKeys == [56])
        #expect(engine.heldKeyCount == 1)
        #expect(model.sessionTotal == 9)
        model.releaseKey(56)
        #expect(player.activeKeys.isEmpty && engine.heldKeyCount == 0)
    }

    @Test @MainActor func failedImportLeavesSelectedMusicAndPlaybackIntentUnchanged() async throws {
        let defaults = MemoryMusicDefaults(["selectedMusicID": "soft-current", "musicWantsPlayback": false])
        let (model, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("broken.mp3")
        try Data("not music".utf8).write(to: invalid)
        let imported = await model.importMusicFile(at: invalid)
        #expect(!imported)
        #expect(model.selectedMusicID == "soft-current")
        #expect(!model.musicWantsPlayback)
        #expect(model.music.importedTracks.isEmpty)
        #expect(model.music.errorMessage != nil)
        #expect(defaults.string(forKey: "selectedMusicID") == "soft-current")
    }

    @Test @MainActor func invalidSavedSelectionFallsBackAndVolumeValuesAreBounded() throws {
        let defaults = MemoryMusicDefaults(["selectedMusicID": "missing-local-track", "hitVolume": 12.0, "musicVolume": -4.0, "hitSound": "missing-sound"])
        let (model, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(model.selectedMusicID == "after-hours")
        #expect(model.hitVolume == 1)
        #expect(model.musicVolume == 0)
        #expect(model.hitSound == .softTap)
        #expect(model.musicTracks.count >= 2)
    }

    @Test @MainActor func bigKeyPressesShapeTheWholeSongWithoutAddingNotesAndRepeatDoesNotRecount() throws {
        let player = ControllableModelMusicPlayer()
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let (model, root) = try fixture(MemoryMusicDefaults(), audioEngine: engine)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        #expect(!model.monitor.isGlobalActive)
        #expect(engine.isInteractiveBuiltIn)
        player.currentTime = 0.25
        model.monitor.onKeyDown?(49)
        let firstHarmony = engine.currentHarmony
        let firstNote = model.lastNote
        model.monitor.onKeyDown?(49)
        #expect(model.sessionTotal == 1)
        #expect(model.strikeCount == 1)
        #expect(model.feedbackPulses.count == 1)
        #expect(engine.heldKeyCount == 1)
        #expect(player.performances.count == 1)
        let firstPerformed = try #require(player.performances.first)
        #expect(firstPerformed.note == nil, "Typing controls the complete recording instead of an added instrument.")
        #expect(!firstHarmony.isEmpty)
        #expect(firstNote != "—")
        model.monitor.onKeyUp?(49)

        // After Hours changes harmony every 4 beats at 78 BPM. Advancing the
        // fake native clock does not rely on the UI's periodic progress timer.
        player.currentTime = 4.1
        model.monitor.onKeyDown?(49)
        #expect(engine.currentHarmony != firstHarmony)
        #expect(model.sessionTotal == 2)
        #expect(player.performances.count == 2)
        #expect(player.performances.last?.note == nil)
        #expect(player.playCalls == 1, "A typing gesture must not restart the song.")
        #expect(player.currentTime == 4.1)
        model.toggleMusicPlayback()
        #expect(!player.isPlaying)
        #expect(engine.heldKeyCount == 1, "Physical key ownership remains until key-up, even while music is paused.")
        model.monitor.onKeyUp?(49)
        #expect(engine.heldKeyCount == 0)
        #expect(player.activeKeys.isEmpty)
    }

    @Test @MainActor func pausedMusicKeepsItsPositionAndStatisticsAcrossMasterPause() throws {
        let player = ControllableModelMusicPlayer()
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let (model, root) = try fixture(MemoryMusicDefaults(), audioEngine: engine)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        player.currentTime = 7.2
        model.toggleMusicPlayback()
        model.receiveKey(36)
        let pausedHarmony = engine.currentHarmony
        #expect(!model.musicWantsPlayback)
        #expect(!player.isPlaying)
        #expect(model.lastNote == "等待播放")
        #expect(player.playCalls == 1)
        #expect(engine.heldKeyCount == 1)
        #expect(!pausedHarmony.isEmpty)
        model.isEnabled = false
        model.receiveKey(2)
        #expect(model.sessionTotal == 1)
        #expect(engine.heldKeyCount == 0)
        #expect(model.heldKeys.isEmpty)
        model.isEnabled = true
        model.receiveKey(48)
        #expect(model.sessionTotal == 2)
        #expect(!model.musicWantsPlayback)
        #expect(!player.isPlaying)
        #expect(player.currentTime == 7.2)
        #expect(player.playCalls == 1)
        #expect(engine.currentHarmony == pausedHarmony)
        model.releaseKey(48)
    }

    @Test @MainActor func previewAndInputResetPreservePhysicalCountsAndAccompanimentTransport() throws {
        let player = ControllableModelMusicPlayer()
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let (model, root) = try fixture(MemoryMusicDefaults(), audioEngine: engine)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        player.currentTime = 10.2
        model.receiveKey(49)
        model.previewKey(36)
        #expect(model.sessionTotal == 1)
        #expect(model.heldKeys == [49])
        #expect(engine.heldKeyCount == 1, "A mouse preview must not take ownership of a physical hold.")
        #expect(player.activeKeys.contains(49))
        model.previewSound()
        #expect(model.sessionTotal == 1 && model.heldKeys == [49])
        #expect(engine.heldKeyCount == 1 && player.activeKeys.contains(49), "A demo must preserve the physical hold too.")
        let pauses = player.pauseCalls
        // This is the callback used by secure input, focus loss, and tap reset.
        model.monitor.onReset?()
        #expect(model.heldKeys.isEmpty)
        #expect(model.feedbackPulses.isEmpty)
        #expect(engine.heldKeyCount == 0)
        #expect(player.activeKeys.isEmpty)
        #expect(player.isPlaying)
        #expect(player.currentTime == 10.2)
        #expect(player.pauseCalls == pauses)
        model.releaseKey(49)
        #expect(model.sessionTotal == 1)
        #expect(engine.heldKeyCount == 0)
    }

    @Test @MainActor func failedTrackChangePreservesPerformanceAndSuccessfulChangeClearsOldLabels() throws {
        let player = ControllableModelMusicPlayer()
        let nextPlayer = ControllableModelMusicPlayer()
        var rejectNextTrack = true
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { url in
            if url.lastPathComponent.contains("soft-current") {
                if rejectNextTrack { throw NSError(domain: "KeyWooModelTests", code: 1) }
                return nextPlayer
            }
            return player
        })
        let (model, root) = try fixture(MemoryMusicDefaults(), audioEngine: engine)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        player.currentTime = 4.1
        model.receiveKey(49)
        let harmony = engine.currentHarmony
        let note = model.lastNote
        let selected = model.selectMusic(id: "soft-current")
        #expect(!selected)
        #expect(model.selectedMusicID == "after-hours")
        #expect(engine.currentHarmony == harmony)
        #expect(engine.heldKeyCount == 1)
        #expect(player.activeKeys.contains(49))
        #expect(model.heldKeys == [49])
        #expect(player.currentTime == 4.1)
        #expect(player.isPlaying)
        #expect(model.musicSelectionError != nil)
        #expect(model.lastNote == note)
        #expect(model.lastKey == 49)
        rejectNextTrack = false
        let changed = model.selectMusic(id: "soft-current")
        #expect(changed)
        #expect(model.lastNote == "—")
        #expect(model.lastKey == nil)
        #expect(model.sessionTotal == 1)
        #expect(model.heldKeys.isEmpty && model.soundingHeldKeys.isEmpty, "A new song clears old gesture ownership without another physical count.")
        #expect(engine.heldKeyCount == 0, "The old track's sounding note must not leak into the new harmony.")
        #expect(player.activeKeys.isEmpty)
        model.releaseKey(49)
    }

    @Test @MainActor func seekingClearsHeldShiftWithoutLosingCountsOrLettingItsLateReleaseAffectSpace() throws {
        let player = ControllableModelMusicPlayer()
        let engine = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let (model, root) = try fixture(MemoryMusicDefaults(["modifierSounds": false]), audioEngine: engine)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        model.receiveKey(56)
        #expect(model.soundingHeldKeys == [56])
        #expect(model.sessionTotal == 1)
        let playCalls = player.playCalls
        let pauseCalls = player.pauseCalls
        model.seekMusic(to: 23)
        #expect(model.sessionTotal == 1)
        #expect(player.currentTime == 23)
        #expect(player.isPlaying)
        #expect(player.playCalls == playCalls && player.pauseCalls == pauseCalls)
        #expect(model.heldKeys.isEmpty && model.soundingHeldKeys.isEmpty)
        #expect(engine.heldKeyCount == 0 && player.activeKeys.isEmpty)
        model.receiveKey(49)
        #expect(model.sessionTotal == 2)
        #expect(model.soundingHeldKeys == [49])
        #expect(engine.heldKeyCount == 1 && player.activeKeys == [49])
        model.releaseKey(56)
        #expect(model.sessionTotal == 2)
        #expect(model.soundingHeldKeys == [49])
        #expect(engine.heldKeyCount == 1 && player.activeKeys == [49])
        model.releaseKey(49)
        #expect(model.soundingHeldKeys.isEmpty && player.activeKeys.isEmpty)
    }
}
