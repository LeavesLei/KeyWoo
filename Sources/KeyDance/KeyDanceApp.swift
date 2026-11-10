import SwiftUI
import AppKit

struct KeyDanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window(AppLocalization.appName, id: "main") {
            ContentView(model: model)
                .frame(minWidth: 920, minHeight: 640)
                .preferredColorScheme(model.appearance.preferredColorScheme)
                .environment(\.locale, AppLocalization.locale)
                .background {
                    WindowTitleSynchronizer(title: AppLocalization.appName)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .onAppear { model.start() }
        }
        .defaultSize(width: 1100, height: 760)
        .windowStyle(.hiddenTitleBar)
        .commands {
            WorkspaceNavigationCommands(model: model)
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(Lf("关于 %@", AppLocalization.appName)) { showBilingualAbout() }
            }
            if model.musicModeAvailable { CommandMenu(L("体验模式")) {
                Picker(L("体验模式"), selection: $model.experienceMode) {
                    ForEach(AppExperienceMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
            } }
            CommandMenu(L("声音")) {
                Button(L(model.isEnabled ? "暂停" : "继续")) { model.isEnabled.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(L(model.isKeyboardSoundMode ? "试听键盘音效" : "试听音乐响应")) { model.previewSound() }
                    .disabled(!model.isEnabled || (!model.isKeyboardSoundMode && !model.musicWantsPlayback))
                if model.isKeyboardSoundMode {
                    Picker(L("键盘音效"), selection: $model.keyboardSoundStyle) {
                        ForEach(KeyboardSoundStyle.allCases) { style in Text(style.title).tag(style) }
                    }
                    if model.canChooseKeyboardSoundQuality {
                        Picker(L("录音版本"), selection: $model.keyboardSoundQuality) {
                            ForEach(KeyboardSoundQuality.allCases) { quality in Text(quality.title).tag(quality) }
                        }
                    }
                } else {
                    Button(L(model.musicWantsPlayback ? "暂停音乐" : "播放音乐")) { model.toggleMusicPlayback() }.disabled(!model.isEnabled)
                    Button(L("加入本地音乐…")) { model.importMusic() }.keyboardShortcut("o")
                }
            }
            CommandMenu(L("特效")) {
                Toggle(L("桌面特效"), isOn: $model.rhythmEnabled)
                Picker(L("显示样式"), selection: Binding(get: { model.rhythmStyle }, set: { model.activateRhythmStyle($0) })) {
                    ForEach(RhythmVisualStyle.allCases) { style in Text(style.title).tag(style) }
                }
                Button(L("演示特效")) { model.previewRhythm() }.disabled(!model.isEnabled || model.monitor.secureInputActive)
                if model.rhythmStyle != .edgeGlow {
                    Toggle(L("鼠标穿透"), isOn: $model.rhythmClickThrough)
                    Button(L("重置律动位置")) { model.resetRhythmPosition() }
                }
            }
        }
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(nsImage: MenuBarGlyph.image).accessibilityLabel(AppLocalization.appName)
        }
    }
}

/// SwiftUI's Window title can retain its initial value after a language change.
/// This view stays outside the visible-content shell and touches only its own
/// window, including when that window is attached again after being reopened.
private struct WindowTitleSynchronizer: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> TitleView {
        let view = TitleView(frame: .zero)
        view.synchronize(to: title)
        return view
    }

    func updateNSView(_ nsView: TitleView, context: Context) {
        nsView.synchronize(to: title)
    }

    final class TitleView: NSView {
        private var requestedTitle = ""

        func synchronize(to title: String) {
            requestedTitle = title
            applyTitle()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyTitle()
        }

        private func applyTitle() {
            guard let window, window.title != requestedTitle else { return }
            window.title = requestedTitle
        }
    }
}

