import AVFoundation
import Foundation

/// One sample clock owns the complete music signal. The fixed arrangement is
/// combined before the gesture processor; keys cannot seek or restart it.
private final class BackingRenderCore: @unchecked Sendable {
    let base: AVAudioPCMBuffer
    let rich: AVAudioPCMBuffer
    let rate: Double
    private let lock = NSLock(), meterLock = NSLock()
    private var requestedPlaying = false, playing = false
    private var requestedSeek: Int?
    private var requestedGain: Float = 0.35, gain: Float = 0.35, gainTarget: Float = 0.35
    private var gainInitialized = false
    private var requestedHeld = 0
    private var requestedDepth = 0.45, requestedDecay = 0.5
    private var requestedIntensity = WholeMusicGesture.Intensity.expressive
    private var requestedProfile = WholeMusicGesture.Profile.breath
    private var pendingAttacks: UInt64 = 0, attacks: UInt64 = 0
    private var pendingWeight = 0.0
    private var pendingAction = DJAction.lift, pendingDuration = 0.24
    private var resetRequested = false, releaseRequested = false
    private var frame = 0, totalFrames: UInt64 = 0
    private var gesture: WholeMusicGesture
    private var published = (position: 0.0, level: 0.0, rms: 0.0, frames: UInt64(0), attacks: UInt64(0))

    init(base: AVAudioPCMBuffer, rich: AVAudioPCMBuffer) {
        self.base = base; self.rich = rich; rate = base.format.sampleRate
        gesture = WholeMusicGesture(sampleRate: rate)
    }
    var duration: Double { Double(base.frameLength) / rate }
    var isPlaying: Bool { lock.lock(); defer { lock.unlock() }; return requestedPlaying }
    func setPlaying(_ value: Bool) { lock.lock(); requestedPlaying = value; lock.unlock() }
    func seek(_ value: Double) { lock.lock(); requestedSeek = min(Int(base.frameLength) - 1, max(0, Int(value * rate))); lock.unlock() }
    func setGain(_ value: Float) { lock.lock(); requestedGain = value; lock.unlock() }
    func setDepth(_ value: Double) { lock.lock(); requestedDepth = min(1, max(0, value)); lock.unlock() }
    func setDecay(_ value: Double) { lock.lock(); requestedDecay = min(1, max(0, value)); lock.unlock() }
    func setIntensity(_ value: WholeMusicGesture.Intensity) { lock.lock(); requestedIntensity = value; lock.unlock() }
    func setProfile(_ value: WholeMusicGesture.Profile) { lock.lock(); requestedProfile = value; lock.unlock() }
    func press(held: Int, weight: Double = 1, action: DJAction = .lift, duration: Double = 0.24) {
        guard weight > 0, action != .none else { return }
        lock.lock(); requestedHeld = held; pendingAttacks &+= 1; pendingWeight=max(pendingWeight,weight)
        pendingAction = action; pendingDuration = duration; lock.unlock()
    }
    func release(held: Int = 0) { lock.lock(); requestedHeld = held; releaseRequested = true; lock.unlock() }
    func clearActivity() { lock.lock(); requestedHeld = 0; pendingAttacks = 0; pendingWeight = 0; resetRequested = true; lock.unlock() }
    func snapshot() -> (position: Double, level: Double, rms: Double, frames: UInt64, attacks: UInt64) {
        meterLock.lock(); defer { meterLock.unlock() }; return published
    }
    func position() -> Double { lock.lock(); let seek = requestedSeek; lock.unlock(); return seek.map { Double($0) / rate } ?? snapshot().position }
    func render(_ count: Int, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) {
        // The realtime callback never waits for the UI/control thread.
        if lock.try() {
            if resetRequested { gesture.reset(); resetRequested = false }
            playing = requestedPlaying
            if let seek = requestedSeek { frame = seek; requestedSeek = nil; gesture.reset() }
            gesture.depth = requestedDepth; gesture.decay = requestedDecay; gesture.intensity = requestedIntensity
            gesture.profile = requestedProfile
            if releaseRequested { gesture.noteOff(heldCount: requestedHeld); releaseRequested = false }
            if pendingAttacks > 0 {
                gesture.noteOn(heldCount: requestedHeld, strength: pendingWeight, action: pendingAction, duration: pendingDuration)
                attacks &+= pendingAttacks; pendingAttacks = 0; pendingWeight = 0
            } else { gesture.noteOff(heldCount: requestedHeld) }
            gainTarget = requestedGain
            if !gainInitialized { gain = gainTarget; gainInitialized = true }
            lock.unlock()
        }
        let b = base.floatChannelData!, x = rich.floatChannelData!
        let n = Int(base.frameLength)
        let gainStep = Float(1 - exp(-1 / (rate * 0.008)))
        var energy = 0.0
        for i in 0..<count {
            gain += (gainTarget - gain) * gainStep
            if playing {
                // A constant blend: there is no keyboard-only instrument or
                // hidden accompaniment stem masquerading as a whole-song change.
                let shaped = gesture.process(left: b[0][frame] + x[0][frame] * 0.35,
                                             right: b[1][frame] + x[1][frame] * 0.35)
                l[i] = shaped.0 * gain; r[i] = shaped.1 * gain
                frame += 1; if frame >= n { frame = 0 }
            } else {
                _ = gesture.process(left: 0, right: 0)
                l[i] = 0; r[i] = 0
            }
            energy += Double(l[i] * l[i] + r[i] * r[i])
        }
        totalFrames &+= UInt64(count)
        if meterLock.try() {
            published = (Double(frame) / rate, playing ? gesture.level : 0,
                         sqrt(energy / Double(max(1, count * 2))), totalFrames, attacks)
            meterLock.unlock()
        }
    }
}

