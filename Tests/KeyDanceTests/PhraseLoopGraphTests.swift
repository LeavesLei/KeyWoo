import Foundation
import Testing
@testable import KeyDance

/// Synthetic, already complete music. These tests never start ML or an audio device.
enum PhrasePlaybackTestAudio {
    static func phrase(variant: Int = 0) throws -> PreparedMusicPhrase {
        let rate = 48_000.0
        let first = variant == 0 ? 230.0 : 310.0
        let second = variant == 0 ? 370.0 : 470.0
        var samples = [Float](repeating: 0, count: Int(rate * 2) * 2)
        for frame in 0..<(samples.count / 2) {
            let time = Double(frame) / rate
            samples[frame * 2] = Float(0.10 * sin(2 * .pi * first * time)
                                      + 0.035 * sin(2 * .pi * second * time))
            samples[frame * 2 + 1] = Float(0.085 * sin(2 * .pi * first * time + 0.2)
                                          + 0.03 * sin(2 * .pi * second * time + 0.4))
        }
        return try PreparedMusicPhrase.prepare(samples: samples)
    }

    static func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count)))
    }

    static func graph(seed: PreparedMusicPhrase) throws -> (PhraseLoopGraph, UInt64) {
        let graph = PhraseLoopGraph(audioDeviceEnabled: false)
        let id = try #require(graph.submit(seed))
        graph.setGain(1)
        graph.setPerformance(depth: 0, decay: 0.5, sound: .softTap)
        try graph.play()
        return (graph, id)
    }
}

@Suite(.serialized)
@MainActor
struct PhraseLoopGraphTests {
    @Test func absentProducerCannotInterruptTheSeedAndWrapUsesPreparedOverlap() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let (graph, id) = try PhrasePlaybackTestAudio.graph(seed: seed)
        defer { graph.stop() }
        let total = seed.frameCount + seed.loopFrames * 5 + 2_048
        let sizes = [512, 4_096, 128, 4_800, 1_024]
        var output = [Float]()
        output.reserveCapacity(total * 2)
        var minimumRMS = Double.infinity
        var index = 0
        while output.count / 2 < total {
            let frames = min(sizes[index % sizes.count], total - output.count / 2)
            let block = graph.renderForVerification(frames: frames)
            minimumRMS = min(minimumRMS, PhrasePlaybackTestAudio.rms(block))
            output.append(contentsOf: block)
            index += 1
        }
        let snapshot = graph.snapshot
        #expect(snapshot.playedFrames == UInt64(total))
        #expect(snapshot.currentPhraseID == id)
        #expect(snapshot.loopCount >= 5)
        #expect(snapshot.transitionCount == 0)
        #expect(snapshot.pendingPhraseCount == 0)
        #expect(minimumRMS > 0.001)
        let finite = output.allSatisfy { $0.isFinite }
        #expect(finite)

