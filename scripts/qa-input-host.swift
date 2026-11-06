import AppKit
import Carbon

/// Disposable, local-only input surface for cross-application QA.
/// It has no global listener, network code, persistence, or input synthesis.
final class QAInputHost: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let ordinary = NSTextField(string: "")
    private let secure = NSSecureTextField(string: "")
    private let countLabel = NSTextField(labelWithString: "本地按下次数：0")
    private let heldLabel = NSTextField(labelWithString: "本地按住数量：0")
    private let focusLabel = NSTextField(labelWithString: "当前输入框：普通")
    private let securityLabel = NSTextField(labelWithString: "系统安全输入：未开启")
    private var monitor: Any?
    private var timer: Timer?
    private var count = 0
    private var held = Set<UInt16>()
    private var capsEnabled = false
    private var lastFocusedField = "普通"
    private let modifierMasks: [UInt16: UInt64] = [59: 1, 56: 2, 60: 4, 55: 8, 54: 16, 58: 32, 61: 64, 62: 0x2000, 63: 0x800000]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "KeyWoo · 输入测试台"
        window.minSize = NSSize(width: 660, height: 570)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)

        let title = label("输入测试台", size: 28, weight: .semibold)
        let intro = label("这是一个独立测试应用。它只观察自己的键盘事件，用于核对 KeyWoo 的跨应用反馈与安全输入保护。", size: 14)
        intro.maximumNumberOfLines = 3
        let instruction = label("在普通框按一下 A，再按住 A 约 2 秒后松开。随后在安全框做同样操作。长按产生的自动重复不会增加下方计数。", size: 13)
        instruction.maximumNumberOfLines = 3

        ordinary.placeholderString = "在这里输入普通测试文字"
        ordinary.identifier = NSUserInterfaceItemIdentifier("qa-normal-input")
        ordinary.setAccessibilityIdentifier("qa-normal-input")
        ordinary.setAccessibilityLabel("普通测试输入框")
        ordinary.font = .systemFont(ofSize: 18)
        ordinary.delegate = self
        secure.placeholderString = "仅输入测试字符，不要输入真实密码"
        secure.identifier = NSUserInterfaceItemIdentifier("qa-secure-input")
        secure.setAccessibilityIdentifier("qa-secure-input")
        secure.setAccessibilityLabel("安全测试输入框")
        secure.font = .systemFont(ofSize: 18)
        secure.delegate = self
        for field in [ordinary, secure] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 38).isActive = true
        }

        let focusOrdinary = NSButton(title: "聚焦普通输入", target: self, action: #selector(focusOrdinaryField))
        let focusSecure = NSButton(title: "聚焦安全输入", target: self, action: #selector(focusSecureField))
        let clear = NSButton(title: "清空测试文字", target: self, action: #selector(clearText))
        let reset = NSButton(title: "重置计数", target: self, action: #selector(resetCounters))
        [focusOrdinary, focusSecure, clear, reset].forEach { $0.bezelStyle = .rounded }
        let buttons = NSStackView(views: [focusOrdinary, focusSecure, clear, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        countLabel.setAccessibilityIdentifier("qa-local-count")
        heldLabel.setAccessibilityIdentifier("qa-held-count")
        focusLabel.setAccessibilityIdentifier("qa-focus")
        securityLabel.setAccessibilityIdentifier("qa-secure-state")
        for status in [countLabel, heldLabel, focusLabel, securityLabel] {
            status.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        }
        let counters = NSStackView(views: [countLabel, heldLabel])
        counters.orientation = .horizontal
        counters.spacing = 28
        let privacy = label("测试文字仅存在于窗口内存，关闭测试台即丢弃。此程序不保存文字或按键记录，也不请求输入监控、辅助功能等权限。", size: 12)
        privacy.maximumNumberOfLines = 3
        privacy.textColor = .secondaryLabelColor

        let content = NSStackView(views: [title, intro, instruction,
            label("普通输入", size: 14, weight: .semibold), ordinary,
            label("安全输入", size: 14, weight: .semibold), secure,
            buttons, counters, focusLabel, securityLabel, privacy])
        content.orientation = .vertical
        content.alignment = .leading
        content.distribution = .fill
        content.spacing = 13
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            content.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20),
            ordinary.widthAnchor.constraint(equalTo: content.widthAnchor),
            secure.widthAnchor.constraint(equalTo: content.widthAnchor),
            intro.widthAnchor.constraint(equalTo: content.widthAnchor),
            instruction.widthAnchor.constraint(equalTo: content.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出输入测试台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        NSApp.mainMenu = menu
        capsEnabled = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.observe(event)
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.refreshLabels() }
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(ordinary)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        return field
    }
    private func observe(_ event: NSEvent) {
        let code = event.keyCode
        switch event.type {
        case .keyDown:
            if !event.isARepeat, held.insert(code).inserted { count += 1 }
        case .keyUp:
            held.remove(code)
        case .flagsChanged:
            if code == 57 {
                let enabled = event.modifierFlags.contains(.capsLock)
                if enabled != capsEnabled { count += 1 }
                capsEnabled = enabled
            } else if let mask = modifierMasks[code] {
                if UInt64(event.modifierFlags.rawValue) & mask != 0 {
                    if held.insert(code).inserted { count += 1 }
                } else { held.remove(code) }
            }
        default: break
        }
        refreshLabels()
    }
    private func refreshLabels() {
        countLabel.stringValue = "本地按下次数：\(count)"
        heldLabel.stringValue = "本地按住数量：\(held.count)"
        focusLabel.stringValue = "当前输入框：\(NSApp.isActive ? lastFocusedField : "测试台不在前台")"
        securityLabel.stringValue = "系统安全输入：\(IsSecureEventInputEnabled() ? "已开启" : "未开启")"
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        lastFocusedField = (notification.object as? NSControl) === secure ? "安全" : "普通"
        refreshLabels()
    }
    func applicationDidResignActive(_ notification: Notification) { held.removeAll(); refreshLabels() }
    func applicationDidBecomeActive(_ notification: Notification) { refreshLabels() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        timer?.invalidate()
    }
    @objc private func focusOrdinaryField() { lastFocusedField = "普通"; window.makeFirstResponder(ordinary); refreshLabels() }
    @objc private func focusSecureField() { lastFocusedField = "安全"; window.makeFirstResponder(secure); refreshLabels() }
    @objc private func clearText() { ordinary.stringValue = ""; secure.stringValue = "" }
    @objc private func resetCounters() { count = 0; held.removeAll(); refreshLabels() }
}

let application = NSApplication.shared
let delegate = QAInputHost()
application.delegate = delegate
application.run()
