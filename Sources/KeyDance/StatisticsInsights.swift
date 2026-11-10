import Foundation

struct HeatmapBand: Identifiable, Equatable {
    let level: Int
    let lowerBound: Int
    let upperBound: Int
    var id: Int { level }
}

/// Zero has its own color. Positive counts use logarithmic bands so a heavily
/// used Space key does not erase the differences between ordinary keys.
struct HeatmapScale: Equatable {
    let maximum: Int
    let bands: [HeatmapBand]

    init(maximum: Int) {
        self.maximum = max(0, maximum)
        guard maximum > 0 else { bands = []; return }
        let logarithm = log1p(Double(maximum))
        var result: [HeatmapBand] = []
        var previousUpper = 0
        for level in 1...5 {
            let upper = level == 5 ? maximum : min(maximum, Int(floor(expm1(logarithm * Double(level) / 5))))
            if upper > previousUpper {
                result.append(HeatmapBand(level: level, lowerBound: previousUpper + 1, upperBound: upper))
                previousUpper = upper
            }
        }
        bands = result
    }

    func level(for count: Int) -> Int {
        guard count > 0, maximum > 0 else { return 0 }
        return bands.first(where: { count <= $0.upperBound })?.level ?? 5
    }
}

enum StatisticsTrendInterval: Hashable {
    case minutes(Int), hours(Int), day, week, month, years(Int)
}

struct StatisticsTrendBucket: Identifiable, Equatable {
    let start: Date
    let end: Date
    var count: Int = 0
    var activeMinutes: Int = 0
    var id: Date { start }
}

struct StatisticsPeakMinute: Equatable {
    let date: Date
    let count: Int
}

struct StatisticsInsights {
    let counts: [UInt16: Int]
    let total: Int
    let activeMinutes: Int
    let peakMinute: StatisticsPeakMinute?
    let trend: [StatisticsTrendBucket]
    let trendInterval: StatisticsTrendInterval

    var averagePerActiveMinute: Double {
        activeMinutes > 0 ? Double(total) / Double(activeMinutes) : 0
    }

    var heatmap: HeatmapScale { HeatmapScale(maximum: counts.values.max() ?? 0) }
}

/// Calendar intervals retain local hour/day boundaries across DST. Edge buckets
/// are clipped to the queried minute range, and the chart never exceeds 72 bars.
struct StatisticsTrendPlan {
    let interval: StatisticsTrendInterval
    let buckets: [StatisticsTrendBucket]

    static func make(from: Date, to: Date, calendar: Calendar,
                     preferred: StatisticsTrendInterval?) -> StatisticsTrendPlan {
        let automatic = automaticInterval(from: from, to: to)
        for interval in [preferred, automatic, yearsInterval(from: from, to: to)].compactMap({ $0 }) {
            if let buckets = buckets(from: from, to: to, calendar: calendar, interval: interval) {
                return StatisticsTrendPlan(interval: interval, buckets: buckets)
            }
        }
        return StatisticsTrendPlan(interval: automatic, buckets: [])
    }

    private static func automaticInterval(from: Date, to: Date) -> StatisticsTrendInterval {
        let duration = to.timeIntervalSince(from)
        if duration <= 90 * 60 { return .minutes(5) }
        if duration <= 12 * 3600 { return .minutes(15) }
        if duration <= 2 * 86_400 { return .hours(1) }
        if duration <= 14 * 86_400 { return .day }
        if duration <= 180 * 86_400 { return .week }
        if duration <= 6 * 365.2425 * 86_400 { return .month }
        return yearsInterval(from: from, to: to)
    }

    private static func yearsInterval(from: Date, to: Date) -> StatisticsTrendInterval {
        .years(max(1, Int(ceil(to.timeIntervalSince(from) / (60 * 365.2425 * 86_400)))))
    }

    private static func buckets(from: Date, to: Date, calendar: Calendar,
                                interval: StatisticsTrendInterval) -> [StatisticsTrendBucket]? {
        guard var start = alignedStart(containing: from, calendar: calendar, interval: interval) else { return nil }
        var result: [StatisticsTrendBucket] = []
        while start < to {
            guard result.count < 72,
                  let end = calendar.date(byAdding: component(interval), value: stride(interval), to: start), end > start else { return nil }
            let clippedStart = max(start, from)
            let clippedEnd = min(end, to)
            if clippedEnd > clippedStart { result.append(StatisticsTrendBucket(start: clippedStart, end: clippedEnd)) }
            start = end
        }
        return result
    }

    private static func alignedStart(containing date: Date, calendar: Calendar,
                                     interval: StatisticsTrendInterval) -> Date? {
        switch interval {
        case .minutes(let step):
            guard step > 0, step <= 60, let hour = calendar.dateInterval(of: .hour, for: date)?.start else { return nil }
            let minute = calendar.component(.minute, from: date) / step * step
            return calendar.date(byAdding: .minute, value: minute, to: hour)
        case .hours(let step):
            guard step > 0, step <= 24 else { return nil }
            if step == 1 { return calendar.dateInterval(of: .hour, for: date)?.start }
            let hour = calendar.component(.hour, from: date) / step * step
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date)
        case .years(let step):
            guard step > 0 else { return nil }
            var components = calendar.dateComponents([.era, .year], from: date)
            guard let year = components.year, year > 0 else { return nil }
            components.year = (year - 1) / step * step + 1
            components.month = 1
            components.day = 1
            return calendar.date(from: components)
        case .day, .week, .month:
            return calendar.dateInterval(of: component(interval), for: date)?.start
        }
    }

    private static func component(_ interval: StatisticsTrendInterval) -> Calendar.Component {
        switch interval {
        case .minutes: return .minute
        case .hours: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .years: return .year
        }
    }

    private static func stride(_ interval: StatisticsTrendInterval) -> Int {
        switch interval {
        case .minutes(let value), .hours(let value), .years(let value): return value
        case .day, .week, .month: return 1
        }
    }
}
