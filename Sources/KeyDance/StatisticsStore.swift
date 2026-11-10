import Foundation
import Combine

struct ActivityBucket: Identifiable {
    let date: Date
    let count: Int
    var id: Date { date }
}

/// Stores minute/key totals only: no characters, typed text, application names, or event order.
/// Queries include whole minute buckets intersecting [from, to). A non-aligned starting
/// time rounds down and a non-aligned ending time rounds up. An exact-minute end is exclusive.
@MainActor
final class StatisticsStore: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var errorMessage: String?
    private(set) var sessionStart = Date()
    private(set) var sessionCounts: [UInt16: Int] = [:]

    private let storageURL: URL
    private var minutes: [Int: [UInt16: Int]] = [:]
    private var sortedMinutes: [Int] = []
    // Short-lived rate meter: only per-second totals, never key IDs or an ordered event log.
    private var recentSeconds: [Int: Int] = [:]
    private var newestRecentSecond: Int?
    private var pendingSave: DispatchWorkItem?
    private var dirty = false
    private var persistenceEnabled = true
    private let saveQueue = DispatchQueue(label: "KeyDance.statistics", qos: .utility)
    private var activeWrites = 0
    private var saveGeneration = 0

    private struct Archive: Codable {
        let version: Int
        let minutes: [MinuteRecord]
    }

    private struct MinuteRecord: Codable {
        let minute: Int
        let keys: [String: Int]
    }

    // Far beyond a person's lifetime of typing, while leaving ample arithmetic
    // headroom for session counters, chart totals and subsequent input. A valid
    // JSON Int alone is not a safe count: corrupt archives can contain Int.max.
    private static let maximumArchiveTotal = 1_000_000_000_000
    private enum ArchiveError: Error { case unsafeCount }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KeyDance", isDirectory: true)
            .appendingPathComponent("statistics.json")
        load()
    }

    func record(keyCode: UInt16, at date: Date = Date()) {
        guard date.timeIntervalSince1970.isFinite else { return }
        let minute = Self.minute(for: date)
        if minutes[minute] == nil {
            sortedMinutes.insert(minute, at: lowerBound(of: minute))
        }
        minutes[minute, default: [:]][keyCode, default: 0] += 1
        sessionCounts[keyCode, default: 0] += 1
        recordRecentSecond(at: date)
        revision &+= 1
        dirty = true
        scheduleSave()
    }

    func counts(from: Date, to: Date) -> [UInt16: Int] {
        guard let range = Self.minuteRange(from: from, to: to) else { return [:] }
        var result: [UInt16: Int] = [:]
        for minute in indexedMinutes(in: range) {
            guard let keys = minutes[minute] else { continue }
            for (key, count) in keys { result[key, default: 0] += count }
        }
        return result
    }

    func total(from: Date, to: Date) -> Int {
        counts(from: from, to: to).values.reduce(0, +)
    }

    func activeMinuteCount(from: Date, to: Date) -> Int {
        guard let range = Self.minuteRange(from: from, to: to) else { return 0 }
        return indexedMinutes(in: range).count
    }

    /// Derive the statistics screen in one pass over occupied selected minutes.
    /// The caller refreshes the snapshot on the presentation clock, not on input.
    func insights(from: Date, to: Date, calendar: Calendar = .current,
                  trendInterval: StatisticsTrendInterval? = nil) -> StatisticsInsights {
        guard let range = Self.minuteRange(from: from, to: to) else {
            return StatisticsInsights(counts: [:], total: 0, activeMinutes: 0,
                                      peakMinute: nil, trend: [], trendInterval: trendInterval ?? .minutes(5))
        }
        let start = Date(timeIntervalSince1970: Double(range.lowerBound) * 60)
        let end = Date(timeIntervalSince1970: Double(range.upperBound) * 60)
        let plan = StatisticsTrendPlan.make(from: start, to: end, calendar: calendar, preferred: trendInterval)
        var trend = plan.buckets
        var counts: [UInt16: Int] = [:]
        var total = 0
        var active = 0
        var peak: StatisticsPeakMinute?
        var bucketIndex = 0
        for minute in indexedMinutes(in: range) {
            guard let keys = minutes[minute] else { continue }
            var minuteTotal = 0
            for (key, count) in keys where count > 0 {
                counts[key, default: 0] += count
                minuteTotal += count
            }
            guard minuteTotal > 0 else { continue }
            total += minuteTotal
            active += 1
            let date = Date(timeIntervalSince1970: Double(minute) * 60)
            if minuteTotal > (peak?.count ?? 0) { peak = StatisticsPeakMinute(date: date, count: minuteTotal) }
            while bucketIndex < trend.count, date >= trend[bucketIndex].end { bucketIndex += 1 }
            if bucketIndex < trend.count, date >= trend[bucketIndex].start {
                trend[bucketIndex].count += minuteTotal
                trend[bucketIndex].activeMinutes += 1
            }
        }
        return StatisticsInsights(counts: counts, total: total, activeMinutes: active,
                                  peakMinute: peak, trend: trend, trendInterval: plan.interval)
    }

    /// Current second and the preceding N-1 seconds, accurate to one second.
    /// Memory-only and limited to the latest five minutes; not reconstructed from minute history.
    func recentCount(seconds: TimeInterval = 60, endingAt date: Date = Date()) -> Int {
        guard date.timeIntervalSince1970.isFinite, seconds.isFinite, seconds > 0 else { return 0 }
        let upper = Int(floor(date.timeIntervalSince1970))
        let width = min(300, max(1, Int(ceil(min(seconds, 300)))))
        let lower = upper - width + 1
        return recentSeconds.reduce(0) { result, entry in
            result + ((lower...upper).contains(entry.key) ? entry.value : 0)
        }
    }

    func activity(from: Date, to: Date, buckets: Int) -> [ActivityBucket] {
        guard buckets > 0, let range = Self.minuteRange(from: from, to: to) else { return [] }
        // At least one minute per bar: a minute is never split across visual buckets.
        let bucketCount = min(buckets, range.count)
        var totals = Array(repeating: 0, count: bucketCount)
        for minute in indexedMinutes(in: range) {
            guard let keys = minutes[minute] else { continue }
            let index = min(bucketCount - 1, (minute - range.lowerBound) * bucketCount / range.count)
            totals[index] += keys.values.reduce(0, +)
        }
        return totals.enumerated().map { index, count in
            let offset = Int(ceil(Double(index * range.count) / Double(bucketCount)))
            let date = Date(timeIntervalSince1970: Double((range.lowerBound + offset) * 60))
            return ActivityBucket(date: date, count: count)
        }
    }

    func csv(from: Date, to: Date) -> String {
        let dateFormat = ISO8601DateFormatter()
        let start: String
        let end: String
        if let range = Self.minuteRange(from: from, to: to) {
            start = dateFormat.string(from: Date(timeIntervalSince1970: Double(range.lowerBound * 60)))
            end = dateFormat.string(from: Date(timeIntervalSince1970: Double(range.upperBound * 60)))
        } else {
            start = dateFormat.string(from: from)
            end = dateFormat.string(from: to)
        }
        var rows = ["from_inclusive,to_exclusive,key_code,key,count"]
        for (code, count) in counts(from: from, to: to).sorted(by: { $0.key < $1.key }) {
            let label = KeyLayout.label(for: code).replacingOccurrences(of: "\"", with: "\"\"")
            rows.append("\(start),\(end),\(code),\"\(label)\",\(count)")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Save after losing focus without making keyboard input wait for disk I/O.
    func requestSave() {
        pendingSave?.cancel()
        pendingSave = nil
        saveInBackground()
    }

    /// Complete the latest save before application termination.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard persistenceEnabled, dirty || activeWrites > 0 else { return }
        saveGeneration += 1
        let snapshot = minutes
        let url = storageURL
        // Serialize behind any background writes, so an older snapshot cannot replace this one.
        let failure = saveQueue.sync { Self.persist(snapshot, to: url) }
        dirty = failure != nil
        errorMessage = failure
    }

    private func saveInBackground() {
        pendingSave = nil
        guard dirty, persistenceEnabled else { return }
        guard activeWrites == 0 else {
            // A slow disk must not accumulate a queue of full-history snapshots.
            scheduleSave()
            return
        }
        dirty = false
        saveGeneration += 1
        let generation = saveGeneration
        let snapshot = minutes
        let url = storageURL
        activeWrites += 1
        saveQueue.async { [weak self] in
            let failure = Self.persist(snapshot, to: url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeWrites -= 1
                guard self.saveGeneration == generation else { return }
                self.errorMessage = failure
                if failure != nil { self.dirty = true }
            }
        }
    }

    nonisolated private static func persist(_ snapshot: [Int: [UInt16: Int]], to url: URL) -> String? {
        do {
            let records = snapshot.sorted { $0.key < $1.key }.map { minute, keys in
                MinuteRecord(minute: minute, keys: Dictionary(uniqueKeysWithValues:
                    keys.map { (String($0.key), $0.value) }))
            }
            let data = try JSONEncoder().encode(Archive(version: 1, minutes: records))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return "按键统计暂时无法保存：\(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        guard pendingSave == nil, persistenceEnabled else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.saveInBackground() }
        }
        pendingSave = work
        // Coalesce changes, but still persist during sustained typing instead of waiting for idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1 else {
                persistenceEnabled = false
                errorMessage = "统计文件版本不兼容，已保留原文件；当前会话仍可统计。"
                return
            }
            var loadedMinutes: [Int: [UInt16: Int]] = [:]
            var loadedTotal = 0
            for record in archive.minutes {
                var keys: [UInt16: Int] = [:]
                for (rawKey, count) in record.keys {
                    guard let code = UInt16(rawKey), count > 0 else { continue }
                    let sum = loadedTotal.addingReportingOverflow(count)
                    guard !sum.overflow, sum.partialValue <= Self.maximumArchiveTotal else {
                        throw ArchiveError.unsafeCount
                    }
                    loadedTotal = sum.partialValue
                    // Every positive count contributes to the bounded aggregate,
                    // so aliases and duplicate minutes can now merge safely.
                    keys[code, default: 0] += count
                }
                for (code, count) in keys { loadedMinutes[record.minute, default: [:]][code, default: 0] += count }
            }
            // Publish only a fully validated archive. A later bad record must
            // not expose partial history or permit rewriting the original file.
            minutes = loadedMinutes
            sortedMinutes = minutes.keys.sorted()
        } catch {
            // Never overwrite unreadable historical statistics with an empty archive.
            persistenceEnabled = false
            errorMessage = "历史统计无法读取，已保留原文件；当前会话仍可统计。"
        }
    }

    /// Binary-search only the selected minutes; long histories do not slow down live counters.
    private func indexedMinutes(in range: Range<Int>) -> ArraySlice<Int> {
        sortedMinutes[lowerBound(of: range.lowerBound)..<lowerBound(of: range.upperBound)]
    }

    private func lowerBound(of value: Int) -> Int {
        var lower = 0
        var upper = sortedMinutes.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sortedMinutes[middle] < value { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private func recordRecentSecond(at date: Date) {
        let second = Int(floor(date.timeIntervalSince1970))
        let newest = max(newestRecentSecond ?? second, second)
        if newest != newestRecentSecond {
            recentSeconds = recentSeconds.filter { $0.key >= newest - 299 }
            newestRecentSecond = newest
        }
        guard second >= newest - 299 else { return }
        recentSeconds[second, default: 0] += 1
    }

    private static func minute(for date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970 / 60))
    }

    private static func minuteRange(from: Date, to: Date) -> Range<Int>? {
        guard from.timeIntervalSince1970.isFinite, to.timeIntervalSince1970.isFinite,
              from.timeIntervalSince1970 > Double(Int.min), to.timeIntervalSince1970 < Double(Int.max), to > from else {
            return nil
        }
        let lower = minute(for: from)
        let upper = Int(ceil(to.timeIntervalSince1970 / 60))
        guard upper > lower else { return nil }
        return lower..<upper
    }
}
