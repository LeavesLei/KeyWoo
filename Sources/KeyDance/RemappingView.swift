import SwiftUI
import AppKit
import UniformTypeIdentifiers

private enum RemapKeyName {
    static let additional = [KeyDescriptor(105, "F13"), KeyDescriptor(107, "F14"),
                             KeyDescriptor(113, "F15"), KeyDescriptor(106, "F16"),
                             KeyDescriptor(64, "F17"), KeyDescriptor(79, "F18"),
                             KeyDescriptor(80, "F19"), KeyDescriptor(90, "F20")]
    static let functionKeys = Array(KeyLayout.extra.prefix(13).dropFirst()) + additional
    static let standardKeys = KeyLayout.all.filter { key in !functionKeys.contains { $0.code == key.code } }
    static let keys = standardKeys + functionKeys

    static func name(_ code: UInt16) -> String {
        if let action = RemapMediaAction.forTriggerCode(code) { return L(action.title) }
        switch code {
        case 54: return L("右 Command")
        case 55: return "⌘ Command"
        case 56: return "⇧ Shift"
        case 60: return L("右 Shift")
        case 58: return "⌥ Option / Alt"
        case 61: return L("右 Option / Alt")
        case 59: return "⌃ Control"
        case 62: return L("右 Control")
        case 63: return "Fn / 🌐"
        case 57: return "Caps Lock"
        case 49: return "Space"
        default: return keys.first { $0.code == code }?.label.uppercased() ?? "Key \(code)"
        }
    }
    static func trigger(_ value: RemapTrigger) -> String {
        [value.modifiers.displayLabel, name(value.keyCode)].filter { !$0.isEmpty }.joined(separator: " + ")
    }
    static func action(_ action: RemapAction) -> String {
        switch action {
        case .key(let code, let mods): return [mods.displayLabel, name(code)].filter { !$0.isEmpty }.joined(separator: " + ")
        case .media(let media): return L(media.title)
        case .disabled: return L("禁用此键")
        }
    }
}

struct RemappingView: View {
    @ObservedObject private var controller: RemapController
    @State private var layerID: UUID?
    @State private var editing: RemapRule?
    @State private var addingLayer = false
    @State private var addingProfile = false
    @State private var profileName = ""
    @State private var message: String?
    @State private var pendingRemoval: Removal?
    @State private var showingRemovalConfirmation = false

    private enum Removal {
        case rule(RemapRule), layer(UUID), profile(UUID)
    }

    init(model: AppModel) { controller = model.remapping }
    private var profile: RemapProfile { controller.configuration.activeProfile! }
    private var rules: [RemapRule] { profile.rules.filter { $0.trigger.layerID == layerID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            activationBar
            if let text = message ?? controller.errorMessage {
                Label(L(text), systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("remap-error")
            }
            rulesSection
            DisclosureGroup {
                RemapKeyboardGrid(rules: rules, layerKeys: profile.layerKeys, select: editKey)
                    .padding(.top, 12)
            } label: {
                Label(L("键盘布局"), systemImage: "keyboard")
                    .font(.system(size: 13, weight: .medium))
            }
            .disclosureGroupStyle(FullRowDisclosureStyle(horizontalPadding: 14, contentBottomPadding: 14))
            .cardStyle()
            .accessibilityIdentifier("remap-keyboard-layout")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    compatibilityHelp
                    Spacer(minLength: 12)
                    emergencyHint
                }
                VStack(alignment: .leading, spacing: 8) {
                    compatibilityHelp
                    emergencyHint
                }
            }
            .padding(.horizontal, 4)
        }
        .sheet(item: $editing) { rule in
            RemapRuleEditor(controller: controller, rule: rule, save: saveRule)
        }
        .sheet(isPresented: $addingLayer) {
            RemapLayerEditor { layer, key in
                var config = controller.configuration
                guard let i = config.profiles.firstIndex(where: { $0.id == config.activeProfileID }) else { return }
                config.profiles[i].layers.append(layer); config.profiles[i].layerKeys.append(key)
                try controller.apply(configuration: config)
                layerID = layer.id
            }
        }
        .alert(L("新建方案"), isPresented: $addingProfile) {
            TextField(L("方案名称"), text: $profileName)
            Button(L("取消"), role: .cancel) {}
            Button(L("创建")) { createProfile() }
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(removalTitle, isPresented: $showingRemovalConfirmation) {
            Button(L("取消"), role: .cancel) { pendingRemoval = nil }
            Button(L("删除"), role: .destructive) { confirmRemoval() }
        } message: {
            Text(removalMessage)
        }
        .onChange(of: controller.configuration) { old, new in
            if old.activeProfileID != new.activeProfileID
                || (layerID != nil && !new.activeProfile!.layers.contains(where: { $0.id == layerID })) { layerID = nil }
        }
        .onDisappear { controller.endCapture() }
    }