        // The prepared tail already fades into the head. Replaying head[0]
        // or applying another crossfade would fail this actual-PCM assertion.
        var wrapError: Float = 0
        for frame in 0..<2_048 {
            for channel in 0..<2 {
                let actual = output[(seed.frameCount + frame) * 2 + channel]
                let expected = seed.samples[(seed.loopStart + frame) * 2 + channel]
                wrapError = max(wrapError, abs(actual - expected))
            }
        }
        #expect(wrapError < 0.000001)
    }

    @Test func emptyCuesAndDepthZeroKeysLeavePCMAndClockUnchanged() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let (control, _) = try PhrasePlaybackTestAudio.graph(seed: seed)
        let (typed, _) = try PhrasePlaybackTestAudio.graph(seed: seed)
        defer { control.stop(); typed.stop() }
        let callbacks = (seed.frameCount + seed.loopFrames * 2) / 512 + 1
        var samePCM = true
        var presses: UInt64 = 0
        for index in 0..<callbacks {
            if index.isMultiple(of: 7) {
                typed.requestPhraseChange()
                typed.press(held: 1, weight: 1)
                presses += 1
            } else {
                typed.release(held: 0)
            }
            let idle = control.renderForVerification(frames: 512)
            let active = typed.renderForVerification(frames: 512)
            if idle != active { samePCM = false }
        }
        #expect(samePCM)
        #expect(typed.snapshot.playedFrames == control.snapshot.playedFrames)
        #expect(typed.snapshot.loopCount == control.snapshot.loopCount)
        #expect(typed.snapshot.transitionCount == 0)
        #expect(typed.snapshot.attacks == presses)
    }

    @Test func oneCandidateChangesThePhraseOnceAndEmptyCuesDoNotRetriggerIt() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let next = try PhrasePlaybackTestAudio.phrase(variant: 1)
        let (graph, seedID) = try PhrasePlaybackTestAudio.graph(seed: seed)
        defer { graph.stop() }
        _ = graph.renderForVerification(frames: 8_192)
        let nextID = try #require(graph.submit(next))
        #expect(nextID != seedID)
        #expect(graph.snapshot.pendingPhraseCount == 1)
        graph.requestPhraseChange()
        var minimumRMS = Double.infinity
        let callbacks = (seed.frameCount + next.frameCount * 2) / 512 + 1
        for _ in 0..<callbacks {
            minimumRMS = min(minimumRMS, PhrasePlaybackTestAudio.rms(graph.renderForVerification(frames: 512)))
        }
        #expect(graph.snapshot.currentPhraseID == nextID)
        #expect(graph.snapshot.transitionCount == 1)
        #expect(graph.snapshot.pendingPhraseCount == 0)
        #expect(minimumRMS > 0.001)
        let played = graph.snapshot.playedFrames
        for _ in 0..<32 {
            graph.requestPhraseChange()
            _ = graph.renderForVerification(frames: 512)
        }
        #expect(graph.snapshot.currentPhraseID == nextID)
        #expect(graph.snapshot.transitionCount == 1)
        #expect(graph.snapshot.playedFrames == played + 32 * 512)
    }

    @Test func pauseFreezesAudioAndStopClearsFuturePhrasesButPreservesTheSeed() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let next = try PhrasePlaybackTestAudio.phrase(variant: 1)
        let (graph, id) = try PhrasePlaybackTestAudio.graph(seed: seed)
        defer { graph.stop() }
        _ = graph.renderForVerification(frames: 8_192)
        _ = try #require(graph.submit(next))
        let before = graph.snapshot
        graph.pause()
        graph.press(held: 1, weight: 1)
        graph.requestPhraseChange()
        let paused = graph.renderForVerification(frames: 4_800)
        let pausedIsSilent = paused.allSatisfy { $0 == 0 }
        #expect(pausedIsSilent)
        #expect(graph.snapshot.playedFrames == before.playedFrames)
        #expect(graph.snapshot.attacks == before.attacks)
        #expect(graph.snapshot.currentPhraseID == id)
        try graph.play()
        let resumed = graph.renderForVerification(frames: 512)
        #expect(PhrasePlaybackTestAudio.rms(resumed) > 0.001)
        #expect(graph.snapshot.playedFrames == before.playedFrames + 512)

        graph.stop()
        let stoppedFrames = graph.snapshot.playedFrames
        #expect(graph.snapshot.pendingPhraseCount == 0)
        let stopped = graph.renderForVerification(frames: 512)
        let stoppedIsSilent = stopped.allSatisfy { $0 == 0 }
        #expect(stoppedIsSilent)
        #expect(graph.snapshot.playedFrames == stoppedFrames)
        try graph.play()
        let replay = graph.renderForVerification(frames: seed.frameCount + 4_096)
        #expect(PhrasePlaybackTestAudio.rms(replay) > 0.001)
        #expect(graph.snapshot.currentPhraseID == id)
        #expect(graph.snapshot.transitionCount == 0)
        #expect(graph.snapshot.pendingPhraseCount == 0)
    }

    @Test func candidateSlotsStayBoundedAndBecomeReusableAfterConsumption() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let next = try PhrasePlaybackTestAudio.phrase(variant: 1)
        let (graph, _) = try PhrasePlaybackTestAudio.graph(seed: seed)
        defer { graph.stop() }
        _ = graph.renderForVerification(frames: 512)
        let accepted = (0..<12).compactMap { _ in graph.submit(next) }
        #expect(!accepted.isEmpty)
        #expect(accepted.count < 12)
        #expect(graph.snapshot.pendingPhraseCount == accepted.count)
        let maximumCallbacks = (seed.frameCount + next.frameCount) * (accepted.count + 1) / 512 + 1
        for _ in 0..<maximumCallbacks {
            _ = graph.renderForVerification(frames: 512)
            if graph.snapshot.transitionCount == UInt64(accepted.count) { break }
        }
        #expect(graph.snapshot.transitionCount == UInt64(accepted.count))
        #expect(graph.snapshot.currentPhraseID == accepted.last)
        #expect(graph.snapshot.pendingPhraseCount == 0)
        #expect(graph.submit(seed) != nil)
    }

    @Test func unrelatedReleasesCannotDropTheHeldGestureAndItsOwnReleaseRestoresDryMusic() throws {
        let seed = try PhrasePlaybackTestAudio.phrase()
        let (control, _) = try PhrasePlaybackTestAudio.graph(seed: seed)
        let (interrupted, _) = try PhrasePlaybackTestAudio.graph(seed: seed)
        defer { control.stop(); interrupted.stop() }
        for graph in [control, interrupted] {
            graph.setPerformance(depth: 0.45, decay: 0.5, sound: .softTap)
            _ = graph.renderForVerification(frames: 2_048)
            graph.press(key: 56, held: 1, weight: 0.8, action: .hold, duration: 0.3)
            _ = graph.renderForVerification(frames: 4_096)
            graph.press(key: 49, held: 2, weight: 0.6, action: .push, duration: 0.2)
            _ = graph.renderForVerification(frames: 512)
        }
        control.release(key: 49, held: 1)
        interrupted.release(key: 49, held: 0)
        interrupted.release(key: 0, held: 0)
        let expectedHold = control.renderForVerification(frames: 48_000)
        let actualHold = interrupted.renderForVerification(frames: 48_000)
        #expect(actualHold == expectedHold)
        #expect(interrupted.snapshot.level > 0.05)
        #expect(interrupted.snapshot.attacks == 2)

        interrupted.release(key: 56, held: 0)
        _ = interrupted.renderForVerification(frames: 96_000)
        #expect(interrupted.snapshot.level == 0)
        let played = Int(interrupted.snapshot.playedFrames)
        let dry = interrupted.renderForVerification(frames: 512)
        var maximumError: Float = 0
        for frame in 0..<512 {
            let position = played + frame
            let sourceFrame = position < seed.frameCount ? position
                : seed.loopStart + (position - seed.frameCount) % seed.loopFrames
            for channel in 0..<2 {
                maximumError = max(maximumError, abs(dry[frame * 2 + channel] - seed.samples[sourceFrame * 2 + channel]))
            }
        }
        #expect(maximumError < 0.000001)
    }
}
