import SwiftUI
import Charts
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

struct ContentView: View {
    // The shell deliberately does not observe the model. Hidden windows keep
    // only this background and the AppKit visibility probe in the view graph.
    let model: AppModel
    @State private var windowVisible = false
    @StateObject private var statisticsPresentation = StatisticsPresentationState()

    var body: some View {
        ZStack {
            Palette.background
            if windowVisible {
                VisibleWindowContent(model: model, statisticsPresentation: statisticsPresentation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WindowVisibilityObserver { visible in
                if windowVisible != visible { windowVisible = visible }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityProbe {
        let view = WindowVisibilityProbe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityProbe, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: WindowVisibilityProbe, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
private final class WindowVisibilityProbe: NSView {
    var onChange: ((Bool) -> Void)?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var revision = 0
    private var lastVisibility: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        observedWindow = window
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.willCloseNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        self?.scheduleUpdate(forceHidden: note.name == NSWindow.willCloseNotification)
                    }
                }
                observers.append(token)
            }
        }
        scheduleUpdate()
    }

    private func scheduleUpdate(forceHidden: Bool = false) {
        revision += 1
        let expectedRevision = revision
        // Avoid changing SwiftUI state during NSView attachment/update. Reading
        // on the next run-loop turn also sees the final order/close state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == expectedRevision else { return }
            let visible: Bool
            if let window = self.observedWindow {
                // A covered window must keep its controls for accessibility
                // and focus restoration. Only truly hidden/miniaturized windows
                // release the presentation subtree.
                visible = !forceHidden && window.isVisible && !window.isMiniaturized && !NSApp.isHidden
            } else {
                visible = false
            }
            guard self.lastVisibility != visible else { return }
            self.lastVisibility = visible
            self.onChange?(visible)
        }
    }

    func stopObserving() {
        removeObservers()
        observedWindow = nil
        onChange = nil
    }

    private func removeObservers() {
        revision += 1
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
}

private struct VisibleWindowContent: View {
    @ObservedObject var model: AppModel
    let statisticsPresentation: StatisticsPresentationState
    @State private var hoveredPage: AppPage?
    private let workspaceInset: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 186)
            Divider().overlay(Palette.line)
            VStack(spacing: 0) {
                topBar
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let error = visibleError {
                                Label(L(error), systemImage: "exclamationmark.circle")
                                    .font(.system(size: 13)).foregroundStyle(Palette.ink).padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            }
                            switch model.page {
                            case .studio:
                                if model.musicModeAvailable { modePicker }
                                if model.isKeyboardSoundMode { KeyboardSoundSpaceView(model: model) }
                                else { MusicSpaceView(model: model) }
                            case .remapping: RemappingView(model: model)
                            case .statistics: StatisticsView(model: model, presentation: statisticsPresentation)
                            case .settings: PreferencesView(model: model)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: max(0, viewport.size.height - 52), alignment: .topLeading)
                        .padding(.horizontal, workspaceInset)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                    }.id(model.page)
                }
            }.background(Palette.background)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .environment(\.locale, AppLocalization.locale)
        .preferredColorScheme(model.appearance.preferredColorScheme)
        // Only the visible presentation refreshes. Its statistics state is
        // owned above this subtree and survives language or appearance changes.
        .id(model.language)
    }

    private var visibleError: String? {
        let soundError = model.isKeyboardSoundMode ? model.keyboardAudio.errorMessage
            : model.musicSelectionError ?? model.music.errorMessage ?? model.audio.musicErrorMessage ?? model.audio.errorMessage
        return soundError ?? model.statistics.errorMessage ?? model.monitor.errorMessage
    }

    private func pageTitle(_ page: AppPage) -> String {
        page == .studio ? model.studioTitle : L(page.rawValue)
    }

    private var modePicker: some View {
        Picker(L("体验模式"), selection: $model.experienceMode) {
            ForEach(AppExperienceMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode == .music ? "music.note" : "keyboard").tag(mode)
            }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            .accessibilityIdentifier("experience-mode")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 34, height: 34)
                Text(AppLocalization.appName)
                    .font(.system(size: 19, weight: .semibold))
            }
            .padding(.top, 32)
            .padding(.bottom, 25)
            .padding(.leading, 8)

            VStack(spacing: 4) {
                ForEach(AppPage.allCases, id: \.self) { page in
                    navigationRow(page)
                }
            }
            Spacer(minLength: 20)
            Divider().overlay(Palette.line)
            listeningStatus.padding(.vertical, 12)
        }
        .padding(.horizontal, 14)
        .background(Palette.sidebar)
    }

    private func navigationRow(_ page: AppPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .frame(width: 18)
                Text(page == .studio && model.isKeyboardSoundMode ? L("音效") : pageTitle(page))
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(selected ? Palette.accent.opacity(0.10)
                        : hoveredPage == page ? Palette.raisedSurface : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredPage = page }
            else if hoveredPage == page { hoveredPage = nil }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(pageTitle(page))
        .accessibilityIdentifier("navigation-\(page)")
    }

    private var listeningStatus: some View {
        Group {
            if !model.monitor.hasGlobalAccess {
                Button { model.monitor.requestPermission() } label: {
                    Label(L("开启全局体验"), systemImage: "keyboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            } else {
                Label(L(model.monitor.isGlobalActive ? "所有应用" : model.isEnabled ? "仅应用内" : "已暂停"),
                      systemImage: model.monitor.isGlobalActive ? "checkmark.shield" : "keyboard")
                    .foregroundStyle(Palette.muted)
                    .help(L("本机统计"))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .frame(minHeight: 26, alignment: .leading)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(pageTitle(model.page))
                .font(.system(size: 25, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if model.isEnabled && model.monitor.secureInputActive {
                Label(L(model.statusText), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Button { model.isEnabled.toggle() } label: {
                Label(L(model.isEnabled ? "全部暂停" : "继续"), systemImage: model.isEnabled ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L("暂停或继续声音、律动与按键统计"))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, workspaceInset)
        .padding(.top, 21)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.line) }
    }
}

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

struct KeyboardView: View {
    let pressed: Set<UInt16>
    let counts: [UInt16: Int]
    let heatmap: Bool
    var performanceOnly = false
    var action: ((UInt16) -> Void)? = nil
    private var maximum: Int { max(1, counts.values.max() ?? 1) }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 5) {
                ForEach(Array(KeyLayout.rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 4) {
                        let rowUnits = max(14.5, row.reduce(0) { $0 + $1.width })
                        let unitWidth = (geometry.size.width - Double(row.count - 1) * 4) / rowUnits
                        ForEach(row) { key in
                            keyView(key, width: max(1, unitWidth * key.width), height: max(1, (geometry.size.height - 20) / 5))
                        }
                    }
                }
            }
        }
    }

    private func keyView(_ key: KeyDescriptor, width: CGFloat, height: CGFloat) -> some View {
        let interactive = !performanceOnly || KeyGestureRole.isPerformanceKey(key.code)
        let down = pressed.contains(key.code)
        let count = counts[key.code, default: 0]
        let level = Double(count) / Double(maximum)
        let cap = Text(key.label)
            .font(.system(size: key.label.count > 2 ? 9 : 11, weight: down ? .semibold : .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(down ? Palette.keyInk : heatmap && level > 0.72 ? Palette.onAccent : Palette.ink)
            .frame(width: width, height: height)
            .background(down ? Palette.mint : heatmap && level > 0
                        ? Palette.accent.opacity(0.12 + level * 0.88) : Palette.raisedSurface,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line.opacity(0.85)))
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
        .help(heatmap ? Lf("%@ · %d 次 · 键码 %d", key.label, count, Int(key.code))
              : (interactive ? Lf("试听 %@", key.label) : L("仅统计，不影响音乐")))
        .accessibilityLabel(heatmap ? Lf("%@ 键，%d 次", key.label, count)
                            : (interactive && action != nil ? Lf("%@ 键，点击试听", key.label) : Lf("%@ 键，仅统计", key.label)))
    }
}

private enum TimeRange: String, CaseIterable {
    case today = "今天", hour = "近一小时", week = "近七天", custom = "自定义"
}

private final class StatisticsPresentationState: ObservableObject {
    @Published var range: TimeRange = .today
    @Published var from = Calendar.current.startOfDay(for: Date())
    @Published var to = Calendar.current.dateInterval(of: .minute, for: Date())!.start.addingTimeInterval(60)
    @Published var showAllKeys = false
}

private struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: StatisticsPresentationState
    private var dates: (Date, Date) {
        switch presentation.range {
        case .today: return (Calendar.current.startOfDay(for: model.now), model.now)
        case .hour: return (model.now.addingTimeInterval(-3600), model.now)
        case .week: return (Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: model.now))!, model.now)
        case .custom: return (Calendar.current.dateInterval(of: .minute, for: presentation.from)!.start, Calendar.current.dateInterval(of: .minute, for: presentation.to)!.start)
        }
    }
    private var snapshot: StatisticsSnapshot {
        let range = dates
        let values = model.statistics.counts(from: range.0, to: range.1)
        let codes: Set<UInt16> = presentation.showAllKeys ? Set(KeyLayout.all.map(\.code)).union(values.keys) : Set(values.keys)
        let ranked: [(code: UInt16, count: Int)] = codes.map { (code: $0, count: values[$0, default: 0]) }
            .sorted { $0.count == $1.count ? $0.code < $1.code : $0.count > $1.count }
        return StatisticsSnapshot(dates: range, counts: values, total: values.values.reduce(0, +), ranked: ranked)
    }
    var body: some View {
        StatisticsContent(model: model, presentation: presentation, snapshot: snapshot)
    }
}