private final class GraphMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var rms = 0.0, peak = 0.0
    private var buffers: UInt64 = 0, nonSilent: UInt64 = 0
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength), n = Int(buffer.format.channelCount)
        var energy = 0.0, p = 0.0
        for c in 0..<n { for i in 0..<count { let v = Double(channels[c][i]); energy += v*v; p = max(p, abs(v)) } }
        if lock.try() { rms = sqrt(energy / Double(max(1, count*n))); peak = p; buffers &+= 1; if rms > 0.00001 { nonSilent &+= 1 }; lock.unlock() }
    }
    func read() -> (rms: Double, peak: Double, buffers: UInt64, nonSilent: UInt64) {
        lock.lock(); defer { lock.unlock() }; return (rms, peak, buffers, nonSilent)
    }
}

/// The complete song passes through one gesture DSP and output limiter.
/// No independently triggered instrument exists in this graph.
final class MusicPerformanceGraph {
    let engine = AVAudioEngine()
    private let core: BackingRenderCore
    private let limiter: AVAudioUnitEffect
    private let outputGain = AVAudioMixerNode()
    private let outputMeter = GraphMeter()
    private let format: AVAudioFormat
    private var configurationObserver: NSObjectProtocol?
    private var desiredActive = false, offline = false
    private var lastError: String?
    private var heldKeys = Set<UInt32>()
    private var holdKeys = Set<UInt32>()
    var gestureIntensity: WholeMusicGesture.Intensity = .expressive { didSet { core.setIntensity(gestureIntensity) } }
    // Kept so old diagnostic harnesses compile. There is no extra lead/body to
    // mute now; whole-music QA uses a zero input signal as its causal check.
    var leadMutedForVerification = false
    var heldBodyMutedForVerification = false
    var heldPitches: [Double] { [] }
    var failureMessage: String? { lastError }
    var duration: Double { core.duration }
    var currentTime: Double { get { core.position() } set { core.seek(newValue) } }
    var isPlaying: Bool { core.isPlaying && engine.isRunning }
    var musicGain: Float = 0.35 { didSet { core.setGain(musicGain) } }
    var snapshot: InteractionSnapshot {
        let c = core.snapshot(), o = outputMeter.read()
        return InteractionSnapshot(level: engine.isRunning ? c.level : 0, performedRMS: 0,
                                   outputRMS: engine.isRunning ? o.rms : 0, voices: 0,
                                   buffers: o.buffers, nonSilentBuffers: o.nonSilent, attacks: c.attacks)
    }
    var measuredMusicRMS: Double { isPlaying ? outputMeter.read().rms : 0 }
    var outputPeak: Double { outputMeter.read().peak }

