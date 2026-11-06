import AVFoundation
import Foundation

/// A 400ms initial safety reservoir inside a bounded 600ms SPSC ring.
/// This tolerates model/scheduler jitter without putting locks on the audio reader.
final class GenerativePCMStream: @unchecked Sendable {
    static let sampleRate = 48_000.0
    static let packetFrames = 1_920
    static let capacityFrames = packetFrames * 15
    static let initialPrebufferFrames = packetFrames * 10
    private let commandLock = NSLock(), meterLock = NSLock()
    private let ring = GenerativeAudioRing(capacity: capacityFrames)
    private var requestedPlaying = false, playing = false, requestedReset = false
    private var requestedGain: Float = 0.48, gain: Float = 0.48
    private var requestedDepth = 0.45, requestedDecay = 0.5
    private var requestedProfile = WholeMusicGesture.Profile.breath
    private var requestedHeld = 0, pendingAttacks: UInt64 = 0
    private var pendingWeight = 0.0
    private var gesture = WholeMusicGesture(sampleRate: sampleRate)
    private var primed = false, hasStarted = false, fade = 0.0
    private var played: UInt64 = 0, underruns: UInt64 = 0, attacks: UInt64 = 0
    private var buffers: UInt64 = 0, nonSilent: UInt64 = 0
    private var maximumRenderFrames = 0, ringMisses: UInt64 = 0
    private var callbackSizes = CallbackSizes()
    private var telemetry = StreamMeter()
    struct CallbackSizes {
        var small: UInt64 = 0, n256: UInt64 = 0, n512: UInt64 = 0, n1024: UInt64 = 0
        var n2048: UInt64 = 0, n4096: UInt64 = 0, n4800: UInt64 = 0, n8192: UInt64 = 0, larger: UInt64 = 0
        mutating func record(_ frames: Int) {
            switch frames {
            case ...128: small &+= 1
            case ...256: n256 &+= 1
            case ...512: n512 &+= 1
            case ...1024: n1024 &+= 1
            case ...2048: n2048 &+= 1
            case ...4096: n4096 &+= 1
            case ...4800: n4800 &+= 1
            case ...8192: n8192 &+= 1
            default: larger &+= 1
            }
        }
        var dictionary: [String: UInt64] {
            ["1...128": small, "129...256": n256, "257...512": n512,
             "513...1024": n1024, "1025...2048": n2048, "2049...4096": n4096,
             "4097...4800": n4800, "4801...8192": n8192, "8193+": larger]
        }
    }
    struct StreamMeter {
        var playedFrames: UInt64 = 0, underrunFrames: UInt64 = 0, attacks: UInt64 = 0
        var rms = 0.0, peak = 0.0, level = 0.0
        var buffers: UInt64 = 0, nonSilent: UInt64 = 0
        var maxRenderFrames = 0, ringLockMisses: UInt64 = 0
        var buffering = false
        var callbackSizes = CallbackSizes()
    }
    var bufferedFrames: Int { ring.count }
    var peakBufferedFrames: Int { ring.maximumCount }
    var freeFrames: Int { Self.capacityFrames - ring.count }
    var startupWatermarkFrames: Int { min(Self.capacityFrames - Self.packetFrames, max(Self.initialPrebufferFrames, snapshot().maxRenderFrames + Self.packetFrames * 3)) }
    func append(_ samples: [Float]) -> Bool { ring.append(samples) }
    func setPlaying(_ value: Bool) { commandLock.lock(); requestedPlaying = value; if !value { requestedHeld = 0; pendingAttacks = 0; pendingWeight = 0; requestedReset = true }; commandLock.unlock() }
    func setGain(_ value: Float) { commandLock.lock(); requestedGain = max(0, min(1, value)); commandLock.unlock() }
    func setPerformance(depth: Double, decay: Double, sound: HitSound) {
        commandLock.lock(); requestedDepth = max(0, min(1, depth)); requestedDecay = max(0, min(1, decay))
        requestedProfile = sound == .softTap ? .breath : sound == .wood ? .clarity : .rhythm; commandLock.unlock()
    }
    func press(held: Int, weight: Double = 1) { commandLock.lock(); requestedHeld = held; pendingAttacks &+= 1; pendingWeight=max(pendingWeight,weight); commandLock.unlock() }
    func release(held: Int) { commandLock.lock(); requestedHeld = held; commandLock.unlock() }
    func releaseAll() { commandLock.lock(); requestedHeld = 0; commandLock.unlock() }
    func clear() {
        setPlaying(false)
        ring.discardQueued()
    }
    func snapshot() -> StreamMeter { meterLock.lock(); defer { meterLock.unlock() }; return telemetry }
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        maximumRenderFrames = max(maximumRenderFrames, frames); callbackSizes.record(frames)
        if commandLock.try() {
            playing = requestedPlaying
            if requestedReset { gesture.reset(); primed = false; hasStarted = false; fade = 0; requestedReset = false }
            gain = requestedGain; gesture.depth = requestedDepth; gesture.decay = requestedDecay; gesture.profile = requestedProfile
            if pendingAttacks > 0 {
                // Multiple physical events inside one audio quantum share one
                // smooth contour, while the diagnostic count retains all keys.
                gesture.noteOn(heldCount: requestedHeld, strength: pendingWeight)
                attacks &+= pendingAttacks; pendingAttacks = 0; pendingWeight = 0
            } else { gesture.noteOff(heldCount: requestedHeld) }
            commandLock.unlock()
        }
        left.update(repeating: 0, count: frames); right.update(repeating: 0, count: frames)
        var available = 0
        if playing {
            let minimum = min(Self.capacityFrames - Self.packetFrames,
                              max(Self.initialPrebufferFrames, maximumRenderFrames + Self.packetFrames * 3))
            if !primed && ring.count >= minimum { primed = true }
            if primed {
                available = ring.consume(frames: frames, left: left, right: right)
                if available < frames { primed = false }
            }
        }
        var energy = 0.0, peak = 0.0
        let fadeStep = 1 - exp(-1 / (Self.sampleRate * 0.004))
        for i in 0..<frames {
            if playing && i < available {
                fade += (1 - fade) * fadeStep
                let pair = gesture.process(left: left[i], right: right[i])
                // The model supplies the only music. This transparent ceiling
                // protects unexpected generated peaks; it never adds a voice.
                func safe(_ value: Float) -> Float {
                    let v = Double(value * gain) * fade, a = abs(v)
                    return Float(a <= 0.8 ? v : (v < 0 ? -1 : 1) * (0.8 + 0.15 * tanh((a - 0.8) / 0.15)))
                }
                left[i] = safe(pair.0); right[i] = safe(pair.1)
            } else { left[i] = 0; right[i] = 0; fade = 0 }
            energy += Double(left[i] * left[i] + right[i] * right[i]); peak = max(peak, Double(abs(left[i])), Double(abs(right[i])))
        }
        played &+= UInt64(available)
        // Loading and the initial safety prebuffer are not audio underruns.
        // Once output has started, shortages remain counted until recovery.
        if available > 0 { hasStarted = true }
        if playing && hasStarted { underruns &+= UInt64(frames - available) }
        buffers &+= 1
        let rms = sqrt(energy / Double(max(1, frames * 2)))
        if rms > 0.00001 { nonSilent &+= 1 }
        if meterLock.try() {
            telemetry = StreamMeter(playedFrames: played, underrunFrames: underruns, attacks: attacks, rms: rms, peak: peak, level: playing ? gesture.level : 0, buffers: buffers, nonSilent: nonSilent, maxRenderFrames: maximumRenderFrames, ringLockMisses: ringMisses, buffering: playing && !primed, callbackSizes: callbackSizes)
            meterLock.unlock()
        }
    }
}

final class GenerativeStreamGraph {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var desiredActive = false
    init(stream: GenerativePCMStream) {
        let format = AVAudioFormat(standardFormatWithSampleRate: GenerativePCMStream.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, count, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self), let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            stream.render(frames: Int(count), left: l, right: r); return noErr
        }
        engine.attach(source); engine.connect(source, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.desiredActive, !self.engine.isRunning else { return }
            try? self.engine.start()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; engine.stop() }
    func activate() throws { desiredActive = true; if !engine.isRunning { try engine.start() } }
    func deactivate() { desiredActive = false; engine.stop(); engine.reset() }
}