private struct StatisticsSnapshot {
    let dates: (Date, Date)
    let counts: [UInt16: Int]
    let total: Int
    let ranked: [(code: UInt16, count: Int)]
}

private struct StatisticsContent: View {
    let model: AppModel
    @ObservedObject var presentation: StatisticsPresentationState
    let snapshot: StatisticsSnapshot
    private var dates: (Date, Date) { snapshot.dates }
    private var counts: [UInt16: Int] { snapshot.counts }
    private var total: Int { snapshot.total }
    private var ranked: [(code: UInt16, count: Int)] { snapshot.ranked }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            rangeControls
            metrics
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    heatmap.frame(minWidth: 600).padding(18).cardStyle()
                    activity.frame(minWidth: 300).padding(18).cardStyle()
                }
                VStack(alignment: .leading, spacing: 18) {
                    heatmap
                    Divider()
                    activity
                }
                .padding(18)
                .cardStyle()
            }
            details
        }
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker(L("时间范围"), selection: $presentation.range) {
                    ForEach(TimeRange.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 356)
                .accessibilityIdentifier("statistics-range")
                .help(L("本机时间 · 精度为分钟"))

                InfoHelpButton(title: "统计方式", message: "只统计真实按下的次数，包括 Shift 等修饰键；长按产生的重复输入不计数。试听按钮和屏幕键盘不计数。时间按本机时区、整分钟统计。结束时间恰好为整分钟时，不计入该分钟。", identifier: "statistics-help")
                Spacer(minLength: 0)

                Button { model.exportCSV(from: dates.0, to: dates.1) } label: {
                    Label(L("导出"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(dates.1 <= dates.0)
                .accessibilityIdentifier("statistics-export")
                .help(L("保存为 CSV 表格，可用 Numbers 或 Excel 打开。"))
            }
            if presentation.range == .custom {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { customDateFields }
                    VStack(alignment: .leading, spacing: 10) { customDateFields }
                }
                .datePickerStyle(.compact)
                .font(.callout)
                if dates.1 <= dates.0 {
                    Label(L("结束时间需要晚于开始时间。"), systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(Palette.accent)
                }
            }
        }
    }

    @ViewBuilder private var customDateFields: some View {
        DatePicker(L("从"), selection: $presentation.from, displayedComponents: [.date, .hourAndMinute])
            .fixedSize()
            .accessibilityIdentifier("statistics-custom-from")
        DatePicker(L("至"), selection: $presentation.to, displayedComponents: [.date, .hourAndMinute])
            .fixedSize()
            .accessibilityIdentifier("statistics-custom-to")
    }

    private var metrics: some View {
        let active = model.statistics.activeMinuteCount(from: dates.0, to: dates.1)
        let mostUsed = ranked.first.flatMap { $0.count > 0 ? KeyLayout.label(for: $0.code).uppercased() : nil }
        return HStack(spacing: 16) {
            metric("总敲击", value: formatted(total), accented: true)
            Divider().frame(height: 34)
            metric("按键种类", value: formatted(counts.count))
            Divider().frame(height: 34)
            metric("最常用", value: mostUsed ?? "—")
            Divider().frame(height: 34)
            metric("打字分钟", value: formatted(active), explanation: "这一分钟内只要按过键，就计为 1 个打字分钟。它不是连续打字时长。")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .cardStyle()
    }

    private func metric(_ title: String, value: String, accented: Bool = false, explanation: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Text(L(title)).font(.callout).foregroundStyle(Palette.muted)
                if let explanation { InfoHelpButton(title: title, message: explanation) }
            }
            .frame(height: 28, alignment: .leading)
            Text(value)
                .font(.system(size: 25, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accented ? Palette.accent : Palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("按键分布")
                InfoHelpButton(title: "按键分布", message: "颜色越深，按得越多。将鼠标放在按键上可查看次数。这里展示常见键盘的主键区；其他按键也会记录，可在下方明细中查看。统计按实际按下的键位计算，不受改键规则影响。", identifier: "statistics-keymap-help")
                Spacer()
                if total == 0 {
                    Text(L("尚无按键记录"))
                        .font(.caption)
                        .foregroundStyle(Palette.muted)
                } else {
                    HStack(spacing: 4) {
                        Text(L("少")).padding(.trailing, 2)
                        ForEach(0..<5) { index in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.accent.opacity(0.12 + Double(index) * 0.22))
                                .frame(width: 10, height: 8)
                                .accessibilityHidden(true)
                        }
                        Text(L("多")).padding(.leading, 2)
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
                }
            }
            KeyboardView(pressed: [], counts: counts, heatmap: true)
                .frame(height: 190)
                .accessibilityIdentifier("statistics-heatmap")
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("打字趋势")
                .frame(height: 28, alignment: .leading)
            Chart(model.statistics.activity(from: dates.0, to: dates.1, buckets: 36)) { item in
                BarMark(x: .value(L("时间"), item.date), y: .value(L("次数"), item.count))
                    .foregroundStyle(Palette.accent.opacity(0.78))
                    .cornerRadius(2)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 190)
            .accessibilityIdentifier("statistics-activity")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("按键次数")
                Spacer()
                Toggle(L("显示未使用的键"), isOn: $presentation.showAllKeys)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .accessibilityIdentifier("statistics-include-unused")
            }
            if ranked.isEmpty {
                Text(L("尚无按键记录"))
                    .font(.callout)
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 144), spacing: 16)], spacing: 0) {
                    ForEach(ranked, id: \.code) { item in
                        let label = KeyLayout.label(for: item.code).uppercased()
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.system(.callout, design: .monospaced, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(formatted(item.count))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(Palette.muted)
                        }
                        .padding(.vertical, 9)
                        .overlay(alignment: .bottom) { Divider() }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Lf("%@ 键，%d 次", label, item.count))
                    }
                }
            }
        }
        .padding(18)
        .cardStyle()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L(title))
            .font(.system(size: 15, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func formatted(_ number: Int) -> String {
        number.formatted(.number.locale(AppLocalization.locale))
    }

}

private struct PreferencesView: View {
    @ObservedObject var model: AppModel
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            displaySettings
            inputSettings
            RhythmSettingsCard(model: model)
            HStack(spacing: 10) {
                BrandMark().frame(width: 23, height: 23)
                Text([AppLocalization.appName, appVersion].filter { !$0.isEmpty }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("显示与语言")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    rowLabel("外观", symbol: "circle.lefthalf.filled")
                    Spacer(minLength: 0)
                    appearanceOptions
                }
                .padding(12)
                Divider().padding(.leading, 42)
                HStack(spacing: 12) {
                    rowLabel("语言", symbol: "globe")
                    Spacer(minLength: 0)
                    languageOptions
                }
                .padding(12)
            }
            .cardStyle()
        }
    }

    private var appearanceOptions: some View {
        HStack(spacing: 3) {
            ForEach(AppAppearance.allCases, id: \.self) { option in
                let selected = model.appearance == option
                Button { model.appearance = option } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(L(selected ? "已选择" : "未选择"))
                .accessibilityIdentifier("appearance-\(option.rawValue)")
            }
        }
        .padding(3)
        .frame(width: 248)
        .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("app-appearance")
    }

    private var languageOptions: some View {
        HStack(spacing: 3) {
            ForEach(AppLanguage.allCases, id: \.self) { option in
                let selected = model.language == option
                Button { model.language = option } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(L(selected ? "已选择" : "未选择"))
                .accessibilityIdentifier("language-\(option.rawValue)")
            }
        }
        .padding(3)
        .frame(width: 248)
        .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("app-language")
    }

    private var inputSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                sectionTitle("跨应用使用")
                InfoHelpButton(title: "跨应用使用", message: "允许“输入监控”后，在其他应用中打字也能播放音效、显示动画并统计次数。改键还需要单独允许“辅助功能”。这些权限都由你在系统设置中开启。", identifier: "preferences-monitoring-help")
            }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if model.monitor.hasGlobalAccess { model.monitor.openPermissionSettings() }
                    else { model.monitor.requestPermission() }
                } label: {
                    HStack(spacing: 12) {
                        rowLabel("其他应用", symbol: "keyboard", detail: monitoringStatus)
                        Spacer(minLength: 12)
                        Text(L(model.monitor.hasGlobalAccess ? "系统设置" : "去开启"))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.accent)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 32)
                    .padding(12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("input-monitoring-settings")
                Divider().padding(.leading, 42)
                HStack(spacing: 8) {
                    rowLabel("隐私", symbol: "hand.raised", detail: L("只记次数，不记文字"))
                    Spacer(minLength: 0)
                    InfoHelpButton(title: "隐私", message: "统计只保存在这台电脑，按分钟保存每个物理键的累计次数。不保存输入文字、按键顺序、剪贴板或其他应用的内容。改键配置也只保存在本机。", identifier: "preferences-privacy-help")
                }
                .padding(12)
                Divider().padding(.leading, 42)
                HStack(spacing: 8) {
                    rowLabel("后台运行", symbol: "menubar.rectangle", detail: L("关闭窗口后继续工作"))
                    Spacer(minLength: 0)
                    InfoHelpButton(title: "后台运行", message: "关闭窗口后，音效、动画与统计会继续工作。点菜单栏中的键舞图标可重新打开。右上角“全部暂停”可同时暂停这些功能；按 ⌘ Q 才会完全退出。改键有独立开关。", identifier: "preferences-background-help")
                }
                .padding(12)
            }
            .cardStyle()
        }
    }

    private var monitoringStatus: String {
        if model.monitor.isGlobalActive { return L("已开启") }
        return L(model.monitor.hasGlobalAccess ? "已授权，当前暂停" : "尚未开启，仅应用内可用")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L(title))
            .font(.system(size: 14, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func rowLabel(_ title: String, symbol: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(Palette.muted)
                }
            }
        }
    }


}

extension View {
    func cardStyle() -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.line.opacity(0.85))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}
