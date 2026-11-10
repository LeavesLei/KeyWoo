import SwiftUI

/// A quiet, full-size hover and press response without changing the control's
/// accessibility semantics or stealing events from neighbouring controls.
struct SettingsActionRowStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Palette.accent.opacity(enabled && configuration.isPressed ? 0.10
                         : enabled && hovering ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}
