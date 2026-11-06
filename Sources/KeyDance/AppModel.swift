import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

enum AppPage: String, CaseIterable {
    case studio = "音乐空间", remapping = "改键", statistics = "按键统计", settings = "偏好设置"
    var symbol: String {
        switch self { case .studio: return "waveform"; case .remapping: return "keyboard"; case .statistics: return "chart.bar.xaxis"; case .settings: return "slider.horizontal.3" }
    }
}

struct FeedbackPulse: Identifiable, Equatable {
    let id: Int
    let time: Date
    let lane: Int
    let strength: Double
}

@MainActor
final class AppModel: ObservableObject {
    let audio: SoundEngine
    let keyboardAudio: KeyboardSoundEngine
    let remapping: RemapController
    let monitor = KeyboardMonitor()
    let statistics: StatisticsStore
    let music: LocalMusicStore
    let rhythmFeedback = RhythmFeedbackModel()
    private var rhythmOverlay: RhythmOverlayController?
    private var rhythmDemoTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let startsKeyboardMonitor: Bool
    let musicModeAvailable: Bool
    @Published var language: AppLanguage {
        didSet {
            AppLocalization.language = language
            defaults.set(language.rawValue, forKey: "appLanguage")
            // App-domain preference only. Cocoa's standard menus pick this up
            // on the next launch; custom SwiftUI content updates immediately.
            defaults.set(language == .system ? nil : [language.rawValue], forKey: "AppleLanguages")
            rhythmFeedback.objectWillChange.send()
        }
    }
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appAppearance") }
    }
    @Published var experienceMode: AppExperienceMode {
        didSet {
            guard musicModeAvailable || experienceMode == .keyboardSounds else {
                experienceMode = .keyboardSounds
                return
            }
            guard experienceMode != oldValue else { return }
            defaults.set(experienceMode.rawValue, forKey: "experienceMode")
            resetHeldNotes()
            audio.stop()
            keyboardAudio.stop()
            lastKey = nil
            lastNote = "—"
            if started && isEnabled { activateAudioAndMonitoring() }
        }
    }
    @Published var keyboardSoundStyle: KeyboardSoundStyle {
        didSet {
            if keyboardSoundStyle != oldValue {
                resetHeldNotes()
                keyboardAudio.style = keyboardSoundStyle
                defaults.set(keyboardSoundStyle.rawValue, forKey: "keyboardSoundStyle")
            }
            if started && isEnabled && isKeyboardSoundMode { keyboardAudio.start() }
        }
    }
    @Published var keyboardVolume: Double {
        didSet {
            let value = Self.validVolume(keyboardVolume, fallback: 0.5, maximum: KeyboardSoundEngine.maximumVolume)
            if keyboardVolume != value { keyboardVolume = value }
            keyboardAudio.volume = value
            defaults.set(value, forKey: "keyboardVolume")
        }
    }
    @Published var page: AppPage = .studio
    @Published var rhythmEnabled: Bool {
        didSet {
            defaults.set(rhythmEnabled, forKey: "rhythmEnabled")
            if !rhythmEnabled { cancelRhythmFeedback() }
            synchronizeRhythmOverlay()
        }
    }
    @Published var rhythmIntensity: Double {
        didSet {
            let value = Self.validRhythmIntensity(rhythmIntensity)
            if rhythmIntensity != value { rhythmIntensity = value }
            rhythmFeedback.intensity = value
            defaults.set(value, forKey: "rhythmIntensity")
        }
    }
    @Published var rhythmStyle: RhythmVisualStyle {
        didSet {
            defaults.set(rhythmStyle.rawValue, forKey: "rhythmStyle")
            rhythmFeedback.visualStyle = rhythmStyle
        }
    }
    @Published var rhythmFlashes: Bool {
        didSet {
            defaults.set(rhythmFlashes, forKey: "rhythmFlashes")
            rhythmFeedback.flashesEnabled = rhythmFlashes
        }
    }
    @Published var rhythmClickThrough: Bool {
        didSet {
            defaults.set(rhythmClickThrough, forKey: "rhythmClickThrough")
            rhythmOverlay?.setClickThrough(rhythmClickThrough)
        }
    }
    @Published var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled {
                if started { activateAudioAndMonitoring() }
            } else {
                resetHeldNotes()
                monitor.stop()
                audio.stop()
                keyboardAudio.stop()
                statistics.flush()
            }
            synchronizeRhythmOverlay()
        }
    }
    @Published var style: SoundStyle {
        didSet { resetHeldNotes(); audio.style = style; defaults.set(style.rawValue, forKey: "soundStyle") }
    }
    /// Compatibility binding for the earlier single-volume interface.
    var volume: Double {
        get { hitVolume }
        set { hitVolume = newValue }
    }
    @Published var musicVolume: Double {
        didSet { audio.musicVolume = musicVolume; defaults.set(musicVolume, forKey: "musicVolume") }
    }
    @Published var hitVolume: Double {
        didSet { audio.hitVolume = hitVolume; defaults.set(hitVolume, forKey: "hitVolume") }
    }
    @Published var hitSound: HitSound {
        didSet { resetHeldNotes(); audio.hitSound = hitSound; defaults.set(hitSound.rawValue, forKey: "hitSound") }
    }
    @Published private(set) var selectedMusicID: String
    @Published private(set) var musicWantsPlayback: Bool
    @Published private(set) var musicSelectionError: String?
    @Published private(set) var feedbackPulses: [FeedbackPulse] = []
    @Published var decay: Double {
        didSet { audio.decay = decay; defaults.set(decay, forKey: "decay") }
    }
    @Published var harmonyEnabled: Bool {
        didSet { resetHeldNotes(); audio.harmonyEnabled = harmonyEnabled; defaults.set(harmonyEnabled, forKey: "harmony") }
    }
    @Published var modifierSoundsEnabled: Bool {
        // Kept for saved-preference compatibility; the DJ key whitelist owns
        // sound eligibility, including Shift, independently of this old switch.
        didSet { defaults.set(modifierSoundsEnabled, forKey: "modifierSounds") }
    }
    @Published var now = Date()
    @Published var lastNote = "—"
    @Published var lastKey: UInt16?
    @Published var lastStrike = Date.distantPast
    @Published var strikeCount = 0
    @Published var pressedKeys: Set<UInt16> = []
    @Published private(set) var heldKeys: Set<UInt16> = []
    @Published var practiceText = ""
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var keyTokens: [UInt16: UUID] = [:]

    /// Offline integration tests inject a device-free engine and disable event
    /// monitoring; normal app construction keeps both production defaults.
    init(defaults: UserDefaults = .standard, statistics: StatisticsStore? = nil, music: LocalMusicStore? = nil,
         audioEngine: SoundEngine? = nil, keyboardAudioEngine: KeyboardSoundEngine? = nil, startsKeyboardMonitor: Bool = true,
         musicModeAvailable: Bool = false, remapController: RemapController? = nil) {
        self.audio = audioEngine ?? SoundEngine(audioDeviceEnabled: musicModeAvailable && startsKeyboardMonitor)
        self.keyboardAudio = keyboardAudioEngine ?? KeyboardSoundEngine(audioDeviceEnabled: startsKeyboardMonitor)
        let remapArguments = CommandLine.arguments
        if let remapController { self.remapping = remapController }
        else if let index = remapArguments.firstIndex(of: "--remap-config"), remapArguments.count > index + 1 {
            self.remapping = RemapController(store: RemapStore(url: URL(fileURLWithPath: remapArguments[index + 1])))
        } else { self.remapping = RemapController() }
        self.defaults = defaults
        self.startsKeyboardMonitor = startsKeyboardMonitor
        self.musicModeAvailable = musicModeAvailable
        rhythmEnabled = defaults.bool(forKey: "rhythmEnabled")
        rhythmIntensity = Self.validRhythmIntensity(defaults.object(forKey: "rhythmIntensity") == nil ? 1 : defaults.double(forKey: "rhythmIntensity"))
        rhythmClickThrough = defaults.bool(forKey: "rhythmClickThrough")
        rhythmStyle = RhythmVisualStyle(rawValue: defaults.string(forKey: "rhythmStyle") ?? "energy") ?? .energy
        rhythmFlashes = defaults.object(forKey: "rhythmFlashes") == nil ? true : defaults.bool(forKey: "rhythmFlashes")
        language = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "zh-Hans") ?? .simplifiedChinese
        appearance = AppAppearance(rawValue: defaults.string(forKey: "appAppearance") ?? "system") ?? .system
        experienceMode = musicModeAvailable ? (AppExperienceMode(rawValue: defaults.string(forKey: "experienceMode") ?? "music") ?? .music) : .keyboardSounds
        keyboardSoundStyle = KeyboardSoundStyle(rawValue: defaults.string(forKey: "keyboardSoundStyle") ?? "red") ?? .red
        keyboardVolume = Self.validVolume(defaults.object(forKey: "keyboardVolume") == nil ? 0.5 : defaults.double(forKey: "keyboardVolume"), fallback: 0.5, maximum: KeyboardSoundEngine.maximumVolume)
        let arguments = ProcessInfo.processInfo.arguments
        if let statistics {
            self.statistics = statistics
        } else if let index = arguments.firstIndex(of: "--statistics-path"), arguments.count > index + 1 {
            self.statistics = StatisticsStore(storageURL: URL(fileURLWithPath: arguments[index + 1]))
        } else {
            self.statistics = StatisticsStore()
        }
        if let music {
            self.music = music
        } else if let index = arguments.firstIndex(of: "--music-directory"), arguments.count > index + 1 {
            self.music = LocalMusicStore(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        } else if let index = arguments.firstIndex(of: "--statistics-path"), arguments.count > index + 1 {
            // QA runs with isolated statistics also get an isolated music library.
            self.music = LocalMusicStore(directory: URL(fileURLWithPath: arguments[index + 1]).deletingLastPathComponent().appendingPathComponent("Music"))
        } else {
            self.music = LocalMusicStore()
        }
        style = SoundStyle(rawValue: defaults.string(forKey: "soundStyle") ?? "felt") ?? .felt
        let legacyHitVolume = defaults.object(forKey: "volume") == nil ? 0.45 : defaults.double(forKey: "volume")
        hitVolume = Self.validVolume(defaults.object(forKey: "hitVolume") == nil ? legacyHitVolume : defaults.double(forKey: "hitVolume"), fallback: 0.45)
        musicVolume = Self.validVolume(defaults.object(forKey: "musicVolume") == nil ? 0.48 : defaults.double(forKey: "musicVolume"), fallback: 0.48)
        hitSound = HitSound(rawValue: defaults.string(forKey: "hitSound") ?? "softTap") ?? .softTap
        musicWantsPlayback = defaults.object(forKey: "musicWantsPlayback") == nil ? true : defaults.bool(forKey: "musicWantsPlayback")
        let savedSelection = defaults.string(forKey: "selectedMusicID") ?? "after-hours"
        let knownIDs = Set((MusicLibrary.builtInTracks + [MusicLibrary.generativeTrack].compactMap { $0 }).map(\.id) + self.music.importedTracks.map(\.id))
        selectedMusicID = knownIDs.contains(savedSelection) ? savedSelection : (MusicLibrary.builtInTracks.first?.id ?? "after-hours")
        decay = defaults.object(forKey: "decay") == nil ? 0.55 : defaults.double(forKey: "decay")
        harmonyEnabled = defaults.object(forKey: "harmony") == nil ? true : defaults.bool(forKey: "harmony")
        modifierSoundsEnabled = defaults.bool(forKey: "modifierSounds")
        AppLocalization.language = language
        defaults.set(language == .system ? nil : [language.rawValue], forKey: "AppleLanguages")
        self.keyboardAudio.style = keyboardSoundStyle
        self.keyboardAudio.volume = keyboardVolume
        rhythmFeedback.intensity = rhythmIntensity
        rhythmFeedback.visualStyle = rhythmStyle
        rhythmFeedback.flashesEnabled = rhythmFlashes
        audio.style = style
        audio.hitVolume = hitVolume
        audio.musicVolume = musicVolume
        audio.hitSound = hitSound
        audio.decay = decay
        audio.harmonyEnabled = harmonyEnabled
        monitor.onKeyDown = { [weak self] code in self?.receiveKey(code) }
        monitor.onKeyUp = { [weak self] code in self?.releaseKey(code) }
        monitor.onReset = { [weak self] in self?.resetHeldNotes() }
        self.remapping.onConsumedPhysicalEvent = { [weak self] event in
            self?.monitor.receiveConsumedPhysicalEvent(event)
        }
        for publisher in [monitor.objectWillChange, self.statistics.objectWillChange, self.music.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        audio.$errorMessage.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.$heldKeyCount.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.$musicErrorMessage.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        self.keyboardAudio.$errorMessage.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] date in
            guard let self else { return }
            self.now = date
            if self.feedbackPulses.contains(where: { date.timeIntervalSince($0.time) > 6 }) {
                self.feedbackPulses.removeAll { date.timeIntervalSince($0.time) > 6 }
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in self?.shutdown() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification).sink { [weak self] _ in self?.statistics.requestSave() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).sink { [weak self] _ in
            guard let self, self.startsKeyboardMonitor else { return }
            self.monitor.refreshPermission()
            self.remapping.refreshPermission()
        }.store(in: &subscriptions)
    }

    var sessionTotal: Int { statistics.sessionCounts.values.reduce(0, +) }
    var recentRate: Int { statistics.recentCount(seconds: 60, endingAt: Date()) }
    var statusText: String {
        if !isEnabled { return L("已暂停") }
        if monitor.secureInputActive { return L("键盘反馈已暂停 · 安全输入") }
        if experienceMode == .keyboardSounds { return L(monitor.isGlobalActive ? "键盘音效 · 所有应用" : "键盘音效 · 仅应用内") }
        return L(monitor.isGlobalActive ? "正在合奏 · 所有应用" : "正在合奏 · 仅应用内")
    }
    var isKeyboardSoundMode: Bool { experienceMode == .keyboardSounds }
    var studioTitle: String { L(isKeyboardSoundMode ? "键盘音效" : "音乐空间") }
    var todayTotal: Int { statistics.total(from: Calendar.current.startOfDay(for: now), to: now) }
    var soundingHeldKeys: Set<UInt16> {
        if isKeyboardSoundMode { return heldKeys }
        guard audio.heldKeyCount > 0 else { return [] }
        return heldKeys.filter { KeyGestureRole.isPerformanceKey($0) }
    }
    private static let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    func start() {
        guard !started else { return }
        started = true
        if startsKeyboardMonitor { remapping.start() }
        if isEnabled { activateAudioAndMonitoring() }
        synchronizeRhythmOverlay()
    }
    private func activateAudioAndMonitoring() {
        if experienceMode == .keyboardSounds {
            audio.stop()
            keyboardAudio.start()
            if startsKeyboardMonitor { monitor.start() }
            return
        }
        keyboardAudio.stop()
        let selected = selectedMusic
        if selected.id != audio.currentTrack.id, !audio.selectTrack(selected, autoplay: false) {
            musicSelectionError = audio.musicErrorMessage ?? L("所选音乐暂时无法播放，已保留当前音乐。")
            selectedMusicID = audio.currentTrack.id
            defaults.set(selectedMusicID, forKey: "selectedMusicID")
        }
        audio.start(resumeMusic: musicWantsPlayback)
        if startsKeyboardMonitor { monitor.start() }
    }
    func shutdown() {
        cancelRhythmFeedback()
        rhythmOverlay?.hide()
        remapping.stop(); statistics.flush(); monitor.stop(); audio.stop(); keyboardAudio.stop()
    }
    func receiveKey(_ code: UInt16) {
        guard isEnabled, !monitor.secureInputActive, !heldKeys.contains(code) else { return }
        let response: String
        if isKeyboardSoundMode {
            keyboardAudio.noteOn(keyCode: code)
            response = keyboardSoundStyle.title
        } else {
            response = audio.noteOn(keyCode: code)
        }
        // Queue audio before statistics and published presentation changes.
        heldKeys.insert(code)
        statistics.record(keyCode: code)
        if rhythmEnabled { rhythmFeedback.receiveKey(code) }
        if !isKeyboardSoundMode && !KeyGestureRole.isPerformanceKey(code) { return }
        pressedKeys.insert(code)
        lastKey = code
        lastNote = response
        lastStrike = Date()
        strikeCount += 1
        appendFeedbackPulse(code: code)
        if code == 57 { retainKeyHighlight(code, duration: 0.15) }
    }
    func releaseKey(_ code: UInt16) {
        heldKeys.remove(code)
        if isKeyboardSoundMode { keyboardAudio.noteOff(keyCode: code) }
        else { audio.noteOff(keyCode: code) }
        if keyTokens[code] == nil { pressedKeys.remove(code) }
    }
    func resetHeldNotes() {
        audio.releaseAll()
        keyboardAudio.releaseAll()
        heldKeys.removeAll()
        pressedKeys.removeAll()
        keyTokens.removeAll()
        feedbackPulses.removeAll()
        cancelRhythmFeedback()
    }
    func previewKey(_ code: UInt16) {
        guard isEnabled, !monitor.secureInputActive else { return }
        if rhythmEnabled { rhythmFeedback.receiveKey(code) }
        if isKeyboardSoundMode {
            keyboardAudio.preview(keyCode: code)
            lastNote = keyboardSoundStyle.title
        } else {
            guard KeyGestureRole.isPerformanceKey(code) else { return }
            lastNote = audio.trigger(keyCode: code)
        }
        lastKey = code
        lastStrike = Date()
        strikeCount += 1
        appendFeedbackPulse(code: code)
        pressedKeys.insert(code)
        retainKeyHighlight(code, duration: 0.22)
    }
    private func retainKeyHighlight(_ code: UInt16, duration: TimeInterval) {
        let token = UUID()
        keyTokens[code] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.keyTokens[code] == token else { return }
            self.keyTokens.removeValue(forKey: code)
            if !self.heldKeys.contains(code) { self.pressedKeys.remove(code) }
        }
    }
    func previewSound() {
        guard isEnabled, !monitor.secureInputActive else { return }
        if isKeyboardSoundMode { keyboardAudio.previewSequence() }
        else { audio.preview() }
    }

    /// Visual-only sample: never synthesizes keyboard input, plays audio, or counts typing.
    func previewRhythm() {
        guard isEnabled, !monitor.secureInputActive else { return }
        rhythmEnabled = true
        cancelRhythmFeedback()
        rhythmDemoTask = Task { @MainActor [weak self] in
            // Continue immediately after Space and Return to demonstrate a phrase,
            // rather than presenting either accent as an isolated finale.
            let sequence: [(UInt16, UInt64)] = [(0, 220), (1, 150), (2, 110), (3, 90), (49, 80),
                                               (4, 90), (5, 90), (38, 100), (40, 120), (36, 120),
                                               (0, 110), (1, 100), (2, 100), (3, 100), (4, 90),
                                               (49, 90), (5, 110), (38, 100), (40, 120), (36, 0)]
            for (code, delay) in sequence {
                guard !Task.isCancelled, let self, self.rhythmEnabled, self.isEnabled,
                      !self.monitor.secureInputActive else { return }
                self.rhythmFeedback.receiveKey(code)
                if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
            }
        }
    }

    func resetRhythmPosition() {
        rhythmClickThrough = false
        defaults.removeObject(forKey: "rhythmOverlayPosition")
        rhythmOverlay?.resetPosition()
    }

    private func cancelRhythmFeedback() {
        rhythmDemoTask?.cancel()
        rhythmDemoTask = nil
        rhythmFeedback.reset()
    }

    private func synchronizeRhythmOverlay() {
        // Device-free tests never instantiate AppKit windows.
        guard started, startsKeyboardMonitor else { return }
        guard rhythmEnabled && isEnabled else { rhythmOverlay?.hide(); return }
        if rhythmOverlay == nil {
            rhythmOverlay = RhythmOverlayController(feedback: rhythmFeedback, defaults: defaults) { [weak self] in
                self?.rhythmEnabled = false
            }
        }
        rhythmOverlay?.setClickThrough(rhythmClickThrough)
        rhythmOverlay?.show()
    }

    private static func validRhythmIntensity(_ value: Double) -> Double {
        value.isFinite ? min(1.5, max(0.4, value)) : 1
    }
    var musicTracks: [MusicTrack] {
        MusicLibrary.builtInTracks + [MusicLibrary.generativeTrack].compactMap { $0 } + music.importedTracks.map { track in
            let url = music.fileURL(for: track)
            return MusicTrack(id: track.id, title: track.title, subtitle: L(url == nil ? "文件暂时不可用" : "本机音乐"),
                              duration: track.duration, url: url, isBuiltIn: false)
        }
    }
    var selectedMusic: MusicTrack {
        musicTracks.first(where: { $0.id == selectedMusicID }) ?? MusicLibrary.builtInTracks[0]
    }

    @discardableResult
    func selectMusic(id: String) -> Bool {
        guard let track = musicTracks.first(where: { $0.id == id }) else { return false }
        guard track.isBuiltIn || track.url != nil else {
            musicSelectionError = L("找不到这首本机音乐的副本。当前音乐会继续播放。")
            return false
        }
        musicSelectionError = nil
        if !started || isKeyboardSoundMode {
            selectedMusicID = track.id
            defaults.set(track.id, forKey: "selectedMusicID")
            lastNote = "—"
            lastKey = nil
            return true
        }
        guard audio.selectTrack(track, autoplay: started && isEnabled && musicWantsPlayback) else {
            musicSelectionError = audio.musicErrorMessage ?? L("这首音乐暂时无法播放，当前音乐保持不变。")
            return false
        }
        resetHeldNotes()
        selectedMusicID = track.id
        defaults.set(track.id, forKey: "selectedMusicID")
        lastNote = "—"
        lastKey = nil
        return true
    }

    func toggleMusicPlayback() {
        guard isEnabled, !isKeyboardSoundMode else { return }
        musicWantsPlayback = started ? !audio.isMusicPlaying : !musicWantsPlayback
        defaults.set(musicWantsPlayback, forKey: "musicWantsPlayback")
        guard started else { return }
        if musicWantsPlayback { audio.playMusic() } else { audio.pauseMusic() }
    }
    func seekMusic(to time: TimeInterval) {
        guard time.isFinite, !isKeyboardSoundMode else { return }
        audio.seekMusic(to: time)
        resetHeldNotes()
    }

    func importMusic() {
        guard !music.isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = L("加入你的音乐")
        panel.message = L("选择本机音频，陪你一起打字。原文件会保留。")
        panel.prompt = L("加入音乐")
        panel.allowedContentTypes = [.audio]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                _ = await self?.importMusicFile(at: url)
            }
        }
    }

    @discardableResult
    func importMusicFile(at url: URL) async -> Bool {
        musicSelectionError = nil
        guard let imported = await music.importFile(at: url) else { return false }
        return selectMusic(id: imported.id)
    }

    func removeImportedMusic(id: String) {
        guard !music.isImporting, music.importedTracks.contains(where: { $0.id == id }) else { return }
        let wasSelected = selectedMusicID == id
        if wasSelected, let fallback = MusicLibrary.builtInTracks.first, !selectMusic(id: fallback.id) { return }
        if !music.removeImportedTrack(id: id), wasSelected { _ = selectMusic(id: id) }
    }

    private func appendFeedbackPulse(code: UInt16) {
        let date = Date()
        feedbackPulses.removeAll { date.timeIntervalSince($0.time) > 6 }
        feedbackPulses.append(FeedbackPulse(id: strikeCount, time: date, lane: Int(code % 4), strength: 0.8))
        if feedbackPulses.count > 48 { feedbackPulses.removeFirst(feedbackPulses.count - 48) }
    }

    private static func validVolume(_ value: Double, fallback: Double, maximum: Double = 1) -> Double {
        value.isFinite ? min(maximum, max(0, value)) : fallback
    }

    func exportCSV(from: Date, to: Date) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("KeyWoo-按键统计.csv")
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try statistics.csv(from: from, to: to).write(to: url, atomically: true, encoding: .utf8) }
        catch { let alert = NSAlert(error: error); alert.runModal() }
    }
}
