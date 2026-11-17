import SwiftUI

struct WorkspaceView: View {
    @ObservedObject var model: AppModel
    let presentation: WorkspacePresentationState
    @State private var hoveredPage: AppPage?
    private let maximumContentWidth: CGFloat = 1100
    private let headerHeight: CGFloat = 70

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 188)
            Divider().overlay(Palette.line.opacity(0.7))
            GeometryReader { viewport in
                let inset: CGFloat = viewport.size.width < 900 ? 24 : 32
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let error = visibleError {
                            Label(L(error), systemImage: "exclamationmark.circle")
                                .font(.system(size: 13))
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                        }
                        pageContent
                    }
                    .frame(maxWidth: maximumContentWidth, minHeight: max(0, viewport.size.height - headerHeight - 52), alignment: .topLeading)
                    .padding(.horizontal, inset)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity)
                }
                .id(model.page)
                .safeAreaInset(edge: .top, spacing: 0) { topBar(inset: inset) }
            }
            .background(Palette.background)
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

    @ViewBuilder private var pageContent: some View {
        switch model.page {
        case .studio:
            if model.musicModeAvailable { modePicker }
            if model.isKeyboardSoundMode {
                KeyboardSoundSpaceView(model: model, presentation: presentation.sound)
            } else {
                MusicSpaceView(model: model)
            }
        case .remapping: RemappingView(model: model)
        case .statistics: StatisticsView(model: model, presentation: presentation.statistics)
        case .effects: DesktopEffectsView(model: model, presentation: presentation.effects)
        case .settings: PreferencesView(model: model)
        }
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
            HStack(spacing: 9) {
                BrandMark().frame(width: 32, height: 32)
                Text(AppLocalization.appName)
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 35)
            .padding(.bottom, 23)
            .padding(.leading, 9)

            VStack(spacing: 3) {
                ForEach(AppPage.primaryPages, id: \.self) { page in
                    navigationRow(page)
                }
            }
            Spacer(minLength: 20)
            navigationRow(.settings)
                .padding(.bottom, 9)
            Divider().overlay(Palette.line.opacity(0.65))
            listeningStatus.padding(.vertical, 9)
        }
        .padding(.horizontal, 12)
        .background(WorkspaceChrome(fill: Palette.sidebar))
    }

    private func navigationRow(_ page: AppPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .frame(width: 18, alignment: .center)
                Text(pageTitle(page))
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(WorkspaceNavigationStyle(selected: selected, hovered: hoveredPage == page))
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
                        .frame(minHeight: 34)
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
        .padding(.horizontal, 11)
        .frame(minHeight: 34, alignment: .leading)
    }

    private func topBar(inset: CGFloat) -> some View {
        HStack(spacing: 14) {
            Text(pageTitle(model.page))
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.25)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            if model.isEnabled && model.monitor.secureInputActive {
                Label(L(model.statusText), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            Button { model.isEnabled.toggle() } label: {
                Label(L(model.isEnabled ? "暂停" : "继续"), systemImage: model.isEnabled ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(model.isEnabled ? Palette.ink : Palette.accent)
                    .frame(minWidth: 66)
                    .padding(.vertical, 1)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help(L("暂停或继续音效、动画与统计。改键有独立开关。"))
            .accessibilityIdentifier("workspace-pause")
        }
        .frame(maxWidth: maximumContentWidth, minHeight: headerHeight, alignment: .leading)
        .padding(.horizontal, inset)
        .frame(maxWidth: .infinity)
        .background(WorkspaceChrome(fill: Palette.surface))
        .overlay(alignment: .bottom) { Divider().overlay(Palette.line.opacity(0.7)) }
    }
}

private struct WorkspaceChrome: View {
    let fill: Color
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if reduceTransparency || contrast == .increased {
            fill
        } else {
            Rectangle()
                .fill(.regularMaterial)
                .overlay(fill.opacity(0.64))
        }
    }
}

private struct WorkspaceNavigationStyle: ButtonStyle {
    let selected: Bool
    let hovered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        configuration.label
            .background {
                if selected {
                    shape.fill(Palette.accent.opacity(configuration.isPressed ? 0.20 : 0.12))
                } else if configuration.isPressed || hovered {
                    shape.fill(Palette.ink.opacity(configuration.isPressed ? 0.10 : 0.06))
                }
            }
            .overlay {
                if selected && contrast == .increased {
                    shape.strokeBorder(Palette.accent, lineWidth: 1).allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

