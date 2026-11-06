import Foundation

struct MusicalHarmony: Equatable {
    let name: String
    let notes: [Int]
    let bar: Int
}

enum MusicInteraction {
    static func harmony(trackID: String, time: Double) -> MusicalHarmony {
        let electronic = trackID == "soft-current"
        let names = electronic ? ["Fmaj7", "G6", "Em9", "Am7", "Fmaj7", "G13", "Cmaj9", "Am9"] : ["Dm9", "G13", "Cmaj9", "Am9", "Fmaj7", "G6", "Em7", "Am9"]
        let chords = electronic ? [[60,64,65,67,69], [62,64,67,71], [62,64,66,67,71], [60,64,67,69], [60,64,65,67,69], [59,62,64,67,69], [60,62,64,67,71], [59,60,64,67,69]] : [[60,62,64,65,69], [59,62,64,67,69], [60,62,64,67,71], [59,60,64,67,69], [60,64,65,69], [59,62,64,67], [59,62,64,67], [59,60,64,67,69]]
        let bpm = electronic ? 88.0 : 78.0
        let bar = Int(max(0, time) * bpm / 240) % 32
        return MusicalHarmony(name: names[bar % 8], notes: chords[bar % 8], bar: bar)
    }
    static func noteName(_ note: Int) -> String {
        let names = ["C","C♯","D","E♭","E","F","F♯","G","A♭","A","B♭","B"]
        return names[(note % 12 + 12) % 12] + String(note / 12 - 1)
    }
}

struct MelodyDirector {
    private var lastNote = 64
    private var lastTime: Double?
    private var interval = 0.22
    private var phrase = 0
    mutating func next(harmony: MusicalHarmony, timestamp: Double) -> (note: Int, velocity: UInt8, richness: Double) {
        let gap = lastTime.map { max(0.008, min(3, timestamp - $0)) } ?? 1
        if gap > 0.65 { interval = 0.22 }
        else { interval = interval * 0.72 + gap * 0.28 }
        let tones = harmony.notes.filter { $0 >= 60 && $0 <= 72 }
        let nearest = tones.min { abs($0-lastNote) < abs($1-lastNote) } ?? 64
        let index = tones.firstIndex(of: nearest) ?? 0
        // Fast typing rearticulates a coherent tone. Slower gestures reveal the
        // next small melodic step, always in the harmony currently sounding.
        let direction = gap < 0.14 ? [0,1,0,-1,-1,0,1,0][(phrase/4) % 8] : [0,1,1,-1,0,-1,-1,1][phrase % 8]
        let nextIndex = gap < 0.14 && phrase % 4 != 0 ? index : min(tones.count-1,max(0,index+direction))
        let candidate = tones.isEmpty ? nearest : tones[nextIndex]
        lastNote = abs(candidate-lastNote)>5 ? nearest : candidate
        lastTime = timestamp; phrase += 1
        let density = min(1,max(0,(0.22-interval)/0.16))
        return (lastNote,UInt8(62-density*20),0.30+density*0.65)
    }
    mutating func reset() { self = MelodyDirector() }
}

struct InteractionSnapshot {
    var level = 0.0
    var performedRMS = 0.0
    var outputRMS = 0.0
    var voices = 0
    var buffers: UInt64 = 0
    var nonSilentBuffers: UInt64 = 0
    var attacks: UInt64 = 0
}
