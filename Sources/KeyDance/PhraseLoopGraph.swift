import AVFoundation
import AudioAtomics
import Foundation

struct PhraseLoopSnapshot {
    var hasPhrase = false
    var isPlaying = false
    var currentPhraseID: UInt64 = 0
    var pendingPhraseCount = 0
    var playedFrames: UInt64 = 0
    var loopCount: UInt64 = 0
    var transitionCount: UInt64 = 0
    var level = 0.0
    var rms = 0.0
    var peak = 0.0
    var buffers: UInt64 = 0
    var nonSilent: UInt64 = 0
    var attacks: UInt64 = 0
}

/// The control thread owns allocation/copying. A slot's immutable samples and
/// metadata are published by a release store; the render thread acquires them.
/// Only a retired/empty slot may be overwritten. No reference is deallocated by
/// a render callback, and there is no producer deadline once one phrase exists.
private final class PhraseRenderSlot: @unchecked Sendable {
    enum State: UInt64 { case empty, writing, ready, active, transitioning, retired }
    let state = KWAtomicCounterCreate(0)!
    let samples: UnsafeMutablePointer<Float>
    var frames = 0, overlap = 0, beatFrames = 0, beatOffset = 0
    var version: UInt64 = 0
    init(capacity: Int) { samples = .allocate(capacity: capacity * 2); samples.initialize(repeating: 0, count: capacity * 2) }
    deinit { samples.deallocate(); KWAtomicCounterDestroy(state) }
    func load() -> State { State(rawValue: KWAtomicCounterLoad(state))! }
    func store(_ value: State) { KWAtomicCounterStore(state, value.rawValue) }
}

private final class PhraseLoopCore: @unchecked Sendable {
    static let rate = 48_000.0
    static let maximumFrames = 48_000 * 16
    private let slots = (0..<4).map { _ in PhraseRenderSlot(capacity: maximumFrames) }
    private let submitLock = NSLock(), commandLock = NSLock(), meterLock = NSLock()
    private var nextVersion: UInt64 = 1
    // A single serialized control writer updates these; the audio reader uses
    // try-lock and otherwise keeps its previous controls without dropping PCM.
    private var desiredPlaying = false, desiredReset = false, desiredChange = false
    private var desiredGain: Float = 0.48, desiredDepth = 0.45, desiredDecay = 0.5
    private var desiredSound = HitSound.softTap, desiredHeld = 0
    private var pendingAttacks: UInt64 = 0, pendingWeight = 0.0
    private var pendingAction = DJAction.lift, pendingDuration = 0.24
    private var activeKeys = Set<UInt32>(), holdKeys = Set<UInt32>()
    // Render-thread-owned state.
    private var playing = false, changeRequested = false
    private var gain: Float = 0.48, gesture = WholeMusicGesture(sampleRate: rate)
    private var current = -1, incoming = -1, cursor = 0, incomingCursor = 0
    private var transitionPosition = 0, transitionLength = 0
    private var fade = 0.0
    private var played: UInt64 = 0, loops: UInt64 = 0, transitions: UInt64 = 0
    private var buffers: UInt64 = 0, nonSilent: UInt64 = 0, attacks: UInt64 = 0
    private var meter = PhraseLoopSnapshot()
    private let fadeStep = 1 - exp(-1 / (rate * 0.006))