    private var compatibilityHelp: some View {
        HStack(spacing: 4) {
            Text(L("键盘兼容性")).font(.system(size: 12)).foregroundStyle(Palette.muted)
            InfoHelpButton(title: "键盘兼容性", message: "改键在电脑上生效，不会写入键盘。Matrix、HHKB 等键盘都使用系统收到的按键；不同键盘共用当前方案。部分 Fn、厂商专用键和系统保留快捷键可能无法改动。方案只保存按键规则，不记录输入文字；导入后需手动启用。", identifier: "remap-compatibility-help")
        }
    }
    private var emergencyHint: some View {
        Text(L("⌃⌥⌘ Esc：立即关闭改键"))
            .font(.system(size: 12)).foregroundStyle(Palette.muted)
    }

    private var activationBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    activationLabel
                    Spacer(minLength: 8)
                    activationControls
                }
                VStack(alignment: .leading, spacing: 12) {
                    activationLabel
                    HStack { Spacer(minLength: 0); activationControls }
                }
            }
            if !controller.hasAccessibilityAccess {
                Text(L("可先编辑规则，授权后再启用。"))
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).cardStyle()
    }
    private var activationLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: controller.hasAccessibilityAccess ? "keyboard" : "hand.raised")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(controller.isActive || !controller.hasAccessibilityAccess ? Palette.accent : Palette.muted)
                .frame(width: 30, height: 30)
                .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(L(activationStatus)).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            InfoHelpButton(title: "启用改键", message: "先添加按键替换规则，再打开「启用改键」。替换其他应用的按键需要 macOS 辅助功能权限；暂不授权也可以编辑。密码等安全输入期间会暂停改键。右上角暂停声音不会关闭改键。", identifier: "remap-activation-help")
        }
    }
    private var activationControls: some View {
        HStack(spacing: 12) {
            if !controller.hasAccessibilityAccess {
                Button(L("授权改键")) { controller.requestAccessibility(); controller.openAccessibilitySettings() }
                    .accessibilityIdentifier("remap-permission")
            }
            Toggle(L("启用改键"), isOn: Binding(get: { controller.isEnabled }, set: { controller.setEnabled($0) }))
                .toggleStyle(.switch).fixedSize().accessibilityIdentifier("remap-enabled")
                .disabled(!controller.hasAccessibilityAccess && !controller.isEnabled)
        }
        .fixedSize()
    }
    private var activationStatus: String {
        if !controller.hasAccessibilityAccess { return "改键需要授权" }
        if controller.isEnabled && controller.secureInputActive { return "安全输入中，改键暂停" }
        if controller.isEnabled && controller.isSuspended { return "改键暂时暂停" }
        if controller.isActive { return "改键已生效" }
        return controller.isEnabled ? "改键尚未生效" : "改键已关闭"
    }
    private var profilePicker: some View {
        Picker(L("方案"), selection: Binding(get: { controller.configuration.activeProfileID }, set: { id in
            do { try controller.selectProfile(id); message = nil } catch { message = error.localizedDescription }
        })) {
            ForEach(controller.configuration.profiles) { item in
                Text(item.name == "默认配置" ? L("默认方案") : item.name).tag(item.id)
            }
        }
        .frame(maxWidth: 240).accessibilityIdentifier("remap-profile")
    }
    private var rulesToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                profileAndLayerPickers.frame(minWidth: 320)
                Spacer(minLength: 12)
                configurationActions
            }
            VStack(alignment: .leading, spacing: 10) {
                profileAndLayerPickers
                HStack { Spacer(minLength: 0); configurationActions }
            }
        }
    }
    private var profileAndLayerPickers: some View {
        HStack(spacing: 12) {
            profilePicker
            Picker(L("键位组"), selection: $layerID) {
                Text(L("默认键位")).tag(UUID?.none)
                ForEach(profile.layers) { layer in Text(layer.name).tag(Optional(layer.id)) }
            }
            .frame(maxWidth: 188).accessibilityIdentifier("remap-layer")
            InfoHelpButton(title: "方案与键位组", message: "方案是一整套改键设置，可为不同键盘手动切换。键位组是一组额外规则：例如按住右 Option 时，让 H、J、K、L 变成方向键。启用按键会被用来切换键位组，未设置的键保持原样。", identifier: "remap-profile-help")
        }
    }
    private var configurationActions: some View {
        HStack(spacing: 12) {
            Menu(L("常用组合")) {
                Button("Fn + Space → \(L("播放 / 暂停"))") { addMediaTemplate(.fn) }
                Button("⌃⌥ Space → \(L("播放 / 暂停"))") { addMediaTemplate([.control, .option]) }
                Button(L("右 Option + HJKL → 方向键")) { addNavigationLayer() }
            }.fixedSize().accessibilityIdentifier("remap-templates")
            Menu {
                Button(L("新建方案")) { profileName = ""; addingProfile = true }
                    .accessibilityIdentifier("remap-add-profile")
                Button(L("添加键位组")) { addingLayer = true }
                    .accessibilityIdentifier("remap-add-layer")
                Divider()
                Button(L("导入方案…")) { importFile() }
                Button(L("导出方案…")) { exportFile() }
                if layerID != nil || controller.configuration.profiles.count > 1 {
                    Divider()
                    if let layerID { Button(L("删除键位组"), role: .destructive) { requestRemoval(.layer(layerID)) } }
                    if controller.configuration.profiles.count > 1 {
                        Button(L("删除当前方案"), role: .destructive) { requestRemoval(.profile(profile.id)) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
                .menuIndicator(.hidden).fixedSize()
                .help(L("管理方案")).accessibilityLabel(L("管理方案"))
        }
    }
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(L("规则")).font(.system(size: 17, weight: .semibold))
                Text(rules.count, format: .number)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Palette.raisedSurface, in: Capsule())
                Spacer()
                Button { editing = RemapRule(trigger: .init(keyCode: 49, modifiers: .fn, layerID: layerID), action: .media(.playPause)) }
                    label: { Label(L("添加规则"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("remap-add-rule")
            }
            rulesToolbar
            Divider()
            ruleList
        }.padding(16).cardStyle()
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 5) {
            if rules.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Text(L("还没有改键。点击「添加规则」开始，其他键保持不变。"))
                        .font(.system(size: 13)).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 24).frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    Text(L("按下")).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").hidden().accessibilityHidden(true)
                    Text(L("改成")).frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil").hidden().accessibilityHidden(true)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.leading, 10).padding(.trailing, 93).padding(.bottom, 2)
            }
            ForEach(rules) { rule in
                RemapRuleRow(rule: rule, edit: { editing = rule }, setEnabled: { enabled in
                    changeProfile { profile in
                        if let i = profile.rules.firstIndex(where: { $0.id == rule.id }) {
                            profile.rules[i].isEnabled = enabled
                        }
                    }
                }, remove: {
                    requestRemoval(.rule(rule))
                })
            }
            if !visibleLayerKeys.isEmpty {
                Divider().padding(.vertical, 7)
                HStack(spacing: 4) {
                    Text(L("键位组")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                    InfoHelpButton(title: "方案与键位组", message: "方案是一整套改键设置，可为不同键盘手动切换。键位组是一组额外规则：例如按住右 Option 时，让 H、J、K、L 变成方向键。启用按键会被用来切换键位组，未设置的键保持原样。", identifier: "remap-layer-list-help")
                }.padding(.leading, 10)
                ForEach(visibleLayerKeys) { key in
                    if layerID == key.layerID {
                        layerKeyLabel(key, navigable: false)
                    } else {
                        Button { layerID = key.layerID } label: {
                            layerKeyLabel(key, navigable: true)
                        }
                        .buttonStyle(.plain)
                        .background(Palette.raisedSurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("remap-layer-key-\(key.id)")
                    }
                }
            }
        }
    }

    private var visibleLayerKeys: [RemapLayerKey] {
        profile.layerKeys.filter { layerID == nil || $0.layerID == layerID }
    }

    private func layerKeyLabel(_ key: RemapLayerKey, navigable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.3.layers.3d").foregroundStyle(Palette.accent).frame(width: 18)
            Text(RemapKeyName.name(key.keyCode)).fontWeight(.medium)
            Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
            Text(profile.layers.first { $0.id == key.layerID }?.name ?? "")
            Spacer(minLength: 8)
            Text(L(key.mode == .hold ? "按住时启用" : "按一次切换")).foregroundStyle(Palette.muted)
            if navigable {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.muted)
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 10).frame(minHeight: 40)
        .frame(maxWidth: .infinity).contentShape(Rectangle())
    }

    private var removalTitle: String {
        switch pendingRemoval {
        case .rule: return L("删除这条规则？")
        case .layer: return L("删除键位组？")
        case .profile: return L("删除当前方案？")
        case nil: return ""
        }
    }

    private var removalMessage: String {
        switch pendingRemoval {
        case .rule(let rule):
            return "\(RemapKeyName.trigger(rule.trigger)) → \(RemapKeyName.action(rule.action))"
        case .layer:
            return L("组内规则和启用按键也会一并删除，其他键位不受影响。")
        case .profile:
            return L("此方案的全部规则和键位组会一并删除。")
        case nil: return ""
        }
    }

    private func requestRemoval(_ removal: Removal) {
        pendingRemoval = removal
        showingRemovalConfirmation = true
    }

    private func confirmRemoval() {
        guard let removal = pendingRemoval else { return }
        pendingRemoval = nil
        switch removal {
        case .rule(let rule): changeProfile { $0.rules.removeAll { $0.id == rule.id } }
        case .layer(let id):
            guard layerID == id else { return }
            removeLayer()
        case .profile(let id):
            guard profile.id == id else { return }
            removeProfile()
        }
    }

    private func changeProfile(_ mutation: (inout RemapProfile) -> Void) {
        var config = controller.configuration
        guard let i = config.profiles.firstIndex(where: { $0.id == config.activeProfileID }) else { return }
        mutation(&config.profiles[i])
        do { try controller.apply(configuration: config); message = nil }
        catch { message = error.localizedDescription }
    }
    private func saveRule(_ candidate: RemapRule) throws {
        var config = controller.configuration
        guard let i = config.profiles.firstIndex(where: { $0.id == config.activeProfileID }) else { return }
        if let j = config.profiles[i].rules.firstIndex(where: { $0.id == candidate.id }) { config.profiles[i].rules[j] = candidate }
        else { config.profiles[i].rules.append(candidate) }
        try controller.apply(configuration: config)
        message = nil
    }
    private func editKey(_ code: UInt16) {
        if let key = profile.layerKeys.first(where: { $0.keyCode == code }) { layerID = key.layerID; return }
        editing = rules.first { $0.trigger.keyCode == code && $0.isEnabled }
            ?? rules.first { $0.trigger.keyCode == code }
            ?? RemapRule(trigger: .init(keyCode: code, layerID: layerID, allowsExtraModifiers: true), action: .key(code: code, modifiers: []))
    }
    private func createProfile() {
        var config = controller.configuration
        let item = RemapProfile(name: profileName.trimmingCharacters(in: .whitespacesAndNewlines))
        config.profiles.append(item); config.activeProfileID = item.id
        do { try controller.apply(configuration: config); message = nil } catch { message = error.localizedDescription }
    }
    private func removeProfile() {
        var config = controller.configuration
        guard config.profiles.count > 1 else { return }
        config.profiles.removeAll { $0.id == config.activeProfileID }; config.activeProfileID = config.profiles[0].id
        do { try controller.apply(configuration: config); message = nil } catch { message = error.localizedDescription }
    }
    private func removeLayer() {
        guard let id = layerID else { return }
        changeProfile { p in p.layers.removeAll { $0.id == id }; p.layerKeys.removeAll { $0.layerID == id }; p.rules.removeAll { $0.trigger.layerID == id } }
        if !profile.layers.contains(where: { $0.id == id }) { layerID = nil }
    }
    private func addMediaTemplate(_ modifiers: RemapModifiers) {
        if let existing = profile.rules.first(where: { $0.trigger.layerID == nil && $0.trigger.keyCode == 49 && $0.trigger.modifiers == modifiers }) {
            layerID = nil
            var draft = existing
            draft.action = .media(.playPause)
            editing = draft
            return
        }
        changeProfile { $0.rules.append(.init(trigger: .init(keyCode: 49, modifiers: modifiers), action: .media(.playPause))) }
        if message == nil { layerID = nil }
    }
    private func addNavigationLayer() {
        if let existing = profile.layerKeys.first(where: { $0.keyCode == 61 }) {
            layerID = existing.layerID
            message = "右 Option 已用于此键位组，可在下方编辑规则。"
            return
        }
        let layer = RemapLayer(name: L("方向键组"))
        changeProfile { p in
            p.layers.append(layer); p.layerKeys.append(.init(keyCode: 61, layerID: layer.id))
            for (source, target): (UInt16, UInt16) in [(4, 123), (38, 125), (40, 126), (37, 124)] {
                p.rules.append(.init(trigger: .init(keyCode: source, layerID: layer.id, allowsExtraModifiers: true), action: .key(code: target, modifiers: [])))
            }
        }
        if profile.layers.contains(where: { $0.id == layer.id }) { layerID = layer.id }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.importConfiguration(from: url); message = nil } catch { message = error.localizedDescription }
    }
    private func exportFile() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "KeyWoo-keymap.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.exportConfiguration(to: url); message = nil } catch { message = error.localizedDescription }
    }
}

