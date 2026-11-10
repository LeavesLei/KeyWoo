import SwiftUI
import AppKit

struct BrandMark: View {
    private static let icon: NSImage? = Bundle.main.url(forResource: "KeyWooIcon", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        if let image = Self.icon {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().accessibilityHidden(true)
        } else {
            Canvas { context, size in
                context.withCGContext { BrandGlyph.draw(in: $0, rect: CGRect(origin: .zero, size: size)) }
            }.accessibilityHidden(true)
        }
    }
}

