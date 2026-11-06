import AVFoundation
import Darwin
import Foundation

struct GenerativePlaybackDiagnostics {
    var bufferedFrames: Int
    var capacityFrames: Int
    var peakBufferedFrames: Int
    var requestCount: UInt64
    var completionCount: UInt64
    var playedFrames: UInt64
    var underrunFrames: UInt64
    var lastConditionSerial: UInt64
    var workerPID: Int32?
    var generationID: Int
    var ready: Bool
    var latestGenerationMS: Double
    var maxRenderFrames: Int
    var ringLockMisses: UInt64
    var callbackHistogram: [String: UInt64]
    var requestRoundTripP50MS: Double
    var requestRoundTripP95MS: Double
    var requestRoundTripMaxMS: Double
    var generationP50MS: Double
    var generationP95MS: Double
    var generationMaxMS: Double
    var startupWatermarkFrames: Int
}

private final class GenerationSession: @unchecked Sendable {
    let condition = NSCondition()
    let stream = GenerativePCMStream()
    var process: Process?
    var stdin: FileHandle?
    var generation = 0, running = false, ready = false, playRequested = false
    var failure: String?, stderrTail = ""
    var requests: UInt64 = 0, completions: UInt64 = 0, serial: UInt64 = 0, lastConditionSerial: UInt64 = 0
    var latestGenerationMS = 0.0, depth = 0.45
    var roundTrips: [Double] = [], generationTimes: [Double] = []
    var timingIndex = 0, maximumRoundTrip = 0.0, maximumGeneration = 0.0
    var style = 0
    var physicalKeys = Set<UInt32>()
    var heldNotes: [UInt32: [Int]] = [:]
    var onsets = Set<Int>(), offs = Set<Int>()
    var fallbackPhrase = 0

    func clearMIDI(clearPhysicalKeys: Bool = true) {
        // Only release notes this player actually controlled. All other pitches
        // remain unconstrained, so typing does not shut off the entire song.
        offs.formUnion(heldNotes.values.flatMap { $0 }); offs.formUnion(onsets)
        heldNotes.removeAll(); onsets.removeAll()
        if clearPhysicalKeys { physicalKeys.removeAll() }
    }
    func nextCondition() -> [Int] {
        var notes = [Int](repeating: -1, count: 128)
        for pitch in offs { notes[pitch] = 0 }
        let held = Set(heldNotes.values.flatMap { $0 })
        if depth > 0 {
            for pitch in held { notes[pitch] = 1 }
            for pitch in onsets { notes[pitch] = 2 }
        }
        // A short tap still gets its onset, followed by its own note-off in the
        // next packet. Unrelated generated parts are never forced off.
        offs = offs.intersection(onsets).subtracting(held)
        onsets.removeAll()
        return notes
    }

}

