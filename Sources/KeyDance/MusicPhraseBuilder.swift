import Foundation

struct MusicPhraseCue: Sendable {
    let note: UInt8?
    let velocity: UInt8
    let richness: Double
    let role: KeyGestureRole
}

protocol MusicPhraseBuilding: AnyObject {
    func setPlaying(_ value: Bool)
    func offerCue(_ cue: MusicPhraseCue?)
    func buildNext(completion: @escaping (Result<PreparedMusicPhrase, Error>) -> Void)
    func stop()
}

/// The model prepares a complete phrase away from the audio device deadline.
/// A slow model postpones the next phrase; it never supplies partial playback.
final class LocalMusicPhraseBuilder: MusicPhraseBuilding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.keywoo.phrase-composer", qos: .userInitiated)
    private let condition = NSCondition()
    private let backend: GenerativeMusicPlayback
    private var playing = false
    private var stopped = false
    private var latestCue: MusicPhraseCue?
    private var cueSerial: UInt64 = 0
    private var lastAppliedCueSerial: UInt64 = 0
    private var compositionStyle = 0
    private var lastBuildFinished = -Double.infinity
    private let targetFrames = 8 * 48_000

    init(runtime: GenerativeMusicRuntime) throws {
        backend = try GenerativeMusicPlayback(runtime: runtime, audioDeviceEnabled: false, appliesImmediateDSP: false)
        backend.volume = 1
        backend.setPerformance(volume: 1, sound: .softTap, decay: 0.5)
    }

    func setPlaying(_ value: Bool) {
        condition.lock(); playing = value; condition.broadcast(); condition.unlock()
    }

    func offerCue(_ cue: MusicPhraseCue?) {
        condition.lock()
        // Keep a sentence intention until it has reached a phrase preparation.
        if cue == nil || latestCue?.role != .phrase || lastAppliedCueSerial == cueSerial || cue?.role == .phrase {
            latestCue = cue; cueSerial &+= 1
        }
        condition.unlock()
    }

    func stop() {
        condition.lock(); stopped = true; playing = false; condition.broadcast(); condition.unlock()
        queue.async { [self] in backend.stop() }
    }

    func buildNext(completion: @escaping (Result<PreparedMusicPhrase, Error>) -> Void) {
        queue.async { [self] in
            do {
                try waitUntilPlaying()
                // A prepared phrase gives the model a genuine idle interval.
                // This is independent of whether the listener asks to change it.
                while ProcessInfo.processInfo.systemUptime - lastBuildFinished < 1 {
                    try waitUntilPlaying()
                    Thread.sleep(forTimeInterval: 0.02)
                }
                completion(.success(try collectPhrase()))
            } catch {
                completion(.failure(error))
            }
            lastBuildFinished = ProcessInfo.processInfo.systemUptime
            backend.pause()
        }
    }

    private func waitUntilPlaying() throws {
        condition.lock()
        while !playing && !stopped { condition.wait() }
        let cancelled = stopped
        condition.unlock()
        if cancelled { throw CancellationError() }
    }

    private func collectPhrase() throws -> PreparedMusicPhrase {
        condition.lock()
        if cueSerial != lastAppliedCueSerial {
            compositionStyle = latestCue.map { $0.role == .separator ? 0 : 1 } ?? 0
            lastAppliedCueSerial = cueSerial
        }
        // The model owns harmony and voice leading. A whole-phrase intention
        // changes its musical direction without imposing notes in an unknown key.
        backend.setGenerationStyle(compositionStyle)
        condition.unlock()
        guard backend.prepare(), backend.play() else { throw failure("无法准备下一乐句。") }
        defer { backend.releaseInteraction() }
        var samples = [Float]()
        samples.reserveCapacity(targetFrames * 2)
        var lastProgress = ProcessInfo.processInfo.systemUptime
        var needsPrebuffer = true
        while samples.count / 2 < targetFrames {
            condition.lock(); let shouldPlay = playing, cancelled = stopped; condition.unlock()
            if cancelled { throw CancellationError() }
            if !shouldPlay {
                backend.pause()
                try waitUntilPlaying()
                guard backend.play() else { throw failure("无法继续准备乐句。") }
                needsPrebuffer = true
                lastProgress = ProcessInfo.processInfo.systemUptime
            }
            if let error = backend.failureMessage { throw failure(error) }
            let diagnostics = backend.diagnostics
            let required = needsPrebuffer ? GenerativePCMStream.initialPrebufferFrames : GenerativePCMStream.packetFrames
            guard diagnostics.ready && diagnostics.bufferedFrames >= required else {
                if ProcessInfo.processInfo.systemUptime - lastProgress > 120 { throw failure("下一乐句准备超时，当前音乐继续。") }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            needsPrebuffer = false
            let frames = samples.count / 2
            let count = min(GenerativePCMStream.packetFrames, targetFrames - frames)
            samples.append(contentsOf: backend.renderForVerification(frames: count))
            lastProgress = ProcessInfo.processInfo.systemUptime
        }
        return try MusicPhraseAudio.prepare(samples: samples)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "KeyWooPhrase", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
