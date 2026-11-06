import Foundation
import Testing
@testable import KeyDance

/// Explicit completion gives deterministic slow/failure cases without sleeps,
/// subprocesses, ML inference, or audio hardware.
private final class ControlledMusicPhraseBuilder: MusicPhraseBuilding {
    private var callbacks: [(Result<PreparedMusicPhrase, Error>) -> Void] = []
    private(set) var buildCount = 0
    private(set) var stopCount = 0
    private(set) var playingValues: [Bool] = []
    private(set) var cues: [MusicPhraseCue] = []
    private(set) var clearedCueCount = 0
    private(set) var lastCue: MusicPhraseCue?

    func setPlaying(_ value: Bool) { playingValues.append(value) }
    func offerCue(_ cue: MusicPhraseCue?) {
        lastCue = cue
        if let cue { cues.append(cue) } else { clearedCueCount += 1 }
    }
    func buildNext(completion: @escaping (Result<PreparedMusicPhrase, Error>) -> Void) {
        buildCount += 1
        callbacks.append(completion)
    }
    func stop() { stopCount += 1 }
    @discardableResult func finish(_ result: Result<PreparedMusicPhrase, Error>) -> Bool {
        guard !callbacks.isEmpty else { return false }
        callbacks.removeFirst()(result)
        return true
    }
}

@Suite(.serialized)
@MainActor
struct PhraseMusicPlaybackTests {
    @Test func delayedAndFailedGenerationLeaveCurrentMusicPlayingWithoutExtraRequests() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let builder = ControlledMusicPhraseBuilder()
        let player = try PhraseMusicPlayback(seed: seed, builder: builder, audioDeviceEnabled: false)
        defer { player.stop() }
        player.volume = 1
        player.setPerformance(volume: 0, sound: .softTap, decay: 0.5)
        #expect(player.play())
        #expect(builder.buildCount == 1)
        #expect(player.preparationDiagnostics.isBuilding)
        let frames = seed.frameCount + seed.loopFrames * 3
        let delayed = player.renderForVerification(frames: frames)
        #expect(PhrasePlaybackTestAudio.rms(delayed) > 0.001)
        #expect(player.diagnostics.playedFrames == UInt64(frames))
        #expect(player.diagnostics.loopCount >= 3)
        #expect(player.diagnostics.transitionCount == 0)
        #expect(builder.buildCount == 1)
        let id = player.diagnostics.currentPhraseID

        #expect(builder.finish(.failure(NSError(domain: "KeyWooPhraseTest", code: 1))))
        let failed = player.renderForVerification(frames: frames)
        #expect(PhrasePlaybackTestAudio.rms(failed) > 0.001)
        #expect(player.isPlaying)
        #expect(player.failureMessage == nil)
        #expect(player.statusMessage?.contains("暂时未就绪") == true)
        #expect(player.diagnostics.currentPhraseID == id)
        #expect(player.diagnostics.playedFrames == UInt64(frames * 2))
        #expect(player.diagnostics.transitionCount == 0)
        #expect(player.preparationDiagnostics.failed == 1)
        #expect(!player.preparationDiagnostics.isBuilding)
        #expect(builder.buildCount == 1)
    }

    @Test func pausedCompletionWaitsForResumeAndLateCompletionAfterStopCannotReviveAudio() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let next = try PhrasePlaybackTestAudio.phrase(variant: 1)
        let builder = ControlledMusicPhraseBuilder()
        let player = try PhraseMusicPlayback(seed: seed, builder: builder, audioDeviceEnabled: false)
        defer { player.stop() }
        #expect(player.play())
        _ = player.renderForVerification(frames: 8_192)
        let initial = player.diagnostics
        player.pause()
        #expect(builder.finish(.success(next)))
        let paused = player.renderForVerification(frames: 4_800)
        let pausedIsSilent = paused.allSatisfy { $0 == 0 }
        #expect(pausedIsSilent)
        #expect(player.diagnostics.playedFrames == initial.playedFrames)
        #expect(player.diagnostics.pendingPhraseCount == 0)
        #expect(player.preparationDiagnostics.completed == 1)
        #expect(builder.buildCount == 1)
        #expect(builder.stopCount == 0)

        #expect(player.play())
        #expect(player.diagnostics.pendingPhraseCount == 1)
        for _ in 0..<((seed.frameCount + next.frameCount) / 512 + 1) {
            _ = player.renderForVerification(frames: 512)
        }
        #expect(player.diagnostics.transitionCount == 1)
        #expect(player.diagnostics.currentPhraseID != initial.currentPhraseID)
        #expect(builder.playingValues == [true, false, true])
        #expect(builder.buildCount == 2)
        player.stop()
        #expect(builder.stopCount == 1)
        let stoppedFrames = player.diagnostics.playedFrames
        #expect(builder.finish(.success(seed)))
        let stopped = player.renderForVerification(frames: 4_800)
        let stoppedIsSilent = stopped.allSatisfy { $0 == 0 }
        #expect(stoppedIsSilent)
        #expect(player.diagnostics.playedFrames == stoppedFrames)
        #expect(player.diagnostics.pendingPhraseCount == 0)
        #expect(player.preparationDiagnostics.completed == 1)
        #expect(!player.play())
        #expect(builder.buildCount == 2)
    }

    @Test func zeroWeightIntentsDoNotClaimKeysAndOnlyEnabledContentDecisionsReachTheBuilder() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let builder = ControlledMusicPhraseBuilder()
        let player = try PhraseMusicPlayback(seed: seed, builder: builder, audioDeviceEnabled: false)
        defer { player.stop() }
        player.setPerformance(volume: 0.45, sound: .softTap, decay: 0.5)
        #expect(player.play())
        // This lower-level key is a voice token. Hardware classification is
        // tested through SoundEngine/AppModel; rejected intentions must not
        // reserve a token and prevent a later valid intention using it.
        player.perform(key: 49, note: 60, velocity: 60, richness: 0.3, heldCount: 1,
                       decision: .init(role: .typing, shouldChangeContent: false, feedbackWeight: 0))
        _ = player.renderForVerification(frames: 512)
        #expect(builder.cues.isEmpty)
        #expect(player.diagnostics.attacks == 0)
        player.perform(key: 49, note: 64, velocity: 62, richness: 0.4, heldCount: 1,
                       decision: .init(role: .separator, shouldChangeContent: true, feedbackWeight: 0.6, action: .push, duration: 0.24))
        player.release(key: 49, heldCount: 0)
        #expect(builder.cues.count == 1)
        #expect(builder.lastCue?.note == 64)
        #expect(builder.lastCue?.role == .separator)
        player.setPerformance(volume: 0, sound: .softTap, decay: 0.5)
        #expect(builder.clearedCueCount == 1)
        #expect(builder.lastCue == nil)
        player.perform(key: 36, note: 67, velocity: 64, richness: 0.5, heldCount: 1,
                       decision: .init(role: .phrase, shouldChangeContent: true, feedbackWeight: 0.8, action: .push, duration: 0.24))
        _ = player.renderForVerification(frames: 512)
        player.release(key: 36, heldCount: 0)
        #expect(builder.cues.count == 1)
        #expect(player.diagnostics.attacks == 2)
        player.pause()
        player.setPerformance(volume: 0.45, sound: .softTap, decay: 0.5)
        player.perform(key: 76, note: 67, velocity: 64, richness: 0.5, heldCount: 1,
                       decision: .init(role: .phrase, shouldChangeContent: true, feedbackWeight: 0.8, action: .push, duration: 0.24))
        #expect(builder.cues.count == 1)
    }
}