/// Blocking pipe reads live only on the producer queue. Handles arbitrary
/// fragmentation and preserves binary bytes between successive JSON headers.
private final class GenerationPipeReader {
    let handle: FileHandle
    private var buffered = Data()
    init(_ handle: FileHandle) { self.handle = handle }
    private func readSome(maximum: Int) throws -> Data {
        // Foundation's read(upToCount:) can wait for the requested amount on a
        // Darwin pipe. A short ready header would then deadlock against the
        // worker waiting for its first request. POSIX read returns available
        // bytes immediately, while still blocking safely when none exist.
        var storage = [UInt8](repeating: 0, count: maximum)
        while true {
            let count = storage.withUnsafeMutableBytes { raw in
                Darwin.read(handle.fileDescriptor, raw.baseAddress!, maximum)
            }
            if count > 0 { return Data(storage.prefix(count)) }
            if count == 0 { throw error("本机生成进程已退出。") }
            if errno == EINTR { continue }
            throw error("本机生成通信中断（\(errno)）。")
        }
    }
    func header() throws -> [String: Any] {
        while !buffered.contains(10) {
            guard buffered.count < 16_384 else { throw error("模型响应头过长。") }
            buffered.append(try readSome(maximum: 8_192))
        }
        let end = buffered.firstIndex(of: 10)!
        let data = buffered.prefix(upTo: end)
        buffered.removeSubrange(...end)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error("模型响应格式不正确。") }
        if let message = json["error"] as? String { throw error(String(message.prefix(500))) }
        return json
    }
    func bytes(_ count: Int) throws -> Data {
        while buffered.count < count {
            buffered.append(try readSome(maximum: count - buffered.count))
        }
        let result = Data(buffered.prefix(count)); buffered.removeFirst(count); return result
    }
    private func error(_ message: String) -> NSError { NSError(domain: "KeyWooAI", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
}

/// A single continuous model-generated music stream. MIDI conditions reshape
/// subsequent generated phrases; the same stream receives the immediate gesture
/// DSP. No triggered sample, oscillator, or second music player is attached.
final class GenerativeMusicPlayback: MusicPlayback {
    private let runtime: GenerativeMusicRuntime
    private let session = GenerationSession()
    private let workerQueue = DispatchQueue(label: "app.keywoo.music-generation", qos: .userInitiated)
    private let audioDeviceEnabled: Bool
    private let appliesImmediateDSP: Bool
    private var graph: GenerativeStreamGraph?
    private var activityToken: NSObjectProtocol?
    private var gain: Float = 0.48
    private var depth = 0.45, decay = 0.5, sound = HitSound.softTap

    init(runtime: GenerativeMusicRuntime, styleKey: Int = 0, audioDeviceEnabled: Bool = true, appliesImmediateDSP: Bool = true) throws {
        guard FileManager.default.isExecutableFile(atPath: runtime.pythonURL.path),
              FileManager.default.fileExists(atPath: runtime.workerURL.path) else {
            throw NSError(domain: "KeyWooAI", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到本机音乐模型运行程序。"])
        }
        self.runtime = runtime; self.audioDeviceEnabled = audioDeviceEnabled
        self.appliesImmediateDSP = appliesImmediateDSP
        session.style = min(1, max(0, styleKey))
        if !appliesImmediateDSP { session.stream.setPerformance(depth: 0, decay: decay, sound: sound) }
    }
    deinit { stop() }
    var duration: TimeInterval { 0 }
    var currentTime: TimeInterval { get { Double(session.stream.snapshot().playedFrames) / GenerativePCMStream.sampleRate } set { /* Live generation has no seekable recording. */ } }
    var isPlaying: Bool { session.condition.lock(); defer { session.condition.unlock() }; return session.playRequested && session.failure == nil }
    var volume: Float { get { gain } set { gain = max(0, min(1, newValue)); session.stream.setGain(gain) } }
    var failureMessage: String? { session.condition.lock(); defer { session.condition.unlock() }; return session.failure }
    var statusMessage: String? {
        session.condition.lock(); let ready = session.ready, playing = session.playRequested, running = session.running, failure = session.failure; session.condition.unlock()
        if failure != nil { return nil }
        if !running { return "本机模型尚未启动" }
        if !ready { return "正在加载本机音乐模型，首次约需半分钟…" }
        if !playing { return "AI 已就绪 · 暂停生成" }
        if session.stream.snapshot().buffering { return "正在缓冲 AI 音乐…" }
        return "AI 正在连续创作 · 按键改变后续旋律与乐句"
    }
    var interactionSnapshot: InteractionSnapshot {
        let m = session.stream.snapshot()
        return InteractionSnapshot(level: isPlaying ? m.level : 0, performedRMS: 0, outputRMS: isPlaying ? m.rms : 0, voices: 0, buffers: m.buffers, nonSilentBuffers: m.nonSilent, attacks: m.attacks)
    }
    var diagnostics: GenerativePlaybackDiagnostics {
        session.condition.lock()
        let values = (session.requests, session.completions, session.lastConditionSerial, session.process?.isRunning == true ? session.process?.processIdentifier : nil, session.generation, session.ready, session.latestGenerationMS)
        let roundTrips = session.roundTrips, generationTimes = session.generationTimes
        let maximumRoundTrip = session.maximumRoundTrip, maximumGeneration = session.maximumGeneration
        session.condition.unlock()
        func percentile(_ array: [Double], _ fraction: Double) -> Double {
            guard !array.isEmpty else { return 0 }; let sorted = array.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let m = session.stream.snapshot()
        return GenerativePlaybackDiagnostics(bufferedFrames: session.stream.bufferedFrames, capacityFrames: GenerativePCMStream.capacityFrames, peakBufferedFrames: session.stream.peakBufferedFrames, requestCount: values.0, completionCount: values.1, playedFrames: m.playedFrames, underrunFrames: m.underrunFrames, lastConditionSerial: values.2, workerPID: values.3, generationID: values.4, ready: values.5, latestGenerationMS: values.6, maxRenderFrames: m.maxRenderFrames, ringLockMisses: m.ringLockMisses, callbackHistogram: m.callbackSizes.dictionary, requestRoundTripP50MS: percentile(roundTrips, 0.50), requestRoundTripP95MS: percentile(roundTrips, 0.95), requestRoundTripMaxMS: maximumRoundTrip, generationP50MS: percentile(generationTimes, 0.50), generationP95MS: percentile(generationTimes, 0.95), generationMaxMS: maximumGeneration, startupWatermarkFrames: session.stream.startupWatermarkFrames)
    }
    func configureInteraction(track: MusicTrack) throws { }
    func prepare() -> Bool {
        session.condition.lock()
        if session.running { session.condition.unlock(); return true }
        session.generation += 1; let generation = session.generation
        session.running = true; session.ready = false; session.failure = nil
        let runtime = runtime, state = session
        session.condition.unlock()
        // The closure retains the session, not the player. Releasing the player
        // still executes deinit/stop and terminates its owned worker.
        workerQueue.async { Self.runWorker(runtime: runtime, state: state, generation: generation) }
        return true
    }
    func activateAudio() throws {
        if audioDeviceEnabled {
            if graph == nil { graph = GenerativeStreamGraph(stream: session.stream) }
            try graph?.activate()
        }
    }
    func deactivateAudio() { pause(); graph?.deactivate() }
    func play() -> Bool {
        _ = prepare()
        do { try activateAudio() } catch { session.condition.lock(); session.failure = error.localizedDescription; session.condition.unlock(); return false }
        session.condition.lock(); session.playRequested = true; session.condition.broadcast(); session.condition.unlock()
        if activityToken == nil { activityToken = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "正在生成并播放本机音乐") }
        session.stream.setPlaying(true); return true
    }
    func pause() {
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token); activityToken = nil }
        session.condition.lock(); session.playRequested = false; session.clearMIDI(); session.condition.broadcast(); session.condition.unlock()
        session.stream.setPlaying(false)
    }
    func stop() {
        if let token = activityToken { ProcessInfo.processInfo.endActivity(token); activityToken = nil }
        session.condition.lock()
        session.generation += 1; session.running = false; session.ready = false; session.playRequested = false; session.clearMIDI()
        let process = session.process; session.process = nil; session.stdin = nil
        session.condition.broadcast(); session.condition.unlock()
        // Invalidate the producer first, then synchronously stop the consumer.
        // Only after both are quiescent may the ring discard queued slots.
        graph?.deactivate()
        session.stream.clear()
        Self.terminate(process)
    }
    func setPerformance(volume: Double, sound: HitSound, decay: Double) {
        self.depth = min(1, max(0, volume)); self.decay = decay; self.sound = sound
        session.condition.lock()
        if self.depth == 0 && session.depth > 0 { session.clearMIDI(clearPhysicalKeys: false) }
        session.depth = self.depth; session.condition.unlock()
        // A phrase collector keeps model conditioning but must not bake the
        // user's immediate gesture into future cached music. Its final phrase
        // player applies that gesture once, at the actual listening instant.
        session.stream.setPerformance(depth: appliesImmediateDSP ? self.depth : 0, decay: decay, sound: sound)
    }
    /// Phrase collectors choose a whole musical style before preparing a new
    /// phrase. This leaves the model state and its unconstrained notes intact.
    func setGenerationStyle(_ index: Int) {
        session.condition.lock(); session.style = min(1, max(0, index)); session.condition.unlock()
    }
    func perform(key: UInt32, note: UInt8?, velocity: UInt8, richness: Double, heldCount: Int) {
        perform(key: key, note: note, velocity: velocity, richness: richness, heldCount: heldCount,
                decision: .init(role: .phrase, shouldChangeContent: true, feedbackWeight: 1))
    }
    func perform(key: UInt32, note: UInt8?, velocity: UInt8, richness: Double, heldCount: Int, decision: ContentChangePolicy.Decision) {
        guard decision.feedbackWeight > 0 else { return }
        session.condition.lock()
        guard session.playRequested, session.ready, session.failure == nil, session.physicalKeys.insert(key).inserted else { session.condition.unlock(); return }
        if decision.shouldChangeContent && session.depth > 0 {
            session.serial &+= 1
            let pentatonic = [60, 62, 64, 67, 69]
            let lead = note.map(Int.init) ?? pentatonic[session.fallbackPhrase % pentatonic.count]
            session.fallbackPhrase += 1
            // Constrain only the performed lead. The model retains room to
            // compose bass/voicing; nearest scale tones are not a chord voicing
            // and repeated low-note onsets would make fast typing too busy.
            let chord = [min(127, max(0, lead))]
            session.heldNotes[key] = chord
            // If several presses arrive before the next 40ms generation step,
            // use its latest lead onset rather than accumulate a dense cluster.
            session.onsets = Set(chord)
        }
        session.condition.broadcast(); session.condition.unlock()
        session.stream.press(held: heldCount, weight: decision.feedbackWeight)
    }
    func release(key: UInt32, heldCount: Int) {
        session.condition.lock(); session.physicalKeys.remove(key)
        if let notes = session.heldNotes.removeValue(forKey: key) {
            let remaining = Set(session.heldNotes.values.flatMap { $0 })
            session.offs.formUnion(notes.filter { !remaining.contains($0) })
        }
        session.condition.unlock(); session.stream.release(held: heldCount)
    }
    func releaseInteraction() {
        session.condition.lock(); session.clearMIDI(); session.condition.unlock(); session.stream.releaseAll()
    }
    func measuredRMS() -> Double { isPlaying ? session.stream.snapshot().rms : 0 }
    /// Uses the identical streaming/render core without opening an audio device.
    /// Only call when audioDeviceEnabled=false, from one test/render thread.
    func renderForVerification(frames: Int) -> [Float] {
        precondition(!audioDeviceEnabled && frames >= 0)
        var l = [Float](repeating: 0, count: frames), r = l
        l.withUnsafeMutableBufferPointer { left in r.withUnsafeMutableBufferPointer { right in
            if frames > 0 { session.stream.render(frames: frames, left: left.baseAddress!, right: right.baseAddress!) }
        } }
        var result = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames { result[i*2] = l[i]; result[i*2+1] = r[i] }; return result
    }

    private static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }
    private static func runWorker(runtime: GenerativeMusicRuntime, state: GenerationSession, generation: Int) {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.qualityOfService = .userInitiated
        process.executableURL = runtime.pythonURL
        process.arguments = ["-u", runtime.workerURL.path, "--assets-root", runtime.modelDirectory.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["MAGENTA_HOME"] = runtime.modelDirectory.path
        environment["HF_HUB_OFFLINE"] = "1"; environment["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
        process.environment = environment
        errors.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            state.condition.lock()
            state.stderrTail += String(decoding: bytes, as: UTF8.self)
            if state.stderrTail.utf8.count > 8_192 { state.stderrTail = String(state.stderrTail.suffix(4_096)) }
            state.condition.unlock()
        }
        defer {
            errors.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            terminate(process)
            state.condition.lock()
            if state.generation == generation { state.running = false; state.ready = false; state.process = nil; state.stdin = nil }
            state.condition.broadcast(); state.condition.unlock()
        }
        do {
            state.condition.lock(); let valid = state.generation == generation && state.running
            if valid { state.process = process; state.stdin = input.fileHandleForWriting }
            state.condition.unlock()
            guard valid else { return }
            try process.run()
            state.condition.lock(); let stillValid = state.generation == generation && state.running; state.condition.unlock()
            guard stillValid else { return }
            let reader = GenerationPipeReader(output.fileHandleForReading)
            let ready = try reader.header()
            guard ready["ready"] as? Bool == true, ready["frames"] as? Int == 1_920, ready["rate"] as? Int == 48_000, ready["channels"] as? Int == 2, ready["format"] as? String == "float32le" else {
                throw NSError(domain: "KeyWooAI", code: 3, userInfo: [NSLocalizedDescriptionKey: "本机模型音频格式不匹配。"])
            }
            state.condition.lock(); if state.generation == generation { state.ready = true }; state.condition.broadcast(); state.condition.unlock()
            while true {
                state.condition.lock()
                while state.generation == generation && state.running && (!state.playRequested || state.stream.freeFrames < 1_920) {
                    if !state.playRequested { state.condition.wait() }
                    else { _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.005)) }
                }
                guard state.generation == generation && state.running else { state.condition.unlock(); return }
                let notes = state.nextCondition(), style = state.style, serial = state.serial
                state.requests &+= 1; state.lastConditionSerial = serial
                state.condition.unlock()
                let request: [String: Any] = ["cmd": "step", "notes": notes, "style": style, "reset": false]
                var line = try JSONSerialization.data(withJSONObject: request); line.append(10)
                let requestStarted = ProcessInfo.processInfo.systemUptime
                try input.fileHandleForWriting.write(contentsOf: line)
                let header = try reader.header()
                guard header["frames"] as? Int == 1_920, header["bytes"] as? Int == 15_360, header["rate"] as? Int == 48_000 else {
                    throw NSError(domain: "KeyWooAI", code: 4, userInfo: [NSLocalizedDescriptionKey: "本机模型返回了无效音频帧。"])
                }
                let data = try reader.bytes(15_360)
                let samples: [Float] = data.withUnsafeBytes { bytes in
                    (0..<3_840).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0*4, as: UInt32.self))) }
                }
                state.condition.lock()
                guard state.generation == generation && state.running else { state.condition.unlock(); return }
                let appended = state.stream.append(samples)
                if appended {
                    state.completions &+= 1; state.latestGenerationMS = header["generation_ms"] as? Double ?? 0
                    let roundTrip = (ProcessInfo.processInfo.systemUptime - requestStarted) * 1_000
                    state.maximumRoundTrip = max(state.maximumRoundTrip, roundTrip)
                    state.maximumGeneration = max(state.maximumGeneration, state.latestGenerationMS)
                    if state.roundTrips.count < 2_048 { state.roundTrips.append(roundTrip); state.generationTimes.append(state.latestGenerationMS) }
                    else { state.roundTrips[state.timingIndex] = roundTrip; state.generationTimes[state.timingIndex] = state.latestGenerationMS; state.timingIndex = (state.timingIndex + 1) % 2_048 }
                }
                state.condition.unlock()
                guard appended else { throw NSError(domain: "KeyWooAI", code: 5, userInfo: [NSLocalizedDescriptionKey: "生成音频无效或缓冲越界。"] ) }
            }
        } catch {
            state.condition.lock()
            if state.generation == generation && state.running {
                state.failure = error.localizedDescription; state.playRequested = false; state.ready = false
                state.stream.setPlaying(false)
            }
            state.condition.broadcast(); state.condition.unlock()
        }
    }
}
