import Foundation
import Testing
@testable import KeyDance

struct MusicPhraseAudioTests {
    private func tone(gain: Float) -> [Float] {
        (0..<96_000).flatMap { frame -> [Float] in
            let value = gain * Float(sin(Double(frame) * 2 * .pi * 333.3 / 48_000))
            return [value, value * 0.8]
        }
    }
    private func rms(_ samples: [Float]) -> Double {
        sqrt(samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count))
    }
    @Test func differentlyLoudArrangementsHaveComparablePhraseLevels() throws {
        let quiet = try MusicPhraseAudio.prepare(samples: tone(gain: 0.20))
        let loud = try MusicPhraseAudio.prepare(samples: tone(gain: 0.80))
        #expect(abs(20 * log10(rms(quiet.samples) / rms(loud.samples))) < 0.3)
        #expect(loud.samples.map(abs).max()! < 0.61)
    }
    @Test func unexpectedModelPeaksKeepHeadroomWithoutNonfiniteSamples() throws {
        var input = tone(gain: 0.2)
        input[48_000] = 3
        input[48_001] = -3
        let phrase = try MusicPhraseAudio.prepare(samples: input)
        let finite = phrase.samples.allSatisfy { $0.isFinite }
        #expect(finite)
        #expect(phrase.samples.map(abs).max()! <= 0.60001)
    }
}