    @discardableResult func submit(_ phrase: PreparedMusicPhrase) -> UInt64? {
        guard phrase.sampleRate == Self.rate, phrase.frameCount > 2,
              phrase.frameCount <= Self.maximumFrames,
              phrase.samples.count == phrase.frameCount * 2,
              phrase.overlapFrames >= 0, phrase.overlapFrames < phrase.frameCount,
              phrase.samples.allSatisfy(\.isFinite) else { return nil }
        submitLock.lock(); defer { submitLock.unlock() }
        guard let index = slots.indices.first(where: { let state = slots[$0].load(); return state == .empty || state == .retired }) else { return nil }
        let slot = slots[index]
        slot.store(.writing)
        phrase.samples.withUnsafeBufferPointer { source in slot.samples.update(from: source.baseAddress!, count: source.count) }
        slot.frames = phrase.frameCount; slot.overlap = phrase.overlapFrames
        slot.beatFrames = max(0, phrase.beatFrames); slot.beatOffset = phrase.beatOffsetFrames
        slot.version = nextVersion
        nextVersion &+= 1
        slot.store(.ready)
        return slot.version
    }
    func setPlaying(_ value: Bool) {
        commandLock.lock(); desiredPlaying = value
        if !value { desiredHeld = 0; activeKeys.removeAll(keepingCapacity: true); holdKeys.removeAll(keepingCapacity: true); pendingAttacks = 0; pendingWeight = 0; desiredReset = true; desiredChange = false }
        commandLock.unlock()
    }
    func setGain(_ value: Float) { commandLock.lock(); desiredGain = max(0, min(1, value)); commandLock.unlock() }
    func setPerformance(depth: Double, decay: Double, sound: HitSound) {
        commandLock.lock(); desiredDepth = min(1, max(0, depth)); desiredDecay = min(1, max(0, decay)); desiredSound = sound; commandLock.unlock()
    }
    func press(key: UInt32? = nil, held: Int, weight: Double, action: DJAction = .lift, duration: Double = 0.24) {
        guard weight > 0, action != .none else { return }
        commandLock.lock()
        if desiredPlaying {
            if let key {
                guard activeKeys.insert(key).inserted else { commandLock.unlock(); return }
                if action == .hold { holdKeys.insert(key) }
                desiredHeld = holdKeys.count
            } else { desiredHeld = max(0, held) }
            pendingAttacks &+= 1; pendingWeight = max(pendingWeight, min(1, max(0, weight)))
            pendingAction = action; pendingDuration = duration
        }
        commandLock.unlock()
    }
    func release(key: UInt32? = nil, held: Int) {
        commandLock.lock()
        if let key { activeKeys.remove(key); holdKeys.remove(key); desiredHeld = holdKeys.count }
        else { desiredHeld = max(0, held) }
        commandLock.unlock()
    }
    func releaseAll() { commandLock.lock(); desiredHeld = 0; activeKeys.removeAll(keepingCapacity: true); holdKeys.removeAll(keepingCapacity: true); pendingAttacks = 0; pendingWeight = 0; commandLock.unlock() }
    func requestChange() { commandLock.lock(); if desiredPlaying { desiredChange = true }; commandLock.unlock() }
    func snapshot() -> PhraseLoopSnapshot {
        meterLock.lock(); var result = meter; meterLock.unlock()
        result.pendingPhraseCount = slots.reduce(0) { $0 + ($1.load() == .ready ? 1 : 0) }
        result.hasPhrase = result.hasPhrase || result.pendingPhraseCount > 0
        commandLock.lock(); result.isPlaying = desiredPlaying; commandLock.unlock()
        return result
    }
    /// Both rendering and submit must be quiescent. The graph stops its engine
    /// before calling this. Preserve the current phrase for an explicit replay.
    func resetWhileQuiescent() {
        setPlaying(false)
        // A seed submitted before the first device callback is still the
        // replayable current phrase, not a discarded future candidate.
        if current < 0 {
            let seed = oldestReady()
            if seed >= 0 { current = seed; slots[seed].store(.active) }
        }
        if incoming >= 0 { slots[incoming].store(.retired); incoming = -1 }
        for index in slots.indices where slots[index].load() == .ready { slots[index].store(.retired) }
        cursor = 0; incomingCursor = 0; transitionPosition = 0; transitionLength = 0
        gesture.reset(); fade = 0; playing = false; changeRequested = false
        meterLock.lock(); meter.isPlaying = false; meter.rms = 0; meter.peak = 0; meter.level = 0; meterLock.unlock()
    }
    private func oldestReady() -> Int {
        var result = -1, version = UInt64.max
        for index in slots.indices {
            let slot = slots[index]
            if slot.load() == .ready && slot.version < version { result = index; version = slot.version }
        }
        return result
    }
    private func startTransition(to index: Int, alignEstimatedBeat: Bool) {
        incoming = index
        // A cue can join estimated pulses when both phrases provide them.
        // Default whole-loop transitions retain the new phrase's quiet opening.
        incomingCursor = alignEstimatedBeat && slots[index].beatFrames > 0 ? slots[index].beatOffset : 0
        transitionPosition = 0
        // Constant-sum raised cosine keeps correlated phrases from adding gain.
        // Prepared phrase loop seams are already baked and are not processed here.
        transitionLength = min(2_880, max(1, min(slots[current].frames - slots[current].overlap, slots[index].frames - slots[index].overlap) / 8))
        slots[index].store(.transitioning)
        changeRequested = false
    }
    private func advance(_ index: Int, cursor: inout Int, countLoop: Bool) {
        cursor += 1
        if cursor >= slots[index].frames {
            cursor = slots[index].overlap
            if countLoop { loops &+= 1 }
        }
    }
    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        if commandLock.try() {
            playing = desiredPlaying; gain = desiredGain
            gesture.depth = desiredDepth; gesture.decay = desiredDecay
            gesture.profile = desiredSound == .softTap ? .breath : desiredSound == .wood ? .clarity : .rhythm
            if desiredReset { gesture.reset(); fade = 0; changeRequested = false; desiredReset = false }
            if desiredChange { changeRequested = true; desiredChange = false }
            if pendingAttacks > 0 {
                gesture.noteOn(heldCount: desiredHeld, strength: pendingWeight, action: pendingAction, duration: pendingDuration)
                attacks &+= pendingAttacks; pendingAttacks = 0; pendingWeight = 0
            } else { gesture.noteOff(heldCount: desiredHeld) }
            commandLock.unlock()
        }
        if current < 0 {
            let index = oldestReady()
            if index >= 0 { current = index; cursor = 0; slots[index].store(.active) }
        }
        var energy = 0.0, peak = 0.0
        // Read at most one newly published candidate per callback. Publication
        // after this point is noticed at the next callback, without waiting.
        var candidate = incoming < 0 ? oldestReady() : -1
        for frame in 0..<frames {
            var l: Float = 0, r: Float = 0
            if playing && current >= 0 {
                if incoming < 0 && candidate >= 0 {
                    let slot = slots[current]
                    let atLoopEnd = cursor == slot.frames - 1
                    // An explicit DJ cue follows the user's timing. The new
                    // phrase may begin at its estimated pulse; it never waits
                    // for the model's unrelated beat grid to accept the key.
                    if atLoopEnd || changeRequested {
                        startTransition(to: candidate, alignEstimatedBeat: changeRequested)
                        candidate = -1
                    }
                }
                let old = slots[current]
                l = old.samples[cursor * 2]; r = old.samples[cursor * 2 + 1]
                advance(current, cursor: &cursor, countLoop: incoming < 0)
                if incoming >= 0 {
                    let next = slots[incoming]
                    let phase = Double(transitionPosition + 1) / Double(transitionLength)
                    let weight = Float(0.5 - 0.5 * cos(.pi * min(1, phase)))
                    l += (next.samples[incomingCursor * 2] - l) * weight
                    r += (next.samples[incomingCursor * 2 + 1] - r) * weight
                    advance(incoming, cursor: &incomingCursor, countLoop: false)
                    transitionPosition += 1
                    if transitionPosition >= transitionLength {
                        let retired = current
                        current = incoming; cursor = incomingCursor; incoming = -1
                        slots[current].store(.active)
                        // No further access to the old samples after retiring;
                        // its owning control thread may now recycle the slot.
                        slots[retired].store(.retired)
                        transitions &+= 1
                    }
                }
                let pair = gesture.process(left: l, right: r)
                fade += (1 - fade) * fadeStep
                let scale = gain * Float(fade)
                l = Self.safe(pair.0 * scale); r = Self.safe(pair.1 * scale)
                played &+= 1
            }
            left[frame] = l; right[frame] = r
            energy += Double(l * l + r * r); peak = max(peak, Double(abs(l)), Double(abs(r)))
        }
        buffers &+= 1
        let rms = sqrt(energy / Double(max(1, frames * 2)))
        if rms > 0.00001 { nonSilent &+= 1 }
        if meterLock.try() {
            meter = PhraseLoopSnapshot(hasPhrase: current >= 0, isPlaying: playing,
                currentPhraseID: current >= 0 ? slots[current].version : 0,
                playedFrames: played, loopCount: loops, transitionCount: transitions,
                level: playing ? gesture.level : 0, rms: rms, peak: peak,
                buffers: buffers, nonSilent: nonSilent, attacks: attacks)
            meterLock.unlock()
        }
    }
    private static func safe(_ value: Float) -> Float {
        let a = abs(value)
        return a <= 0.8 ? value : (value < 0 ? -1 : 1) * (0.8 + 0.15 * tanh((a - 0.8) / 0.15))
    }
}

