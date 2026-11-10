import SwiftUI
import AppKit

enum Palette {
    private static func adaptive(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("KeyWoo.\(name)"), dynamicProvider: { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb.0), green: CGFloat(rgb.1), blue: CGFloat(rgb.2), alpha: 1)
        }))
    }
    static let background = adaptive("background", light: (0.974, 0.965, 0.952), dark: (0.092, 0.087, 0.086))
    static let sidebar = adaptive("sidebar", light: (0.945, 0.930, 0.911), dark: (0.122, 0.115, 0.113))
    static let surface = adaptive("surface", light: (0.998, 0.991, 0.980), dark: (0.153, 0.145, 0.143))
    static let raisedSurface = adaptive("raised", light: (0.957, 0.942, 0.923), dark: (0.197, 0.185, 0.180))
    static let ink = adaptive("ink", light: (0.151, 0.130, 0.123), dark: (0.961, 0.939, 0.914))
    static let muted = adaptive("muted", light: (0.373, 0.342, 0.322), dark: (0.692, 0.661, 0.641))
    static let accent = adaptive("accent", light: (0.640, 0.252, 0.189), dark: (0.989, 0.645, 0.549))
    static let mint = adaptive("mint", light: (0.97, 0.838, 0.779), dark: (0.946, 0.709, 0.624))
    static let line = adaptive("line", light: (0.858, 0.833, 0.802), dark: (0.268, 0.250, 0.241))
    static let coral = adaptive("coral", light: (0.797, 0.389, 0.310), dark: (0.989, 0.645, 0.549))
    static let onAccent = adaptive("onAccent", light: (1, 1, 1), dark: (0.16, 0.10, 0.09))
    // The album card is deliberately dark in both appearances. Its white
    // typography and the light highlighted keycaps retain their contrast.
    static let forest = Color(red: 0.14, green: 0.13, blue: 0.23)
    static let keyInk = forest
}

extension View {
    func cardStyle() -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.line.opacity(0.65), lineWidth: 0.8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
