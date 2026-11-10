import SwiftUI
import AppKit

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    let presentation: WorkspacePresentationState
    @State private var hoveredPage: AppPage?
    private let workspaceInset: CGFloat = 24
    private let maximumContentWidth: CGFloat = 1120

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 186)
            Divider().overlay(Palette.line)
            VStack(spacing: 0) {
                topBar
                GeometryReader { viewport in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if let error = visibleError {
                                Label(L(error), systemImage: "exclamationmark.circle")
                                    .font(.system(size: 13)).foregroundStyle(Palette.ink).padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                            }
                            switch model.page {
                            case .studio:
                                if model.musicModeAvailable { modePicker }
                                if model.isKeyboardSoundMode { KeyboardSoundSpaceView(model: model, presentation: presentation.sound) }
                                else { MusicSpaceView(model: model) }
                            case .remapping: RemappingView(model: model)
                            case .statistics: StatisticsView(model: model, presentation: presentation.statistics)
                            case .effects: DesktopEffectsView(model: model, presentation: presentation.effects)
                            case .settings: PreferencesView(model: model)
                            }
                        }
                        .frame(maxWidth: maximumContentWidth, minHeight: max(0, viewport.size.height - 52), alignment: .topLeading)
                        .padding(.horizontal, workspaceInset)
                        .padding(.top, 20)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                    }.id(model.page)
                }
            }.background(Palette.background)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .environment(\.locale, AppLocalization.locale)
        .preferredColorScheme(model.appearance.preferredColorScheme)
        // Only the visible presentation refreshes. Its statistics state is
        // owned above this subtree and survives language or appearance changes.
        .id(model.language)
    }

    private var visibleError: String? {
        switch model.page {
        case .studio:
            return (model.isKeyboardSoundMode ? model.keyboardAudio.errorMessage : model.musicSelectionError ?? model.music.errorMessage ?? model.audio.musicErrorMessage ?? model.audio.errorMessage) ?? model.monitor.errorMessage
        case .statistics: return model.statistics.errorMessage
        case .effects: return model.monitor.errorMessage
        case .remapping, .settings: return nil
        }
    }

    private func pageTitle(_ page: AppPage) -> String {
        page == .studio ? model.studioTitle : L(page.rawValue)
    }

    private var modePicker: some View {
        Picker(L("体验模式"), selection: $model.experienceMode) {
            ForEach(AppExperienceMode.allCases, id: \.self) { mode in
                Label(mode.title, systemImage: mode == .music ? "music.note" : "keyboard").tag(mode)
            }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            .accessibilityIdentifier("experience-mode")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark().frame(width: 34, height: 34)
                Text(AppLocalization.appName)
                    .font(.system(size: 19, weight: .semibold))
            }
            .padding(.top, 30)
            .padding(.bottom, 24)
            .padding(.leading, 8)

            VStack(spacing: 4) {
                ForEach(AppPage.primaryPages, id: \.self) { page in
                    navigationRow(page)
                }
            }
            Spacer(minLength: 20)
            navigationRow(.settings)
                .padding(.bottom, 8)
            Divider().overlay(Palette.line.opacity(0.6))
            listeningStatus.padding(.vertical, 12)
        }
        .padding(.horizontal, 14)
        .background(Palette.sidebar)
    }

    private func navigationRow(_ page: AppPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .frame(width: 18)
                Text(page == .studio && model.isKeyboardSoundMode ? L("音效") : page == .effects ? L("特效") : pageTitle(page))
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 40)
            .background(selected ? Palette.accent.opacity(0.10)
                        : hoveredPage == page ? Palette.raisedSurface : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredPage = page }
            else if hoveredPage == page { hoveredPage = nil }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(pageTitle(page))
        .accessibilityIdentifier("navigation-\(page)")
        .help(pageTitle(page) + " · " + page.shortcutLabel)
    }

    private var listeningStatus: some View {
        Group {
            if !model.monitor.hasGlobalAccess {
                Button { model.monitor.requestPermission() } label: {
                    Label(L("开启全局体验"), systemImage: "keyboard")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
            } else {
                Label(L(model.monitor.isGlobalActive ? "所有应用" : model.isEnabled ? "仅应用内" : "已暂停"),
                      systemImage: model.monitor.isGlobalActive ? "checkmark.shield" : "keyboard")
                    .foregroundStyle(Palette.muted)
                    .help(L("音效、动画与统计的输入范围；改键有独立开关。"))
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 9)
        .frame(minHeight: 26, alignment: .leading)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Text(pageTitle(model.page))
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if model.isEnabled && model.monitor.secureInputActive {
                Label(L(model.statusText), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Button { model.isEnabled.toggle() } label: {
                Label(L(model.isEnabled ? "暂停" : "继续"), systemImage: model.isEnabled ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L("暂停或继续音效、动画与统计。改键有独立开关。"))
            .accessibilityIdentifier("workspace-pause")
        }
        .frame(maxWidth: maximumContentWidth)
        .padding(.horizontal, workspaceInset)
        .padding(.top, 21)
        .padding(.bottom, 15)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider().overlay(Palette.line) }
    }
}

