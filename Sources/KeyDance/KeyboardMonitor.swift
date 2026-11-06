import AppKit
import Carbon
import Combine
import CoreGraphics

/// Retains only the set of currently held keys, never text or key order.
/// Kept independent from AppKit event sources so boundary cases can be tested.
struct KeyboardPressFilter {
    enum EventKind { case keyDown, keyUp, flagsChanged }
    enum Transition: Equatable { case down, up, tap }

    private(set) var heldKeys = Set<UInt16>()
    private var capsLockEnabled = false

    // Public device masks from IOKit/hidsystem/IOLLEvent.h. Independent masks
    // such as maskShift alone cannot distinguish two Shift keys held together.
    private static let modifierMasks: [UInt16: UInt64] = [
        59: 0x00000001, 56: 0x00000002, 60: 0x00000004,
        55: 0x00000008, 54: 0x00000010, 58: 0x00000020,
        61: 0x00000040, 62: 0x00002000, 63: 0x00800000
    ]

    mutating func reset(flags: UInt64) {
        heldKeys = Set(Self.modifierMasks.compactMap { code, mask in
            flags & mask != 0 ? code : nil
        })
        capsLockEnabled = flags & CGEventFlags.maskAlphaShift.rawValue != 0
    }

    mutating func transition(kind: EventKind, code: UInt16, flags: UInt64 = 0, isRepeat: Bool = false) -> Transition? {
        guard !isRepeat else { return nil }
        if code == 57 {
            // Caps Lock has no conventional release; never leave it sustaining.
            guard kind == .flagsChanged else { return nil }
            let enabled = flags & CGEventFlags.maskAlphaShift.rawValue != 0
            defer { capsLockEnabled = enabled }
            return capsLockEnabled != enabled ? .tap : nil
        }
        switch kind {
        case .keyDown:
            return heldKeys.insert(code).inserted ? .down : nil
        case .keyUp:
            return heldKeys.remove(code) != nil ? .up : nil
        case .flagsChanged:
            guard let mask = Self.modifierMasks[code] else { return nil }
            if flags & mask != 0 { return heldKeys.insert(code).inserted ? .down : nil }
            return heldKeys.remove(code) != nil ? .up : nil
        }
    }

    /// Recover individual lost releases without interrupting any keys still down.
    mutating func releaseMissingKeys(isPhysicallyDown: (UInt16) -> Bool) -> [UInt16] {
        let released = heldKeys.filter { !isPhysicallyDown($0) }.sorted()
        for code in released { heldKeys.remove(code) }
        return released
    }
}

/// Observes physical key presses, never characters, text, or application contents.
/// A listen-only session tap needs Input Monitoring permission. Until it is granted,
/// the local NSEvent monitor lets the user try the instrument inside KeyWoo.
@MainActor
final class KeyboardMonitor: ObservableObject {
    @Published private(set) var hasGlobalAccess = CGPreflightListenEventAccess()
    @Published private(set) var isGlobalActive = false
    @Published private(set) var secureInputActive = false
    @Published private(set) var errorMessage: String?

    var onKeyDown: ((UInt16) -> Void)?
    var onKeyUp: ((UInt16) -> Void)?
    /// Ends all held voices when the event stream can no longer guarantee releases.
    var onReset: (() -> Void)?

    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private enum SuspensionReason { case sleep, session }
    private var suspensions = Set<SuspensionReason>()
    private var isStarted = false
    private var pressFilter = KeyboardPressFilter()
    private var physicalEventGate = KeyboardPhysicalEventGate()
    private var lastTapAttempt = Date.distantPast

