import Foundation

/// A complete, immutable stereo phrase prepared off the audio thread.
/// The tail already crossfades into the head. Play 0..<frameCount once, then
/// wrap to loopStart (not zero): each later cycle is exactly loopFrames long.
final class PreparedMusicPhrase: @unchecked Sendable {
    let samples: [Float]
    let sampleRate: Double
    /// An estimate, not a beat-grid guarantee. Zero means no trustworthy pulse.
    let beatFrames: Int
    /// Estimated pulse phase relative to samples[0], not a downbeat guarantee.
    /// Zero when beatFrames is zero. Quiet seam selection does not reset phase.
    let beatOffsetFrames: Int
    let beatConfidence: Double
    let beatsPerLoop: Int?
    let overlapFrames: Int
    var frameCount: Int { samples.count / 2 }
    var loopFrames: Int { frameCount - overlapFrames }
    var loopStart: Int { overlapFrames }
    var loopEnd: Int { frameCount }

    enum PreparationError: Error, Equatable, LocalizedError {
        case invalidSampleRate, invalidStereoSamples, invalidDuration, silentAudio
        var errorDescription: String? {
            switch self {
            case .invalidSampleRate: return "音乐采样率无效。"
            case .invalidStereoSamples: return "音乐数据不是完整的双声道音频。"
            case .invalidDuration: return "请提供 2 至 60 秒的完整音乐片段。"
            case .silentAudio: return "这段音乐没有可听见的声音。"
            }
        }
    }

    private init(samples: [Float], sampleRate: Double, beatFrames: Int, beatOffsetFrames: Int,
                 beatConfidence: Double, beatsPerLoop: Int?, overlapFrames: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.beatFrames = beatFrames
        self.beatOffsetFrames = beatOffsetFrames
        self.beatConfidence = beatConfidence
        self.beatsPerLoop = beatsPerLoop
        self.overlapFrames = overlapFrames
    }

    /// RMS-onset autocorrelation estimates a pulse without interpreting notes or
    /// claiming downbeat detection. Ambiguous/weak material keeps a long phrase
    /// and chooses a quiet seam instead. All work and allocation happen here.
    static func prepare(samples input: [Float], sampleRate: Double = 48_000) throws -> PreparedMusicPhrase {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate) else {
            throw PreparationError.invalidSampleRate
        }
        guard !input.isEmpty, input.count.isMultiple(of: 2), input.allSatisfy({ $0.isFinite }) else {
            throw PreparationError.invalidStereoSamples
        }
        let frames = input.count / 2
        guard Double(frames) >= sampleRate * 2, Double(frames) <= sampleRate * 60 else {
            throw PreparationError.invalidDuration
        }
        let hop = max(1, Int((sampleRate * 0.01).rounded()))
        var energy = [Double](repeating: 0, count: (frames + hop - 1) / hop)
        var sum = 0.0
        for frame in 0..<frames {
            let l = Double(input[frame * 2]), r = Double(input[frame * 2 + 1])
            let squared = (l * l + r * r) * 0.5
            energy[frame / hop] += squared
            sum += squared
        }
        guard sqrt(sum / Double(frames)) > 0.000001 else { throw PreparationError.silentAudio }
        for i in energy.indices {
            energy[i] = sqrt(energy[i] / Double(min(hop, frames - i * hop)))
        }
        let pulse = estimatePulse(energy, hop: hop, sampleRate: sampleRate)
        let overlap = max(2, Int((sampleRate * 0.025).rounded()))
        let loop: (start: Int, length: Int, beats: Int?)
        if pulse.frames > 0,
           let beats = [8, 4].first(where: { $0 * pulse.frames + overlap <= frames }) {
            let length = beats * pulse.frames
            let start = quietStart(energy, hop: hop, maximumStart: frames - length - overlap,
                                   length: length, overlap: overlap)
            loop = (start, length, beats)
        } else {
            // Retain most of the source when there is no reliable pulse. Search
            // only the first/last half-second so silence cannot become the loop.
            let edge = min(Int(sampleRate * 0.5), frames / 8)
            let start = quietestEdge(energy, hop: hop, lower: 0, upper: edge, overlap: overlap)
            let tail = quietestEdge(energy, hop: hop, lower: frames - edge - overlap,
                                   upper: frames - overlap, overlap: overlap)
            loop = (start, tail - start, nil)
        }

