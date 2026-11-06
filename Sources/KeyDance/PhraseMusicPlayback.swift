import AVFoundation
import Foundation

struct PhrasePreparationSnapshot {
    let started: Int
    let completed: Int
    let failed: Int
    let lastSeconds: Double
    let isBuilding: Bool
}

/// Only complete, prepared music reaches the sound device. The current phrase
/// keeps playing while AI prepares another one, including under sustained load.
final class PhraseMusicPlayback: MusicPlayback {
    private let graph: PhraseLoopGraph
    private let builder: MusicPhraseBuilding
    private let lock = NSLock()
    private var timer: Timer?
    private var playing = false, stopped = false, building = false
    private var candidate: PreparedMusicPhrase?
    private var preparationError: String?
    private var hardwareError: String?
    private var gain: Float = 0.48
    private var responseDepth = 0.45
    private var held = Set<UInt32>()
    private var startedBuilds = 0, completedBuilds = 0, failedBuilds = 0
    private var preparationStarted = 0.0, lastPreparationSeconds = 0.0

    convenience init(runtime: GenerativeMusicRuntime, audioDeviceEnabled: Bool = true) throws {
        try self.init(seed: Self.loadSeed(filename: "keywoo-ai-seed.wav"),
                      initialVariation: try? Self.loadSeed(filename: "keywoo-ai-variation.wav"),
                      builder: LocalMusicPhraseBuilder(runtime: runtime), audioDeviceEnabled: audioDeviceEnabled)
    }

    init(seed: PreparedMusicPhrase, initialVariation: PreparedMusicPhrase? = nil,
         builder: MusicPhraseBuilding, audioDeviceEnabled: Bool = true) throws {
        self.builder = builder
        graph = PhraseLoopGraph(audioDeviceEnabled: audioDeviceEnabled)
        guard graph.submit(seed) != nil else { throw NSError(domain: "KeyWooPhrase", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法载入初始乐句。"]) }
        if let initialVariation { _ = graph.submit(initialVariation) }
        graph.setGain(gain)
    }

    deinit { stop() }
    var duration: TimeInterval { 0 }
    var currentTime: TimeInterval { get { Double(graph.snapshot.playedFrames) / 48_000 } set {} }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return playing && hardwareError == nil }
    var volume: Float {
        get { lock.lock(); defer { lock.unlock() }; return gain }
        set { lock.lock(); gain = max(0, min(1, newValue)); let value = gain; lock.unlock(); graph.setGain(value) }
    }
    var failureMessage: String? { lock.lock(); defer { lock.unlock() }; return hardwareError }
    var statusMessage: String? {
        lock.lock(); let active = playing, busy = building, error = preparationError; lock.unlock()
        if !active { return "音乐已暂停 · 乐句已保留" }
        if error != nil { return "音乐继续 · 下一乐句暂时未就绪" }
        if graph.snapshot.pendingPhraseCount > 0 { return "下一乐句已就绪 · 随输入自然衔接" }
        return busy ? "音乐继续 · 正在准备下一乐句" : "轻触当前音乐 · 词句推动变奏"
    }
    var interactionSnapshot: InteractionSnapshot {
        let value = graph.snapshot
        return InteractionSnapshot(level: value.level, performedRMS: 0, outputRMS: value.rms, voices: 0,
                                   buffers: value.buffers, nonSilentBuffers: value.nonSilent, attacks: value.attacks)
    }
    var diagnostics: PhraseLoopSnapshot { graph.snapshot }
    var preparationDiagnostics: PhrasePreparationSnapshot {
        lock.lock(); defer { lock.unlock() }
        return PhrasePreparationSnapshot(started: startedBuilds, completed: completedBuilds,
                                         failed: failedBuilds, lastSeconds: lastPreparationSeconds, isBuilding: building)
    }
    func prepare() -> Bool { true }
    func activateAudio() throws { try graph.activate() }
    func deactivateAudio() { graph.deactivate() }
    func configureInteraction(track: MusicTrack) throws {}
    func play() -> Bool {
        lock.lock(); let cancelled = stopped; lock.unlock()
        guard !cancelled else { return false }
        do { try graph.play() } catch {
            lock.lock(); hardwareError = error.localizedDescription; lock.unlock(); return false
        }
        lock.lock(); playing = true; hardwareError = nil; lock.unlock()
        lock.lock(); preparationError = nil; lock.unlock()
        builder.setPlaying(true)
        if timer == nil {
            let next = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.pump() }
            RunLoop.main.add(next, forMode: .common); timer = next
        }
        pump()
        return true
    }
    func pause() {
        lock.lock(); playing = false; held.removeAll(); lock.unlock()
        timer?.invalidate(); timer = nil
        graph.pause(); builder.setPlaying(false)
    }
    func stop() {
        lock.lock(); let alreadyStopped = stopped; stopped = true; playing = false; held.removeAll(); candidate = nil; lock.unlock()
        guard !alreadyStopped else { return }
        timer?.invalidate(); timer = nil
        graph.stop(); builder.stop()
    }
    func setPerformance(volume: Double, sound: HitSound, decay: Double) {
        lock.lock(); responseDepth = max(0, min(1, volume)); let enabled = responseDepth > 0; lock.unlock()
        if !enabled { builder.offerCue(nil) }
        graph.setPerformance(depth: volume, decay: decay, sound: sound)
    }
    func perform(key: UInt32, note: UInt8?, velocity: UInt8, richness: Double, heldCount: Int) {
        perform(key: key, note: note, velocity: velocity, richness: richness, heldCount: heldCount,
                decision: .init(role: .phrase, shouldChangeContent: true, feedbackWeight: 1, action: .lift))
    }
    func perform(key: UInt32, note: UInt8?, velocity: UInt8, richness: Double, heldCount: Int, decision: ContentChangePolicy.Decision) {
        guard decision.feedbackWeight > 0 else { return }
        lock.lock()
        let accepted = playing && held.insert(key).inserted
        let changesContent = decision.shouldChangeContent && responseDepth > 0
        lock.unlock()
        guard accepted else { return }
        graph.press(key: key, held: heldCount, weight: decision.feedbackWeight, action: decision.action, duration: decision.duration)
        if changesContent {
            graph.requestPhraseChange()
            builder.offerCue(.init(note: note, velocity: velocity, richness: richness, role: decision.role))
        }
    }
    func release(key: UInt32, heldCount: Int) {
        lock.lock(); held.remove(key); lock.unlock(); graph.release(key: key, held: heldCount)
    }
    func releaseInteraction() { lock.lock(); held.removeAll(); lock.unlock(); graph.releaseAll() }
    func measuredRMS() -> Double { isPlaying ? graph.snapshot.rms : 0 }
    func renderForVerification(frames: Int) -> [Float] {
        let output = graph.renderForVerification(frames: frames)
        pump()
        return output
    }

