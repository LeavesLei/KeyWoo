// Compile alongside RemapModels.swift, KeyLayout.swift, AudioSpectrum.swift, RhythmFeedback.swift and RhythmOverlay.swift.
// Deterministic rendering of the production painter, without a keyboard monitor.
// --music adds synthetic three-band music to edgeGlow; --music-only-sheet also
// renders an edgeGlow contact sheet with music and no keyboard events.
import AppKit
import SwiftUI

func L(_ value: String) -> String { value }

@main @MainActor
enum RenderRhythmPreview {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let includesMusic = CommandLine.arguments.contains("--music")
        let includesMusicOnlySheet = CommandLine.arguments.contains("--music-only-sheet")
            || CommandLine.arguments.contains("--music-only")
        let styles: [RhythmVisualStyle]
        if let index = CommandLine.arguments.firstIndex(of: "--style") {
            guard CommandLine.arguments.count > index + 1,
                  let style = RhythmVisualStyle(rawValue: CommandLine.arguments[index + 1]) else {
                throw NSError(domain: "RhythmPreview", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "--style requires one of: \(RhythmVisualStyle.allCases.map(\.rawValue).joined(separator: ", "))"])
            }
            styles = [style]
        } else {
            styles = RhythmVisualStyle.allCases
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let hits: [(Double, UInt16)] = [(0.1, 0), (0.4, 1), (0.55, 2), (0.68, 3), (0.80, 5),
                                      (0.92, 4), (1.10, 49), (1.18, 0), (1.28, 37), (1.38, 40),
                                      (1.48, 38), (1.58, 2), (1.7, 0), (1.8, 1), (1.9, 3),
                                      (2.0, 36), (2.12, 4), (2.22, 5), (2.32, 38), (2.42, 40),
                                      (2.52, 0), (2.62, 1), (2.72, 49), (2.81, 2), (2.92, 3)]
        let fullRow: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 18]
        let burstHits = hits + fullRow.enumerated().map { (6.1 + Double($0.offset) * 0.1, $0.element) }
            + [(7.08, 49), (7.12, 8), (7.19, 49), (7.24, 9)]
        func samples(style: RhythmVisualStyle) -> [(String, Double)] {
            switch style {
            case .energy:
                return [("Rest", 0), ("Building", 0.99), ("Full energy", 2.8),
                        ("Holding after typing", 3.75), ("Fading", 5.1), ("Settled", 9.5)]
            case .pulse:
                return [("Rest", 0), ("Small key", 0.73), ("Space attack", 1.15),
                        ("Space + next key", 1.22), ("Return attack", 2.05), ("Settled", 9.5)]
            case .burst:
                return [("First glyph", 0.25), ("Building the row", 1.06), ("Space fractures", 1.145),
                        ("Sparks + next key", 1.22), ("Return sweep", 2.08), ("Fades without Space", 5.45)]
            case .edgeGlow:
                return [("Before Space · 1.06 s", 1.06), ("Space +25 ms · center ignition", 1.125),
                        ("Space +75 ms · spreading outward", 1.175), ("Space +145 ms · next key layered", 1.245),
                        ("Space +380 ms · continued typing", 1.48), ("Afterglow · no keys since 2.92 s", 4.8)]
            }
        }
        func state(at time: Double, style: RhythmVisualStyle) -> RhythmDynamics {
            var state = RhythmDynamics()
            for (instant, code) in (style == .burst ? burstHits : hits) where instant <= time {
                state.receiveKey(code, at: instant, tracksKeyQueue: style == .burst)
            }
            if let last = state.lastHit, time - last > RhythmDynamics.settleDelay { state.reset() }
            return state
        }
        // These are deterministic envelope fixtures, not a recording or a
        // measurement of the system-audio capture path. Each band varies
        // continuously, with a short attack and a longer musical release.
        func musicSpectrum(at time: Double) -> AudioSpectrum {
            func smooth(_ x: Double) -> Double {
                let p = min(1, max(0, x))
                return p * p * (3 - 2 * p)
            }
            func beats(period: Double, offset: Double, attack: Double, release: Double) -> Double {
                guard time >= offset else { return 0 }
                let peakTime = log(release / attack) / (1 / attack - 1 / release)
                let normalization = exp(-peakTime / release) - exp(-peakTime / attack)
                var sum = 0.0
                for beat in 0...Int((time - offset) / period) {
                    let age = time - offset - Double(beat) * period
                    sum += (exp(-age / release) - exp(-age / attack)) / normalization
                }
                return min(1, max(0, sum))
            }
            let quietPhrase = 1 - 0.73 * smooth((time - 3.2) / 0.45) * (1 - smooth((time - 5.8) / 0.45))
            let gate = smooth((time - 0.08) / 0.20) * (1 - smooth((time - 7.6) / 0.8)) * quietPhrase
            let kick = beats(period: 0.50, offset: 0.10, attack: 0.018, release: 0.19)
            let beat = 0.92 * beats(period: 0.50, offset: 0.10, attack: 0.010, release: 0.13)
            let low = 0.14 + 0.72 * kick
            let mid = 0.30 + 0.15 * sin(time * 0.92) + 0.13 * (1 + sin(time * 3.1)) / 2
            let high = 0.08 + 0.52 * beats(period: 0.25, offset: 0.22, attack: 0.008, release: 0.065)
            return AudioSpectrum(low: low, mid: mid, high: high, level: low * 0.55 + mid * 0.30 + high * 0.15, beat: beat)
                .scaled(by: gate)
        }
        // Replay the production 60 Hz presentation state up to each requested
        // instant. This keeps arbitrary contact-sheet times deterministic while
        // including both immediate light and the independently eased contour.
        func presentedMusicSpectrum(at time: Double) -> AudioSpectrum {
            guard time > 0 else { return .silent }
            var motion = AudioSpectrumMotion()
            let frameCount = Int(floor(time * 60))
            if frameCount > 0 {
                for frame in 1...frameCount {
                    _ = motion.advance(towards: musicSpectrum(at: Double(frame) / 60), elapsed: 1.0 / 60)
                }
            }
            let remaining = time - Double(frameCount) / 60
            if remaining > 0.000001 {
                _ = motion.advance(towards: musicSpectrum(at: time), elapsed: remaining)
            }
            return motion.value
        }
        func artwork(time: Double, style: RhythmVisualStyle = .energy, musicOnly: Bool = false,
                     spectrumOverride: AudioSpectrum? = nil) -> some View {
            let spectrum = spectrumOverride ?? (style == .edgeGlow && (includesMusic || musicOnly) ? presentedMusicSpectrum(at: time) : .silent)
            let keyboard = musicOnly ? RhythmDynamics() : state(at: time, style: style)
            return Canvas { context, size in
                RhythmPainter.draw(context: &context, size: size, dynamics: keyboard,
                                   time: time, intensity: 1, reducedMotion: false, style: style, spectrum: spectrum)
            }.frame(width: style == .edgeGlow ? 760 : 340, height: style == .edgeGlow ? 140 : 224)
        }
        func save<V: View>(_ view: V, name: String, scale: Double = 2) throws {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { throw NSError(domain: "RhythmPreview", code: 1) }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "RhythmPreview", code: 2) }
            try png.write(to: output.appendingPathComponent(name))
        }
        let musicSamples: [(String, Double)] = [
            ("Beat arrives · light responds", 0.625),
            ("Contour follows · fixed side anchors", 0.73),
            ("Between beats · calm broad glow", 1.04),
            ("Soft phrase · gentle side breathing", 4.635),
            ("Strong phrase · rounded low waves", 6.73),
            ("Music stopped · no keyboard input", 9.5)
        ]
        // Equal overall level in the first three fixtures exposes spectral
        // differences in the production renderer, not just loudness changes.
        let musicProfiles: [(name: String, title: String, spectrum: AudioSpectrum)] = [
            ("bass-heavy", "Bass-heavy · broad left wave",
             AudioSpectrum(low: 0.86, mid: 0.22, high: 0.12, level: 0.72, beat: 0.10)),
            ("treble-heavy", "Treble-heavy · layered right wave",
             AudioSpectrum(low: 0.16, mid: 0.57, high: 0.87, level: 0.72, beat: 0.10)),
            ("beat", "Strong beat · colored contour, fixed anchors",
             AudioSpectrum(low: 0.80, mid: 0.58, high: 0.43, level: 0.72, beat: 0.94)),
            ("quiet", "Quiet phrase · restrained light",
             AudioSpectrum(low: 0.10, mid: 0.12, high: 0.08, level: 0.12, beat: 0.015))
        ]
        func musicProfileSheet() -> some View { VStack(spacing: 0) {
            ForEach(0..<2) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2) { column in
                        let sample = musicProfiles[row * 2 + column]
                        VStack(spacing: 0) {
                            artwork(time: 1, style: .edgeGlow, musicOnly: true, spectrumOverride: sample.spectrum)
                            Text(sample.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6)).padding(.bottom, 18)
                        }
                    }
                }
            }
        }.background(Color(white: 0.065)) }
        // Holding all bands constant isolates the vertical onset response from
        // spectral changes. These fixtures expose an alpha-only beat regression.
        let musicBeatStages: [(String, Double)] = [
            ("Fixed bands · between beats", 0),
            ("Fixed bands · attack", 0.25),
            ("Fixed bands · peak", 1),
            ("Fixed bands · settling", 0.35)
        ]
        func musicBeatSheet() -> some View { VStack(spacing: 0) {
            ForEach(0..<2) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2) { column in
                        let sample = musicBeatStages[row * 2 + column]
                        VStack(spacing: 0) {
                            artwork(time: 1, style: .edgeGlow, musicOnly: true,
                                    spectrumOverride: AudioSpectrum(low: 0.70, mid: 0.65, high: 0.55,
                                                                    level: 0.75, beat: sample.1))
                            Text(sample.0).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6)).padding(.bottom, 18)
                        }
                    }
                }
            }
        }.background(Color(white: 0.065)) }
        func sheet(style: RhythmVisualStyle, musicOnly: Bool = false) -> some View { VStack(spacing: 0) {
            ForEach(0..<2) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3) { column in
                        let sample = (musicOnly ? musicSamples : samples(style: style))[row * 3 + column]
                        VStack(spacing: 0) {
                            artwork(time: sample.1, style: style, musicOnly: musicOnly)
                            Text(sample.0 + (includesMusic && style == .edgeGlow && !musicOnly ? " · synthetic music + keys" : "")).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6)).padding(.bottom, 18)
                        }
                    }
                }
            }
        }.background(Color(white: 0.065)) }
        for style in styles {
            try save(sheet(style: style), name: "\(style.rawValue)-contact-sheet.png")
            try save(artwork(time: 1.22, style: style), name: "\(style.rawValue)-transparent.png")
            try save(artwork(time: 1.22, style: style).background(Color(white: 0.97)), name: "\(style.rawValue)-light-background.png")
            for frame in 0..<285 {
                try save(artwork(time: Double(frame) / 30, style: style).background(Color(white: 0.065)),
                         name: String(format: "\(style.rawValue)-frame-%03d.png", frame), scale: 1)
            }
        }
        if includesMusicOnlySheet {
            try save(sheet(style: .edgeGlow, musicOnly: true), name: "edgeGlow-music-only-contact-sheet.png")
            try save(musicProfileSheet(), name: "edgeGlow-music-profile-sheet.png")
            try save(musicBeatSheet(), name: "edgeGlow-music-beat-height-sheet.png")
            for sample in musicProfiles {
                let view = artwork(time: 1, style: .edgeGlow, musicOnly: true, spectrumOverride: sample.spectrum)
                try save(view.background(Color(white: 0.065)), name: "edgeGlow-music-\(sample.name).png")
                try save(view.background(Color(white: 0.97)), name: "edgeGlow-music-\(sample.name)-light.png")
            }
        }
        print("Rendered \(styles.map(\.rawValue).joined(separator: ", ")) and 285 frames each to \(output.path)\(includesMusic ? " (edgeGlow: synthetic music + keyboard)" : "")")
    }
}
