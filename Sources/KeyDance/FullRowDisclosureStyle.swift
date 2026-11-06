import SwiftUI

/// Only the header toggles expansion; controls in the content remain independent.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    var horizontalPadding: CGFloat = 0
    var contentBottomPadding: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .contentShape(Rectangle())
            }
            .buttonStyle(DisclosureHeaderButtonStyle())
            .accessibilityValue(Text(L(configuration.isExpanded ? "已展开" : "已收起")))
            .accessibilityHint(Text(L("展开或收起内容")))

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, horizontalPadding + 20)
                    .padding(.trailing, horizontalPadding)
                    .padding(.bottom, contentBottomPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DisclosureHeaderButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Palette.accent.opacity(configuration.isPressed ? 0.10 : hovering ? 0.05 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }
}
