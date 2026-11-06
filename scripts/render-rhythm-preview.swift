// Compile alongside RemapModels.swift, KeyLayout.swift, RhythmFeedback.swift and RhythmOverlay.swift.
// Deterministic rendering of the production painter, without a keyboard monitor.
import AppKit
import SwiftUI

func L(_ value: String) -> String { value }

@main @MainActor
enum RenderRhythmPreview {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
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
        func artwork(time: Double, style: RhythmVisualStyle = .energy) -> some View {
            Canvas { context, size in
                RhythmPainter.draw(context: &context, size: size, dynamics: state(at: time, style: style),
                                   time: time, intensity: 1, reducedMotion: false, style: style)
            }.frame(width: 340, height: 224)
        }
        func save<V: View>(_ view: V, name: String, scale: Double = 2) throws {
            let renderer = ImageRenderer(content: view)
            renderer.scale = scale
            guard let cgImage = renderer.cgImage else { throw NSError(domain: "RhythmPreview", code: 1) }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "RhythmPreview", code: 2) }
            try png.write(to: output.appendingPathComponent(name))
        }
        func sheet(style: RhythmVisualStyle) -> some View { VStack(spacing: 0) {
            ForEach(0..<2) { row in
                HStack(spacing: 0) {
                    ForEach(0..<3) { column in
                        let sample = samples(style: style)[row * 3 + column]
                        VStack(spacing: 0) {
                            artwork(time: sample.1, style: style)
                            Text(sample.0).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6)).padding(.bottom, 18)
                        }
                    }
                }
            }
        }.background(Color(white: 0.065)) }
        for style in RhythmVisualStyle.allCases {
            try save(sheet(style: style), name: "\(style.rawValue)-contact-sheet.png")
            try save(artwork(time: 1.22, style: style), name: "\(style.rawValue)-transparent.png")
            try save(artwork(time: 1.22, style: style).background(Color(white: 0.97)), name: "\(style.rawValue)-light-background.png")
            for frame in 0..<285 {
                try save(artwork(time: Double(frame) / 30, style: style).background(Color(white: 0.065)),
                         name: String(format: "\(style.rawValue)-frame-%03d.png", frame), scale: 1)
            }
        }
        print("Rendered production styles and 285 frames each to \(output.path)")
    }
}
