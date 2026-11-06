import AVFoundation
import Foundation

// Standalone offline harness: no preferences, input hooks or audio device.
func L(_ text: String) -> String { text }

@main struct KeyboardLoudnessQA {
    @MainActor static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "dist/qa/keyboard-loudness")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let started = ProcessInfo.processInfo.systemUptime
        let probe = KeyboardSoundEngine(audioDeviceEnabled: false)
        let preparation = ProcessInfo.processInfo.systemUptime - started
        // Held-out ordinary keys + each large key, slow and dense typing with
        // realistic staggered releases. No per-preset choice of test sequence.
        let keys: [UInt16] = [0, 14, 1, 17, 49, 2, 32, 3, 49, 51, 36, 48, 56, 40, 45, 46]
        var events: [(Int, UInt16, Bool)] = []
        var cursor = 0
        for i in 0..<96 {
            let interval = [7_200, 6_000, 5_400, 4_800, 3_600, 2_400][i % 6]
            let key = keys[i % keys.count]
            events.append((cursor, key, true)); events.append((cursor + min(interval - 64, 2_880), key, false))
            cursor += interval
        }
        events.sort { $0.0 == $1.0 ? !$0.2 : $0.0 < $1.0 }
        let totalFrames = cursor + 24_000
        var rows: [[String: Any]] = []
        for style in KeyboardSoundStyle.allCases {
            let profile = probe.loudnessProfile(for: style)!
            var row: [String: Any] = ["style": style.rawValue, "gain": profile.gain,
                "gainDB": 20 * log10(Double(profile.gain)), "sourceEventRMS": profile.measuredRMS,
                "sourcePeak": profile.sourcePeak]
            for normalized in [false, true] {
                let engine = KeyboardSoundEngine(audioDeviceEnabled: false, normalizationEnabled: normalized)
                engine.style = style; engine.volume = 1; engine.start()
                var pcm: [Float] = [], position = 0
                let renderStart = ProcessInfo.processInfo.systemUptime
                for (time, key, down) in events {
                    if time > position { pcm += engine.renderForVerification(frames: time - position); position = time }
                    if down { engine.noteOn(keyCode: key) } else { engine.noteOff(keyCode: key) }
                }
                pcm += engine.renderForVerification(frames: totalFrames - position)
                let renderSeconds = ProcessInfo.processInfo.systemUptime - renderStart
                let measurement = pcm.withUnsafeBufferPointer {
                    KeyboardLoudness.measure(samples: $0.baseAddress!, frames: pcm.count / 2, channels: 2)
                }
                let prefix = normalized ? "after" : "before"
                row[prefix + "ScoreDB"] = 10 * log10(measurement.energy)
                let energy = pcm.reduce(0.0) { $0 + Double($1) * Double($1) }
                row[prefix + "RMS"] = sqrt(energy / Double(pcm.count))
                row[prefix + "Peak"] = measurement.peak
                row[prefix + "RenderSeconds"] = renderSeconds
                precondition(pcm.allSatisfy(\.isFinite) && measurement.peak < 0.420001)
                precondition(engine.diagnostics.attacks == 96 && engine.diagnostics.releases == 96)
                precondition(engine.diagnostics.droppedEvents == 0)
                precondition(pcm.suffix(4_800).allSatisfy { $0 == 0 })
                engine.stop()
            }
            // Independent, nonuniform worst-case pattern: big keys dominate,
            // 0–20 ms gaps, every clip alternate, maximum 1600% output.
            let dense = KeyboardSoundEngine(audioDeviceEnabled: false)
            dense.style = style; dense.volume = 16; dense.start()
            var seed: UInt64 = 0x4B6579576F6F, stressPeak: Float = 0, worstRender = 0.0
            let stressKeys: [UInt16] = [49, 36, 51, 48, 56, 49, 36, 51, 0, 14, 32, 45]
            let left = UnsafeMutablePointer<Float>.allocate(capacity: 960)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: 960)
            for _ in 0..<256 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                let key = stressKeys[Int((seed >> 32) % UInt64(stressKeys.count))]
                dense.noteOn(keyCode: key); dense.noteOff(keyCode: key)
                let frames = [64, 96, 128, 256, 960][Int((seed >> 40) % 5)]
                let start = ProcessInfo.processInfo.systemUptime
                dense.renderIntoForVerification(frames: frames, left: left, right: right)
                worstRender = max(worstRender, ProcessInfo.processInfo.systemUptime - start)
                for i in 0..<frames {
                    precondition(left[i].isFinite && right[i].isFinite)
                    stressPeak = max(stressPeak, abs(left[i]), abs(right[i]))
                }
            }
            left.deallocate(); right.deallocate()
            precondition(stressPeak < 0.980001)
            precondition(dense.diagnostics.attacks == 256 && dense.diagnostics.releases == 256)
            precondition(dense.diagnostics.droppedEvents == 0 && dense.heldKeyCount == 0)
            precondition(dense.renderForVerification(frames: 48_000).suffix(9_600).allSatisfy { $0 == 0 })
            row["randomDensePeakAt1600"] = stressPeak
            row["randomDenseWorstRenderSeconds"] = worstRender
            row["randomDenseAttacks"] = dense.diagnostics.attacks
            row["randomDenseDropped"] = dense.diagnostics.droppedEvents
            dense.stop()
            rows.append(row)
        }
        let before = rows.compactMap { $0["beforeScoreDB"] as? Double }
        let after = rows.compactMap { $0["afterScoreDB"] as? Double }
        let summary: [String: Any] = ["scope": "96 identical strokes per preset, production offline mixer, K-weighted event-energy proxy, not LUFS/SPL/device latency", "bankPreparationSeconds": preparation,
            "beforeSpreadDB": before.max()! - before.min()!, "afterSpreadDB": after.max()! - after.min()!, "rows": rows]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("normalization.json"), options: .atomic)
        for row in rows {
            print(String(format: "%@ gain %.3f (%+.1f dB) before %.2f after %.2f peak %.3f", row["style"] as! String,
                (row["gain"] as! Float), row["gainDB"] as! Double, row["beforeScoreDB"] as! Double,
                row["afterScoreDB"] as! Double, row["afterPeak"] as! Double))
        }
        print("Spread dB", before.max()! - before.min()!, "→", after.max()! - after.min()!, "bank preparation", preparation)
    }
}