    func start() {
        guard !isStarted else { refreshPermission(); return }
        isStarted = true
        resetPressFilter()
        refreshPermission()
        installLocalMonitorIfNeeded()

        // Permission can change while System Settings is in front. A timer also
        // keeps the status honest when another application enables secure input.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Global monitoring keeps notes held while switching applications.
                if !self.isGlobalActive { self.resetPressFilter() }
                self.refreshPermission()
            }
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isGlobalActive else { return }
                self.resetPressFilter()
            }
        }
        observeWorkspace(NSWorkspace.willSleepNotification, reason: .sleep, suspended: true)
        observeWorkspace(NSWorkspace.didWakeNotification, reason: .sleep, suspended: false)
        observeWorkspace(NSWorkspace.sessionDidResignActiveNotification, reason: .session, suspended: true)
        observeWorkspace(NSWorkspace.sessionDidBecomeActiveNotification, reason: .session, suspended: false)
    }

    func stop() {
        isStarted = false
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        suspensions.removeAll()
        removeLocalMonitor()
        removeGlobalTap()
        resetPressFilter()
    }

    /// Read-only: this never presents a macOS permission prompt.
    func refreshPermission() {
        let allowed = CGPreflightListenEventAccess()
        if hasGlobalAccess != allowed { hasGlobalAccess = allowed }
        updateSecureInputState()
        guard isStarted, suspensions.isEmpty else { return }
        if let eventTap, !CFMachPortIsValid(eventTap) { removeGlobalTap() }
        if allowed {
            if let eventTap, !CGEvent.tapIsEnabled(tap: eventTap) {
                resetPressFilter()
                CGEvent.tapEnable(tap: eventTap, enable: true)
                if !CGEvent.tapIsEnabled(tap: eventTap) { removeGlobalTap() }
            }
            if eventTap == nil, Date().timeIntervalSince(lastTapAttempt) > 4 {
                installGlobalTap()
            }
        } else if eventTap != nil {
            removeGlobalTap()
        }
        if isGlobalActive { removeLocalMonitor() } else { installLocalMonitorIfNeeded() }
        // A missing key-up (device disconnect or an OS-consumed shortcut) must
        // not leave a voice sounding forever. This checks only held codes and
        // releases only codes reported up, never resets all voices each tick.
        // Restrict it to authorized global input: local fallback must not depend
        // on a system-wide state query whose availability varies with permission.
        if isGlobalActive, !secureInputActive {
            for code in pressFilter.releaseMissingKeys(isPhysicallyDown: {
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
            }) { onKeyUp?(code) }
        }
    }

    /// Call only in response to the user's Enable button.
    func requestPermission() {
        _ = CGRequestListenEventAccess()
        lastTapAttempt = .distantPast
        refreshPermission()
        if !hasGlobalAccess { openPermissionSettings() }
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else { return }
        NSWorkspace.shared.open(url)
    }

    private func installGlobalTap() {
        lastTapAttempt = Date()
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | RemapEventCodec.auxiliaryEventMask
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                // The source is attached exclusively to the main run loop.
                MainActor.assumeIsolated {
                    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(context).takeUnretainedValue()
                    monitor.receiveGlobalEvent(type: type, event: event)
                }
                // Listen-only taps cannot alter events; always return the original.
                return Unmanaged.passUnretained(event)
            },
            userInfo: pointer
        ) else {
            errorMessage = L("全局监听尚未生效。授权后可尝试退出并重新打开 KeyWoo。")
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            errorMessage = L("无法建立键盘监听，当前仍可在应用内试奏。")
            return
        }
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            removeGlobalTap()
            errorMessage = L("全局监听未能启用，当前仍可在应用内试奏。")
            return
        }
        isGlobalActive = true
        errorMessage = nil
        resetPressFilter()
        removeLocalMonitor()
    }

    private func removeGlobalTap() {
        let hadTap = eventTap != nil
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventSource = nil
        eventTap = nil
        isGlobalActive = false
        if hadTap { resetPressFilter() }
    }

    private func installLocalMonitorIfNeeded() {
        guard localMonitor == nil, !isGlobalActive, isStarted else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] event in
            // Remapping emits logical output keys; statistics/music continue to
            // observe physical presses once, not the keys synthesized for apps.
            if let cgEvent = event.cgEvent, RemapEventMarker.isInjected(cgEvent) { return event }
            MainActor.assumeIsolated {
                guard let self, self.isStarted, self.suspensions.isEmpty, !self.isGlobalActive else { return }
                if let physical = KeyboardPhysicalEvent(nativeEvent: event) {
                    self.receivePhysicalEvent(physical)
                }
            }
            return event
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    private func receiveGlobalEvent(type: CGEventType, event: CGEvent) {
        guard isStarted, suspensions.isEmpty else { return }
        guard !RemapEventMarker.isInjected(event) else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            resetPressFilter()
            return
        }
        if let physical = KeyboardPhysicalEvent(type: type, event: event) {
            receivePhysicalEvent(physical)
        }
    }

    /// The active remap tap forwards consumed originals here before dropping
    /// them. The same gate handles native delivery, so each physical press is
    /// sounded and counted once even when both sources report it.
    func receiveConsumedPhysicalEvent(_ event: KeyboardPhysicalEvent) {
        // Accessibility can remain authorized when Input Monitoring is denied.
        // The bridge must respect the same app-only scope shown in the UI.
        guard isGlobalActive || NSApp?.isActive == true else { return }
        receivePhysicalEvent(event)
    }

    private func receivePhysicalEvent(_ event: KeyboardPhysicalEvent) {
        guard isStarted, suspensions.isEmpty, !updateSecureInputState() else { return }
        deliver(physicalEventGate.transition(for: event, filter: &pressFilter), code: event.code)
    }

    private func deliver(_ transition: KeyboardPressFilter.Transition?, code: UInt16) {
        switch transition {
        case .down: onKeyDown?(code)
        case .up: onKeyUp?(code)
        case .tap:
            onKeyDown?(code)
            onKeyUp?(code)
        case nil: break
        }
    }

    private func resetPressFilter() {
        physicalEventGate.reset(ignoringEventsBefore: DispatchTime.now().uptimeNanoseconds)
        pressFilter.reset(flags: CGEventSource.flagsState(.combinedSessionState).rawValue)
        onReset?()
    }

    private func observeWorkspace(_ name: Notification.Name, reason: SuspensionReason, suspended: Bool) {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isStarted else { return }
                if suspended { self.suspensions.insert(reason) }
                else { self.suspensions.remove(reason) }
                self.resetPressFilter()
                if self.suspensions.isEmpty {
                    self.lastTapAttempt = .distantPast
                    self.refreshPermission()
                }
            }
        }
        workspaceObservers.append(observer)
    }

    @discardableResult
    private func updateSecureInputState() -> Bool {
        let active = IsSecureEventInputEnabled()
        if secureInputActive != active {
            secureInputActive = active
            resetPressFilter()
        }
        // Respect secure input regardless of global/local fallback; never disable it.
        return active
    }

    deinit {
        permissionTimer?.invalidate()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
    }
}
