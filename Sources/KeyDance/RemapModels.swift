import Foundation

/// Quartz virtual key positions, never characters or entered text. Profiles are
/// manually selected and apply to the session, not to an individual HID device.
struct RemapModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt16
    init(rawValue: UInt16) { self.rawValue = rawValue }
    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let fn = Self(rawValue: 1 << 4)
    static let capsLock = Self(rawValue: 1 << 5)
    static let all: Self = [.shift, .control, .option, .command, .fn, .capsLock]

    static func forKeyCode(_ code: UInt16) -> Self {
        switch code {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 54, 55: return .command
        case 63: return .fn
        case 57: return .capsLock
        default: return []
        }
    }

    var keyCodes: [UInt16] {
        // Stable ordering ensures modifiers go down before their associated key.
        [(Self.control, UInt16(59)), (.option, 58), (.shift, 56), (.command, 55), (.fn, 63)]
            .compactMap { contains($0.0) ? $0.1 : nil }
    }

    var displayLabel: String {
        [(Self.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"), (.fn, "Fn"), (.capsLock, "⇪")]
            .compactMap { contains($0.0) ? $0.1 : nil }.joined(separator: " ")
    }
}

enum RemapMediaAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    case brightnessUp, brightnessDown, keyboardLightUp, keyboardLightDown
    var id: String { rawValue }

    // Auxiliary key types from IOKit/hidsystem/ev_keymap.h. Reserve a separate
    // range in the saved trigger code so these never collide with Quartz keys.
    var nativeKeyType: UInt16 {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        case .mute: return 7
        case .playPause: return 16
        case .nextTrack: return 17
        case .previousTrack: return 18
        case .keyboardLightUp: return 21
        case .keyboardLightDown: return 22
        }
    }
    private static let triggerOffset: UInt16 = 0x100
    static func auxiliaryCode(for nativeKeyType: UInt16) -> UInt16 { triggerOffset + nativeKeyType }
    var triggerCode: UInt16 { Self.auxiliaryCode(for: nativeKeyType) }

    static func forTriggerCode(_ code: UInt16) -> Self? {
        allCases.first { $0.triggerCode == code }
    }
    static func forNativeKeyType(_ type: UInt16) -> Self? {
        // Apple keyboards can report Fast/Rewind on their next/previous keys.
        switch type {
        case 19: return .nextTrack
        case 20: return .previousTrack
        default: return allCases.first { $0.nativeKeyType == type }
        }
    }

    var isDisplayControl: Bool {
        switch self {
        case .brightnessUp, .brightnessDown, .keyboardLightUp, .keyboardLightDown: return true
        default: return false
        }
    }
    var title: String {
        switch self {
        case .playPause: return "播放 / 暂停"
        case .nextTrack: return "下一首"
        case .previousTrack: return "上一首"
        case .volumeUp: return "增加音量"
        case .volumeDown: return "降低音量"
        case .mute: return "静音"
        case .brightnessUp: return "调高屏幕亮度"
        case .brightnessDown: return "调低屏幕亮度"
        case .keyboardLightUp: return "调高键盘背光"
        case .keyboardLightDown: return "调低键盘背光"
        }
    }
}

enum RemapAction: Codable, Equatable, Sendable {
    case key(code: UInt16, modifiers: RemapModifiers)
    case media(RemapMediaAction)
    case disabled
}

struct RemapTrigger: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: RemapModifiers
    var layerID: UUID?
    var allowsExtraModifiers: Bool
    init(keyCode: UInt16, modifiers: RemapModifiers = [], layerID: UUID? = nil,
         allowsExtraModifiers: Bool = false) {
        self.keyCode = keyCode; self.modifiers = modifiers
        self.layerID = layerID; self.allowsExtraModifiers = allowsExtraModifiers
    }
    func matches(_ actual: RemapModifiers) -> Bool {
        allowsExtraModifiers ? actual.isSuperset(of: modifiers) : actual == modifiers
    }
}

struct RemapRule: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var trigger: RemapTrigger
    var action: RemapAction
    var isEnabled: Bool
    init(id: UUID = UUID(), trigger: RemapTrigger, action: RemapAction, isEnabled: Bool = true) {
        self.id = id; self.trigger = trigger; self.action = action; self.isEnabled = isEnabled
    }
}

struct RemapLayer: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

