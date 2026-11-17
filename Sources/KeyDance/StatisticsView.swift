import SwiftUI
import Charts

enum TimeRange: String, CaseIterable {
    case today = "今天", hour = "近一小时", week = "近七天", month = "近 30 天", custom = "自定义"

    var trendInterval: StatisticsTrendInterval? {
        switch self {
        case .today: return .hours(1)
        case .hour: return .minutes(5)
        case .week, .month: return .day
        case .custom: return nil
        }
    }

    var lookback: StatisticsLookback {
        switch self {
        case .today: return .calendarDays(1)
        case .week: return .calendarDays(7)
        case .month: return .calendarDays(30)
        case .hour, .custom: return .elapsed
        }
    }
}

final class StatisticsPresentationState: ObservableObject {
    @Published var range: TimeRange = .today
    @Published var activityRange: StatisticsDayRange = .week
    @Published var activityDay: Date?
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
    @State private var comparison: StatisticsComparison?
    @State private var dailyActivity: [StatisticsActiveMinutePoint] = []
    @State private var hourlyActivity: [StatisticsActiveMinutePoint] = []

    private var dates: (Date, Date) {
        let calendar = Calendar.current
        switch presentation.range {
        case .today: return (calendar.startOfDay(for: model.now), model.now)
        case .hour: return (model.now.addingTimeInterval(-3600), model.now)
        case .week: return (StatisticsDayRange.week.start(through: model.now, calendar: calendar), model.now)
        case .month: return (StatisticsDayRange.month.start(through: model.now, calendar: calendar), model.now)
        case .custom: return (presentation.from, presentation.to)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            rangeControls
            if dates.1 <= dates.0 {
                ContentUnavailableView(L("结束时间需要晚于开始时间。"), systemImage: "calendar.badge.exclamationmark")
                    .frame(maxWidth: .infinity, minHeight: 260)
                    .accessibilityIdentifier("statistics-invalid-range")
                activeMinutes
            } else if let snapshot {
                StatisticsDashboard(snapshot: snapshot, comparison: comparison, activeMinutes: activeMinutes,
                                    presentation: presentation)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .onAppear(perform: refreshAll)
        .onChange(of: model.now) { _, _ in refreshAll() }
        .onChange(of: presentation.range) { _, _ in refresh() }
        .onChange(of: presentation.from) { _, _ in refresh() }
        .onChange(of: presentation.to) { _, _ in refresh() }
        .onChange(of: presentation.activityRange) { _, _ in refreshDailyActivity() }
        .onChange(of: presentation.activityDay) { _, _ in refreshHourlyActivity() }
    }

    private func refresh() {
        let (from, to) = dates
        snapshot = model.statistics.insights(from: from, to: to, trendInterval: presentation.range.trendInterval)
        comparison = model.statistics.comparison(from: from, to: to, lookback: presentation.range.lookback)
    }

    private func refreshDailyActivity() {
        dailyActivity = model.statistics.dailyActivity(through: model.now, range: presentation.activityRange)
        if let day = presentation.activityDay, !dailyActivity.contains(where: { $0.date == day }) {
            presentation.activityDay = nil
        }
        refreshHourlyActivity()
    }

    private func refreshHourlyActivity() {
        hourlyActivity = model.statistics.hourlyActivity(on: presentation.activityDay ?? model.now, through: model.now)
    }

    private func refreshAll() {
        refresh()
        refreshDailyActivity()
    }

    private var activeMinutes: ActiveMinutesCard {
        ActiveMinutesCard(days: dailyActivity, hours: hourlyActivity,
                          range: $presentation.activityRange, selectedDay: $presentation.activityDay)
    }

    private var rangeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker(L("时间范围"), selection: $presentation.range) {
                    ForEach(TimeRange.allCases, id: \.self) { Text(L($0.rawValue)).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 458)
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
        let start = snapshot?.trend.first?.start ?? dates.0
        let end = snapshot?.trend.last?.end ?? dates.1
        let interval = start < end ? statisticsDateInterval(from: start, to: end)
            : start.formatted(.dateTime.month().day().hour().minute().locale(AppLocalization.locale))
        return interval + "  ·  " + L("本机时间")
    }
}

private struct StatisticsDashboard: View {
    let snapshot: StatisticsInsights
    let comparison: StatisticsComparison?
    let activeMinutes: ActiveMinutesCard
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
        VStack(alignment: .leading, spacing: 16) {
            overview
            activity
            activeMinutes
            heatmap
            ranking
        }
        .onChange(of: presentation.search) { _, _ in presentation.expanded = false }
        .onChange(of: presentation.showAllKeys) { _, _ in presentation.expanded = false }
    }

    private var overview: some View {
        let baseline = comparison.flatMap { $0.hasHistory ? $0 : nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 5) {
                title("概览")
                Spacer(minLength: 10)
                Text(baseline.map { Lf("对比 %@", statisticsDateInterval(from: $0.from, to: $0.to)) }
                     ?? L("暂无可对比的历史"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("statistics-comparison-period")
                InfoHelpButton(title: "历史对比", message: "今天、近七天和近 30 天与上一时段的相同本地时刻对齐。近一小时和自定义与紧邻的等长时段对比。若上一时段开始时还没有按键记录，则不显示变化。", identifier: "statistics-comparison-help")
            }
            HStack(alignment: .top, spacing: 14) {
                metric("总敲击", value: number(snapshot.total),
                       detail: Lf("%d 个键", snapshot.counts.count), accented: true,
                       change: baseline.map { metricChange(current: snapshot.total, previous: $0.total, units: "%@ 次") })
                metricDivider
                metric("活跃分钟", value: number(snapshot.activeMinutes), detail: L("分钟"),
                       explanation: "只有发生过敲击的分钟才计入活跃分钟，不能用来衡量连续打字时长。",
                       change: baseline.map { metricChange(current: snapshot.activeMinutes, previous: $0.activeMinutes, units: "%@ 分钟") })
                metricDivider
                metric("平均每分钟", value: snapshot.averagePerActiveMinute.formatted(.number.locale(AppLocalization.locale).precision(.fractionLength(0...1))),
                       detail: L("次/分钟"), explanation: "总敲击除以活跃分钟。统计包含修饰键，不等同于每分钟字数。")
                metricDivider
                metric("最高一分钟", value: snapshot.peakMinute.map { number($0.count) } ?? "—",
                       detail: snapshot.peakMinute.map { minuteLabel($0.date) } ?? L("暂无记录"),
                       explanation: "所选时间内，敲击次数最多的一个自然分钟。")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .cardStyle()
        .accessibilityIdentifier("statistics-overview")
    }

    private var metricDivider: some View {
        Rectangle().fill(Palette.line.opacity(0.7)).frame(width: 1)
            .accessibilityHidden(true)
    }

    private struct MetricChange {
        let label: String
        let previous: String
    }

    private func metricChange(current: Int, previous: Int, units: String) -> MetricChange {
        let difference = current - previous
        let label: String
        if difference == 0 {
            label = L("持平")
        } else if previous == 0 || abs(Double(difference) / Double(previous)) < 0.0005 {
            let count = difference.formatted(.number.locale(AppLocalization.locale).sign(strategy: .always()))
            label = Lf(units, count)
        } else {
            label = (Double(difference) / Double(previous)).formatted(
                .percent.locale(AppLocalization.locale).precision(.fractionLength(0...1)).sign(strategy: .always())
            )
        }
        return MetricChange(label: label, previous: Lf("上一时段 %@", Lf(units, number(previous))))
    }

    private func metric(_ title: String, value: String, detail: String, accented: Bool = false,
                        explanation: String? = nil, change: MetricChange? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 1) {
                Text(L(title)).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                if let explanation { InfoHelpButton(title: title, message: explanation) }
            }
            .foregroundStyle(Palette.muted)
            .frame(height: 20, alignment: .leading)
            Text(value)
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accented ? Palette.accent : Palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 34, alignment: .center)
            if let change {
                Text(change.label)
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.raisedSurface, in: Capsule())
                    .help(detail + "  ·  " + change.previous)
                    .accessibilityLabel(Lf("较上一时段 %@", change.label))
                    .accessibilityHint(detail + "  ·  " + change.previous)
            } else {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .frame(height: 17, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                title("按键分布")
                InfoHelpButton(title: "按键分布", message: "颜色按敲击次数分为五档。悬停查看次数，点击固定。功能键和其他按键可在下方查看。", identifier: "statistics-keymap-help")
                Spacer()
                Text(L("主键区")).font(.caption).foregroundStyle(Palette.muted)
            }
            keyInspector
            KeyboardView(pressed: [], counts: snapshot.counts, heatmap: true, action: pin,
                         selectedKey: inspectedKey, hoverAction: { hoveredKey = $0 })
                .frame(height: 202)
                .accessibilityElement(children: .contain)
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
        }
        .padding(18)
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
        .accessibilityElement(children: .contain)
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
                InfoHelpButton(title: "打字趋势", message: "每个点代表对应时段的敲击次数，曲线连接各时段的变化。首尾时段可能不足完整间隔，悬停可查看具体时间和次数。", identifier: "statistics-trend-help")
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
        }
        .padding(18)
        .cardStyle()
    }