    private func pump() {
        lock.lock()
        guard playing, !stopped else { lock.unlock(); return }
        if let ready = candidate {
            lock.unlock()
            if graph.submit(ready) != nil { lock.lock(); candidate = nil; lock.unlock() }
            return
        }
        guard !building, preparationError == nil,
              graph.snapshot.pendingPhraseCount == 0 || startedBuilds == 0 else { lock.unlock(); return }
        building = true
        startedBuilds += 1
        preparationStarted = ProcessInfo.processInfo.systemUptime
        lock.unlock()
        builder.buildNext { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.building = false
            self.lastPreparationSeconds = ProcessInfo.processInfo.systemUptime - self.preparationStarted
            if !self.stopped {
                switch result {
                case .success(let phrase): self.candidate = phrase; self.preparationError = nil; self.completedBuilds += 1
                case .failure(let error): self.preparationError = error.localizedDescription; self.failedBuilds += 1
                }
            }
            self.lock.unlock()
        }
    }

    private static func loadSeed(filename: String) throws -> PreparedMusicPhrase {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/Music/" + filename)
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Music/" + filename), source,
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/KeyDance/Resources/Music/" + filename)].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw NSError(domain: "KeyWooPhrase", code: 3, userInfo: [NSLocalizedDescriptionKey: "找不到初始音乐乐句。"])
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.length <= 48_000 * 16, file.processingFormat.sampleRate == 48_000,
              file.processingFormat.channelCount == 2,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "KeyWooPhrase", code: 4, userInfo: [NSLocalizedDescriptionKey: "初始乐句格式不正确。"])
        }
        try file.read(into: pcm)
        guard let channels = pcm.floatChannelData else { throw NSError(domain: "KeyWooPhrase", code: 5) }
        var samples = [Float](repeating: 0, count: Int(pcm.frameLength) * 2)
        for frame in 0..<Int(pcm.frameLength) { samples[frame * 2] = channels[0][frame]; samples[frame * 2 + 1] = channels[1][frame] }
        return try MusicPhraseAudio.prepare(samples: samples)
    }
}
