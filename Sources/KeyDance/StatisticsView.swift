import SwiftUI
import Charts

enum TimeRange: String, CaseIterable {
    case today = "今天", hour = "近一小时", week = "近七天", custom = "自定义"

    var trendInterval: StatisticsTrendInterval? {
        switch self {
        case .today: return .hours(1)
        case .hour: return .minutes(5)
        case .week: return .day
        case .custom: return nil
        }
    }
}

final class StatisticsPresentationState: ObservableObject {
    @Published var range: TimeRange = .today
    @Published var from = Calendar.current.startOfDay(for: Date())
    @Published var to = Calendar.current.dateInterval(of: .minute, for: Date())!.end
    @Published var showAllKeys = false
    @Published var search = ""
    @Published var expanded = false
    @Published var selectedKey: UInt16?
}

enum StatisticsColors {
    static func fill(for level: Int) -> Color {
        let opacities = [0.0, 0.12, 0.25, 0.43, 0.68, 1.0]
        return level == 0 ? Palette.raisedSurface : Palette.accent.opacity(opacities[min(5, max(0, level))])
    }

    static func title(for level: Int) -> String {
        L(["未使用", "低频", "较少", "常用", "高频", "最多"][min(5, max(0, level))])
    }
}

enum StatisticsKeyLabels {
    static func label(for code: UInt16) -> String {
        switch code {
        case 49: return L("空格")
        case 36: return L("回车")
        case 51: return L("退格")
        case 56: return L("左 Shift")
        case 60: return L("右 Shift")
        case 55: return L("左 Command")
        case 54: return L("右 Command")
        case 58: return L("左 Option")
        case 61: return L("右 Option")
        case 59: return L("左 Control")
        case 62: return L("右 Control")
        default: return KeyLayout.label(for: code).uppercased()
        }
    }
}