struct RemapLayerKey: Codable, Equatable, Identifiable, Sendable {
    enum Mode: String, Codable, CaseIterable, Sendable { case hold, toggle }
    var id: UUID
    var keyCode: UInt16
    var layerID: UUID
    var mode: Mode
    init(id: UUID = UUID(), keyCode: UInt16, layerID: UUID, mode: Mode = .hold) {
        self.id = id; self.keyCode = keyCode; self.layerID = layerID; self.mode = mode
    }
}

struct RemapProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var layers: [RemapLayer]
    var layerKeys: [RemapLayerKey]
    var rules: [RemapRule]
    init(id: UUID = UUID(), name: String, layers: [RemapLayer] = [],
         layerKeys: [RemapLayerKey] = [], rules: [RemapRule] = []) {
        self.id = id; self.name = name; self.layers = layers
        self.layerKeys = layerKeys; self.rules = rules
    }
}

struct RemapConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    var version: Int
    var platform: String
    var keyCodeSystem: String
    var isEnabled: Bool
    var profiles: [RemapProfile]
    var activeProfileID: UUID
    init(version: Int = schemaVersion, isEnabled: Bool = false,
         profiles: [RemapProfile], activeProfileID: UUID,
         platform: String = "macOS", keyCodeSystem: String = "quartz") {
        self.version = version; self.isEnabled = isEnabled
        self.platform = platform; self.keyCodeSystem = keyCodeSystem
        self.profiles = profiles; self.activeProfileID = activeProfileID
    }
    var activeProfile: RemapProfile? { profiles.first { $0.id == activeProfileID } }
    static var empty: Self {
        let profile = RemapProfile(name: "默认配置")
        return Self(profiles: [profile], activeProfileID: profile.id)
    }
}

struct RemapValidationIssue: Equatable, Identifiable, Sendable {
    enum Severity: String, Sendable { case error, warning }
    var id: String
    var severity: Severity
    var message: String
    var profileID: UUID?
    var ruleIDs: [UUID]
}