    private var trendInspector: some View {
        HStack(spacing: 8) {
            if let bucket = hoveredBucket {
                Text(bucketLabel(bucket)).foregroundStyle(Palette.muted)
                Text(Lf("%@ 次", number(bucket.count))).fontWeight(.semibold).monospacedDigit()
            } else if let peak = snapshot.trend.max(by: { $0.count < $1.count }), peak.count > 0 {
                Text(L("峰值")).foregroundStyle(Palette.muted)
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
        let selected = hoveredBucket
        let peak = snapshot.trend.first { $0.count == maximum && maximum > 0 }
        return Chart {
            ForEach(snapshot.trend) { bucket in
                AreaMark(x: .value(L("时间"), midpoint(bucket)),
                         yStart: .value(L("次数"), 0), yEnd: .value(L("次数"), bucket.count))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.23), Palette.accent.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                LineMark(x: .value(L("时间"), midpoint(bucket)), y: .value(L("次数"), bucket.count))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(snapshot.total > 0 ? Palette.accent : Palette.line)
                    .accessibilityLabel(bucketLabel(bucket))
                    .accessibilityValue(Lf("%@ 次", number(bucket.count)))
            }
            if let bucket = selected ?? peak {
                PointMark(x: .value(L("时间"), midpoint(bucket)), y: .value(L("次数"), bucket.count))
                    .foregroundStyle(Palette.accent)
                    .symbolSize(selected == nil ? 22 : 48)
                    .accessibilityHidden(true)
            }
            if let bucket = selected {
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
        .chartXSelection(value: $hoveredDate)
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
        .padding(18)
        .cardStyle()
        .accessibilityElement(children: .contain)
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

private struct ActiveMinutesCard: View {
    let days: [StatisticsActiveMinutePoint]
    let hours: [StatisticsActiveMinutePoint]
    @Binding var range: StatisticsDayRange
    @Binding var selectedDay: Date?
    @State private var hoveredDay: Date?
    @State private var hoveredHour: Date?

    private var focusedDay: Date? { selectedDay ?? days.last?.date }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                title("每日活跃分钟")
                InfoHelpButton(title: "每日活跃分钟", message: "一分钟内有敲击记录，就计为 1 个活跃分钟。按本机日期汇总。点击曲线查看当天的分时统计。", identifier: "statistics-daily-activity-help")
                Spacer()
                Picker(L("活跃分钟时间范围"), selection: $range) {
                    ForEach(StatisticsDayRange.allCases, id: \.self) { option in
                        Text(Lf("%d 天", option.rawValue)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                .accessibilityIdentifier("statistics-daily-activity-range")
            }
            dayDetails
            ActiveMinutesPlot(points: days, interval: .day, selectedDate: focusedDay,
                              hoveredDate: $hoveredDay, selectDate: selectDay)
                .frame(height: 174)
                .accessibilityIdentifier("statistics-daily-activity-chart")
            Divider().overlay(Palette.line.opacity(0.45))
            HStack(spacing: 4) {
                title("分时活跃分钟")
                InfoHelpButton(title: "分时活跃分钟", message: "每个点表示这一小时中有敲击记录的分钟数。查看今天时，曲线更新至当前小时。", identifier: "statistics-hourly-activity-help")
                Spacer()
                Picker(L("查看哪一天"), selection: $selectedDay) {
                    Text(L("今天")).tag(nil as Date?)
                    ForEach(days.dropLast().reversed()) { day in
                        Text(activityDateLabel(day.date)).tag(Optional(day.date))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 150)
                .accessibilityIdentifier("statistics-hourly-activity-day")
            }
            hourDetails
            ActiveMinutesPlot(points: hours, interval: .hour, hoveredDate: $hoveredHour)
                .frame(height: 156)
                .accessibilityIdentifier("statistics-hourly-activity-chart")
        }
        .padding(18)
        .cardStyle()
        .onChange(of: range) { _, _ in hoveredDay = nil }
        .onChange(of: hours.first?.date) { _, _ in hoveredHour = nil }
    }

    private func selectDay(_ date: Date) {
        selectedDay = date == days.last?.date ? nil : date
    }

    private func title(_ text: String) -> some View {
        Text(L(text))
            .font(.system(size: 14, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private var dayDetails: some View {
        let inspected = days.first { $0.date == (hoveredDay ?? focusedDay) }
        return HStack(spacing: 8) {
            if let inspected {
                Text(inspected.date == days.last?.date ? L("今天") : activityDateLabel(inspected.date))
                    .foregroundStyle(Palette.muted)
                Text(activeMinutesLabel(inspected.activeMinutes)).fontWeight(.semibold).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .frame(height: 20)
        .accessibilityIdentifier("statistics-daily-activity-details")
    }

    private var hourDetails: some View {
        let hovered = hours.first { $0.date == hoveredHour }
        let peak = hours.max { $0.activeMinutes < $1.activeMinutes }
        return HStack(spacing: 8) {
            if let point = hovered ?? peak, hovered != nil || point.activeMinutes > 0 {
                if hovered == nil { Text(L("峰值")).foregroundStyle(Palette.muted) }
                Text(activityHourLabel(point.date, in: hours)).foregroundStyle(Palette.muted)
                Text(activeMinutesLabel(point.activeMinutes)).fontWeight(.semibold).monospacedDigit()
            } else {
                Text(L("当天没有敲击记录")).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .frame(height: 20)
        .accessibilityIdentifier("statistics-hourly-activity-details")
    }
}

private struct ActiveMinutesPlot: View {
    enum Interval { case day, hour }

    let points: [StatisticsActiveMinutePoint]
    let interval: Interval
    var selectedDate: Date?
    @Binding var hoveredDate: Date?
    var selectDate: ((Date) -> Void)?

    private var horizontalLabel: String { L(interval == .day ? "日期" : "时间") }

    var body: some View {
        if let start = points.first?.date, let end = points.last?.date {
            let intervalSeconds = interval == .day ? 86_400.0 : 3_600.0
            let margin = max(intervalSeconds * 0.35, end.timeIntervalSince(start) * 0.045)
            chart(domain: start.addingTimeInterval(-margin)...end.addingTimeInterval(margin))
        }
    }

    private func chart(domain: ClosedRange<Date>) -> some View {
        let maximum = points.map(\.activeMinutes).max() ?? 0
        let selected = points.first { $0.date == selectedDate }
        let hovered = points.first { $0.date == hoveredDate }
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value(horizontalLabel, point.date),
                         yStart: .value(L("活跃分钟"), 0),
                         yEnd: .value(L("活跃分钟"), point.activeMinutes))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [Palette.accent.opacity(0.19), Palette.accent.opacity(0.01)],
                                                    startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                LineMark(x: .value(horizontalLabel, point.date), y: .value(L("活跃分钟"), point.activeMinutes))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(maximum > 0 ? Palette.accent : Palette.line)
                    .accessibilityLabel(detailLabel(point.date))
                    .accessibilityValue(activeMinutesLabel(point.activeMinutes))
            }
            if let highlighted = hovered ?? selected {
                RuleMark(x: .value(horizontalLabel, highlighted.date))
                    .foregroundStyle(Palette.muted.opacity(hovered == nil ? 0.28 : 0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
            if let point = hovered ?? selected ?? (points.count == 1 ? points.first : nil) {
                PointMark(x: .value(horizontalLabel, point.date), y: .value(L("活跃分钟"), point.activeMinutes))
                    .foregroundStyle(Palette.accent)
                    .symbolSize(hovered == nil ? 32 : 48)
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...max(5.0, Double(maximum) * 1.15))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    .foregroundStyle(Palette.line.opacity(0.7))
                AxisValueLabel().foregroundStyle(Palette.muted)
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel(centered: false, anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let date = nearestDate(at: location, proxy: proxy, geometry: geometry)
                            if date != hoveredDate { hoveredDate = date }
                        case .ended: hoveredDate = nil
                        }
                    }
                    .onTapGesture { location in
                        if let date = nearestDate(at: location, proxy: proxy, geometry: geometry) {
                            selectDate?(date)
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
    }

    private func nearestDate(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let frame = proxy.plotFrame else { return nil }
        let plot = geometry[frame]
        guard plot.contains(location), let date = proxy.value(atX: location.x - plot.minX, as: Date.self) else { return nil }
        return points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.date
    }

    private var axisDates: [Date] {
        let step = interval == .day && points.count <= 7 ? 1 : max(1, (points.count + 5) / 6)
        let dates = stride(from: 0, to: points.count, by: step).map { points[$0].date }
        guard let last = points.last?.date, dates.last != last else { return dates }
        return dates + [last]
    }

    private func axisLabel(_ date: Date) -> String {
        if interval == .hour { return date.formatted(.dateTime.hour().minute().locale(AppLocalization.locale)) }
        return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).locale(AppLocalization.locale))
    }

    private func detailLabel(_ date: Date) -> String {
        interval == .day ? activityDateLabel(date) : activityHourLabel(date, in: points)
    }
}

private func activityDateLabel(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().year().locale(AppLocalization.locale))
}

private func statisticsDateInterval(from: Date, to: Date) -> String {
    let style = Date.IntervalFormatStyle()
        .locale(AppLocalization.locale).month(.abbreviated).day().hour().minute()
    let calendar = Calendar.current
    let range = from..<to
    if calendar.isDate(from, equalTo: Date(), toGranularity: .year),
       calendar.isDate(from, equalTo: to, toGranularity: .year) {
        return range.formatted(style)
    }
    return range.formatted(style.year())
}

private func activityHourLabel(_ date: Date, in hours: [StatisticsActiveMinutePoint]) -> String {
    let time = date.formatted(.dateTime.hour().minute().locale(AppLocalization.locale))
    let zone = Calendar.current.timeZone
    guard let first = hours.first?.date, let last = hours.last?.date,
          zone.secondsFromGMT(for: first) != zone.secondsFromGMT(for: last),
          let abbreviation = zone.abbreviation(for: date) else { return time }
    return time + " " + abbreviation
}

private func activeMinutesLabel(_ minutes: Int) -> String {
    Lf("%@ 分钟", minutes.formatted(.number.locale(AppLocalization.locale)))
}