struct StatisticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: StatisticsPresentationState
    @State private var snapshot: StatisticsInsights?

    private var dates: (Date, Date) {
        let calendar = Calendar.current
        switch presentation.range {
        case .today: return (calendar.startOfDay(for: model.now), model.now)
        case .hour: return (model.now.addingTimeInterval(-3600), model.now)
        case .week: return (calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: model.now))!, model.now)
        case .custom: return (presentation.from, presentation.to)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            rangeControls
            if dates.1 <= dates.0 {
                ContentUnavailableView(L("结束时间需要晚于开始时间。"), systemImage: "calendar.badge.exclamationmark")
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .accessibilityIdentifier("statistics-invalid-range")
            } else if let snapshot {
                StatisticsDashboard(snapshot: snapshot, presentation: presentation)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.now) { _, _ in refresh() }
        .onChange(of: presentation.range) { _, _ in refresh() }
        .onChange(of: presentation.from) { _, _ in refresh() }
        .onChange(of: presentation.to) { _, _ in refresh() }
    }

    private func refresh() {
        snapshot = model.statistics.insights(from: dates.0, to: dates.1, trendInterval: presentation.range.trendInterval)
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(L("时间范围"), selection: $presentation.range) {
                    ForEach(TimeRange.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 372)
                .accessibilityIdentifier("statistics-range")
                InfoHelpButton(title: "统计方式", message: "只统计真实按下的次数，包括 Shift 等修饰键；长按产生的重复输入不计数。试听按钮和屏幕键盘不计数。时间按本机时区、整分钟统计。结束时间恰好为整分钟时，不计入该分钟。", identifier: "statistics-help")
                Spacer(minLength: 0)
                Button { model.exportCSV(from: dates.0, to: dates.1) } label: {
                    Label(L("导出"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(dates.1 <= dates.0)
                .accessibilityIdentifier("statistics-export")
            }
            if presentation.range == .custom {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { dateFields }
                    VStack(alignment: .leading, spacing: 10) { dateFields }
                }
                .datePickerStyle(.compact)
                .font(.callout)
            } else {
                Text(dateRangeCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder private var dateFields: some View {
        DatePicker(L("从"), selection: $presentation.from, displayedComponents: [.date, .hourAndMinute])
            .accessibilityIdentifier("statistics-custom-from")
        DatePicker(L("至"), selection: $presentation.to, displayedComponents: [.date, .hourAndMinute])
            .accessibilityIdentifier("statistics-custom-to")
    }

    private var dateRangeCaption: String {
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLocalization.locale)
        return dates.0.formatted(style) + " – " + dates.1.formatted(style) + "  ·  " + L("本机时间")
    }
}

private struct StatisticsDashboard: View {
    let snapshot: StatisticsInsights
    @ObservedObject var presentation: StatisticsPresentationState
    @State private var hoveredKey: UInt16?
    @State private var hoveredDate: Date?

    private var inspectedKey: UInt16? { hoveredKey ?? presentation.selectedKey }
    private var scale: HeatmapScale { snapshot.heatmap }
    private var ranked: [(code: UInt16, count: Int)] {
        let keys = presentation.showAllKeys ? Set(KeyLayout.all.map(\.code)).union(snapshot.counts.keys) : Set(snapshot.counts.keys)
        let query = presentation.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return keys.filter { code in
            query.isEmpty || StatisticsKeyLabels.label(for: code).localizedStandardContains(query)
                || KeyLayout.label(for: code).localizedStandardContains(query) || String(code) == query
        }.map { (code: $0, count: snapshot.counts[$0, default: 0]) }
            .sorted { $0.count == $1.count ? $0.code < $1.code : $0.count > $1.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            metrics
            heatmap
            activity
            ranking
        }
        .onChange(of: presentation.search) { _, _ in presentation.expanded = false }
        .onChange(of: presentation.showAllKeys) { _, _ in presentation.expanded = false }
    }

    private var metrics: some View {
        HStack(spacing: 12) {
            metric("总敲击", value: number(snapshot.total), detail: Lf("%d 个键", snapshot.counts.count), accented: true)
            metric("活跃分钟", value: number(snapshot.activeMinutes), detail: L("分钟"),
                   explanation: "只有发生过敲击的分钟才计入活跃分钟，不能用来衡量连续打字时长。")
            metric("平均每分钟", value: snapshot.averagePerActiveMinute.formatted(.number.locale(AppLocalization.locale).precision(.fractionLength(0...1))), detail: L("次/分钟"),
                   explanation: "总敲击除以活跃分钟。统计包含修饰键，不等同于每分钟字数。")
            metric("最高一分钟", value: snapshot.peakMinute.map { number($0.count) } ?? "—",
                   detail: snapshot.peakMinute.map { minuteLabel($0.date) } ?? L("暂无记录"),
                   explanation: "所选时间内，敲击次数最多的一个自然分钟。")
        }
    }

    private func metric(_ title: String, value: String, detail: String, accented: Bool = false, explanation: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 1) {
                Text(L(title)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                if let explanation { InfoHelpButton(title: title, message: explanation) }
            }
            .foregroundStyle(Palette.muted)
            .frame(height: 20, alignment: .leading)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accented ? Palette.accent : Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                title("按键分布")
                InfoHelpButton(title: "按键分布", message: "颜色按次数分为五档，让常用键与偶尔使用的键都容易看清。", identifier: "statistics-keymap-help")
                Spacer()
                Text(L("主键区")).font(.caption).foregroundStyle(Palette.muted)
            }
            keyInspector
            KeyboardView(pressed: [], counts: snapshot.counts, heatmap: true, action: pin,
                         selectedKey: inspectedKey, hoverAction: { hoveredKey = $0 })
                .frame(height: 202)
                .accessibilityIdentifier("statistics-heatmap")
            HStack(spacing: 12) {
                legendItem(level: 0, text: "0")
                ForEach(scale.bands) { band in
                    legendItem(level: band.level, text: band.lowerBound == band.upperBound
                               ? number(band.lowerBound) : number(band.lowerBound) + "–" + number(band.upperBound))
                }
                Spacer(minLength: 0)
                Text(L("次")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            .accessibilityIdentifier("statistics-heatmap-legend")
            Text(L("热力图展示主键区，功能键和其他按键可在下方排行查看。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .padding(20)
        .cardStyle()
    }

    private var keyInspector: some View {
        HStack(spacing: 10) {
            if let code = inspectedKey {
                let count = snapshot.counts[code, default: 0]
                Text(StatisticsKeyLabels.label(for: code))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(StatisticsColors.fill(for: scale.level(for: count)).opacity(0.25), in: RoundedRectangle(cornerRadius: 5))
                Text(Lf("%@ 次", number(count))).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text(share(count)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                Text(StatisticsColors.title(for: scale.level(for: count))).font(.system(size: 11)).foregroundStyle(Palette.muted)
                if presentation.selectedKey != nil {
                    Button { presentation.selectedKey = nil } label: { Image(systemName: "pin.slash") }
                        .buttonStyle(.plain).help(L("取消固定"))
                        .accessibilityLabel(L("取消固定"))
                }
            } else {
                Image(systemName: "cursorarrow").foregroundStyle(Palette.accent)
                Text(L("悬停查看详情")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                Spacer()
                Text(L("点击固定")).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("statistics-key-details")
    }

    private func legendItem(level: Int, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(StatisticsColors.fill(for: level))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Palette.line.opacity(0.5), lineWidth: 0.5))
                .frame(width: 11, height: 11)
            Text(text).font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
        }
        .help(StatisticsColors.title(for: level) + " · " + text + " " + L("次"))
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                title("打字趋势")
                Spacer()
                Text(intervalLabel).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            trendInspector
            trendChart
                .frame(height: 174)
                .overlay {
                    if snapshot.total == 0 {
                        VStack(spacing: 7) {
                            Image(systemName: "chart.bar.xaxis").font(.system(size: 22)).foregroundStyle(Palette.line)
                            Text(L("这段时间还没有记录")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                        .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("statistics-activity")
            Text(L("每根柱表示对应时段的敲击次数，首尾时段可能不足一个完整间隔。"))
                .font(.system(size: 10)).foregroundStyle(Palette.muted)
        }
        .padding(20)
        .cardStyle()
    }

    private var trendInspector: some View {
        HStack(spacing: 8) {
            if let bucket = hoveredBucket {
                Text(bucketLabel(bucket)).foregroundStyle(Palette.muted)
                Text(Lf("%@ 次", number(bucket.count))).fontWeight(.semibold).monospacedDigit()
            } else if let peak = snapshot.trend.max(by: { $0.count < $1.count }), peak.count > 0 {
                Text(L("最多")).foregroundStyle(Palette.muted)
                Text(bucketLabel(peak)).foregroundStyle(Palette.muted)
                Text(Lf("%@ 次", number(peak.count))).fontWeight(.semibold).monospacedDigit()
            } else {
                Text(L("悬停查看时段")).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .frame(height: 20)
        .accessibilityIdentifier("statistics-trend-details")
    }

    private var hoveredBucket: StatisticsTrendBucket? {
        guard let hoveredDate else { return nil }
        return snapshot.trend.first { hoveredDate >= $0.start && hoveredDate < $0.end }
    }

    private var trendChart: some View {
        let maximum = snapshot.trend.map(\.count).max() ?? 0
        return Chart {
            ForEach(snapshot.trend) { bucket in
                let inset = bucket.end.timeIntervalSince(bucket.start) * 0.14
                RectangleMark(xStart: .value(L("从"), bucket.start.addingTimeInterval(inset)),
                              xEnd: .value(L("至"), bucket.end.addingTimeInterval(-inset)),
                              yStart: .value(L("次数"), 0), yEnd: .value(L("次数"), bucket.count))
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(hoveredBucket?.id == bucket.id ? 1 : 0.78), Palette.accent.opacity(0.32)], startPoint: .top, endPoint: .bottom))
                    .cornerRadius(3)
                    .accessibilityLabel(bucketLabel(bucket))
                    .accessibilityValue(Lf("%@ 次", number(bucket.count)))
            }
            if let bucket = hoveredBucket {
                RuleMark(x: .value(L("时间"), midpoint(bucket)))
                    .foregroundStyle(Palette.muted.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: 0...max(5.0, Double(maximum) * 1.15))
        .chartXScale(domain: trendDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4])).foregroundStyle(Palette.line.opacity(0.7))
                AxisValueLabel().foregroundStyle(Palette.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: trendAxisDates) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) { Text(axisLabel(date)).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let anchor = proxy.plotFrame else { return }
                            let frame = geometry[anchor]
                            hoveredDate = frame.contains(point) ? proxy.value(atX: point.x - frame.minX, as: Date.self) : nil
                        case .ended: hoveredDate = nil
                        }
                    }
            }
        }
    }

    private var trendAxisDates: [Date] {
        let domain = trendDomain
        let duration = domain.upperBound.timeIntervalSince(domain.lowerBound)
        if duration <= 90 { return [domain.lowerBound, domain.upperBound] }
        let count = snapshot.trend.count
        guard count > 1 else { return [domain.lowerBound, domain.upperBound] }
        let step = max(1, Int(ceil(Double(count) / 6)))
        return stride(from: 0, to: count, by: step).map { snapshot.trend[$0].start }
    }

    private var trendDomain: ClosedRange<Date> {
        let start = snapshot.trend.first?.start ?? Date()
        let end = snapshot.trend.last?.end ?? start.addingTimeInterval(60)
        return start...max(start.addingTimeInterval(60), end)
    }

    private var intervalLabel: String {
        switch snapshot.trendInterval {
        case .minutes(let value): return value == 1 ? L("每分钟") : Lf("每 %d 分钟", value)
        case .hours(let value): return value == 1 ? L("每小时") : Lf("每 %d 小时", value)
        case .day: return L("每天")
        case .week: return L("每周")
        case .month: return L("每月")
        case .years(let value): return value == 1 ? L("每年") : Lf("每 %d 年", value)
        }
    }

    private func midpoint(_ bucket: StatisticsTrendBucket) -> Date {
        bucket.start.addingTimeInterval(bucket.end.timeIntervalSince(bucket.start) / 2)
    }

    private func axisLabel(_ date: Date) -> String {
        switch snapshot.trendInterval {
        case .minutes, .hours: return date.formatted(.dateTime.hour().minute().locale(AppLocalization.locale))
        case .day, .week: return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(AppLocalization.locale))
        case .month: return date.formatted(.dateTime.year(.twoDigits).month(.abbreviated).locale(AppLocalization.locale))
        case .years: return date.formatted(.dateTime.year().locale(AppLocalization.locale))
        }
    }

    private func bucketLabel(_ bucket: StatisticsTrendBucket) -> String {
        let calendar = Calendar.current
        let locale = AppLocalization.locale
        let day = calendar.dateInterval(of: .day, for: bucket.start)
        if snapshot.trendInterval == .day, day?.start == bucket.start, day?.end == bucket.end {
            return bucket.start.formatted(.dateTime.month(.abbreviated).day().year().locale(locale))
        }
        let shortInterval: Bool
        switch snapshot.trendInterval {
        case .minutes, .hours: shortInterval = true
        default: shortInterval = false
        }
        let fullDates: Bool
        switch snapshot.trendInterval {
        case .week, .month, .years: fullDates = true
        default: fullDates = false
        }
        if fullDates {
            let component: Calendar.Component = snapshot.trendInterval == .week ? .weekOfYear
                : snapshot.trendInterval == .month ? .month : .year
            let natural = calendar.dateInterval(of: component, for: bucket.start)
            let fullEnd: Date?
            if case .years(let count) = snapshot.trendInterval {
                fullEnd = calendar.date(byAdding: .year, value: count, to: bucket.start)
            } else {
                fullEnd = natural?.end
            }
            if natural?.start == bucket.start, fullEnd == bucket.end {
                let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
                return bucket.start.formatted(style) + " – " + bucket.end.addingTimeInterval(-1).formatted(style)
            }
        }
        let sameDay = calendar.isDate(bucket.start, inSameDayAs: bucket.end.addingTimeInterval(-1))
        let style = Date.FormatStyle(date: shortInterval && sameDay ? .omitted : .abbreviated, time: .shortened).locale(locale)
        let zone = calendar.timeZone
        let changesOffset = zone.secondsFromGMT(for: bucket.start) != zone.secondsFromGMT(for: bucket.end)
        func label(_ date: Date) -> String {
            let abbreviation = changesOffset ? " " + (zone.abbreviation(for: date) ?? "") : ""
            return date.formatted(style) + abbreviation
        }
        return label(bucket.start) + " – " + label(bucket.end)
    }

    private var ranking: some View {
        let rows = ranked
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                title("按键次数")
                Spacer(minLength: 0)
                TextField(L("搜索按键"), text: $presentation.search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 184)
                    .accessibilityIdentifier("statistics-search")
                Toggle(L("显示未使用的键"), isOn: $presentation.showAllKeys)
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .accessibilityIdentifier("statistics-include-unused")
            }
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Text(L(presentation.search.isEmpty ? "尚无按键记录" : "没有匹配的按键"))
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                    if !presentation.search.isEmpty {
                        Button(L("清除搜索")) { presentation.search = "" }.buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(Array(rows.prefix(presentation.expanded ? rows.count : 8).enumerated()), id: \.element.code) { index, item in
                        rankRow(index: index, code: item.code, count: item.count)
                    }
                }
                if rows.count > 8 {
                    Button {
                        presentation.expanded.toggle()
                    } label: {
                        HStack {
                            Spacer()
                            Text(presentation.expanded ? L("收起") : Lf("查看全部 %d 个键", rows.count))
                            Image(systemName: presentation.expanded ? "chevron.up" : "chevron.down")
                            Spacer()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .frame(height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(Palette.accent)
                    .accessibilityIdentifier("statistics-expand-keys")
                }
            }
        }
        .padding(20)
        .cardStyle()
        .accessibilityIdentifier("statistics-ranking")
    }

    private func rankRow(index: Int, code: UInt16, count: Int) -> some View {
        Button { pin(code) } label: {
            HStack(spacing: 12) {
                Text(String(format: "%02d", index + 1)).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Palette.muted).frame(width: 22)
                Text(StatisticsKeyLabels.label(for: code)).font(.system(size: 12, weight: .medium, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7).frame(width: 108, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.raisedSurface)
                        if count > 0 {
                            Capsule().fill(Palette.accent.opacity(inspectedKey == code ? 1 : 0.65))
                                .frame(width: max(3, geometry.size.width * Double(count) / Double(max(1, scale.maximum))))
                        }
                    }
                }
                .frame(height: 7)
                Text(number(count)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .frame(minWidth: 62, alignment: .trailing)
                Text(share(count)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.muted)
                    .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: 39)
            .background(inspectedKey == code ? Palette.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredKey = $0 ? code : nil }
        .help(Lf("%@ · %@ 次", StatisticsKeyLabels.label(for: code), number(count)) + " · " + share(count))
        .accessibilityLabel(Lf("%@ 键，%@ 次", StatisticsKeyLabels.label(for: code), number(count)))
    }

    private func pin(_ code: UInt16) {
        presentation.selectedKey = presentation.selectedKey == code ? nil : code
    }

    private func title(_ text: String) -> some View {
        Text(L(text)).font(.system(size: 14, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(AppLocalization.locale))
    }

    private func share(_ count: Int) -> String {
        (snapshot.total > 0 ? Double(count) / Double(snapshot.total) : 0)
            .formatted(.percent.locale(AppLocalization.locale).precision(.fractionLength(1)))
    }

    private func minuteLabel(_ date: Date) -> String {
        let format: Date.FormatStyle = presentation.range == .today || presentation.range == .hour
            ? .init(date: .omitted, time: .shortened).locale(AppLocalization.locale)
            : .init(date: .abbreviated, time: .shortened).locale(AppLocalization.locale)
        return date.formatted(format)
    }
}
