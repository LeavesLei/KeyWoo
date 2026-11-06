import Foundation
import Testing
@testable import KeyDance

struct RemapStoreTests {
    @Test func legacyProfileLoadsAndNewRulesDoNotOverwriteIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("remapping.json")
        let newURL = dir.appendingPathComponent("remapping-v2.json")
        var legacy = RemapConfiguration.empty
        legacy.version = 1
        legacy.profiles[0].rules = [
            RemapRule(trigger: RemapTrigger(keyCode: 49, modifiers: .fn), action: .media(.playPause))
        ]
        let original = try JSONEncoder().encode(legacy)
        try original.write(to: oldURL)

        let store = RemapStore(url: newURL, legacyURL: oldURL)
        let loaded = try store.load()
        var migrated = try #require(loaded)
        #expect(migrated.version == RemapConfiguration.schemaVersion)
        #expect(migrated.profiles == legacy.profiles)
        #expect(!FileManager.default.fileExists(atPath: newURL.path))
        migrated.profiles[0].rules.append(RemapRule(
            trigger: RemapTrigger(keyCode: RemapMediaAction.nextTrack.triggerCode), action: .media(.brightnessUp)))
        try store.save(migrated)
        let saved = try store.load()
        let preserved = try Data(contentsOf: oldURL)
        #expect(saved == migrated)
        #expect(preserved == original)
    }

    @Test func versionedRoundTripPreservesProfileRulesAndManualSelection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemapStore(url: dir.appendingPathComponent("rules.json"))
        let layer = RemapLayer(name: "Navigation")
        let profile = RemapProfile(name: "HHKB manual", layers: [layer],
            layerKeys: [.init(keyCode: 61, layerID: layer.id)], rules: [
                .init(trigger: .init(keyCode: 49, modifiers: [.fn]), action: .media(.playPause)),
                .init(trigger: .init(keyCode: 4, layerID: layer.id), action: .key(code: 123, modifiers: []))
            ])
        let config = RemapConfiguration(isEnabled: true, profiles: [profile], activeProfileID: profile.id)
        try store.save(config)
        let loaded = try store.load()
        #expect(loaded == config)
        let raw = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!raw.contains("characters") && !raw.contains("eventHistory") && !raw.contains("application"))
    }

    @Test func invalidWriteDoesNotReplacePreviouslyValidConfiguration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemapStore(url: dir.appendingPathComponent("rules.json"))
        let valid = RemapConfiguration.empty
        try store.save(valid)
        var invalid = valid; invalid.version = 999
        var rejected = false
        do { try store.save(invalid) } catch { rejected = true }
        #expect(rejected)
        let loaded = try store.load()
        #expect(loaded == valid)
    }

    @Test func conflictingExactAndWildcardRulesAreRejectedButDisabledRuleIsHarmless() {
        let a = RemapRule(trigger: .init(keyCode: 49, modifiers: [.control], allowsExtraModifiers: true), action: .media(.playPause))
        var b = RemapRule(trigger: .init(keyCode: 49, modifiers: [.control, .shift]), action: .disabled)
        let id = UUID()
        var configuration = RemapConfiguration(profiles: [.init(id: id, name: "test", rules: [a, b])], activeProfileID: id)
        #expect(RemapValidation.issues(in: configuration).contains { $0.severity == .error && $0.ruleIDs.count == 2 })
        b.isEnabled = false; configuration.profiles[0].rules[1] = b
        #expect(!RemapValidation.issues(in: configuration).contains { $0.severity == .error })
    }

    @Test func differentLayersCanReuseKeyAndCapsHoldIsExplicitlyRejected() {
        let layer = RemapLayer(name: "Fn")
        let rule = RemapRule(trigger: .init(keyCode: 0), action: .disabled)
        var layered = rule; layered.id = UUID(); layered.trigger.layerID = layer.id
        let profile = RemapProfile(name: "test", layers: [layer], rules: [rule, layered])
        var configuration = RemapConfiguration(profiles: [profile], activeProfileID: profile.id)
        #expect(!RemapValidation.issues(in: configuration).contains { $0.severity == .error })
        configuration.profiles[0].layerKeys = [.init(keyCode: 57, layerID: layer.id, mode: .hold)]
        #expect(RemapValidation.issues(in: configuration).contains { $0.severity == .error && $0.message.contains("Caps Lock") })
    }

    @Test func emergencyShortcutIsReservedEvenWhenRuleWouldOtherwiseBeValid() {
        let p = RemapProfile(name: "test", rules: [.init(trigger: .init(keyCode: 53, modifiers: [.control, .option, .command]), action: .disabled)])
        let issues = RemapValidation.issues(in: .init(profiles: [p], activeProfileID: p.id))
        #expect(issues.contains { $0.severity == .error && $0.message.contains("紧急") })
    }

    @Test func capsCannotPretendToBeAHeldModifierButTapActionsStayAvailable() {
        func errors(_ action: RemapAction, source: UInt16 = 57) -> [RemapValidationIssue] {
            let p = RemapProfile(name: "test", rules: [.init(trigger: .init(keyCode: source), action: action)])
            return RemapValidation.issues(in: .init(profiles: [p], activeProfileID: p.id)).filter { $0.severity == .error }
        }
        for modifier: UInt16 in [54, 55, 56, 58, 59, 60, 61, 62, 63] {
            #expect(!errors(.key(code: modifier, modifiers: [])).isEmpty)
        }
        #expect(errors(.key(code: 53, modifiers: [])).isEmpty)
        #expect(errors(.key(code: 8, modifiers: [.command])).isEmpty)
        #expect(errors(.media(.playPause)).isEmpty)
        // A hardware/DIP-remapped HHKB Control reports a real Control keycode;
        // it is not restricted merely because its physical keycap says Caps.
        #expect(errors(.key(code: 58, modifiers: []), source: 59).isEmpty)
    }

    @MainActor @Test func queuedGlobalCaptureCannotDismantleInAppShortcutShieldOrResurrectEndedCapture() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        let controller = RemapController(store: RemapStore(url: directory.appendingPathComponent("unused.json")))
        controller.beginCapture()
        defer { controller.endCapture() }
        let commandQ = RemapCapturedKey(keyCode: 12, modifiers: [.command])
        controller.receiveGlobalCapture(commandQ, applicationIsActive: true)
        #expect(controller.lastCapturedKey == nil)
        #expect(controller.isCapturing)
        let nextTrack = RemapCapturedKey(keyCode: RemapMediaAction.nextTrack.triggerCode, modifiers: [])
        controller.receiveGlobalCapture(nextTrack, applicationIsActive: true)
        #expect(controller.lastCapturedKey == nextTrack)
        #expect(controller.lastCapturedKey?.mediaAction == .nextTrack)
        controller.receiveGlobalCapture(commandQ, applicationIsActive: false)
        #expect(controller.lastCapturedKey == commandQ)
        controller.endCapture()
        controller.receiveGlobalCapture(commandQ, applicationIsActive: false)
        #expect(controller.lastCapturedKey == nil && !controller.isCapturing)
    }

    @Test func oversizedAndCorruptImportsCannotBeAccepted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("large.json")
        try Data(repeating: 0x20, count: RemapStore.maximumBytes + 1).write(to: file)
        var rejected = false
        do { _ = try RemapStore.read(from: file) } catch RemapError.fileTooLarge { rejected = true }
        #expect(rejected)
        try Data("not JSON".utf8).write(to: file)
        rejected = false
        do { _ = try RemapStore.read(from: file) } catch { rejected = true }
        #expect(rejected)
    }

    @MainActor @Test func importingEnabledConfigStaysDisabledAndCaptureRetainsNoHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemapStore(url: dir.appendingPathComponent("saved.json"))
        let controller = RemapController(store: store)
        var imported = RemapConfiguration.empty; imported.isEnabled = true
        let source = dir.appendingPathComponent("import.json")
        try RemapStore.write(imported, to: source)
        try controller.importConfiguration(from: source)
        #expect(!controller.isEnabled)
        controller.beginCapture()
        #expect(controller.isCapturing && controller.isSuspended)
        controller.endCapture()
        #expect(!controller.isCapturing && controller.lastCapturedKey == nil)
        let saved = try store.load()
        #expect(saved?.isEnabled == false)
    }

    @MainActor @Test func emergencyDisableStillTakesEffectWhenSavingBecomesImpossible() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("config")
        let store = RemapStore(url: parent.appendingPathComponent("remapping.json"))
        let controller = RemapController(store: store)
        var configuration = controller.configuration; configuration.isEnabled = true
        try controller.apply(configuration: configuration)
        try FileManager.default.removeItem(at: parent)
        try Data("not a directory".utf8).write(to: parent)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        #expect(controller.errorMessage != nil)
    }
}
