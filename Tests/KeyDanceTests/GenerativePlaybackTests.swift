import Darwin
import Foundation
import Testing
@testable import KeyDance

/// Standard-library worker fixtures exercise the real pipes and stream core.
/// They never load ML weights, open an audio device, or touch user preferences.
private final class GenerativeWorkerFixture {
    let directory: URL
    let player: GenerativeMusicPlayback

    init(fragmented: Bool = true, delay: Double = 0, ignoreTermination: Bool = false, mode: String = "normal") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooGenerativeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worker = directory.appendingPathComponent("mock-worker.py")
        let configuration: [String: Any] = ["fragmented": fragmented, "delay": delay, "ignore_termination": ignoreTermination, "mode": mode]
        try JSONSerialization.data(withJSONObject: configuration).write(to: directory.appendingPathComponent("fixture.json"))
        try Self.script.write(to: worker, atomically: true, encoding: .utf8)
        player = try GenerativeMusicPlayback(runtime: GenerativeMusicRuntime(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: worker,
            modelDirectory: directory), audioDeviceEnabled: false)
        player.volume = 1
        player.setPerformance(volume: 0, sound: .softTap, decay: 0.5)
    }

    func cleanUp() { player.stop(); try? FileManager.default.removeItem(at: directory) }
    func requests() throws -> [[String: Any]] {
        let url = directory.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    func launches() throws -> [String] {
        let url = directory.appendingPathComponent("launches.txt")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    private static let script = #"""
import json, os, signal, struct, sys, time
from pathlib import Path
root = Path(__file__).parent
cfg = json.loads((root / 'fixture.json').read_text())
if cfg['ignore_termination']:
    signal.signal(signal.SIGTERM, lambda *_: None)
with (root / 'launches.txt').open('a') as f:
    f.write(str(os.getpid()) + '\n')

def send(data):
    sizes = [1, 2, 7, 1023, 17, 4093, 5, 64, 8191]
    pos = step = 0
    while pos < len(data):
        size = sizes[step % len(sizes)] if cfg['fragmented'] else len(data)
        end = min(len(data), pos + size)
        chunk = memoryview(data)[pos:end]
        while chunk:
            wrote = os.write(sys.stdout.fileno(), chunk)
            chunk = chunk[wrote:]
        pos = end
        step += 1
        if cfg['fragmented']:
            time.sleep(0.0003)

def header(value):
    return json.dumps(value, separators=(',', ':')).encode() + b'\n'

send(header({'ready': True, 'frames': 1920, 'rate': 48000, 'channels': 2, 'format': 'float32le'}))
sequence = 0
for line in sys.stdin.buffer:
    request = json.loads(line)
    if request.get('cmd') == 'quit':
        break
    with (root / 'requests.jsonl').open('a') as f:
        f.write(json.dumps(request) + '\n')
    time.sleep(cfg['delay'])
    if cfg['mode'] == 'wrong_header':
        send(header({'frames': 1920, 'bytes': 999999999, 'rate': 48000}))
        continue
    value = (sequence + 1) / 100.0
    payload = struct.pack('<ff', value, -value) * 1920
    packet = header({'frames': 1920, 'bytes': len(payload), 'rate': 48000,
                     'sequence': sequence, 'generation_ms': 1.25}) + payload
    # Header and PCM share one byte stream; no newline is added after the PCM.
    send(packet)
    sequence += 1
"""#
}

@Suite(.serialized)
@MainActor
struct GenerativePlaybackTests {
    private func eventually(timeout: TimeInterval = 3, _ predicate: () -> Bool) async throws -> Bool {
        let end = Date(timeIntervalSinceNow: timeout)
        while Date() < end {
            if predicate() { return true }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }
    private var packetFrames: Int { GenerativePCMStream.packetFrames }
    private func fullPacketWatermark(_ player: GenerativeMusicPlayback) -> Int {
        (player.diagnostics.capacityFrames / packetFrames) * packetFrames
    }
    private func startAndFill(_ fixture: GenerativeWorkerFixture) async throws {
        #expect(fixture.player.play())
        let target = fullPacketWatermark(fixture.player)
        let filled = try await eventually { fixture.player.diagnostics.bufferedFrames == target }
        try #require(filled, "Mock stream did not reach its bounded packet watermark: \(fixture.player.failureMessage ?? "no failure")")
    }
    private func consumeAndRefill(_ fixture: GenerativeWorkerFixture) async throws {
        let completed = fixture.player.diagnostics.completionCount
        _ = fixture.player.renderForVerification(frames: 1_920)
        let refilled = try await eventually { fixture.player.diagnostics.completionCount == completed + 1 && fixture.player.diagnostics.bufferedFrames == fullPacketWatermark(fixture.player) }
        try #require(refilled)
    }

    @Test func boundedCapacityBackpressuresProducerAndPartialReadsDoNotRequestMore() async throws {
        let f = try GenerativeWorkerFixture()
        defer { f.cleanUp() }
        #expect(f.player.prepare())
        let ready = try await eventually { f.player.diagnostics.ready }
        try #require(ready)
        #expect(f.player.diagnostics.requestCount == 0)
        try await startAndFill(f)
        let full = f.player.diagnostics
        let target = fullPacketWatermark(f.player)
        let expectedPackets = UInt64(target / packetFrames)
        #expect(full.capacityFrames >= full.startupWatermarkFrames + packetFrames)
        #expect(full.requestCount == expectedPackets)
        #expect(full.completionCount == expectedPackets)
        #expect(full.peakBufferedFrames <= full.capacityFrames)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(f.player.diagnostics.requestCount == full.requestCount)
        let freeAtFull = full.capacityFrames - target
        let partial = min(257, packetFrames - freeAtFull - 1)
        try #require(partial > 0)
        _ = f.player.renderForVerification(frames: partial)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(f.player.diagnostics.bufferedFrames == target - partial)
        #expect(f.player.diagnostics.requestCount == full.requestCount)
        _ = f.player.renderForVerification(frames: packetFrames - partial)
        let refilled = try await eventually { f.player.diagnostics.completionCount == expectedPackets + 1 }
        try #require(refilled)
        #expect(f.player.diagnostics.bufferedFrames == target)
        #expect(f.player.diagnostics.peakBufferedFrames <= full.capacityFrames)
        #expect(f.player.diagnostics.playedFrames == UInt64(packetFrames))
    }

    @Test func fragmentedHeadersAndPCMStayInOrderWithoutDuplicationOrMixing() async throws {
        let f = try GenerativeWorkerFixture(fragmented: true)
        defer { f.cleanUp() }
        try await startAndFill(f)
        f.player.pause() // Freeze the producer while inspecting the full ring.
        #expect(f.player.play())
        let frames = fullPacketWatermark(f.player)
        let pcm = f.player.renderForVerification(frames: frames)
        #expect(pcm.count == frames * 2)
        // Ignore the deliberate short startup fade; later samples identify all
        // three distinct packets and prove stereo order across split headers.
        for (frame, expected) in [(1_900, Float(0.01)), (2_500, Float(0.02)), (4_500, Float(0.03))] {
            #expect(abs(pcm[frame * 2] - expected) < 0.000002)
            #expect(abs(pcm[frame * 2 + 1] + expected) < 0.000002)
        }
        let allSamplesAreFinite = pcm.allSatisfy { $0.isFinite }
        #expect(allSamplesAreFinite)
        #expect(f.player.diagnostics.playedFrames == UInt64(frames))
        #expect(f.player.diagnostics.underrunFrames == 0)
    }

    @Test func pauseFreezesClockAndRequestsWhileResumeKeepsSameWorker() async throws {
        let f = try GenerativeWorkerFixture(delay: 0.025)
        defer { f.cleanUp() }
        try await startAndFill(f)
        let before = f.player.diagnostics
        let pid = try #require(before.workerPID)
        _ = f.player.renderForVerification(frames: 1_920)
        f.player.pause()
        let paused = f.player.diagnostics
        let output = f.player.renderForVerification(frames: 4_096)
        #expect(output.allSatisfy { $0 == 0 })
        try await Task.sleep(nanoseconds: 150_000_000) // Allow a previously sent request to finish.
        #expect(f.player.diagnostics.playedFrames == paused.playedFrames)
        #expect(f.player.diagnostics.requestCount == paused.requestCount)
        #expect(f.player.diagnostics.workerPID == pid)
        #expect(f.player.diagnostics.generationID == before.generationID)
        #expect(f.player.play())
        let resumed = f.player.renderForVerification(frames: 1_920)
        #expect(resumed.contains { $0 != 0 })
        #expect(f.player.diagnostics.playedFrames == paused.playedFrames + 1_920)
        #expect(f.player.diagnostics.workerPID == pid)
        #expect(f.player.diagnostics.generationID == before.generationID)
        #expect(try f.launches().count == 1)
    }

    @Test func quickDownUpIsSentAsAnOnsetThenReleaseThenFreeContinuation() async throws {
        let f = try GenerativeWorkerFixture()
        defer { f.cleanUp() }
        try await startAndFill(f)
        f.player.setPerformance(volume: 0.45, sound: .softTap, decay: 0.5)
        f.player.perform(key: 49, note: 64, velocity: 60, richness: 0.3, heldCount: 1,
                         decision: .init(role: .separator, shouldChangeContent: true, feedbackWeight: 0.6))
        f.player.release(key: 49, heldCount: 0)
        try await consumeAndRefill(f)
        var requests = try f.requests()
        let first = try #require(requests.last?["notes"] as? [Int])
        #expect(first.count == 128)
        #expect(first[64] == 2)
        try await consumeAndRefill(f)
        requests = try f.requests()
        let release = try #require(requests.last?["notes"] as? [Int])
        #expect(release.count == 128)
        #expect(release[64] == 0)
        let unrelatedPitchesAreFree = release.enumerated().allSatisfy { $0.offset == 64 || $0.element == -1 }
        #expect(unrelatedPitchesAreFree)
        try await consumeAndRefill(f)
        requests = try f.requests()
        let free = try #require(requests.last?["notes"] as? [Int])
        #expect(free.allSatisfy { $0 == -1 })
    }

    @Test func ordinaryKeysAndZeroDepthDoNotSendNewMIDIConditions() async throws {
        let f = try GenerativeWorkerFixture()
        defer { f.cleanUp() }
        try await startAndFill(f)
        f.player.setPerformance(volume: 0.45, sound: .softTap, decay: 0.5)
        f.player.perform(key: 7, note: 64, velocity: 60, richness: 0.3, heldCount: 1,
                         decision: .init(role: .typing, shouldChangeContent: false, feedbackWeight: 0.25))
        f.player.release(key: 7, heldCount: 0)
        try await consumeAndRefill(f)
        let ordinaryRequests = try f.requests()
        let ordinaryNotes = try #require(ordinaryRequests.last?["notes"] as? [Int])
        #expect(ordinaryNotes.allSatisfy { $0 == -1 })
        #expect(f.player.interactionSnapshot.attacks == 1)
        #expect(f.player.diagnostics.lastConditionSerial == 0)
        f.player.perform(key: 49, note: 64, velocity: 60, richness: 0.3, heldCount: 1,
                         decision: .init(role: .separator, shouldChangeContent: true, feedbackWeight: 0.6))
        try await consumeAndRefill(f)
        f.player.setPerformance(volume: 0, sound: .softTap, decay: 0.5)
        try await consumeAndRefill(f)
        let releaseRequests = try f.requests()
        let released = try #require(releaseRequests.last?["notes"] as? [Int])
        #expect(released.count == 128)
        #expect(released[64] == 0)
        let unrelatedPitchesAreFree = released.enumerated().allSatisfy { $0.offset == 64 || $0.element == -1 }
        #expect(unrelatedPitchesAreFree)
        f.player.perform(key: 36, note: 67, velocity: 60, richness: 0.3, heldCount: 1,
                         decision: .init(role: .phrase, shouldChangeContent: true, feedbackWeight: 0.8))
        try await consumeAndRefill(f)
        let freeRequests = try f.requests()
        let free = try #require(freeRequests.last?["notes"] as? [Int])
        #expect(free.allSatisfy { $0 == -1 })
    }

    @Test func stopClearsBufferAndTerminatesEvenAWorkerIgnoringSIGTERM() async throws {
        let f = try GenerativeWorkerFixture(ignoreTermination: true)
        defer { f.cleanUp() }
        try await startAndFill(f)
        let pid = try #require(f.player.diagnostics.workerPID)
        f.player.stop()
        #expect(f.player.diagnostics.bufferedFrames == 0)
        #expect(f.player.renderForVerification(frames: 512).allSatisfy { $0 == 0 })
        let exited = try await eventually(timeout: 3) { Darwin.kill(pid, 0) == -1 && errno == ESRCH }
        #expect(exited, "The owned mock worker must leave the process table after stop.")
        #expect(f.player.diagnostics.workerPID == nil)
        #expect(f.player.diagnostics.bufferedFrames == 0)
    }

    @Test func immediateStopAndRestartCannotLetOldWorkerSilenceTheNewSession() async throws {
        let f = try GenerativeWorkerFixture(delay: 0.08)
        defer { f.cleanUp() }
        #expect(f.player.play())
        let inFlight = try await eventually { f.player.diagnostics.requestCount == 1 }
        try #require(inFlight)
        let old = f.player.diagnostics
        f.player.stop()
        #expect(f.player.play())
        let target = fullPacketWatermark(f.player)
        let filled = try await eventually { f.player.diagnostics.ready && f.player.diagnostics.bufferedFrames == target }
        try #require(filled)
        #expect(f.player.diagnostics.generationID > old.generationID)
        #expect(f.player.diagnostics.workerPID != old.workerPID)
        let pcm = f.player.renderForVerification(frames: 1_920)
        #expect(pcm.contains { $0 != 0 })
        #expect(f.player.diagnostics.playedFrames == 1_920)
        #expect(try f.launches().count == 2)
    }

    @Test func oversizedFrameHeaderFailsWithoutAllocatingOrPlayingItsPayload() async throws {
        let f = try GenerativeWorkerFixture(mode: "wrong_header")
        defer { f.cleanUp() }
        #expect(f.player.play())
        let failed = try await eventually { f.player.failureMessage != nil }
        try #require(failed)
        #expect(!f.player.isPlaying)
        #expect(f.player.diagnostics.bufferedFrames == 0)
        #expect(f.player.diagnostics.completionCount == 0)
        #expect(f.player.renderForVerification(frames: 1_920).allSatisfy { $0 == 0 })
    }
    private func renderCore(_ core: GenerativePCMStream, frames: Int) -> [Float] {
        var left = [Float](repeating: 0, count: frames), right = left
        left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
            core.render(frames: frames, left: l.baseAddress!, right: r.baseAddress!)
        } }
        return left.indices.flatMap { [left[$0], right[$0]] }
    }

    @Test func largeAndBackToBackPullsRemainContinuousWithinTheSafetyReservoir() throws {
        let core = GenerativePCMStream()
        core.setGain(1); core.setPerformance(depth: 0, decay: 0.5, sound: .softTap); core.setPlaying(true)
        let packet = [Float](repeating: 0.05, count: packetFrames * 2)
        let bursts = [[4_096, 4_096], [4_800, 4_800], [16_384], [512, 8_192, 4_096]]
        var requested = 0, zeroFrames = 0
        for _ in 0..<8 {
            for burst in bursts {
                while core.freeFrames >= packetFrames {
                    let accepted = core.append(packet)
                    try #require(accepted)
                }
                // No producer completion is allowed between the pulls in a
                // burst. This reproduced deterministic holes in the old core.
                for frames in burst {
                    let pcm = renderCore(core, frames: frames)
                    for i in 0..<frames { if pcm[i*2] == 0 && pcm[i*2+1] == 0 { zeroFrames += 1 } }
                    requested += frames
                }
            }
        }
        #expect(zeroFrames == 0)
        #expect(core.snapshot().playedFrames == UInt64(requested))
        #expect(core.snapshot().underrunFrames == 0)
        #expect(core.startupWatermarkFrames >= 16_384)
        #expect(core.peakBufferedFrames <= GenerativePCMStream.capacityFrames)
    }

    @Test func boundedProducerGapKeepsAudioAndFIFOOrderAcrossRingWraps() throws {
        let core = GenerativePCMStream()
        core.setGain(1); core.setPerformance(depth: 0, decay: 0.5, sound: .softTap); core.setPlaying(true)
        var produced = 0, consumed = 0, ordered = true, allNonzero = true
        func value(_ frame: Int) -> Float { Float(frame % 65_521 + 1) / 131_072 }
        func appendPacket() throws {
            var packet = [Float](); packet.reserveCapacity(packetFrames * 2)
            for frame in produced..<(produced + packetFrames) { let v = value(frame); packet += [v, -v] }
            let accepted = core.append(packet)
            try #require(accepted)
            produced += packetFrames
        }
        while core.bufferedFrames < core.startupWatermarkFrames { try appendPacket() }
        for pull in 0..<64 {
            // Consume 128ms without ANY producer completion, then allow one
            // 40ms packet per 32ms consumed. This is deterministic simulated
            // producer jitter, without sleeping or involving a real device.
            if pull >= 12 && (pull - 12) % 3 == 0 && core.freeFrames >= packetFrames { try appendPacket() }
            let pcm = renderCore(core, frames: 512)
            for i in 0..<512 {
                let frame = consumed + i
                allNonzero = allNonzero && pcm[i*2] != 0 && pcm[i*2+1] != 0
                // The startup fade has settled below Float32 precision here;
                // exact frame identities expose drops, repeats, and bad wraps.
                if frame >= 4_096 {
                    ordered = ordered && pcm[i*2].bitPattern == value(frame).bitPattern
                        && pcm[i*2+1].bitPattern == (-value(frame)).bitPattern
                }
            }
            consumed += 512
        }
        #expect(allNonzero)
        #expect(ordered)
        #expect(consumed > GenerativePCMStream.capacityFrames)
        #expect(core.snapshot().playedFrames == UInt64(consumed))
        #expect(core.snapshot().underrunFrames == 0)
        #expect(core.bufferedFrames == produced - consumed)
    }

}
