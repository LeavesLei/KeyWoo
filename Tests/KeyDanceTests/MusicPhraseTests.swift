import Foundation
import Testing
@testable import KeyDance

struct MusicPhraseTests {
    private let rate = 16_000.0

    private func musicalPulse(bpm: Double, duration: Double = 8) -> [Float] {
        let frames = Int(rate * duration), period = 60 / bpm
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let time = Double(i) / rate
            let phase = (time + period - 0.06).truncatingRemainder(dividingBy: period)
            let attack = phase < 0.08 ? exp(-phase / 0.018) * 0.55 : 0
            let body = 0.045 * sin(2 * .pi * 110 * time) + 0.025 * sin(2 * .pi * 165 * time)
            samples[i * 2] = Float(body + attack * sin(2 * .pi * 70 * time))
            samples[i * 2 + 1] = Float(body * 0.7 + attack * sin(2 * .pi * 93 * time))
        }
        return samples
    }

    @Test func regularMusicUsesEightBeatPeriodWithoutOverlapDrift() throws {
        let phrase = try PreparedMusicPhrase.prepare(samples: musicalPulse(bpm: 120), sampleRate: rate)
        try #require(phrase.beatFrames > 0)
        #expect(phrase.beatConfidence >= 0.58)
        #expect(abs(phrase.beatFrames - 8_000) < 80)
        #expect(phrase.beatsPerLoop == 8)
        #expect(phrase.loopFrames == phrase.beatFrames * 8)
        #expect(phrase.frameCount == phrase.loopFrames + phrase.overlapFrames)
        #expect((0..<phrase.beatFrames).contains(phrase.beatOffsetFrames))
        func energy(at offset: Int) -> Double {
            (offset..<(offset + 640)).reduce(0.0) { value, i in
                value + Double(phrase.samples[i * 2]) * Double(phrase.samples[i * 2])
            }
        }
        #expect(energy(at: phrase.beatOffsetFrames) > energy(at: (phrase.beatOffsetFrames + phrase.beatFrames / 2) % phrase.beatFrames) * 1.5)
        // Consumer wrap convention: 100 cycles add no crossfade-shortening drift.
        var cursor = phrase.loopStart, consumed = 0
        for _ in 0..<(phrase.loopFrames * 100) {
            cursor += 1; consumed += 1
            if cursor == phrase.loopEnd { cursor = phrase.loopStart }
        }
        #expect(cursor == phrase.loopStart)
        #expect(consumed == phrase.beatFrames * 8 * 100)
    }

    @Test func fourBeatFallbackFitsAShorterCompleteSource() throws {
        let phrase = try PreparedMusicPhrase.prepare(samples: musicalPulse(bpm: 75, duration: 5), sampleRate: rate)
        #expect(phrase.beatsPerLoop == 4)
        #expect(abs(phrase.beatFrames - 12_800) < 160)
        #expect(phrase.frameCount <= 80_000)
    }

    @Test func seamIsPreparedInBothChannelsWithoutPeakBoost() throws {
        var input = musicalPulse(bpm: 120)
        // A carrier that does not repeat exactly at the beat-loop period makes
        // this a real seam repair, rather than an already seamless fixture.
        for i in 0..<(input.count / 2) {
            input[i * 2] += Float(0.035 * sin(2 * .pi * 123.456 * Double(i) / rate))
        }
        let phrase = try PreparedMusicPhrase.prepare(samples: input, sampleRate: rate)
        let peak = input.map { abs($0) }.max()!
        #expect(phrase.samples.allSatisfy { $0.isFinite && abs($0) <= peak })
        for channel in 0..<2 {
            let final = phrase.samples[(phrase.frameCount - 1) * 2 + channel]
            let priorHead = phrase.samples[(phrase.overlapFrames - 1) * 2 + channel]
            #expect(final == priorHead)
            let wrapped = phrase.samples[phrase.loopStart * 2 + channel]
            // The wrap is an ordinary adjacent source-sample transition.
            #expect(abs(wrapped - final) < 0.04)
        }
        #expect(phrase.samples != Array(input.prefix(phrase.samples.count)))
    }

    @Test func steadyToneFallsBackConservativelyAndRetainsMostOfTheSource() throws {
        let frames = Int(rate * 8)
        var input = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            input[i * 2] = Float(0.1 * sin(2 * .pi * 440 * Double(i) / rate))
            input[i * 2 + 1] = Float(0.08 * sin(2 * .pi * 330 * Double(i) / rate))
        }
        let phrase = try PreparedMusicPhrase.prepare(samples: input, sampleRate: rate)
        #expect(phrase.beatFrames == 0)
        #expect(phrase.beatOffsetFrames == 0)
        #expect(phrase.beatsPerLoop == nil)
        #expect(phrase.loopFrames >= Int(rate * 7))
        #expect(phrase.frameCount <= frames)
    }

    @Test func malformedSilentAndNonfiniteAudioAreRejected() {
        let valid = musicalPulse(bpm: 120)
        #expect(throws: PreparedMusicPhrase.PreparationError.invalidSampleRate) {
            try PreparedMusicPhrase.prepare(samples: valid, sampleRate: .nan)
        }
        #expect(throws: PreparedMusicPhrase.PreparationError.invalidStereoSamples) {
            try PreparedMusicPhrase.prepare(samples: [0, 1, 2], sampleRate: rate)
        }
        #expect(throws: PreparedMusicPhrase.PreparationError.invalidStereoSamples) {
            var broken = valid; broken[17] = .infinity
            return try PreparedMusicPhrase.prepare(samples: broken, sampleRate: rate)
        }
        #expect(throws: PreparedMusicPhrase.PreparationError.invalidDuration) {
            try PreparedMusicPhrase.prepare(samples: [0.1, 0.1], sampleRate: rate)
        }
        #expect(throws: PreparedMusicPhrase.PreparationError.silentAudio) {
            try PreparedMusicPhrase.prepare(samples: Array(repeating: 0, count: valid.count), sampleRate: rate)
        }
    }
}
