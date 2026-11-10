import SwiftUI
import AppKit

/// Details stay discoverable without making everyday controls verbose.
struct InfoHelpButton: View {
    let title: String
    let message: String
    var identifier: String? = nil
    var rowSymbol: String? = nil
    var rowDetail: String? = nil
    @State private var showingDetails = false
    @State private var escapeMonitor: Any?

    var body: some View {
        Button { showingDetails.toggle() } label: {
            Group {
                if let rowSymbol {
                    HStack(spacing: 12) {
                        Image(systemName: rowSymbol)
                            .font(.system(size: 14)).frame(width: 20)
                            .foregroundStyle(Palette.muted)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L(title)).font(.system(size: 13, weight: .medium))
                            if let rowDetail {
                                Text(L(rowDetail)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                            }
                        }
                        Spacer(minLength: 12)
                        Image(systemName: "info.circle").foregroundStyle(Palette.muted)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                    .contentShape(Rectangle())
                } else {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(SettingsActionRowStyle())
        .help(L("查看说明"))
        .accessibilityLabel(rowSymbol == nil ? Lf("%@说明", L(title)) : L(title))
        .accessibilityValue(rowDetail.map { L($0) } ?? "")
        .accessibilityIdentifier(identifier ?? "info-\(title)")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text(L(title))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button { showingDetails = false } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L("关闭说明"))
                }
                Text(L(message))
                    .font(.callout)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .foregroundStyle(Palette.ink)
            .padding(18)
            .frame(width: 340, alignment: .leading)
            .onExitCommand { showingDetails = false }
        }
        .onChange(of: showingDetails) { _, visible in
            removeEscapeMonitor()
            if visible {
                // A SwiftUI popover need not become key. Consume Escape before
                // a containing editor's Cancel shortcut can discard its draft.
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53 else { return event }
                    MainActor.assumeIsolated { showingDetails = false }
                    return nil
                }
            }
        }
        .onDisappear { removeEscapeMonitor() }
    }

    private func removeEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}
