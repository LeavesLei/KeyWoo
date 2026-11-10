// Render the production statistics view with an isolated, device-free model.
// Build the debug module first with scripts/test.sh, then compile this file with
// -enable-testing -I .build/arm64-apple-macosx/debug/Modules and link the app's
// object files except Launcher.swift.o, plus AudioAtomics.build/*.o. Include the
// generated AudioAtomics module-map directory through -I as well.
import AppKit
import SwiftUI
@testable import KeyDance

private final class PreviewDefaults: UserDefaults {
    private var values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
        super.init(suiteName: "KeyWooStatisticsPreview-\(UUID().uuidString)")!
    }

    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func double(forKey key: String) -> Double { (values[key] as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

@main @MainActor
enum RenderStatisticsPreview {
    private struct Scenario {
        let name: String
        let width: CGFloat
        let language: AppLanguage
        let appearance: AppAppearance
        var empty = false
        var week = false
        var pinnedKey: UInt16?
        var search = ""
        var invalidRange = false
        var oneMinute = false
        var showAllKeys = false
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "StatisticsPreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Provide an output directory."])
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let previousLanguage = AppLocalization.language
        defer { AppLocalization.language = previousLanguage }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 17, minute: 43))!
        let scenarios = [
            Scenario(name: "populated-zh-light-706", width: 706, language: .simplifiedChinese, appearance: .light, pinnedKey: 49),
            Scenario(name: "populated-zh-light-866", width: 866, language: .simplifiedChinese, appearance: .light),
            Scenario(name: "populated-en-light-866", width: 866, language: .english, appearance: .light, pinnedKey: 56),
            Scenario(name: "populated-en-dark-866", width: 866, language: .english, appearance: .dark),
            Scenario(name: "populated-zh-dark-1100", width: 1100, language: .simplifiedChinese, appearance: .dark),
            Scenario(name: "week-zh-light-866", width: 866, language: .simplifiedChinese, appearance: .light, week: true),
            Scenario(name: "empty-zh-light-706", width: 706, language: .simplifiedChinese, appearance: .light, empty: true),
            Scenario(name: "empty-en-dark-866", width: 866, language: .english, appearance: .dark, empty: true),
            Scenario(name: "search-no-results-en-light-706", width: 706, language: .english, appearance: .light, search: "no-matching-key"),
            Scenario(name: "search-modifiers-en-light-706", width: 706, language: .english, appearance: .light, search: "Shift", showAllKeys: true),
            Scenario(name: "invalid-range-zh-light-706", width: 706, language: .simplifiedChinese, appearance: .light, invalidRange: true),
            Scenario(name: "one-minute-zh-light-706", width: 706, language: .simplifiedChinese, appearance: .light, pinnedKey: 49, oneMinute: true),
            Scenario(name: "zero-keys-en-dark-706", width: 706, language: .english, appearance: .dark, empty: true, pinnedKey: 49, showAllKeys: true)
        ]
        var rendered: [[String: Any]] = []
        for scenario in scenarios {
            let directory = output.appendingPathComponent("fixture-" + scenario.name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent("statistics.json")
            try writeArchive(to: archive, now: now, calendar: calendar, empty: scenario.empty)
            let initialData = try Data(contentsOf: archive)
            let model = AppModel(
                defaults: PreviewDefaults(["appLanguage": scenario.language.rawValue,
                                           "appAppearance": scenario.appearance.rawValue]),
                statistics: StatisticsStore(storageURL: archive),
                music: LocalMusicStore(directory: directory.appendingPathComponent("Music")),
                audioEngine: SoundEngine(audioDeviceEnabled: false),
                keyboardAudioEngine: KeyboardSoundEngine(audioDeviceEnabled: false),
                startsKeyboardMonitor: false,
                remapController: RemapController(store: RemapStore(url: directory.appendingPathComponent("remapping.json"))))
            defer { model.shutdown() }
            model.now = now
            model.page = .statistics
            let presentation = StatisticsPresentationState()
            if scenario.week { presentation.range = .week }
            presentation.selectedKey = scenario.pinnedKey
            presentation.search = scenario.search
            presentation.showAllKeys = scenario.showAllKeys
            if scenario.invalidRange || scenario.oneMinute {
                presentation.range = .custom
                presentation.from = now.addingTimeInterval(scenario.oneMinute ? -60 : 60)
                presentation.to = now
            }
            let view = StatisticsView(model: model, presentation: presentation)
                .padding(24)
                .frame(width: scenario.width)
                .frame(minHeight: 640, alignment: .top)
                .background(Palette.background)
                .foregroundStyle(Palette.ink)
                .tint(Palette.accent)
                .preferredColorScheme(scenario.appearance.preferredColorScheme)
                .environment(\.locale, AppLocalization.locale)
            let png = output.appendingPathComponent(scenario.name + ".png")
            let size = try capture(view: AnyView(view), width: scenario.width, model: model, now: now, output: png)
            guard try Data(contentsOf: archive) == initialData else {
                throw NSError(domain: "StatisticsPreview", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Preview changed its statistics fixture."])
            }
            rendered.append(["file": png.lastPathComponent, "width": size.width, "height": size.height,
                             "empty": scenario.empty, "language": scenario.language.rawValue,
                             "appearance": scenario.appearance.rawValue, "search": scenario.search,
                             "showAllKeys": scenario.showAllKeys, "invalidRange": scenario.invalidRange,
                             "oneMinute": scenario.oneMinute])
        }
        let manifest: [String: Any] = ["fixtureDate": now.timeIntervalSince1970,
                                        "keyboardMonitoringStarted": false, "audioDeviceStarted": false,
                                        "realPreferencesUsed": false, "renders": rendered]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("preview-manifest.json"))
        print("Rendered \(rendered.count) isolated statistics previews in \(output.path)")
    }

    private static func capture(view: AnyView, width: CGFloat, model: AppModel,
                                now: Date, output: URL) throws -> CGSize {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: model.appearance == .dark ? .darkAqua : .aqua)
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: 1400)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        // Attaching to an offscreen window supplies native controls and Charts
        // with their usual AppKit context, without showing or activating a window.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        for _ in 0..<4 {
            model.now = now
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        model.now = now
        let height = max(640, ceil(hosting.fittingSize.height))
        hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.setContentSize(hosting.frame.size)
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "StatisticsPreview", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate a statistics bitmap."])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "StatisticsPreview", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode the statistics bitmap."])
        }
        try png.write(to: output)
        window.contentView = nil
        return hosting.frame.size
    }

    private static func writeArchive(to url: URL, now: Date, calendar: Calendar, empty: Bool) throws {
        var records: [[String: Any]] = []
        if !empty {
            let keys: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 14, 13, 15, 17, 31, 32, 49, 36, 51, 55, 56, 123, 124, 122]
            for day in 0..<7 {
                let date = calendar.date(byAdding: .day, value: -day, to: now)!
                let start = calendar.startOfDay(for: date)
                for minuteOfDay in stride(from: 8 * 60, through: 17 * 60 + 42, by: 3) {
                    guard !(minuteOfDay > 11 * 60 + 20 && minuteOfDay < 13 * 60 + 10) else { continue }
                    let instant = start.addingTimeInterval(Double(minuteOfDay * 60))
                    guard instant <= now else { continue }
                    let unixMinute = Int(floor(instant.timeIntervalSince1970 / 60))
                    let wave = 0.45 + 0.55 * abs(sin(Double(minuteOfDay + day * 17) * 0.021))
                    var counts: [String: Int] = [:]
                    for (index, code) in keys.enumerated() {
                        let base = code == 49 ? 23 : max(1, 13 - index / 2)
                        let count = Int(Double(base) * wave) + ((minuteOfDay + index + day) % 5 == 0 ? 3 : 0)
                        if count > 0 { counts[String(code)] = count }
                    }
                    records.append(["minute": unixMinute, "keys": counts])
                }
            }
        }
        let archive: [String: Any] = ["version": 1, "minutes": records]
        try JSONSerialization.data(withJSONObject: archive, options: [.sortedKeys]).write(to: url)
    }
}