    init(baseURL: URL, richURL: URL, trackID: String? = nil) throws {
        func load(_ url: URL) throws -> AVAudioPCMBuffer {
            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.channelCount == 2, file.length > 0, file.length < 44_100 * 180 else {
                throw NSError(domain: "KeyWooInteraction", code: 1, userInfo: [NSLocalizedDescriptionKey: "互动音乐格式不正确。"])
            }
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer); return buffer
        }
        let base = try load(baseURL), rich = try load(richURL)
        guard base.frameLength == rich.frameLength, base.format.sampleRate == rich.format.sampleRate else {
            throw NSError(domain: "KeyWooInteraction", code: 2, userInfo: [NSLocalizedDescriptionKey: "音乐声部没有对齐。"])
        }
        format = AVAudioFormat(standardFormatWithSampleRate: base.format.sampleRate, channels: 2)!
        core = BackingRenderCore(base: base, rich: rich)
        limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let c = core
        let source = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self), let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            c.render(Int(count), l, r); return noErr
        }
        for node in [source, limiter, outputGain] as [AVAudioNode] { engine.attach(node) }
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: limiter, format: format)
        engine.connect(limiter, to: outputGain, format: format)
        engine.connect(outputGain, to: engine.outputNode, format: format)
        restoreRuntimeSettings()
        let meter = outputMeter
        outputGain.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in meter.consume(buffer) }
        engine.prepare()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.desiredActive, !self.offline, !self.engine.isRunning else { return }
            self.releaseAll()
            do { try self.activate(); self.lastError = nil } catch { self.lastError = error.localizedDescription }
        }
    }
    deinit { if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }; engine.stop() }
    func activate() throws { desiredActive = true; if !engine.isRunning { try engine.start(); restoreRuntimeSettings() } }
    func play() -> Bool { do { try activate(); core.setPlaying(true); lastError = nil; return true } catch { lastError = error.localizedDescription; return false } }
    func pause() { core.setPlaying(false); heldKeys.removeAll(keepingCapacity: true); holdKeys.removeAll(keepingCapacity: true); core.clearActivity() }
    func deactivate() { desiredActive = false; pause(); releaseAll(); engine.stop(); core.clearActivity(); engine.reset() }
    func stop() { desiredActive = false; core.setPlaying(false); releaseAll(); engine.stop(); core.clearActivity() }
    func setPerformanceVolume(_ value: Double) { core.setDepth(value) }
    func setDecay(_ value: Double) { core.setDecay(value) }
    func setSound(_ value: HitSound) {
        core.setProfile(value == .softTap ? .breath : value == .wood ? .clarity : .rhythm)
    }
    private func restoreRuntimeSettings() {
        outputGain.outputVolume = 0.90
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.06, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
    }
    func noteOn(key: UInt32, note: UInt8, velocity: UInt8, richness: Double, decay: Double, heldCount: Int, feedbackWeight: Double = 1, action: DJAction = .lift, duration: Double = 0.24) {
        guard isPlaying, feedbackWeight > 0, action != .none else { return }
        guard heldKeys.insert(key).inserted else { return }
        if action == .hold { holdKeys.insert(key) }
        core.press(held: holdKeys.count, weight: feedbackWeight, action: action, duration: duration)
    }
    func noteOff(key: UInt32, heldCount: Int) { guard heldKeys.remove(key) != nil else { return }; holdKeys.remove(key); core.release(held: holdKeys.count) }
    func advanceControls() { /* All gesture curves advance on the audio sample clock. */ }
    func releaseAll() { heldKeys.removeAll(keepingCapacity: true); holdKeys.removeAll(keepingCapacity: true); core.release() }
    func beginOffline() throws {
        offline = true; engine.stop()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start(); restoreRuntimeSettings(); core.setPlaying(true)
    }
    func renderOffline(frames: Int) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        let status = try engine.renderOffline(AVAudioFrameCount(frames), to: buffer)
        guard status == .success else { throw NSError(domain: "KeyWooOffline", code: Int(status.rawValue)) }
        var result = [Float](repeating: 0, count: Int(buffer.frameLength) * 2)
        for i in 0..<Int(buffer.frameLength) { result[i*2] = buffer.floatChannelData![0][i]; result[i*2+1] = buffer.floatChannelData![1][i] }
        return result
    }
}