private struct RemapRuleRow: View {
    let rule: RemapRule
    let edit: () -> Void
    let setEnabled: (Bool) -> Void
    let remove: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: edit) {
                HStack(spacing: 10) {
                    Text(RemapKeyName.trigger(rule.trigger)).fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Text(RemapKeyName.action(rule.action))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil").foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                .font(.system(size: 13)).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(rule.isEnabled ? Palette.ink : Palette.muted)
            .help(Lf("编辑规则：%@ → %@", RemapKeyName.trigger(rule.trigger), RemapKeyName.action(rule.action)))
            .accessibilityLabel(Lf("编辑规则：%@ → %@", RemapKeyName.trigger(rule.trigger), RemapKeyName.action(rule.action)))
            .accessibilityIdentifier("remap-rule-\(rule.id)")
            Toggle(L("启用规则"), isOn: Binding(get: { rule.isEnabled }, set: setEnabled))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel(Lf("启用规则：%@", RemapKeyName.trigger(rule.trigger)))
            Menu {
                Button(L("移除规则"), role: .destructive, action: remove)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Palette.muted)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("规则操作"))
        }
        .padding(.trailing, 4)
        .background(isHovered ? Palette.raisedSurface : .clear, in: RoundedRectangle(cornerRadius: 8))
        .onHover { isHovered = $0 }
    }
}

