import SwiftUI
import AppKit

struct KeyboardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let pressed: Set<UInt16>
    let counts: [UInt16: Int]
    let heatmap: Bool
    var performanceOnly = false
    var action: ((UInt16) -> Void)? = nil
    var selectedKey: UInt16? = nil
    var hoverAction: ((UInt16?) -> Void)? = nil
    private var heatScale: HeatmapScale { HeatmapScale(maximum: counts.values.max() ?? 0) }
    var body: some View {
        let scale = heatScale
        return GeometryReader { geometry in
            VStack(spacing: 5) {
                ForEach(Array(KeyLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        let rowUnits = max(14.5, row.reduce(0) { $0 + $1.width })
                        let unitWidth = (geometry.size.width - Double(row.count - 1) * 4) / rowUnits
                        ForEach(row) { key in
                            keyView(key, width: max(1, unitWidth * key.width), height: max(1, (geometry.size.height - 20) / 5), level: heatmap ? scale.level(for: counts[key.code, default: 0]) : 0)
                        }
                    }
                }
            }
        }
    }

    private func keyView(_ key: KeyDescriptor, width: CGFloat, height: CGFloat, level: Int) -> some View {
        let interactive = !performanceOnly || KeyGestureRole.isPerformanceKey(key.code)
        let down = pressed.contains(key.code)
        let count = counts[key.code, default: 0]
        let accessibleLabel = heatmap ? StatisticsKeyLabels.label(for: key.code) : key.label
        let cap = Text(key.label)
            .font(.system(size: key.label.count > 2 ? 9 : 11, weight: down ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(down ? Palette.keyInk : heatmap && level >= (colorScheme == .dark ? 4 : 5) ? Palette.onAccent : Palette.ink)
            .frame(width: width, height: height)
            .background(down ? Palette.mint : heatmap && level > 0
                        ? StatisticsColors.fill(for: level) : Palette.raisedSurface,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                heatmap && selectedKey == key.code ? Palette.accent : Palette.line.opacity(0.85),
                lineWidth: heatmap && selectedKey == key.code ? 1.8 : 0.8))
            .offset(y: down ? 1 : 0)
            .contentShape(Rectangle())
        return Group {
            if let action {
                Button { action(key.code) } label: { cap }
                    .buttonStyle(.plain)
                    .disabled(!interactive)
            } else {
                cap
            }
        }
        .opacity(interactive ? 1 : 0.40)
        .accessibilityIdentifier(heatmap ? "statistics-key-\(key.code)" : "keyboard-key-\(key.code)")
        .onHover { inside in
            if heatmap { hoverAction?(inside ? key.code : nil) }
        }
        .help(heatmap ? Lf("%@ · %@ 次 · 键码 %d", accessibleLabel, count.formatted(.number.locale(AppLocalization.locale)), Int(key.code))
              : (interactive ? Lf("试听 %@", key.label) : L("仅统计，不影响音乐")))
        .accessibilityLabel(heatmap ? Lf("%@ 键，%@ 次", accessibleLabel, count.formatted(.number.locale(AppLocalization.locale)))
                            : (interactive && action != nil ? Lf("%@ 键，点击试听", key.label) : Lf("%@ 键，仅统计", key.label)))
    }
}

