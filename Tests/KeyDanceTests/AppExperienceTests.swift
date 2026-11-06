import Foundation
import Testing
@testable import KeyDance

private final class ExperienceDefaults: UserDefaults {
    private var values: [String: Any]
    init(_ values: [String: Any] = [:]) {
        self.values = values
        super.init(suiteName: "KeyWooExperience-\(UUID().uuidString)")!
    }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
}

private final class ExperienceMusicPlayer: MusicPlayback {
    var duration: TimeInterval = 100
    var currentTime: TimeInterval = 0
    var isPlaying = false
    var volume: Float = 0
    var attacks = 0
    var active = Set<UInt32>()
    func prepare() -> Bool { true }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false; active.removeAll() }
    func measuredRMS() -> Double { 0 }
    func perform(key: UInt32, note: UInt8?, velocity: UInt8, richness: Double, heldCount: Int) { attacks += 1; active.insert(key) }
    func release(key: UInt32, heldCount: Int) { active.remove(key) }
    func releaseInteraction() { active.removeAll() }
}

struct AppExperienceTests {
    @Test @MainActor func boostPersistsAndLegacySpatialSettingCannotColorTheRecording() throws {
        let defaults = ExperienceDefaults(["experienceMode": "keyboardSounds", "keyboardVolume": 1.6, "keyboardSpatialEnabled": true])
        let (model, _, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(model.keyboardVolume == 1.6 && model.keyboardAudio.volume == 1.6)
        let musicVolume = model.musicVolume
        model.keyboardVolume = 20
        #expect(model.keyboardVolume == 16 && model.keyboardAudio.volume == 16)
        model.keyboardVolume = .nan
        #expect(model.keyboardVolume == 0.5)
        model.keyboardVolume = 12.5
        let (restored, _, restoredRoot) = try fixture(defaults)
        defer { restored.shutdown(); try? FileManager.default.removeItem(at: restoredRoot) }
        #expect(restored.keyboardVolume == 12.5)
        #expect(model.musicVolume == musicVolume)
        // A persisted 2.7 spatial preference has no audio path after rollback.
        let dry = KeyboardSoundEngine(audioDeviceEnabled: false)
        defer { dry.stop() }
        dry.style = restored.keyboardSoundStyle
        dry.volume = restored.keyboardVolume
        restored.keyboardAudio.start(); dry.start()
        restored.keyboardAudio.noteOn(keyCode: 49); dry.noteOn(keyCode: 49)
        #expect(restored.keyboardAudio.renderForVerification(frames: 8192) == dry.renderForVerification(frames: 8192))
    }

    @MainActor private func fixture(_ defaults: UserDefaults = ExperienceDefaults(), musicModeAvailable: Bool = true) throws -> (AppModel, ExperienceMusicPlayer, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooExperience-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let player = ExperienceMusicPlayer()
        let music = SoundEngine(audioDeviceEnabled: false, musicFactory: { _ in player })
        let keyboard = KeyboardSoundEngine(audioDeviceEnabled: false)
        return (AppModel(defaults: defaults, statistics: StatisticsStore(storageURL: root.appendingPathComponent("stats.json")),
                         music: LocalMusicStore(directory: root.appendingPathComponent("Music")), audioEngine: music,
                         keyboardAudioEngine: keyboard, startsKeyboardMonitor: false,
                         musicModeAvailable: musicModeAvailable,
                         remapController: RemapController(store: RemapStore(url: root.appendingPathComponent("remap.json")))), player, root)
    }

    @Test @MainActor func releaseHidesMusicEvenWhenPreviousVersionSavedIt() throws {
        let defaults = ExperienceDefaults(["experienceMode": "music", "musicWantsPlayback": true])
        let (model, player, root) = try fixture(defaults, musicModeAvailable: false)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        #expect(!model.musicModeAvailable && model.isKeyboardSoundMode)
        model.start()
        #expect(!player.isPlaying)
        model.experienceMode = .music
        #expect(model.experienceMode == .keyboardSounds)
    }

    @Test @MainActor func preferencesPersistIndependentlyAndInvalidValuesMigrateSafely() throws {
        let defaults = ExperienceDefaults(["appLanguage": "unknown", "appAppearance": "unknown", "experienceMode": "unknown", "keyboardVolume": Double.nan])
        let (model, _, root) = try fixture(defaults)
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root); AppLocalization.language = .simplifiedChinese }
        #expect(model.language == .simplifiedChinese && model.appearance == .system && model.experienceMode == .music)
        #expect(model.keyboardSoundStyle == .red && model.keyboardVolume == 0.5 && model.keyboardSoundQuality == .original)
        let oldMusicVolume = model.musicVolume, oldImpact = model.hitVolume
        model.language = .english
        model.appearance = .dark
        model.experienceMode = .keyboardSounds
        #expect(model.canChooseKeyboardSoundQuality)
        model.keyboardSoundQuality = .hiFi
        model.keyboardSoundStyle = .mahjong
        #expect(!model.canChooseKeyboardSoundQuality && model.keyboardAudio.quality == .hiFi)
        model.keyboardVolume = 0.27
        #expect(AppLocalization.appName == "KeyWoo")
        #expect(defaults.string(forKey: "appLanguage") == "en")
        #expect(defaults.object(forKey: "AppleLanguages") as? [String] == ["en"])
        #expect(defaults.string(forKey: "appAppearance") == "dark")
        #expect(defaults.string(forKey: "experienceMode") == "keyboardSounds")
        #expect(defaults.string(forKey: "keyboardSoundStyle") == "mahjong")
        #expect(defaults.string(forKey: "keyboardSoundQuality") == "hiFi")
        #expect(defaults.double(forKey: "keyboardVolume") == 0.27)
        #expect(model.musicVolume == oldMusicVolume && model.hitVolume == oldImpact)
        #expect(!model.keyboardAudio.isRunning && !model.audio.isEnabled)
        model.language = .system
        #expect(defaults.object(forKey: "AppleLanguages") == nil)
        let (restored, _, restoredRoot) = try fixture(defaults)
        defer { restored.shutdown(); try? FileManager.default.removeItem(at: restoredRoot) }
        restored.keyboardSoundStyle = .red
        #expect(restored.canChooseKeyboardSoundQuality && restored.keyboardSoundQuality == .hiFi)
        #expect(restored.keyboardAudio.quality == .hiFi)
    }

    @Test @MainActor func keyboardModeCountsEveryKeyWithoutPlayingMusicAndDeduplicatesHeldKeys() throws {
        let (model, player, root) = try fixture(ExperienceDefaults(["experienceMode": "keyboardSounds"]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        #expect(model.keyboardAudio.isRunning)
        #expect(!model.audio.isEnabled && !model.audio.isMusicPlaying && !player.isPlaying)
        for code in UInt16(0)..<128 {
            model.receiveKey(code)
            model.receiveKey(code)
            model.releaseKey(code)
        }
        #expect(model.sessionTotal == 128)
        #expect(model.strikeCount == 128 && player.attacks == 0)
        #expect(model.heldKeys.isEmpty && model.keyboardAudio.heldKeyCount == 0)
        #expect((UInt16(0)..<128).allSatisfy { model.statistics.sessionCounts[$0] == 1 })
    }

    @Test @MainActor func switchingModesStopsTheOtherEngineAndClearsOldHolds() throws {
        let (model, player, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        #expect(player.isPlaying && !model.keyboardAudio.isRunning)
        model.receiveKey(56)
        model.experienceMode = .keyboardSounds
        #expect(!model.audio.isEnabled && !player.isPlaying && player.active.isEmpty)
        #expect(model.heldKeys.isEmpty && model.keyboardAudio.isRunning)
        model.receiveKey(0)
        #expect(model.keyboardAudio.heldKeyCount == 1)
        model.experienceMode = .music
        #expect(!model.keyboardAudio.isRunning && model.keyboardAudio.heldKeyCount == 0)
        #expect(model.audio.isEnabled && player.isPlaying && model.musicWantsPlayback)
        model.releaseKey(0)
        model.releaseKey(56)
        #expect(model.heldKeys.isEmpty && player.active.isEmpty)
        model.receiveKey(49)
        model.releaseKey(49)
        #expect(player.attacks == 2 && model.sessionTotal == 3)
    }

    @Test @MainActor func musicPauseIntentSurvivesKeyboardModeAndMasterPauseStopsEverything() throws {
        let (model, player, root) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        model.toggleMusicPlayback()
        #expect(!model.musicWantsPlayback && !player.isPlaying)
        model.experienceMode = .keyboardSounds
        model.toggleMusicPlayback()
        #expect(!model.musicWantsPlayback && !player.isPlaying && model.keyboardAudio.isRunning)
        model.receiveKey(0)
        model.isEnabled = false
        #expect(!model.keyboardAudio.isRunning && model.heldKeys.isEmpty && !model.audio.isEnabled)
        model.receiveKey(1)
        #expect(model.sessionTotal == 1)
        model.experienceMode = .music
        #expect(!player.isPlaying)
        model.isEnabled = true
        #expect(model.audio.isEnabled && !player.isPlaying && !model.musicWantsPlayback)
    }

    @Test @MainActor func keyboardAuditionsDoNotCountOrReleasePhysicalKeys() throws {
        let (model, player, root) = try fixture(ExperienceDefaults(["experienceMode": "keyboardSounds"]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        model.receiveKey(0)
        let currentPreset = model.keyboardSoundStyle
        model.keyboardSoundStyle = currentPreset
        #expect(model.heldKeys == [0] && model.keyboardAudio.heldKeyCount == 1)
        model.previewKey(49)
        model.previewKey(0)
        model.previewSound()
        #expect(model.sessionTotal == 1 && model.heldKeys == [0])
        #expect(model.keyboardAudio.heldKeyCount == 1 && player.attacks == 0)
        model.releaseKey(0)
        #expect(model.keyboardAudio.heldKeyCount == 0)
    }

    @Test @MainActor func choosingAHealthyPresetRestartsAnInactiveKeyboardEngineWithoutOverridingMasterPause() throws {
        let (model, _, root) = try fixture(ExperienceDefaults(["experienceMode": "keyboardSounds"]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        model.keyboardAudio.stop()
        model.keyboardSoundStyle = .mahjong
        #expect(model.keyboardAudio.isRunning)
        model.isEnabled = false
        model.keyboardSoundStyle = .blue
        #expect(!model.keyboardAudio.isRunning)
        #expect(model.sessionTotal == 0)
    }

    @Test @MainActor func selectingMusicInKeyboardModeDoesNotActivateMusicUntilModeChanges() throws {
        let (model, player, root) = try fixture(ExperienceDefaults(["experienceMode": "keyboardSounds"]))
        defer { model.shutdown(); try? FileManager.default.removeItem(at: root) }
        model.start()
        let next = try #require(model.musicTracks.first { $0.id != model.selectedMusicID && !$0.isGenerative })
        #expect(model.selectMusic(id: next.id))
        #expect(!model.audio.isEnabled && !player.isPlaying && model.keyboardAudio.isRunning)
        model.experienceMode = .music
        #expect(model.audio.currentTrack.id == next.id && player.isPlaying && !model.keyboardAudio.isRunning)
    }
}