private struct RemapKeyboardGrid: View {
    let rules: [RemapRule]
    let layerKeys: [RemapLayerKey]
    let select: (UInt16) -> Void
    var body: some View {
        VStack(spacing: 5) {
            keyboardRow(Array(KeyLayout.extra.prefix(13)))
            ForEach(Array(KeyLayout.rows.enumerated()), id: \.offset) { _, row in
                keyboardRow(row)
            }
        }
    }
    private func keyboardRow(_ keys: [KeyDescriptor]) -> some View {
        GeometryReader { geometry in
            let units = keys.reduce(0.0) { $0 + $1.width }
            let width = max(1, (geometry.size.width - CGFloat(keys.count - 1) * 5) / units)
            HStack(spacing: 5) {
                ForEach(keys) { key in cap(key).frame(width: width * key.width) }
            }
        }.frame(height: 40)
    }
    private func cap(_ key: KeyDescriptor) -> some View {
        let rule = rules.first { $0.trigger.keyCode == key.code && $0.isEnabled }
        let layerKey = layerKeys.first { $0.keyCode == key.code }
        return Button { select(key.code) } label: {
            VStack(spacing: 3) {
                Text(key.label.uppercased()).font(.system(size: 10, weight: .medium, design: .monospaced))
                if let rule { Text(RemapKeyName.action(rule.action)).font(.system(size: 8)).lineLimit(1) }
                else if layerKey != nil { Image(systemName: "square.3.layers.3d").font(.system(size: 9)) }
            }.frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(rule != nil || layerKey != nil ? Palette.accent : Palette.ink)
                .background(rule != nil || layerKey != nil ? Palette.accent.opacity(0.10) : Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Palette.line, lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).frame(maxWidth: .infinity)
            .help(rule.map { RemapKeyName.action($0.action) } ?? RemapKeyName.name(key.code))
            .accessibilityLabel(Lf("设置 %@", RemapKeyName.name(key.code)))
            .accessibilityIdentifier("remap-key-\(key.code)")
    }
}

private struct RemapRuleEditor: View {
    @ObservedObject var controller: RemapController
    @Environment(\.dismiss) private var dismiss
    @State private var rule: RemapRule
    @State private var actionKind: String
    @State private var targetCode: UInt16
    @State private var targetModifiers: RemapModifiers
    @State private var media: RemapMediaAction
    @State private var captureTarget: String?
    @State private var error: String?
    let save: (RemapRule) throws -> Void