enum RemapValidation {
    /// All validation is pure. Ambiguous active rules are errors rather than
    /// relying on list order, which would make a keyboard editor misleading.
    static func issues(in configuration: RemapConfiguration) -> [RemapValidationIssue] {
        var result: [RemapValidationIssue] = []
        func issue(_ text: String, profile: UUID? = nil, rules: [UUID] = [], warning: Bool = false) {
            result.append(.init(id: "\(result.count)", severity: warning ? .warning : .error,
                                message: text, profileID: profile, ruleIDs: rules))
        }
        if configuration.version != RemapConfiguration.schemaVersion { issue("不支持此改键配置版本。") }
        if configuration.platform != "macOS" || configuration.keyCodeSystem != "quartz" {
            issue("此配置不是 macOS Quartz 键码配置，不能直接导入。")
        }
        if configuration.profiles.isEmpty || configuration.profiles.count > 32 {
            issue("配置集数量必须为 1–32。")
            return result
        }
        if Set(configuration.profiles.map(\.id)).count != configuration.profiles.count { issue("配置集标识重复。") }
        if configuration.activeProfile == nil { issue("当前配置集不存在。") }
        for profile in configuration.profiles {
            let p = profile.id
            if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.name.count > 100 {
                issue("配置名称必须为 1–100 个字符。", profile: p)
            }
            if profile.layers.count > 16 || profile.rules.count > 256 || profile.layerKeys.count > 32 {
                issue("每个配置最多 16 层、256 条规则和 32 个层切换键。", profile: p)
                continue
            }
            let layerIDs = Set(profile.layers.map(\.id))
            if layerIDs.count != profile.layers.count { issue("层标识重复。", profile: p) }
            if Set(profile.rules.map(\.id)).count != profile.rules.count { issue("规则标识重复。", profile: p) }
            if Set(profile.layerKeys.map(\.id)).count != profile.layerKeys.count { issue("层切换键标识重复。", profile: p) }
            for layer in profile.layers where layer.name.isEmpty || layer.name.count > 100 {
                issue("层名称必须为 1–100 个字符。", profile: p)
            }
            if Set(profile.layerKeys.map(\.keyCode)).count != profile.layerKeys.count {
                issue("同一个按键不能同时作为多个层切换键。", profile: p)
            }
            for key in profile.layerKeys {
                if key.keyCode > 127 || !layerIDs.contains(key.layerID) { issue("层切换键或目标层无效。", profile: p) }
                if key.keyCode == 57 && key.mode == .hold {
                    issue("Caps Lock 只支持切换层；按住层请使用右 Option 等有按下和松开事件的键。", profile: p)
                }
            }
            if profile.layerKeys.contains(where: { $0.keyCode == 57 }) || profile.rules.contains(where: { $0.isEnabled && $0.trigger.keyCode == 57 }) {
                issue("Caps Lock 映射不会控制键盘指示灯；停用改键后请检查系统大小写锁定状态。", profile: p, warning: true)
            }
            let enabled = profile.rules.filter(\.isEnabled)
            for rule in profile.rules {
                if rule.trigger.keyCode == 53 && rule.trigger.modifiers.isSuperset(of: [.control, .option, .command]) {
                    issue("⌃⌥⌘ Esc 保留用于紧急关闭改键，不能作为规则。", profile: p, rules: [rule.id])
                }
                if (rule.trigger.keyCode > 127 && RemapMediaAction.forTriggerCode(rule.trigger.keyCode) == nil)
                    || !RemapModifiers.all.isSuperset(of: rule.trigger.modifiers) {
                    issue("触发键或修饰键无效。", profile: p, rules: [rule.id])
                }
                if !rule.trigger.modifiers.intersection(RemapModifiers.forKeyCode(rule.trigger.keyCode)).isEmpty {
                    issue("触发键本身的修饰键不应再次选择。", profile: p, rules: [rule.id])
                }
                if let id = rule.trigger.layerID, !layerIDs.contains(id) { issue("规则引用的层不存在。", profile: p, rules: [rule.id]) }
                if rule.isEnabled && profile.layerKeys.contains(where: { $0.keyCode == rule.trigger.keyCode }) {
                    issue("层切换键不能同时作为普通规则的触发键。", profile: p, rules: [rule.id])
                }
                if case let .key(code, modifiers) = rule.action {
                    if rule.trigger.keyCode == 57 && !RemapModifiers.forKeyCode(code).isEmpty {
                        issue("Caps Lock 没有可靠的松开事件，不能映射为按住的修饰键；请选择普通按键、单次组合键、媒体控制或切换层。", profile: p, rules: [rule.id])
                    }
                    if code > 127 || !RemapModifiers.all.isSuperset(of: modifiers) {
                        issue("输出键或修饰键无效。", profile: p, rules: [rule.id])
                    }
                    // Caps is a lock-state toggle, not a releasable output modifier.
                    if code == 57 || modifiers.contains(.capsLock) {
                        issue("暂不支持合成 Caps Lock 锁定状态；可把它作为触发键。", profile: p, rules: [rule.id])
                    }
                }
                if rule.trigger.modifiers.contains(.fn) || rule.trigger.keyCode == 63 {
                    issue("Fn 组合只有在键盘向 macOS 上报 Fn 时才可用；固件内部 Fn 请改用软件层。", profile: p, rules: [rule.id], warning: true)
                }
            }
            for i in enabled.indices {
                for j in enabled.indices where j > i {
                    let a = enabled[i], b = enabled[j]
                    guard a.trigger.keyCode == b.trigger.keyCode && a.trigger.layerID == b.trigger.layerID else { continue }
                    let overlap = a.trigger.modifiers == b.trigger.modifiers
                        || (a.trigger.allowsExtraModifiers && b.trigger.modifiers.isSuperset(of: a.trigger.modifiers))
                        || (b.trigger.allowsExtraModifiers && a.trigger.modifiers.isSuperset(of: b.trigger.modifiers))
                        || (a.trigger.allowsExtraModifiers && b.trigger.allowsExtraModifiers)
                    if overlap { issue("两条已启用规则会匹配同一组合，请停用或修改其中一条。", profile: p, rules: [a.id, b.id]) }
                }
            }
        }
        return result
    }
    static func validate(_ configuration: RemapConfiguration) throws {
        if let issue = issues(in: configuration).first(where: { $0.severity == .error }) {
            throw RemapError.invalidConfiguration(issue.message)
        }
    }
}

enum RemapError: Error, LocalizedError {
    case invalidConfiguration(String)
    case fileTooLarge
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let text): return text
        case .fileTooLarge: return "改键配置文件不能超过 2 MB。"
        }
    }
}