@MainActor
private enum MenuBarGlyph {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            BrandGlyph.draw(in: context, rect: CGRect(x: 0, y: 0, width: 18, height: 18), background: false)
            return true
        }
        image.isTemplate = true
        return image
    }()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("\(AppLocalization.appName) · \(model.experienceMode.title)")
        Text(model.statusText)
        Divider()
        Button(Lf("打开 %@", AppLocalization.appName)) {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button(L(model.isEnabled ? "暂停" : "继续")) { model.isEnabled.toggle() }
        Toggle(L("桌面特效"), isOn: $model.rhythmEnabled)
        if model.rhythmEnabled {
            Picker(L("显示样式"), selection: Binding(get: { model.rhythmStyle }, set: { model.activateRhythmStyle($0) })) {
                ForEach(RhythmVisualStyle.allCases) { style in Text(style.title).tag(style) }
            }
            if model.rhythmStyle != .edgeGlow {
                Toggle(L("鼠标穿透"), isOn: $model.rhythmClickThrough)
                Button(L("重置律动位置")) { model.resetRhythmPosition() }
            }
        }
        if model.musicModeAvailable { Menu(L("体验模式")) {
            ForEach(AppExperienceMode.allCases) { mode in
                Button { model.experienceMode = mode } label: {
                    if model.experienceMode == mode { Label(mode.title, systemImage: "checkmark") }
                    else { Text(mode.title) }
                }
            }
        } }
        if model.isKeyboardSoundMode {
            Menu(L("键盘音效")) {
                ForEach(KeyboardSoundStyle.allCases) { style in
                    Button { model.keyboardSoundStyle = style } label: {
                        if model.keyboardSoundStyle == style { Label(style.title, systemImage: "checkmark") }
                        else { Text(style.title) }
                    }
                }
            }
            if model.canChooseKeyboardSoundQuality {
                Picker(L("录音版本"), selection: $model.keyboardSoundQuality) {
                    ForEach(KeyboardSoundQuality.allCases) { quality in Text(quality.title).tag(quality) }
                }
            }
            Button(L("试听键盘音效")) { model.previewSound() }.disabled(!model.isEnabled)
        } else {
            Button(L(model.musicWantsPlayback ? "暂停音乐" : "播放音乐")) { model.toggleMusicPlayback() }.disabled(!model.isEnabled)
            Menu(L("歌曲")) {
                ForEach(model.musicTracks) { track in
                    Button { model.selectMusic(id: track.id) } label: {
                        if model.selectedMusicID == track.id { Label(track.displayTitle, systemImage: "checkmark") }
                        else { Text(track.displayTitle) }
                    }
                }
                Divider()
                Button(L("加入本地音乐…")) { model.importMusic() }
            }
            if model.selectedMusic.isBuiltIn {
                Menu(L("响应方式")) {
                    ForEach(HitSound.allCases) { sound in
                        Button { model.hitSound = sound } label: {
                            if model.hitSound == sound { Label(sound.title, systemImage: "checkmark") }
                            else { Text(sound.title) }
                        }
                    }
                }
            }
        }
        Divider()
        Text(Lf("本次敲击 %d 次", model.sessionTotal))
        Button(Lf("关于 %@", AppLocalization.appName)) { showBilingualAbout() }
        Button(Lf("退出 %@", AppLocalization.appName)) {
            model.shutdown()
            NSApplication.shared.terminate(nil)
        }.keyboardShortcut("q")
    }
}

@MainActor private func showBilingualAbout() {
    NSApplication.shared.orderFrontStandardAboutPanel(options: [
        .applicationName: "键舞 · KeyWoo",
        .credits: NSAttributedString(string: L("让每次敲击，都有喜欢的声音。") + "\n" + L("本机运行 · 不保存输入文字"))
    ])
}

/// Standard Mac navigation remains available after the main window is closed.
private struct WorkspaceNavigationCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L("偏好设置…")) { show(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(AppPage.allCases, id: \.self) { page in
                Button(page == .studio ? model.studioTitle : L(page.rawValue)) { show(page) }
                    .keyboardShortcut(KeyEquivalent(page == .settings ? "4" : page.shortcut), modifiers: .command)
            }
        }
    }

    private func show(_ page: AppPage) {
        // Page changes must never dismiss an editor or a confirmation sheet.
        guard NSApplication.shared.modalWindow == nil,
              NSApplication.shared.keyWindow?.sheetParent == nil,
              NSApplication.shared.mainWindow?.attachedSheet == nil else { return }
        model.page = page
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