        var prepared = Array(input[(loop.start * 2)..<((loop.start + loop.length + overlap) * 2)])
        for frame in 0..<overlap {
            // Complementary weights preserve the original peak bound, unlike
            // an equal-power fade over strongly correlated music.
            let weight = 0.5 - 0.5 * cos(.pi * Double(frame) / Double(overlap - 1))
            for channel in 0..<2 {
                let head = Double(prepared[frame * 2 + channel])
                let tailIndex = (loop.length + frame) * 2 + channel
                let tail = Double(prepared[tailIndex])
                prepared[tailIndex] = Float(tail * (1 - weight) + head * weight)
            }
        }
        return PreparedMusicPhrase(samples: prepared, sampleRate: sampleRate,
                                   beatFrames: loop.beats == nil ? 0 : pulse.frames,
                                   beatOffsetFrames: loop.beats == nil ? 0 : ((pulse.phase - loop.start) % pulse.frames + pulse.frames) % pulse.frames,
                                   beatConfidence: pulse.confidence, beatsPerLoop: loop.beats,
                                   overlapFrames: overlap)
    }

    private static func estimatePulse(_ energy: [Double], hop: Int, sampleRate: Double) -> (frames: Int, phase: Int, confidence: Double) {
        let mean = energy.reduce(0, +) / Double(energy.count)
        let variance = energy.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(energy.count)
        // A nearly steady tone has envelope ripple, but does not establish a beat.
        guard mean > 0, sqrt(variance) / mean >= 0.08 else { return (0, 0, 0) }
        var onset = [Double](repeating: 0, count: energy.count)
        for i in 1..<energy.count { onset[i] = max(0, energy[i] - energy[i - 1]) }
        let onsetMean = onset.reduce(0, +) / Double(onset.count)
        for i in onset.indices { onset[i] -= onsetMean }
        let minimumLag = max(2, Int((sampleRate * 60 / 160 / Double(hop)).rounded()))
        let maximumLag = min(onset.count / 4, Int((sampleRate * 60 / 60 / Double(hop)).rounded()))
        guard maximumLag > minimumLag else { return (0, 0, 0) }
        var scores = [Double](repeating: 0, count: maximumLag + 2)
        for lag in (minimumLag - 1)...(maximumLag + 1) {
            var dot = 0.0, a = 0.0, b = 0.0
            for i in lag..<onset.count {
                dot += onset[i] * onset[i - lag]
                a += onset[i] * onset[i]
                b += onset[i - lag] * onset[i - lag]
            }
            scores[lag] = a > 0 && b > 0 ? max(0, dot / sqrt(a * b)) : 0
        }
        var best = minimumLag, bestRank = -Double.infinity
        for lag in minimumLag...maximumLag {
            let bpm = sampleRate * 60 / Double(lag * hop)
            // A weak tempo prior resolves integer multiples; it never turns a
            // weak correlation into a confident pulse estimate.
            let rank = scores[lag] * (1 - 0.06 * abs(log(bpm / 105)))
            if rank > bestRank { best = lag; bestRank = rank }
        }
        // Alternating kick/tone timbres can make two beats correlate slightly
        // better than one. Prefer the shorter pulse only when its half-period
        // peak is almost as strong; never invent a missing subdivision.
        if best >= minimumLag * 2 {
            let candidates = (max(minimumLag, best / 2 - 1)...min(maximumLag, best / 2 + 1))
            if let half = candidates.max(by: { scores[$0] < scores[$1] }),
               scores[half] >= scores[best] * 0.9 { best = half }
        }
        let periodicity = min(1, scores[best])
        guard periodicity >= 0.58 else { return (0, 0, periodicity) }
        let left = scores[best - 1], middle = scores[best], right = scores[best + 1]
        let denominator = left - 2 * middle + right
        let offset = abs(denominator) > 0.000001 ? min(0.5, max(-0.5, 0.5 * (left - right) / denominator)) : 0
        let period = Int(((Double(best) + offset) * Double(hop)).rounded())
        var phaseX = 0.0, phaseY = 0.0, weightSum = 0.0
        for i in onset.indices {
            // onset is mean-centered here: this keeps only stronger rises and
            // suppresses quiet carrier ripple when locating a pulse phase.
            let weight = max(0, onset[i] - onsetMean)
            let angle = 2 * Double.pi * Double((i * hop) % period) / Double(period)
            phaseX += cos(angle) * weight; phaseY += sin(angle) * weight
            weightSum += weight
        }
        let concentration = weightSum > 0 ? hypot(phaseX, phaseY) / weightSum : 0
        let confidence = min(periodicity, concentration)
        guard confidence >= 0.58 else { return (0, 0, confidence) }
        let angle = atan2(phaseY, phaseX)
        let phase = Int(((angle < 0 ? angle + 2 * .pi : angle) * Double(period) / (2 * .pi)).rounded()) % period
        return (period, phase, confidence)
    }

    private static func seamEnergy(_ energy: [Double], hop: Int, frame: Int, overlap: Int) -> Double {
        let first = max(0, frame / hop)
        let last = min(energy.count - 1, (frame + overlap - 1) / hop)
        guard first <= last else { return .infinity }
        var total = 0.0
        for i in first...last { total += energy[i] * energy[i] }
        return total / Double(last - first + 1)
    }

    private static func quietStart(_ energy: [Double], hop: Int, maximumStart: Int, length: Int, overlap: Int) -> Int {
        var best = 0, bestCost = Double.infinity
        for start in stride(from: 0, through: maximumStart, by: hop) {
            let cost = seamEnergy(energy, hop: hop, frame: start, overlap: overlap)
                + seamEnergy(energy, hop: hop, frame: start + length, overlap: overlap)
            if cost < bestCost { best = start; bestCost = cost }
        }
        return best
    }

    private static func quietestEdge(_ energy: [Double], hop: Int, lower: Int, upper: Int, overlap: Int) -> Int {
        var best = lower, bestCost = Double.infinity
        for frame in stride(from: lower, through: upper, by: hop) {
            let cost = seamEnergy(energy, hop: hop, frame: frame, overlap: overlap)
            if cost < bestCost { best = frame; bestCost = cost }
        }
        return best
    }
}
