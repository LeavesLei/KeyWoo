import Foundation
import Testing
@testable import KeyDance

struct StatisticsTests {
    private func fixtureURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KeyDanceTests-\(UUID().uuidString)")
            .appendingPathComponent("statistics.json")
    }

    @Test func testMinuteWindowsAndActivityConserveCounts() async throws {
        await MainActor.run {
            let url = fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = StatisticsStore(storageURL: url)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            store.record(keyCode: 0, at: start.addingTimeInterval(2))
            store.record(keyCode: 0, at: start.addingTimeInterval(59))
            store.record(keyCode: 1, at: start.addingTimeInterval(60))
            store.record(keyCode: 2, at: start.addingTimeInterval(121))
            #expect(store.counts(from: start, to: start.addingTimeInterval(60)) == [0: 2])
            #expect(store.total(from: start.addingTimeInterval(59), to: start.addingTimeInterval(61)) == 3)
            #expect(store.total(from: start, to: start) == 0)
            let activity = store.activity(from: start, to: start.addingTimeInterval(180), buckets: 2)
            #expect(activity.map(\.count) == [3, 1])
            #expect(activity.map(\.date) == [start, start.addingTimeInterval(120)])
            #expect(activity.reduce(0) { $0 + $1.count } == 4)
            #expect(store.activeMinuteCount(from: start, to: start.addingTimeInterval(180)) == 3)
            #expect(store.sessionCounts.values.reduce(0, +) == 4)
            store.flush()
        }
    }

    @Test func testRollingRateUsesSecondsNotMinuteBuckets() async {
        await MainActor.run {
            let url = fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = StatisticsStore(storageURL: url)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            store.record(keyCode: 0, at: start)
            store.record(keyCode: 0, at: start.addingTimeInterval(30))
            store.record(keyCode: 0, at: start.addingTimeInterval(59))
            store.record(keyCode: 0, at: start.addingTimeInterval(60))
            #expect(store.recentCount(seconds: 60, endingAt: start.addingTimeInterval(60)) == 3)
            #expect(store.recentCount(seconds: 60, endingAt: start.addingTimeInterval(120)) == 0)
            store.record(keyCode: 0, at: start.addingTimeInterval(400))
            #expect(store.recentCount(seconds: 300, endingAt: start.addingTimeInterval(400)) == 1)
            #expect(store.activeMinuteCount(from: start, to: start.addingTimeInterval(86_400 * 365)) == 3)
            store.flush()
            let restored = StatisticsStore(storageURL: url)
            #expect(restored.recentCount(seconds: 60, endingAt: start.addingTimeInterval(400)) == 0)
        }
    }

    @Test func testOutOfOrderHistoryRemainsQueryable() async throws {
        await MainActor.run {
            let url = fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = StatisticsStore(storageURL: url)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            store.record(keyCode: 0, at: start.addingTimeInterval(3600))
            store.record(keyCode: 1, at: start)
            store.record(keyCode: 2, at: start.addingTimeInterval(60))
            #expect(store.counts(from: start, to: start.addingTimeInterval(120)) == [1: 1, 2: 1])
            #expect(store.total(from: start.addingTimeInterval(120), to: start.addingTimeInterval(3600)) == 0)
            store.flush()
        }
    }

    @Test func testBackgroundSaveAndFinalFlushKeepNewestCounts() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = await MainActor.run { () -> StatisticsStore in
            let store = StatisticsStore(storageURL: url)
            store.record(keyCode: 0, at: start)
            return store
        }
        try await Task.sleep(nanoseconds: 1_800_000_000)
        await MainActor.run {
            store.record(keyCode: 0, at: start.addingTimeInterval(1))
            store.flush()
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await MainActor.run {
            let restored = StatisticsStore(storageURL: url)
            #expect(restored.counts(from: start, to: start.addingTimeInterval(60)) == [0: 2])
            #expect(store.errorMessage == nil)
        }
    }

    @Test func testFocusSavePersistsWithoutRunLoopAndFinalFlushKeepsNewerKeys() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try await MainActor.run { () throws -> StatisticsStore in
            let store = StatisticsStore(storageURL: url)
            store.record(keyCode: 0, at: start)
            store.requestSave()

            // Keep this actor turn occupied: the delayed autosave cannot satisfy
            // the assertion. The explicit request must write on its own queue.
            // Foundation can expose an empty destination placeholder before a
            // first atomic write commits. Existence is not a completed save.
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            var committedCounts: [UInt16: Int] = [:]
            while ProcessInfo.processInfo.systemUptime < deadline {
                let firstSave = StatisticsStore(storageURL: url)
                if firstSave.errorMessage == nil {
                    committedCounts = firstSave.counts(from: start, to: start.addingTimeInterval(60))
                    if committedCounts == [0: 1] { break }
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try #require(committedCounts == [0: 1])

            // The earlier writer's MainActor completion has not run yet. A
            // second focus request and immediate exit must retain newer input.
            store.record(keyCode: 49, at: start.addingTimeInterval(1))
            store.requestSave()
            store.record(keyCode: 36, at: start.addingTimeInterval(2))
            store.flush()
            return store
        }
        await Task.yield()
        await MainActor.run {
            let restored = StatisticsStore(storageURL: url)
            #expect(restored.counts(from: start, to: start.addingTimeInterval(60)) == [0: 1, 49: 1, 36: 1])
            #expect(store.errorMessage == nil)
        }
    }

    @Test func testArchiveRoundTripAndNoEventSequence() async throws {
        try await MainActor.run {
            let url = fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let store = StatisticsStore(storageURL: url)
            store.record(keyCode: 12, at: start.addingTimeInterval(10))
            store.record(keyCode: 12, at: start.addingTimeInterval(15))
            store.record(keyCode: 49, at: start.addingTimeInterval(20))
            store.flush()
            #expect(store.errorMessage == nil)
            let restored = StatisticsStore(storageURL: url)
            #expect(restored.counts(from: start, to: start.addingTimeInterval(60)) == [12: 2, 49: 1])
            #expect(restored.sessionCounts.isEmpty)
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let records = try #require(json["minutes"] as? [[String: Any]])
            #expect(records.count == 1)
            #expect(Set(records[0].keys) == ["minute", "keys"])
            #expect(restored.csv(from: start, to: start.addingTimeInterval(60)).components(separatedBy: "\n").count == 4)
        }
    }

    @Test func testUnreadableArchiveIsNotOverwritten() async throws {
        try await MainActor.run {
            let url = fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("corrupt archive".utf8)
            try original.write(to: url)
            let store = StatisticsStore(storageURL: url)
            #expect(store.errorMessage != nil)
            store.record(keyCode: 0)
            store.flush()
            #expect(try Data(contentsOf: url) == original)
            #expect(store.sessionCounts == [0: 1])
        }
    }

    @Test func testUnsafeArchiveCountsAreRejectedWithoutPartialHistoryOrOverwrite() async throws {
        try await MainActor.run {
            let minute = 30_000_000
            let unsafeRecords = [
                // Duplicate minutes and noncanonical aliases used to overflow
                // during load; distinct keys could overflow later UI totals.
                "{\"minute\":\(minute),\"keys\":{\"0\":\(Int.max)}},{\"minute\":\(minute),\"keys\":{\"0\":1}}",
                "{\"minute\":\(minute),\"keys\":{\"0\":\(Int.max),\"00\":1}}",
                "{\"minute\":\(minute),\"keys\":{\"0\":\(Int.max / 2 + 1),\"1\":\(Int.max / 2 + 1)}}",
                // Individually permitted counts must also obey the aggregate
                // bound across different minutes, not just within one key.
                "{\"minute\":\(minute),\"keys\":{\"0\":600000000000}},{\"minute\":\(minute + 1),\"keys\":{\"1\":600000000000}}"
            ]
            for records in unsafeRecords {
                let url = fixtureURL()
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // A valid first record verifies that failure never leaks a
                // partially loaded archive into the displayed statistics.
                let original = Data("{\"version\":1,\"minutes\":[{\"minute\":\(minute),\"keys\":{\"12\":7}},\(records)]}".utf8)
                try original.write(to: url)
                let store = StatisticsStore(storageURL: url)
                let start = Date(timeIntervalSince1970: Double(minute * 60))
                #expect(store.errorMessage != nil)
                #expect(store.counts(from: start, to: start.addingTimeInterval(120)).isEmpty)
                store.record(keyCode: 49, at: start)
                #expect(store.total(from: start, to: start.addingTimeInterval(120)) == 1)
                #expect(store.sessionCounts == [49: 1])
                store.flush()
                #expect(try Data(contentsOf: url) == original)
            }
        }
    }

    @Test func testSafeArchiveAliasesAndDuplicateMinutesStillMerge() async throws {
        try await MainActor.run {
            let url = fixtureURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("{\"version\":1,\"minutes\":[{\"minute\":30000000,\"keys\":{\"0\":2,\"00\":3,\"1\":4}},{\"minute\":30000000,\"keys\":{\"0\":5}},{\"minute\":30000001,\"keys\":{\"1\":6}}]}".utf8)
            try original.write(to: url)
            let store = StatisticsStore(storageURL: url)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            #expect(store.errorMessage == nil)
            #expect(store.counts(from: start, to: start.addingTimeInterval(120)) == [0: 10, 1: 10])
            #expect(store.total(from: start, to: start.addingTimeInterval(120)) == 20)
            #expect(store.activity(from: start, to: start.addingTimeInterval(120), buckets: 2).map(\.count) == [14, 6])
            store.record(keyCode: 49, at: start)
            store.flush()
            let restored = StatisticsStore(storageURL: url)
            #expect(restored.errorMessage == nil)
            #expect(restored.total(from: start, to: start.addingTimeInterval(120)) == 21)
        }
    }

    @Test func testKeyboardCodesAreUniqueAndMainRowsAligned() {
        #expect(Set(KeyLayout.all.map(\.code)).count == KeyLayout.all.count)
        #expect(KeyLayout.label(for: 49) == "space")
        #expect(KeyLayout.label(for: 56) == "shift")
        #expect(KeyLayout.label(for: 60) == "shift")
        for row in KeyLayout.rows { #expect(abs(row.reduce(0) { $0 + $1.width } - 14.5) < 0.001) }
    }
}