    init(controller: RemapController, rule: RemapRule, save: @escaping (RemapRule) throws -> Void) {
        self.controller = controller; _rule = State(initialValue: rule); self.save = save
        if case .key(let code, let mods) = rule.action {
            _actionKind = State(initialValue: "key"); _targetCode = State(initialValue: code); _targetModifiers = State(initialValue: mods)
        } else { _actionKind = State(initialValue: rule.action == .disabled ? "disabled" : "media"); _targetCode = State(initialValue: 49); _targetModifiers = State(initialValue: []) }
        if case .media(let value) = rule.action { _media = State(initialValue: value) } else { _media = State(initialValue: .playPause) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("设置按键")).font(.system(size: 22, weight: .semibold))
                HStack(spacing: 12) {
                    Text(RemapKeyName.trigger(rule.trigger))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Text(RemapKeyName.action(draftAction))
                        .foregroundStyle(Palette.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("remap-draft-preview")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    triggerPanel
                    actionPanel
                    HStack(spacing: 4) {
                        Toggle(L("与其他组合键一起生效"), isOn: $rule.trigger.allowsExtraModifiers).toggleStyle(.checkbox)
                        InfoHelpButton(title: "与其他组合键一起生效", message: "例如把 A 改成 B：开启后，Shift + A 也会变成 Shift + B。关闭时，只有完全符合「按下」设置的组合才会替换。", identifier: "remap-extra-modifiers-help")
                        Spacer(minLength: 0)
                    }
                    if let error {
                        Label(L(error), systemImage: "exclamationmark.circle")
                            .font(.system(size: 12)).foregroundStyle(Palette.accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                Spacer()
                Button(L("取消")) { stopCapture(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存")) { commit() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(captureTarget != nil)
                    .accessibilityIdentifier("remap-save-rule")
            }.padding(.horizontal, 20).padding(.vertical, 16)
        }
        .frame(width: 530, height: 570).background(Palette.background)
        .interactiveDismissDisabled(captureTarget != nil)
        .onChange(of: controller.lastCapturedKey) { _, value in
            guard let value, !value.isModifier, let target = captureTarget else { return }
            if target == "source" {
                rule.trigger.keyCode = value.keyCode; rule.trigger.modifiers = value.modifiers
            } else if let action = value.mediaAction {
                media = action; actionKind = "media"
            } else {
                targetCode = value.keyCode; targetModifiers = value.modifiers
            }
            stopCapture()
        }
        .onChange(of: controller.isCapturing) { _, capturing in
            if !capturing { captureTarget = nil }
        }
        .onChange(of: actionKind) { _, _ in
            stopCapture()
            error = nil
        }
        .onChange(of: rule.trigger) { _, _ in error = nil }
        .onChange(of: rule.trigger.keyCode) { _, code in
            // A physical modifier selected as the source is already the key;
            // selecting it again as a modifier makes an unusable combination.
            rule.trigger.modifiers.subtract(RemapModifiers.forKeyCode(code))
        }
        .onChange(of: targetCode) { _, _ in error = nil }
        .onChange(of: targetModifiers) { _, _ in error = nil }
        .onChange(of: media) { _, _ in error = nil }
        .onDisappear { controller.endCapture() }
    }
    private var draftAction: RemapAction {
        switch actionKind {
        case "key": return .key(code: targetCode, modifiers: targetModifiers)
        case "media": return .media(media)
        default: return .disabled
        }
    }
    private var triggerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(L("按下")).font(.system(size: 13, weight: .semibold))
                InfoHelpButton(title: "选择原按键", message: "从列表选键，或点「按键录入」后直接按下要设置的键。单独的修饰键请从列表选择。需要组合键时，可点选下方的 ⌃、⌥、⇧、⌘ 或 Fn。录入完成后会自动停止。", identifier: "remap-capture-help")
            }
            keyPicker(L("按下"), code: $rule.trigger.keyCode, target: "source", includesMedia: true)
            RemapModifierChips(value: Binding(get: { rule.trigger.modifiers }, set: { selected in
                stopCapture()
                rule.trigger.modifiers = selected
            }), excluding: RemapModifiers.forKeyCode(rule.trigger.keyCode))
            if captureTarget == "source" {
                captureHint
            } else {
                if RemapMediaAction.forTriggerCode(rule.trigger.keyCode) != nil {
                    HStack(spacing: 4) {
                        Text(L("媒体键每次按下执行一次")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        InfoHelpButton(title: "媒体键", message: "媒体键和亮度键每次按下只执行一次。能否录入取决于 macOS 是否收到该键。", identifier: "remap-trigger-media-help")
                    }
                }
                if rule.trigger.modifiers.contains(.fn) {
                    HStack(spacing: 4) {
                        Text(L("Fn 需要键盘支持")).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        InfoHelpButton(title: "Fn 需要键盘支持", message: "有些键盘只在内部处理 Fn，电脑无法识别。如果 Fn 组合不生效，可添加键位组，用右 Option 等按键代替 Fn。", identifier: "remap-fn-help")
                    }
                }
            }
        }.padding(14).cardStyle()
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(captureTarget == "source" ? Palette.accent : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
    }
    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(L("改成")).font(.system(size: 13, weight: .semibold))
                InfoHelpButton(title: "选择替换效果", message: "可以替换为另一个按键或组合键，控制播放、音量，也可以禁用原按键。媒体指令交给当前媒体应用；亮度和背光功能取决于设备支持。", identifier: "remap-action-help")
            }
            Picker(L("改成"), selection: $actionKind) {
                Text(L("按键组合")).tag("key")
                Text(L("媒体控制")).tag("media")
                Text(L("禁用此键")).tag("disabled")
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("remap-action-kind")
            if actionKind == "key" {
                keyPicker(L("输出"), code: $targetCode, target: "target")
                RemapModifierChips(value: Binding(get: { targetModifiers }, set: { selected in
                    stopCapture()
                    targetModifiers = selected
                }))
                if captureTarget == "target" { captureHint }
            } else if actionKind == "media" {
                HStack(spacing: 6) {
                    mediaShortcut(.previousTrack, symbol: "backward.end.fill")
                    mediaShortcut(.playPause, symbol: "playpause.fill")
                    mediaShortcut(.nextTrack, symbol: "forward.end.fill")
                }
                Picker(L("输出"), selection: Binding(get: { media }, set: { selected in
                    stopCapture()
                    media = selected
                })) {
                    Section(L("媒体控制")) {
                        ForEach(RemapMediaAction.allCases.filter { !$0.isDisplayControl }) { action in
                            Text(L(action.title)).tag(action)
                        }
                    }
                    Section(L("屏幕与键盘背光")) {
                        ForEach(RemapMediaAction.allCases.filter(\.isDisplayControl)) { action in
                            Text(L(action.title)).tag(action)
                        }
                    }
                }.labelsHidden().accessibilityIdentifier("remap-media-action")
                    .help(L("媒体指令由当前媒体应用接收；亮度与背光取决于设备支持。"))
            }
        }.padding(14).cardStyle()
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(captureTarget == "target" ? Palette.accent : .clear, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
    }
    private func mediaShortcut(_ action: RemapMediaAction, symbol: String) -> some View {
        let selected = media == action
        return Button { stopCapture(); media = action } label: {
            Label(L(action.title), systemImage: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 32)
                .foregroundStyle(selected ? Palette.accent : Palette.ink)
                .background(selected ? Palette.accent.opacity(0.12) : Palette.raisedSurface,
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(L(selected ? "已选择" : "未选择"))
        .accessibilityIdentifier("remap-quick-\(action.rawValue)")
    }
    private var captureHint: some View {
        Label(L("请按下按键或组合键…"), systemImage: "record.circle")
            .font(.system(size: 12)).foregroundStyle(Palette.accent)
    }
    private func keyPicker(_ label: String, code: Binding<UInt16>, target: String, includesMedia: Bool = false) -> some View {
        HStack(spacing: 8) {
            Picker(label, selection: Binding(get: { code.wrappedValue }, set: { selected in
                stopCapture()
                code.wrappedValue = selected
            })) {
                Section(L("常用键")) {
                    ForEach(RemapKeyName.standardKeys) { key in Text(RemapKeyName.name(key.code)).tag(key.code) }
                    if code.wrappedValue <= 127 && !RemapKeyName.keys.contains(where: { $0.code == code.wrappedValue }) {
                        Text(RemapKeyName.name(code.wrappedValue)).tag(code.wrappedValue)
                    }
                }
                Section(L("功能键")) {
                    ForEach(RemapKeyName.functionKeys) { key in Text(RemapKeyName.name(key.code)).tag(key.code) }
                }
                if includesMedia {
                    Section(L("媒体与系统")) {
                        ForEach(RemapMediaAction.allCases) { action in Text(L(action.title)).tag(action.triggerCode) }
                    }
                }
            }.labelsHidden().accessibilityIdentifier("remap-\(target)-key")
            Button {
                if captureTarget == target { stopCapture() }
                else { captureTarget = target; controller.beginCapture() }
            } label: {
                Label(L(captureTarget == target ? "取消录入" : "按键录入"),
                      systemImage: captureTarget == target ? "stop.circle" : "record.circle")
            }
            .fixedSize()
            .tint(captureTarget == target ? Palette.accent : nil)
            .accessibilityIdentifier("remap-capture-\(target)")
        }
    }
    private func stopCapture() {
        captureTarget = nil
        controller.endCapture()
    }
    private func commit() {
        stopCapture()
        var changed = rule
        changed.action = draftAction
        var config = controller.configuration
        guard let index = config.profiles.firstIndex(where: { $0.id == config.activeProfileID }) else { return }
        config.profiles[index].rules.removeAll { $0.id == changed.id }; config.profiles[index].rules.append(changed)
        do { try RemapValidation.validate(config); try save(changed); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct RemapModifierChips: View {
    @Binding var value: RemapModifiers
    var excluding: RemapModifiers = []
    private let options: [(symbol: String, name: String, modifier: RemapModifiers)] = [
        ("⌃", "Control", .control), ("⌥", "Option / Alt", .option),
        ("⇧", "Shift", .shift), ("⌘", "Command", .command), ("Fn", "Fn / 🌐", .fn)
    ]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button {
                    if value.contains(option.modifier) { value.remove(option.modifier) } else { value.insert(option.modifier) }
                } label: {
                    Text(option.symbol).font(.system(size: 13, weight: .medium)).frame(minWidth: 40).padding(.vertical, 7)
                        .background(value.contains(option.modifier) ? Palette.accent.opacity(0.14) : Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(value.contains(option.modifier) ? Palette.accent : Palette.line)
                                .allowsHitTesting(false)
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(option.name)
                    .help(option.name)
                    .accessibilityValue(L(value.contains(option.modifier) ? "已选择" : "未选择"))
                    .disabled(excluding.contains(option.modifier))
                    .opacity(excluding.contains(option.modifier) ? 0.4 : 1)
            }
            Spacer()
        }
    }
}

private struct RemapLayerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Fn"
    @State private var key: UInt16 = 61
    @State private var mode: RemapLayerKey.Mode = .hold
    @State private var error: String?
    let save: (RemapLayer, RemapLayerKey) throws -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Text(L("添加键位组")).font(.system(size: 22, weight: .semibold))
                InfoHelpButton(title: "什么是键位组？", message: "键位组是一组临时使用的改键规则。例如按住右 Option 后，H、J、K、L 变成方向键。选定的启用按键会用于切换键位组；组内没有设置的键保持原样。", identifier: "remap-layer-help")
            }
            VStack(alignment: .leading, spacing: 12) {
                TextField(L("键位组名称"), text: $name).textFieldStyle(.roundedBorder)
                Picker(L("启用按键"), selection: $key) {
                    ForEach(RemapKeyName.keys) { item in Text(RemapKeyName.name(item.code)).tag(item.code) }
                }
                Picker(L("切换方式"), selection: $mode) {
                    Text(L("按住时启用")).tag(RemapLayerKey.Mode.hold)
                    Text(L("按一次切换")).tag(RemapLayerKey.Mode.toggle)
                }.pickerStyle(.segmented)
                if key == 57 && mode == .hold {
                    Label(L("Caps Lock 请选择「按一次切换」。"), systemImage: "exclamationmark.circle")
                        .font(.system(size: 12)).foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(14).cardStyle()
            if let error {
                Label(L(error), systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("添加")) {
                    let layer = RemapLayer(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                    do { try save(layer, .init(keyCode: key, layerID: layer.id, mode: mode)); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (key == 57 && mode == .hold))
            }
        }.padding(26).frame(width: 470).background(Palette.background)
    }
}
