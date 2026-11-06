import AVFoundation
import Foundation

/// Build-time renderer for KeyWoo's complete original music. The base includes
/// the composed melody; rich adds supporting texture. Both are played through
/// the app's whole-music response DSP. The installed soundbank is used only to
/// render these original scores and is never copied or shipped.
enum OriginalMusicComposer {
    enum Layer: String, CaseIterable { case base, rich }
    static let sampleRate = 44_100.0
    static let warmupCycles = 2

    struct MIDIEvent {
        let beat: Double
        let instrument: Int
        let note: UInt8
        let velocity: UInt8
        let on: Bool
    }
    struct Score {
        let id: String
        let layer: Layer
        let bpm: Double
        let programs: [UInt8]
        let gains: [Float]
        let events: [MIDIEvent]
        let bars = 32
        var seconds: Double { Double(bars * 4) * 60 / bpm }
    }
    private struct Chord {
        let bass: Int
        let keys: [Int]
        let color: [Int]
    }

    static func score(id: String, layer: Layer = .base) -> Score {
        let electronic = id == "soft-current"
        let chords = electronic ? [
            Chord(bass: 41, keys: [53,57,60,64], color: [69,67,64,60]),
            Chord(bass: 43, keys: [55,59,62,64], color: [67,69,71,67]),
            Chord(bass: 40, keys: [55,59,62,66], color: [67,66,64,62]),
            Chord(bass: 45, keys: [55,60,64,67], color: [69,67,64,60]),
            Chord(bass: 41, keys: [53,57,60,64], color: [64,67,69,67]),
            Chord(bass: 43, keys: [53,57,59,64], color: [67,64,62,59]),
            Chord(bass: 36, keys: [52,55,59,62], color: [64,62,60,59]),
            Chord(bass: 45, keys: [52,55,59,60], color: [64,67,64,60])
        ] : [
            Chord(bass: 38, keys: [53,57,60,64], color: [69,67,64,65]),
            Chord(bass: 43, keys: [53,57,59,64], color: [67,64,62,59]),
            Chord(bass: 36, keys: [52,55,59,62], color: [64,67,71,69]),
            Chord(bass: 33, keys: [52,55,59,60], color: [67,64,62,60]),
            Chord(bass: 41, keys: [52,57,60,64], color: [69,67,64,60]),
            Chord(bass: 43, keys: [52,55,59,62], color: [67,69,67,62]),
            Chord(bass: 40, keys: [50,55,59,62], color: [67,64,62,59]),
            Chord(bass: 33, keys: [52,55,59,60], color: [64,62,60,59])
        ]
        var events: [MIDIEvent] = []
        var previousMelodyNote = 64
        func melodyPitch(_ preferred: Int, in chord: Chord) -> Int {
            if abs(preferred - previousMelodyNote) <= 5 { return preferred }
            // Keep the original color-line character, but connect phrases by
            // common tones and nearby chord colors instead of octave jumps.
            let candidates = Array(Set(chord.color + chord.keys.map { $0 < 59 ? $0 + 12 : $0 }))
                .filter { (59...71).contains($0) }.sorted()
            return candidates.min {
                let a = Double(abs($0 - previousMelodyNote)) + Double(abs($0 - preferred)) * 0.20
                let b = Double(abs($1 - previousMelodyNote)) + Double(abs($1 - preferred)) * 0.20
                return a < b
            } ?? preferred
        }
        func note(_ instrument: Int, _ pitch: Int, _ beat: Double, _ length: Double, _ velocity: Int) {
            let safePitch = UInt8(min(127, max(0, pitch)))
            events.append(MIDIEvent(beat: beat, instrument: instrument, note: safePitch, velocity: UInt8(min(110, max(1, velocity))), on: true))
            events.append(MIDIEvent(beat: beat + length, instrument: instrument, note: safePitch, velocity: 0, on: false))
        }
        for bar in 0..<32 {
            let chord = chords[bar % 8]
            let section = bar / 8
            let base = Double(bar * 4)
            let intro = bar < 4
            let bridge = section == 2
            let chordVelocity = electronic ? 60 : 63
            if layer == .base {
                // A complete, restrained song: sparse chord onsets, bass and
                // a quiet pad support one gently connected composed melody.
                for (j, pitch) in chord.keys.enumerated() {
                    note(0, pitch, base + Double(j) * 0.014, intro ? 2.8 : 1.62,
                         chordVelocity - j * 3 + (bar % 3 - 1) * 2)
                }
                note(1, chord.bass, base + 0.018, intro ? 2.8 : 1.45, intro ? 57 : 66)
                if !intro && !bridge {
                    note(1, chord.bass + 12, base + 2.45, 0.62, 49)
                    if bar % 4 == 3 { note(1, chords[(bar + 1) % 8].bass - 1, base + 3.55, 0.32, 42) }
                }
                for pitch in [chord.keys[1], chord.keys[3], chord.keys[0] + 12] {
                    note(2, pitch, base + 0.035, 3.72, intro || bridge ? 42 : 32)
                }
                // Eight-bar theme, a lightly varied repeat, a more spacious
                // bridge, then a return. The song keeps its melody at rest;
                // typing will shape this whole mix rather than add new notes.
                var indices = [0, 1, 2]
                if !electronic && bar % 8 == 3 { indices = [0, 1, 3] }
                if bar % 8 == 7 { indices = electronic ? [1, 2, 0] : [0, 1, 0] }
                var offsets = bar % 2 == 0 ? [0.55, 1.75, 2.90] : [0.35, 1.60, 2.70]
                var lengths = [0.98, 0.92, 1.05]
                if bar < 2 {
                    indices = [0, 2]; offsets = [0.65, 2.25]; lengths = [1.30, 1.48]
                } else if bridge {
                    indices = bar % 8 == 7 ? [1, 0] : [1, 2]
                    offsets = [0.35, 2.15]; lengths = [1.55, 1.56]
                } else if section == 1 && (bar % 8 == 1 || bar % 8 == 5) {
                    // A short, quiet answer inside the same harmony, never an
                    // automatic high arpeggio filling every rhythmic gap.
                    indices.append(3); offsets.append(3.48); lengths.append(0.36)
                }
                if bar == 31 { offsets[offsets.count - 1] = 2.48; lengths[lengths.count - 1] = 1.38 }
                for i in indices.indices {
                    let preferred = chord.color[indices[i]]
                    let pitch = melodyPitch(preferred, in: chord)
                    let nextOffset = i + 1 < offsets.count ? offsets[i + 1] : 4.0
                    let length = min(lengths[i], nextOffset - offsets[i] - 0.07)
                    let emphasis = i == 0 ? 3 : (i == indices.count - 1 ? -2 : 0)
                    let sectionVelocity = bridge ? -5 : (section == 1 ? 2 : 0)
                    let velocity = (electronic ? 60 : 59) + emphasis + sectionVelocity + (bar % 3 - 1)
                    note(3, pitch, base + offsets[i], length, velocity)
                    previousMelodyNote = pitch
                }
            } else {
                // This phase-aligned supporting stem adds harmonic color and
                // restrained rhythm. It is part of the complete music before
                // whole-signal interaction, and never adds a second melody.
                for pitch in [chord.keys[0], chord.keys[2]] {
                    note(2, pitch, base + 0.035, 3.72, intro || bridge ? 25 : 21)
                }
                let beat = base + (electronic ? 2.5 : 2.65)
                for (j, pitch) in chord.keys.enumerated().dropFirst() {
                    note(0, pitch, beat + Double(j) * 0.011, 1.05,
                         chordVelocity - 11 - j * 2 - (intro || bridge ? 8 : 0))
                }
                // Restrained pulse and brush-like hats. Instrument 3 belongs
                // exclusively to the composed melody in the base stem.
                let softness = intro || bridge ? 8 : 0
                note(4, 36, base, 0.13, (electronic ? 43 : 37) - softness)
                if bar % 2 == 1 {
                    note(4, 37, base + 2.04, 0.09, (electronic ? 35 : 31) - softness)
                }
                for beat in electronic ? [0.75, 1.75, 2.75, 3.75] : [1.72, 3.72] {
                    note(4, 42, base + beat, 0.055, (electronic ? 23 : 19) - softness / 2)
                }
            }
        }
        var gains: [Float] = electronic ? [-7,-12,-24,-15,-16] : [-6,-10,-25,-13,-18]
        gains[3] = electronic ? -2 : -5.5
        if layer == .rich {
            // Favor a sustained chord texture over a single large piano attack.
            // The final stem is still normalized with its conservative peak cap.
            gains[0] -= 6
            gains[2] += 21
        }
        return Score(id: id, layer: layer, bpm: electronic ? 88 : 78,
                     programs: electronic ? [5,33,89,24,0] : [4,32,89,4,0],
                     gains: gains, events: events)
    }

