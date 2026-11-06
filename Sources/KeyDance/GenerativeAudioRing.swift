import AudioAtomics
import Foundation

/// Single producer / single consumer storage with acquire/release publication.
/// The audio callback neither waits for a lock nor allocates memory.
final class GenerativeAudioRing: @unchecked Sendable {
    let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private let read: OpaquePointer, write: OpaquePointer, discardBefore: OpaquePointer, peak: OpaquePointer
    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity * 2); samples.initialize(repeating: 0, count: capacity * 2)
        read = KWAtomicCounterCreate(0)!; write = KWAtomicCounterCreate(0)!
        discardBefore = KWAtomicCounterCreate(0)!; peak = KWAtomicCounterCreate(0)!
    }
    deinit {
        samples.deinitialize(count: capacity * 2); samples.deallocate()
        for counter in [read, write, discardBefore, peak] { KWAtomicCounterDestroy(counter) }
    }
    var count: Int {
        let floor = KWAtomicCounterLoad(discardBefore)
        let r = max(KWAtomicCounterLoad(read), floor), w = KWAtomicCounterLoad(write)
        return w >= r ? min(capacity, Int(w - r)) : 0
    }
    var maximumCount: Int { Int(KWAtomicCounterLoad(peak)) }
    /// Only the producer calls append; the session lock serializes cancellation.
    func append(_ input: [Float]) -> Bool {
        let frames = input.count / 2
        guard input.count % 2 == 0, frames <= capacity, input.allSatisfy({ $0.isFinite }) else { return false }
        let r = max(KWAtomicCounterLoad(read), KWAtomicCounterLoad(discardBefore)), w = KWAtomicCounterLoad(write)
        guard w >= r, Int(w - r) + frames <= capacity else { return false }
        var position = Int(w % UInt64(capacity))
        for i in 0..<frames {
            samples[position * 2] = input[i * 2]; samples[position * 2 + 1] = input[i * 2 + 1]
            position += 1; if position == capacity { position = 0 }
        }
        KWAtomicCounterStore(write, w + UInt64(frames))
        let occupied = UInt64(Int(w - r) + frames)
        if occupied > KWAtomicCounterLoad(peak) { KWAtomicCounterStore(peak, occupied) }
        return true
    }
    /// Only the audio callback calls consume. A concurrent writer touches only
    /// free slots and publishes them after all channel samples have been stored.
    func consume(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        let r = max(KWAtomicCounterLoad(read), KWAtomicCounterLoad(discardBefore)), w = KWAtomicCounterLoad(write)
        let available = w >= r ? min(frames, Int(w - r)) : 0
        var position = Int(r % UInt64(capacity))
        for i in 0..<available {
            left[i] = samples[position * 2]; right[i] = samples[position * 2 + 1]
            position += 1; if position == capacity { position = 0 }
        }
        KWAtomicCounterStore(read, r + UInt64(available)); return available
    }
    /// Both producer and consumer must be quiescent before discard; stop()
    /// invalidates the producer generation and stops the engine first. Never
    /// use this for an active pause. The consumer applies the floor on restart.
    func discardQueued() { KWAtomicCounterStore(discardBefore, KWAtomicCounterLoad(write)) }
}