/// Plays complete prepared music indefinitely, independent of model generation
/// speed. All samples (including new phrases) pass through the same gesture DSP.
/// Control calls are serialized by the owner; tests render on one thread only.
final class PhraseLoopGraph {
    private let core = PhraseLoopCore()
    private let audioDeviceEnabled: Bool
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var desiredActive = false
    init(audioDeviceEnabled: Bool = true) { self.audioDeviceEnabled = audioDeviceEnabled }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) }; engine?.stop() }
    var snapshot: PhraseLoopSnapshot { core.snapshot() }
    var currentTime: TimeInterval { Double(snapshot.playedFrames) / PhraseLoopCore.rate }
    var isPlaying: Bool { snapshot.isPlaying }
    var hasPendingPhrase: Bool { snapshot.pendingPhraseCount > 0 }
    @discardableResult func submit(_ phrase: PreparedMusicPhrase) -> UInt64? { core.submit(phrase) }
    func setGain(_ value: Float) { core.setGain(value) }
    func setPerformance(depth: Double, decay: Double, sound: HitSound) { core.setPerformance(depth: depth, decay: decay, sound: sound) }
    func press(held: Int, weight: Double) { core.press(held: held, weight: weight) }
    func press(key: UInt32, held: Int, weight: Double, action: DJAction, duration: Double) { core.press(key: key, held: held, weight: weight, action: action, duration: duration) }
    func release(held: Int) { core.release(held: held) }
    func release(key: UInt32, held: Int) { core.release(key: key, held: held) }
    func releaseAll() { core.releaseAll() }
    func requestPhraseChange() { core.requestChange() }
    func activate() throws {
        desiredActive = true
        guard audioDeviceEnabled else { return }
        if engine == nil {
            let newEngine = AVAudioEngine(), core = core
            let format = AVAudioFormat(standardFormatWithSampleRate: PhraseLoopCore.rate, channels: 2)!
            let source = AVAudioSourceNode(format: format) { _, _, count, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self), let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                core.render(frames: Int(count), left: l, right: r); return noErr
            }
            newEngine.attach(source); newEngine.connect(source, to: newEngine.mainMixerNode, format: format)
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main) { [weak self] _ in
                guard let self, self.desiredActive, self.engine?.isRunning == false else { return }
                try? self.engine?.start()
            }
            engine = newEngine
        }
        if engine?.isRunning == false { try engine?.start() }
    }
    func play() throws { try activate(); core.setPlaying(true) }
    func pause() { core.setPlaying(false) }
    func deactivate() { pause(); desiredActive = false; engine?.stop(); engine?.reset() }
    func stop() { deactivate(); core.resetWhileQuiescent() }
    func renderForVerification(frames: Int) -> [Float] {
        precondition(!audioDeviceEnabled && frames >= 0)
        var left = [Float](repeating: 0, count: frames), right = left
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            if frames > 0 { core.render(frames: frames, left: l.baseAddress!, right: r.baseAddress!) }
        } }
        var result = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames { result[index * 2] = left[index]; result[index * 2 + 1] = right[index] }
        return result
    }
}