    @discardableResult
    static func render(id: String, layer: Layer = .base, to url: URL) throws -> [String: Double] {
        let score = score(id: id, layer: layer)
        let rate = sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let engine = AVAudioEngine()
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumRoom); reverb.wetDryMix = id == "soft-current" ? 15 : 12
        let eq = AVAudioUnitEQ(numberOfBands: 2)
        eq.bands[0].filterType = .lowPass; eq.bands[0].frequency = id == "soft-current" ? 7200 : 5700
        eq.bands[0].bandwidth = 0.7; eq.bands[0].bypass = false
        eq.bands[1].filterType = .lowShelf; eq.bands[1].frequency = 85; eq.bands[1].gain = -2; eq.bands[1].bypass = false
        let mix = AVAudioMixerNode()
        engine.attach(mix); engine.attach(reverb); engine.attach(eq)
        engine.connect(mix, to: reverb, format: format)
        engine.connect(reverb, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)
        let bank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
        var instruments: [AVAudioUnitSampler] = []
        for i in score.programs.indices {
            let sampler = AVAudioUnitSampler(); engine.attach(sampler)
            if i == 3 {
                // Soften the lead's pick/hammer edge while retaining the full
                // music's broader bandwidth for the interactive brightness DSP.
                let soften = AVAudioUnitEQ(numberOfBands: 1)
                soften.bands[0].filterType = .lowPass
                soften.bands[0].frequency = id == "soft-current" ? 3400 : 3100
                soften.bands[0].bandwidth = 0.7; soften.bands[0].bypass = false
                engine.attach(soften)
                engine.connect(sampler, to: soften, format: format)
                engine.connect(soften, to: mix, format: format)
            } else { engine.connect(sampler, to: mix, format: format) }
            try sampler.loadSoundBankInstrument(at: bank, program: score.programs[i],
                bankMSB: UInt8(i == 4 ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            guard let gain = sampler.auAudioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSamplerParam_Gain)) else {
                throw NSError(domain: "KeyWooComposer", code: 3, userInfo: [NSLocalizedDescriptionKey: "The system sampler does not expose its gain parameter."])
            }
            gain.value = score.gains[i]
            instruments.append(sampler)
        }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        try engine.start()
        defer { engine.stop() }
        let loopFrames = Int((score.seconds * rate).rounded())
        struct Scheduled { let frame: Int; let event: MIDIEvent }
        // Render two complete warm-up cycles, then save the third. Both stems
        // use the same frame clock and bar phase, including reverb history.
        let savedStart = loopFrames * warmupCycles
        let totalFrames = loopFrames * (warmupCycles + 1)
        let scheduled = (0...warmupCycles).flatMap { cycle in
            score.events.map { Scheduled(frame: cycle * loopFrames + Int(($0.beat * 60 / score.bpm * rate).rounded()), event: $0) }
        }.sorted { $0.frame == $1.frame ? (!$0.event.on && $1.event.on) : $0.frame < $1.frame }
        var samples = Array(repeating: Float(0), count: loopFrames * 2)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        var frame = 0; var eventIndex = 0; var retries = 0
        while frame < totalFrames {
            while eventIndex < scheduled.count && scheduled[eventIndex].frame <= frame {
                let event = scheduled[eventIndex].event
                if event.on { instruments[event.instrument].startNote(event.note, withVelocity: event.velocity, onChannel: 0) }
                else { instruments[event.instrument].stopNote(event.note, onChannel: 0) }
                eventIndex += 1
            }
            let next = eventIndex < scheduled.count ? scheduled[eventIndex].frame : totalFrames
            let count = min(1024, totalFrames - frame, max(1, next - frame))
            let result = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            guard result == .success else {
                retries += 1
                if retries > 100 { throw NSError(domain: "KeyWooComposer", code: Int(result.rawValue), userInfo: [NSLocalizedDescriptionKey: "Offline renderer could not advance."]) }
                continue
            }
            retries = 0
            let actual = Int(buffer.frameLength)
            guard actual > 0 else {
                throw NSError(domain: "KeyWooComposer", code: 4, userInfo: [NSLocalizedDescriptionKey: "Offline renderer returned no frames."])
            }
            if frame + actual > savedStart {
                for i in max(0, savedStart - frame)..<actual {
                    let index = (frame + i - savedStart) * 2
                    samples[index] = buffer.floatChannelData![0][i]
                    samples[index + 1] = buffer.floatChannelData![1][i]
                }
            }
            frame += actual
        }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        let targetRMS = layer == .base ? 0.085 : 0.050
        let peakLimit = layer == .base ? 0.55 : 0.28
        let gain = min(targetRMS / max(0.00001, rms), peakLimit / Double(max(0.00001, peak)))
        // A 2 ms boundary taper removes sub-sample loop discontinuities without
        // changing tempo, duration, or the arrangement's native musical timing.
        let fade = Int(rate * 0.002)
        for i in 0..<loopFrames {
            let edge = min(1, Double(min(i, loopFrames - 1 - i)) / Double(fade))
            samples[i * 2] *= Float(gain * edge); samples[i * 2 + 1] *= Float(gain * edge)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(loopFrames))!
        out.frameLength = out.frameCapacity
        for i in 0..<loopFrames { out.floatChannelData![0][i] = samples[i*2]; out.floatChannelData![1][i] = samples[i*2+1] }
        let settings: [String: Any] = [AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:rate,AVNumberOfChannelsKey:2,
            AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false]
        let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: out)
        let outputPeak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let outputRMS = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
        return ["seconds": Double(loopFrames) / rate, "bpm": score.bpm, "bars":32,
                "frames": Double(loopFrames), "sample_rate": rate, "channels": 2,
                "warmup_cycles": Double(warmupCycles), "saved_cycle": Double(warmupCycles + 1),
                "note_on_events": Double(score.events.filter(\.on).count),
                "fixed_lead_events": Double(score.events.filter { $0.on && $0.instrument == 3 }.count),
                "composed_melody_events": Double(score.events.filter { $0.on && $0.instrument == 3 }.count),
                "pre_normalization_rms":rms,"gain":gain,"peak":Double(outputPeak),
                "rms":outputRMS,"target_rms":targetRMS,"peak_limit":peakLimit,
                "loop_boundary_step": Double(max(abs(samples[0] - samples[samples.count - 2]),
                                                 abs(samples[1] - samples[samples.count - 1])))]
    }

    /// Renders a shared-clock pair: a complete base song and supporting texture.
    /// The player combines them before applying whole-music interaction; no
    /// extra key-triggered lead is encoded or expected outside this score.
    @discardableResult
    static func renderPair(id: String, baseURL: URL, richURL: URL) throws -> [String: [String: Double]] {
        guard baseURL.standardizedFileURL != richURL.standardizedFileURL else {
            throw NSError(domain: "KeyWooComposer", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Base and rich layers need different output files."])
        }
        let base = try render(id: id, layer: .base, to: baseURL)
        let rich = try render(id: id, layer: .rich, to: richURL)
        guard base["frames"] == rich["frames"], base["sample_rate"] == rich["sample_rate"] else {
            throw NSError(domain: "KeyWooComposer", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Accompaniment layers do not share the same loop clock."])
        }
        return ["base": base, "rich": rich]
    }
}
