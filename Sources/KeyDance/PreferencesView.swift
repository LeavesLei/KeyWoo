import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            displaySettings
            inputSettings
            HStack(spacing: 10) {
                BrandMark().frame(width: 23, height: 23)
                Text([AppLocalization.appName, appVersion].filter { !$0.isEmpty }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(Palette.muted)
            }
            .padding(.leading, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displaySettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("显示与语言")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    rowLabel("外观", symbol: "circle.lefthalf.filled")
                    Spacer(minLength: 0)
                    appearanceOptions
                }
                .padding(16)
                Divider().padding(.leading, 48)
                HStack(spacing: 12) {
                    rowLabel("语言", symbol: "globe")
                    Spacer(minLength: 0)
                    languageOptions
                }
                .padding(16)
            }
            .cardStyle()
        }
    }

    private var appearanceOptions: some View {
        HStack(spacing: 3) {
            ForEach(AppAppearance.allCases, id: \.self) { option in
                let selected = model.appearance == option
                Button { model.appearance = option } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(L(selected ? "已选择" : "未选择"))
                .accessibilityIdentifier("appearance-\(option.rawValue)")
            }
        }
        .padding(3)
        .frame(width: 248)
        .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("外观"))
    }

    private var languageOptions: some View {
        HStack(spacing: 3) {
            ForEach(AppLanguage.allCases, id: \.self) { option in
                let selected = model.language == option
                Button { model.language = option } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(selected ? Palette.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityValue(L(selected ? "已选择" : "未选择"))
                .accessibilityIdentifier("language-\(option.rawValue)")
            }
        }
        .padding(3)
        .frame(width: 248)
        .background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("语言"))
    }

    private var inputSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                sectionTitle("使用与隐私")
                InfoHelpButton(title: "跨应用使用", message: "允许“输入监控”后，在其他应用中打字也能播放音效、显示动画并统计次数。改键还需要单独允许“辅助功能”。这些权限都由你在系统设置中开启。", identifier: "preferences-monitoring-help")
            }
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if model.monitor.hasGlobalAccess { model.monitor.openPermissionSettings() }
                    else { model.monitor.requestPermission() }
                } label: {
                    HStack(spacing: 12) {
                        rowLabel("全局输入", symbol: "keyboard", detail: monitoringStatus)
                        Spacer(minLength: 12)
                        Text(L(model.monitor.hasGlobalAccess ? "系统设置" : "去开启"))
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.accent)
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 32)
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsActionRowStyle())
                .accessibilityIdentifier("input-monitoring-settings")
                Divider().padding(.leading, 42)
                InfoHelpButton(title: "隐私", message: "统计只保存在这台电脑，按分钟保存每个物理键的累计次数。不保存输入文字、按键顺序、剪贴板或其他应用的内容。改键配置也只保存在本机。", identifier: "preferences-privacy-help", rowSymbol: "hand.raised", rowDetail: "只记次数，不记文字")
                Divider().padding(.leading, 48)
                InfoHelpButton(title: "后台运行", message: "关闭窗口后，音效、动画与统计会继续工作。点菜单栏中的键舞图标可重新打开。右上角“暂停”可暂停这些功能；按 ⌘ Q 才会完全退出。改键有独立开关。", identifier: "preferences-background-help", rowSymbol: "menubar.rectangle", rowDetail: "关闭窗口后继续工作")
            }
            .cardStyle()
        }
    }

    private var monitoringStatus: String {
        if model.monitor.isGlobalActive { return L("已开启") }
        if !model.monitor.hasGlobalAccess { return L("尚未开启，仅应用内可用") }
        return L(!model.isEnabled ? "已授权，当前暂停" : "已授权，当前仅应用内")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(L(title))
            .font(.system(size: 14, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    private func rowLabel(_ title: String, symbol: String, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Palette.muted)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L(title)).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }
        }
    }


}

