import Foundation
import Testing
@testable import KeyDance

struct StatisticsInsightsTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.firstWeekday = 2
        return calendar
    }

    @MainActor private func fixture(_ records: [(Date, [UInt16: Int])]) throws -> (StatisticsStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeyWooInsights-\(UUID().uuidString)/statistics.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let minutes = records.map { date, counts -> [String: Any] in
            ["minute": Int(floor(date.timeIntervalSince1970 / 60)),
             "keys": Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) })]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "minutes": minutes]).write(to: url)
        return (StatisticsStore(storageURL: url), url)
    }

    @Test func heatBandsPartitionPositiveCountsAndPreserveLongTail() {
        for maximum in [0, 1, 2, 5, 12, 31, 1_000, 10_000, Int.max] {
            let scale = HeatmapScale(maximum: maximum)
            #expect(scale.level(for: 0) == 0)
            #expect(scale.level(for: -1) == 0)
            #expect(scale.bands.count <= 5)
            guard maximum > 0 else { #expect(scale.bands.isEmpty); continue }
            #expect(scale.bands.first?.lowerBound == 1)
            #expect(scale.bands.last?.upperBound == maximum)
            #expect(scale.level(for: maximum) == 5)
            var previous = 0
            for band in scale.bands {
                #expect(band.lowerBound == previous + 1)
                #expect(band.lowerBound <= band.upperBound)
                #expect(scale.level(for: band.lowerBound) == band.level)
                #expect(scale.level(for: band.upperBound) == band.level)
                previous = band.upperBound
            }
        }
        let scale = HeatmapScale(maximum: 10_000)
        #expect(scale.level(for: 1) < scale.level(for: 100))
        #expect(scale.level(for: 100) < scale.level(for: 10_000))
        #expect(HeatmapScale(maximum: 1).bands == [HeatmapBand(level: 5, lowerBound: 1, upperBound: 1)])
    }

    @Test @MainActor func summaryConservesCountsWithEarliestPeakAndUnknownKeys() throws {
        let first = date("2026-11-10T09:02:00+08:00")
        let (store, url) = try fixture([
            (first, [0: 10, 49: 5]),
            (first.addingTimeInterval(60), [0: 4, 49: 11]),
            (first.addingTimeInterval(3600), [65_535: 3])
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try Data(contentsOf: url)
        let result = store.insights(from: first, to: first.addingTimeInterval(3660), calendar: calendar(), trendInterval: .hours(1))
        #expect(result.counts == [0: 14, 49: 16, 65_535: 3])
        #expect(result.total == 33)
        #expect(result.activeMinutes == 3)
        #expect(result.averagePerActiveMinute == 11)
        #expect(result.peakMinute == StatisticsPeakMinute(date: first, count: 15))
        #expect(result.trend.map(\.count) == [30, 3])
        #expect(result.trend.reduce(0) { $0 + $1.activeMinutes } == result.activeMinutes)
        #expect(result.trend.reduce(0) { $0 + $1.count } == result.total)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test @MainActor func trendUsesAlignedFiveMinuteGroupsAndClipsEdgeTooltips() throws {
        let day = date("2026-11-10T09:00:00+08:00")
        let (store, url) = try fixture([
            (day.addingTimeInterval(2 * 60), [0: 2]),
            (day.addingTimeInterval(5 * 60), [0: 3]),
            (day.addingTimeInterval(14 * 60), [0: 4]),
            (day.addingTimeInterval(18 * 60), [0: 100])
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = store.insights(from: day.addingTimeInterval(2 * 60 + 30),
                                    to: day.addingTimeInterval(17 * 60 + 59), calendar: calendar(), trendInterval: .minutes(5))
        #expect(result.trend.map(\.start) == [2, 5, 10, 15].map { day.addingTimeInterval(Double($0 * 60)) })
        #expect(result.trend.map(\.end) == [5, 10, 15, 18].map { day.addingTimeInterval(Double($0 * 60)) })
        #expect(result.trend.map(\.count) == [2, 3, 4, 0])
        #expect(result.total == 9)
        #expect(result.counts == store.counts(from: day.addingTimeInterval(150), to: day.addingTimeInterval(1079)))
    }

    @Test @MainActor func exactMinuteEndRemainsExclusiveAndPartialMinuteRoundsOutward() throws {
        let start = date("2026-11-10T09:02:00+08:00")
        let (store, url) = try fixture([(start, [0: 2]), (start.addingTimeInterval(60), [0: 7])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let exclusive = store.insights(from: start.addingTimeInterval(30), to: start.addingTimeInterval(60), calendar: calendar())
        #expect(exclusive.total == 2)
        #expect(exclusive.trend.first?.start == start)
        #expect(exclusive.trend.last?.end == start.addingTimeInterval(60))
        let intersecting = store.insights(from: start.addingTimeInterval(30), to: start.addingTimeInterval(61), calendar: calendar())
        #expect(intersecting.total == 9)
        #expect(intersecting.activeMinutes == 2)
        #expect(intersecting.trend.last?.end == start.addingTimeInterval(120))
    }

    @Test @MainActor func emptyAndInvalidRangesDoNotInventRatesOrPeaks() throws {
        let start = date("2026-11-10T00:00:00+08:00")
        let (store, url) = try fixture([])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let empty = store.insights(from: start, to: start.addingTimeInterval(86400), calendar: calendar(), trendInterval: .hours(1))
        #expect(empty.trend.count == 24)
        #expect(empty.trend.allSatisfy { $0.count == 0 && $0.activeMinutes == 0 })
        #expect(empty.total == 0 && empty.activeMinutes == 0 && empty.averagePerActiveMinute == 0)
        #expect(empty.peakMinute == nil && empty.heatmap.bands.isEmpty)
        for (from, to) in [(start, start), (start.addingTimeInterval(1), start),
                           (Date(timeIntervalSince1970: .infinity), start),
                           (Date(timeIntervalSince1970: 1e300), Date(timeIntervalSince1970: 1.1e300))] {
            let result = store.insights(from: from, to: to)
            #expect(result.total == 0 && result.counts.isEmpty && result.trend.isEmpty && result.peakMinute == nil)
        }
    }

    @Test @MainActor func fallBackHoursKeepBothRepeatedLocalHoursDistinct() throws {
        let start = date("2026-11-01T00:00:00-07:00")
        let end = date("2026-11-01T04:00:00-08:00")
        let (store, url) = try fixture([(date("2026-11-01T01:15:00-07:00"), [0: 3]),
                                        (date("2026-11-01T01:15:00-08:00"), [0: 5])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = store.insights(from: start, to: end, calendar: calendar("America/Los_Angeles"), trendInterval: .hours(1))
        #expect(result.trend.count == 5)
        #expect(result.trend.map(\.count) == [0, 3, 5, 0, 0])
        #expect(Set(result.trend.map(\.id)).count == 5)
        #expect(result.trend.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
    }

    @Test @MainActor func springForwardDayUsesTwentyThreeHours() throws {
        let start = date("2026-03-08T00:00:00-08:00")
        let end = date("2026-03-09T00:00:00-07:00")
        let (store, url) = try fixture([(date("2026-03-08T01:30:00-08:00"), [0: 3]),
                                        (date("2026-03-08T03:30:00-07:00"), [0: 5])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let day = store.insights(from: start, to: end, calendar: calendar("America/Los_Angeles"), trendInterval: .day)
        #expect(day.trend.count == 1 && day.trend[0].count == 8)
        #expect(day.trend[0].end.timeIntervalSince(day.trend[0].start) == 23 * 3600)
        let hours = store.insights(from: start, to: end, calendar: calendar("America/Los_Angeles"), trendInterval: .hours(1))
        #expect(hours.trend.count == 23)
        #expect(hours.trend.map(\.count).reduce(0, +) == 8)
        let hourlyActivity = store.hourlyActivity(on: start, through: end, calendar: calendar("America/Los_Angeles"))
        #expect(hourlyActivity.count == 23)
        #expect(hourlyActivity.filter { $0.activeMinutes > 0 }.map(\.date) == [
            date("2026-03-08T01:00:00-08:00"), date("2026-03-08T03:00:00-07:00")
        ])
    }

    @Test @MainActor func dailyActivityUsesExistingMinutesAndIncludesEmptyCalendarDays() throws {
        let zone = calendar()
        let now = date("2026-11-10T09:00:30+08:00")
        let (store, url) = try fixture([
            (date("2026-10-11T23:59:00+08:00"), [0: 9]),
            (date("2026-10-12T00:00:00+08:00"), [0: 50, 49: 20]),
            (date("2026-11-04T00:00:00+08:00"), [0: 2]),
            (date("2026-11-05T00:00:00+08:00"), [0: 0]),
            (date("2026-11-09T23:59:00+08:00"), [0: 6]),
            (date("2026-11-10T00:00:00+08:00"), [0: 5]),
            (date("2026-11-10T09:00:00+08:00"), [49: 7]),
            (date("2026-11-10T09:01:00+08:00"), [0: 12])
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let month = store.dailyActivity(through: now, range: .month, calendar: zone)
        let week = store.dailyActivity(through: now, range: .week, calendar: zone)
        #expect(month.count == 30)
        #expect(month.first?.date == date("2026-10-12T00:00:00+08:00"))
        #expect(month.first?.activeMinutes == 1)
        #expect(week == Array(month.suffix(7)))
        #expect(week.map(\.activeMinutes) == [1, 0, 0, 0, 0, 1, 2])
        #expect(week.last?.date == zone.startOfDay(for: now))
        let monthStart = StatisticsDayRange.month.start(through: now, calendar: zone)
        let main = store.insights(from: monthStart, to: now, calendar: zone, trendInterval: .day)
        #expect(main.trend.map(\.activeMinutes) == month.map(\.activeMinutes))
        #expect(main.total == 90)

        let today = store.hourlyActivity(on: now, through: now, calendar: zone)
        #expect(today.map(\.activeMinutes) == [1, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        #expect(today.last?.date == date("2026-11-10T09:00:00+08:00"))
        #expect(store.hourlyActivity(on: date("2026-11-11T00:00:00+08:00"), through: now, calendar: zone).isEmpty)
    }

    @Test @MainActor func dailyActivityKeepsRepeatedLocalMinutesAndStopsAtMidnight() throws {
        let zone = calendar("America/Los_Angeles")
        let (store, url) = try fixture([
            (date("2026-11-01T01:15:00-07:00"), [0: 3]),
            (date("2026-11-01T01:15:00-08:00"), [0: 5]),
            (date("2026-11-02T00:00:00-08:00"), [0: 7])
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let midnight = date("2026-11-02T00:00:00-08:00")
        let atMidnight = store.dailyActivity(through: midnight, range: .week, calendar: zone)
        try #require(atMidnight.count == 7)
        #expect(atMidnight.last?.date == midnight)
        #expect(atMidnight.map(\.activeMinutes) == [0, 0, 0, 0, 0, 2, 0])
        #expect(atMidnight[6].date.timeIntervalSince(atMidnight[5].date) == 25 * 3600)
        let yesterday = store.hourlyActivity(on: atMidnight[5].date, through: midnight, calendar: zone)
        #expect(yesterday.count == 25)
        #expect(yesterday.filter { $0.activeMinutes > 0 }.map(\.date) == [
            date("2026-11-01T01:00:00-07:00"), date("2026-11-01T01:00:00-08:00")
        ])
        #expect(yesterday.map(\.activeMinutes).reduce(0, +) == 2)
        let afterMidnight = store.dailyActivity(through: midnight.addingTimeInterval(1), range: .week, calendar: zone)
        #expect(afterMidnight.last?.activeMinutes == 1)
    }

    @Test @MainActor func comparisonUsesThePreviousCalendarPeriodAtTheSameLocalTime() throws {
        let zone = calendar()
        let today = date("2026-11-13T00:00:00+08:00")
        let now = date("2026-11-13T10:15:30+08:00")
        let (store, url) = try fixture([
            (date("2026-09-15T00:00:00+08:00"), [0: 1]),
            (date("2026-11-12T10:15:00+08:00"), [0: 4, 49: 2]),
            (date("2026-11-12T10:16:00+08:00"), [0: 500]),
            (today, [0: 9])
        ])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let previousDay = try #require(store.comparison(from: today, to: now, lookback: .calendarDays(1), calendar: zone))
        #expect(previousDay.from == date("2026-11-12T00:00:00+08:00"))
        #expect(previousDay.to == date("2026-11-12T10:16:00+08:00"))
        #expect(previousDay.hasHistory && previousDay.total == 6 && previousDay.activeMinutes == 1)

        let weekStart = StatisticsDayRange.week.start(through: now, calendar: zone)
        let previousWeek = try #require(store.comparison(from: weekStart, to: now, lookback: .calendarDays(7), calendar: zone))
        #expect(previousWeek.from == date("2026-10-31T00:00:00+08:00"))
        #expect(previousWeek.to == date("2026-11-06T10:16:00+08:00"))
        #expect(previousWeek.hasHistory && previousWeek.total == 0 && previousWeek.activeMinutes == 0)

        let monthStart = StatisticsDayRange.month.start(through: now, calendar: zone)
        let previousMonth = try #require(store.comparison(from: monthStart, to: now, lookback: .calendarDays(30), calendar: zone))
        #expect(previousMonth.from == date("2026-09-15T00:00:00+08:00"))
        #expect(previousMonth.to == date("2026-10-14T10:16:00+08:00"))
        #expect(previousMonth.hasHistory && previousMonth.total == 1 && previousMonth.activeMinutes == 1)

        let older = try #require(store.comparison(from: previousMonth.from, to: previousMonth.to,
                                                   lookback: .calendarDays(30), calendar: zone))
        #expect(!older.hasHistory)
    }

    @Test @MainActor func elapsedComparisonUsesAdjacentWholeMinutesAndRefreshesWhenBaselineChanges() throws {
        let zone = calendar("UTC")
        let first = date("2026-11-13T09:00:00Z")
        let from = first.addingTimeInterval(150)
        let to = first.addingTimeInterval(200)
        let (store, url) = try fixture([(first, [0: 2]), (first.addingTimeInterval(120), [0: 5])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let baseline = try #require(store.comparison(from: from, to: to, lookback: .elapsed, calendar: zone))
        #expect(baseline.from == first && baseline.to == first.addingTimeInterval(120))
        #expect(baseline.hasHistory && baseline.total == 2 && baseline.activeMinutes == 1)
        #expect(store.total(from: from, to: to) == 5)

        store.record(keyCode: 49, at: first.addingTimeInterval(60))
        let updated = try #require(store.comparison(from: from, to: to, lookback: .elapsed, calendar: zone))
        #expect(updated.total == 3 && updated.activeMinutes == 2)
        let beforeFirstRecord = try #require(store.comparison(from: first, to: first.addingTimeInterval(60),
                                                               lookback: .elapsed, calendar: zone))
        #expect(!beforeFirstRecord.hasHistory)
        #expect(store.comparison(from: to, to: from, lookback: .elapsed, calendar: zone) == nil)
    }

    @Test @MainActor func calendarComparisonKeepsWallClockAfterDaylightSavingChange() throws {
        let zone = calendar("America/Los_Angeles")
        let from = date("2026-11-01T00:00:00-07:00")
        let to = date("2026-11-01T10:15:00-08:00")
        let (store, url) = try fixture([(date("2026-10-30T12:00:00-07:00"), [0: 1]),
                                        (date("2026-10-31T10:14:00-07:00"), [0: 2]),
                                        (date("2026-10-31T10:15:00-07:00"), [0: 5])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let baseline = try #require(store.comparison(from: from, to: to, lookback: .calendarDays(1), calendar: zone))
        #expect(baseline.from == date("2026-10-31T00:00:00-07:00"))
        #expect(baseline.to == date("2026-10-31T10:15:00-07:00"))
        #expect(baseline.hasHistory && baseline.total == 2 && baseline.activeMinutes == 1)

        let transition = try #require(store.comparison(from: from, to: date("2026-11-01T01:59:30-07:00"),
                                                        lookback: .calendarDays(1), calendar: zone))
        #expect(transition.to == date("2026-10-31T02:00:00-07:00"))
    }

    @Test @MainActor func centuriesOfSparseHistoryStayBoundedAndConserveTotals() throws {
        let start = date("2020-01-01T00:00:00Z")
        let end = date("2420-01-01T00:00:00Z")
        let (store, url) = try fixture([(start, [0: 3]), (date("2419-12-31T23:59:00Z"), [49: 5])])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let result = store.insights(from: start, to: end, calendar: calendar("UTC"), trendInterval: .minutes(1))
        #expect(!result.trend.isEmpty && result.trend.count <= 72)
        #expect(result.trend.reduce(0) { $0 + $1.count } == 8)
        #expect(result.total == 8 && result.activeMinutes == 2 && result.averagePerActiveMinute == 4)
        #expect(result.trend.first?.start == start && result.trend.last?.end == end)
        #expect(result.trendInterval == .years(7))
    }
}
