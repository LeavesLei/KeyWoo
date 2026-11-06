import Foundation
import Darwin

@main
enum RemapSoakMain {
    private struct Status: Codable {
        var status: String
        var pid: Int32
        var startedUTC: String
        var updatedUTC: String
        var earliestCompletionUTC: String
        var targetQualifiedSeconds: Double
        var qualifiedElapsedSeconds: Double
        var wallElapsedSeconds: Double
        var excludedGapSeconds: Double
        var gapCount: Int
        var iterations: UInt64
        var validatedInputEvents: UInt64
        var lastSeed: UInt64
        var currentRSSBytes: UInt64
        var peakRSSBytes: UInt64
        var maximumExerciseMilliseconds: Double
        var failure: String?
        let scope = "pure state machine; no event tap, OS event posting, permission prompt, audio, or user configuration access"
    }
    static func main() {
        guard CommandLine.arguments.count == 3,
              let duration = Double(CommandLine.arguments[1]), duration >= 1 else {
            fputs("Usage: remap-soak <qualified-seconds> <output-directory>\n", stderr)
            exit(2)
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let started = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var state = Status(status: "running", pid: getpid(), startedUTC: iso.string(from: started),
            updatedUTC: iso.string(from: started), earliestCompletionUTC: iso.string(from: started.addingTimeInterval(duration)),
            targetQualifiedSeconds: duration, qualifiedElapsedSeconds: 0, wallElapsedSeconds: 0,
            excludedGapSeconds: 0, gapCount: 0, iterations: 0, validatedInputEvents: 0, lastSeed: 0,
            currentRSSBytes: 0, peakRSSBytes: 0, maximumExerciseMilliseconds: 0)
        func save(_ name: String) throws {
            try encoder.encode(state).write(to: output.appendingPathComponent(name), options: .atomic)
        }
        var previousTicks = DispatchTime.now().uptimeNanoseconds
        var previousWall = started
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try save("run.json")
            while state.qualifiedElapsedSeconds < duration {
                try autoreleasepool {
                let ticks = DispatchTime.now().uptimeNanoseconds
                let now = Date()
                let monotonicDelta = Double(ticks - previousTicks) / 1_000_000_000
                let wallDelta = now.timeIntervalSince(previousWall)
                // A sleep or descheduling gap never counts as tested uptime.
                // Wall time is only a guard against sleep behavior of the clock;
                // accumulated qualifying time always comes from monotonic ticks.
                if monotonicDelta <= 2 && wallDelta >= 0 && wallDelta <= 2 {
                    state.qualifiedElapsedSeconds += monotonicDelta
                } else {
                    state.gapCount += 1
                    state.excludedGapSeconds += max(0, monotonicDelta, wallDelta)
                }
                previousTicks = ticks; previousWall = now
                let seed = UInt64(20261106) &+ state.iterations &* 0x9E3779B97F4A7C15
                let begin = DispatchTime.now().uptimeNanoseconds
                let checked = try RemapSoakVerifier.exercise(seed: seed)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000
                state.maximumExerciseMilliseconds = max(state.maximumExerciseMilliseconds, ms)
                state.iterations += 1
                state.lastSeed = seed
                state.validatedInputEvents += UInt64(checked)
                state.updatedUTC = iso.string(from: Date())
                state.wallElapsedSeconds = Date().timeIntervalSince(started)
                state.currentRSSBytes = currentRSS()
                state.peakRSSBytes = max(state.peakRSSBytes, state.currentRSSBytes)
                try save("state.json")
                if state.iterations == 1 || state.iterations % 60 == 0 {
                    print("validated=\(state.validatedInputEvents) iterations=\(state.iterations) qualified=\(String(format: "%.2f", state.qualifiedElapsedSeconds))s rss=\(state.currentRSSBytes)")
                    fflush(stdout)
                }
                if state.qualifiedElapsedSeconds < duration { Thread.sleep(forTimeInterval: 1) }
                }
            }
            state.status = "passed"
            state.updatedUTC = iso.string(from: Date())
            try save("state.json"); try save("result.json")
            print("PASS: \(state.iterations) iterations, \(state.validatedInputEvents) validated input events, \(state.qualifiedElapsedSeconds) qualifying wall-clock seconds")
        } catch {
            state.status = "failed"; state.failure = String(describing: error)
            state.updatedUTC = iso.string(from: Date())
            try? save("state.json"); try? save("result.json")
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
    private static func currentRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
