import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics

struct RemapCapturedKey: Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: RemapModifiers
    var isModifier: Bool { !RemapModifiers.forKeyCode(keyCode).isEmpty }
    var mediaAction: RemapMediaAction? { RemapMediaAction.forTriggerCode(keyCode) }
}

/// UI/persistence facade. Permission is requested only by requestAccessibility,
/// never on launch, on a timer, or because an imported file was enabled elsewhere.
@MainActor
final class RemapController: ObservableObject {
    @Published private(set) var configuration: RemapConfiguration
    @Published private(set) var isActive = false
    @Published private(set) var hasAccessibilityAccess = false
    @Published private(set) var isSuspended = false
    @Published private(set) var secureInputActive = false
    @Published private(set) var isCapturing = false
    @Published private(set) var lastCapturedKey: RemapCapturedKey?
    @Published private(set) var activeLayerIDs: [UUID] = []
    @Published private(set) var errorMessage: String?
    var onConsumedPhysicalEvent: ((KeyboardPhysicalEvent) -> Void)?
    var isEnabled: Bool { configuration.isEnabled }
    var validationIssues: [RemapValidationIssue] { RemapValidation.issues(in: configuration) }
    private let store: RemapStore
    private var worker: RemapTapWorker?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var suspensions = Set<String>()
    private var generation: UInt64 = 0
    private var storageError: String?
    private var localCaptureMonitor: Any?
    private var localDecoder = RemapInputDecoder()
    private var captureShield = RemapCaptureShield()

    init(store: RemapStore = RemapStore()) {
        self.store = store
        do { configuration = try store.load() ?? .empty }
        catch {
            configuration = .empty
            storageError = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func start() {
        guard worker == nil else { refreshPermission(); return }
        generation &+= 1
        let generation = self.generation
        let worker = RemapTapWorker(profile: configuration.activeProfile!, reportPhysicalInput: { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onConsumedPhysicalEvent?(event)
            }
        }) { [weak self] update in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                if self.hasAccessibilityAccess != update.allowed { self.hasAccessibilityAccess = update.allowed }
                if self.isActive != update.active { self.isActive = update.active }
                if self.secureInputActive != update.secure { self.secureInputActive = update.secure }
                let suspended = update.secure || self.isCapturing || !self.suspensions.isEmpty
                if self.isSuspended != suspended { self.isSuspended = suspended }
                if self.activeLayerIDs != update.layers { self.activeLayerIDs = update.layers }
                if let captured = update.captured {
                    self.receiveGlobalCapture(captured, applicationIsActive: NSApp?.isActive == true)
                }
                let error = self.storageError ?? update.error
                if self.errorMessage != error { self.errorMessage = error }
                if update.emergencyDisabled { self.setEnabled(false); self.endCapture() }
            }
        }
        self.worker = worker
        worker.start()
        updateWorker()
        observe(NSWorkspace.willSleepNotification, reason: "sleep", suspended: true)
        observe(NSWorkspace.didWakeNotification, reason: "sleep", suspended: false)
        observe(NSWorkspace.sessionDidResignActiveNotification, reason: "session", suspended: true)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, reason: "session", suspended: false)
    }
    func stop() {
        generation &+= 1
        removeLocalCapture()
        worker?.stop(); worker = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll(); suspensions.removeAll()
        isActive = false; isCapturing = false; isSuspended = false
        activeLayerIDs = []; lastCapturedKey = nil
    }
    func setEnabled(_ enabled: Bool) {
        var changed = configuration; changed.isEnabled = enabled
        if !enabled {
            // Emergency disable must remain effective even on a full/read-only
            // disk. Report the persistence failure rather than keep intercepting.
            configuration = changed
            updateWorker()
            do { try store.save(changed); storageError = nil; errorMessage = nil }
            catch { storageError = error.localizedDescription; errorMessage = storageError }
            return
        }
        do { try apply(configuration: changed) }
        catch { errorMessage = error.localizedDescription }
    }
    func apply(configuration candidate: RemapConfiguration) throws {
        try RemapValidation.validate(candidate)
        // A failed write leaves both the active configuration and the saved file
        // intact; UI cannot claim a configuration was applied but forget it later.
        try store.save(candidate)
        configuration = candidate
        storageError = nil
        errorMessage = nil
        updateWorker()
    }
    func selectProfile(_ id: UUID) throws {
        var changed = configuration; changed.activeProfileID = id
        try apply(configuration: changed)
    }
    func beginCapture() {
        lastCapturedKey = nil; isCapturing = true; isSuspended = true; updateWorker()
        installLocalCapture()
    }
    func endCapture() {
        isCapturing = false; lastCapturedKey = nil
        if !captureShield.isDraining { removeLocalCapture() }
        isSuspended = secureInputActive || !suspensions.isEmpty; updateWorker()
    }
    func refreshPermission() { worker?.refresh() }
    /// The global tap can run ahead of NSApplication.sendEvent. If its callback
    /// completed an in-app recording first, SwiftUI could remove the local shield
    /// before Command-Q arrived. Ordinary in-app keys must complete locally.
    /// The system can route media controls without delivering them to AppKit.
    func receiveGlobalCapture(_ captured: RemapCapturedKey, applicationIsActive: Bool) {
        guard isCapturing, !applicationIsActive || captured.mediaAction != nil else { return }
        lastCapturedKey = captured
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibilityAccess = AXIsProcessTrustedWithOptions(options)
        refreshPermission()
    }
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func importConfiguration(from url: URL) throws {
        var imported = try RemapStore.read(from: url)
        // Import is editing, not permission to activate somebody else's mapping.
        imported.isEnabled = false
        try apply(configuration: imported)
    }
    func exportConfiguration(to url: URL) throws { try RemapStore.write(configuration, to: url) }
    private func updateWorker() {
        guard let profile = configuration.activeProfile else { return }
        worker?.configure(profile: profile, enabled: isEnabled, capturing: isCapturing, suspended: !suspensions.isEmpty)
    }
    private func installLocalCapture() {
        guard localCaptureMonitor == nil else { return }
        localDecoder.reset(flags: CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue)),
            fnIsPhysicallyDown: CGPreflightListenEventAccess() ? CGEventSource.keyState(.hidSystemState, key: 63) : nil)
        localCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard let self, self.isCapturing || self.captureShield.isDraining,
                      !IsSecureEventInputEnabled(), NSApp?.isActive == true else { return event }
                if let cgEvent = event.cgEvent, RemapEventMarker.isInjected(cgEvent) { return event }
                // In our own editor, recording Command-Q must not quit the app.
                // This local shield never intercepts another application's input.
                let input: RemapInput?
                if event.type == .systemDefined {
                    input = self.localDecoder.decodeAuxiliary(event)
                    guard input != nil else { return event }
                } else {
                    let type: CGEventType = event.type == .keyDown ? .keyDown : event.type == .keyUp ? .keyUp : .flagsChanged
                    input = self.localDecoder.decode(type: type, code: event.keyCode,
                        flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
                        isRepeat: event.type == .keyDown && event.isARepeat)
                }
                let shouldShield = input.map { self.captureShield.shouldSuppress($0, isCapturing: self.isCapturing) }
                    ?? self.isCapturing
                if self.isCapturing, let input, input.kind != .up, !input.isRepeat {
                    if input.keyCode == 53 && input.modifiers.isSuperset(of: [.control, .option, .command]) {
                        self.setEnabled(false); self.endCapture()
                    } else {
                        self.lastCapturedKey = RemapCapturedKey(keyCode: input.keyCode,
                            modifiers: input.modifiers.subtracting(RemapModifiers.forKeyCode(input.keyCode)))
                    }
                }
                if !self.isCapturing && !self.captureShield.isDraining { self.removeLocalCapture() }
                return shouldShield ? nil : event
            }
        }
    }
    private func removeLocalCapture() {
        if let localCaptureMonitor { NSEvent.removeMonitor(localCaptureMonitor) }
        localCaptureMonitor = nil
        captureShield.reset()
    }
    private func observe(_ name: Notification.Name, reason: String, suspended: Bool) {
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if suspended { self.suspensions.insert(reason) } else { self.suspensions.remove(reason) }
                self.updateWorker()
            }
        })
    }
    deinit {
        worker?.stop()
        if let localCaptureMonitor { NSEvent.removeMonitor(localCaptureMonitor) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

/// Owns the active tap and all mutable remapping state on one dedicated run loop.
/// The callback never waits for SwiftUI, disk, or main-thread model mutations.
private final class RemapTapWorker: @unchecked Sendable {
    struct Update {
        var allowed: Bool
        var active: Bool
        var secure: Bool
        var layers: [UUID]
        var captured: RemapCapturedKey?
        var error: String?
        var emergencyDisabled = false
    }
    private let report: (Update) -> Void
    private let reportPhysicalInput: (KeyboardPhysicalEvent) -> Void
    private let lifecycleLock = NSLock()
    private var runLoop: CFRunLoop?
    private var pending: [() -> Void] = []
    private var finished = false
    private var stopRequested = false
    // Fields below are accessed exclusively on the worker run loop.
    private var state: RemapStateMachine
    private var decoder = RemapInputDecoder()
    private var consumerPresses = RemapConsumerPresses()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var eventSource: CGEventSource?
    private var enabled = false
    private var capturing = false
    private var suspended = false
    private var allowed = false
    private var secure = false
    private var error: String?
    private var lastAttempt = -Double.infinity
    private var lastReport: String?
    private var lastPhysicalFlags: CGEventFlags = []

    init(profile: RemapProfile, reportPhysicalInput: @escaping (KeyboardPhysicalEvent) -> Void,
         report: @escaping (Update) -> Void) {
        state = RemapStateMachine(profile: profile); self.report = report
        self.reportPhysicalInput = reportPhysicalInput
    }
    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "KeyWoo keyboard remapping"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
    func configure(profile: RemapProfile, enabled: Bool, capturing: Bool, suspended: Bool) {
        submit { [self] in
            let changed = state.profile != profile || self.enabled != enabled
                || self.capturing != capturing || self.suspended != suspended
            if changed {
                refreshPhysicalSnapshot()
                post(state.replaceProfile(profile))
                resetDecoder()
            }
            self.enabled = enabled; self.capturing = capturing; self.suspended = suspended
            lastAttempt = -Double.infinity
            maintain()
        }
    }
    func refresh() { submit { [self] in lastAttempt = -Double.infinity; maintain() } }
    func stop() {
        let completed = DispatchSemaphore(value: 0)
        let cleanup = { [self] in
            refreshPhysicalSnapshot()
            post(state.releaseAll()); removeTap()
            timer?.invalidate(); timer = nil
            lifecycleLock.lock(); finished = true; lifecycleLock.unlock()
            CFRunLoopStop(CFRunLoopGetCurrent())
            completed.signal()
        }
        lifecycleLock.lock()
        guard !finished && !stopRequested else { lifecycleLock.unlock(); return }
        stopRequested = true
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, cleanup)
            CFRunLoopWakeUp(runLoop)
        } else { pending.append(cleanup) }
        lifecycleLock.unlock()
        // Application termination must not return before releasing synthetic
        // holds. The callback never waits on the main thread, so this bounded
        // shutdown join cannot form a main/worker dispatch cycle.
        _ = completed.wait(timeout: .now() + 0.5)
    }
    private func submit(_ operation: @escaping () -> Void) {
        lifecycleLock.lock()
        guard !finished && !stopRequested else { lifecycleLock.unlock(); return }
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, operation)
            CFRunLoopWakeUp(runLoop)
        } else { pending.append(operation) }
        lifecycleLock.unlock()
    }
    private func run() {
        autoreleasepool {
            eventSource = CGEventSource(stateID: .privateState)
            eventSource?.userData = RemapEventMarker.value
            resetDecoder()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                autoreleasepool { self?.maintain() }
            }
            self.timer = timer; RunLoop.current.add(timer, forMode: .common)
            lifecycleLock.lock()
            runLoop = CFRunLoopGetCurrent()
            let initial = pending; pending.removeAll()
            lifecycleLock.unlock()
            for action in initial { action() }
            lifecycleLock.lock(); let shouldRun = !finished; lifecycleLock.unlock()
            if shouldRun { CFRunLoopRun() }
            lifecycleLock.lock(); runLoop = nil; finished = true; pending.removeAll(); lifecycleLock.unlock()
            eventSource = nil
        }
    }
    private func maintain() {
        let newAllowed = AXIsProcessTrusted()
        let newSecure = IsSecureEventInputEnabled()
        if allowed != newAllowed || secure != newSecure {
            refreshPhysicalSnapshot()
            post(state.releaseAll())
            resetDecoder()
            allowed = newAllowed; secure = newSecure
        }
        let shouldHaveTap = allowed && (enabled || capturing) && !suspended && !secure
        if shouldHaveTap {
            if let tap, !CFMachPortIsValid(tap) { removeTap() }
            if let tap, !CGEvent.tapIsEnabled(tap: tap) {
                refreshPhysicalSnapshot()
                post(state.releaseAll()); CGEvent.tapEnable(tap: tap, enable: true)
            }
            if tap == nil, ProcessInfo.processInfo.systemUptime - lastAttempt > 3 { installTap() }
        } else if tap != nil { refreshPhysicalSnapshot(); post(state.releaseAll()); removeTap() }
        if shouldHaveTap && !capturing && CGPreflightListenEventAccess() {
            var states: [UInt16: Bool] = [:]
            func physicallyDown(_ code: UInt16) -> Bool {
                if let known = states[code] { return known }
                let value = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
                states[code] = value; return value
            }
            post(state.releaseMissingKeys(isPhysicallyDown: physicallyDown))
            decoder.releaseMissingModifiers(isPhysicallyDown: physicallyDown)
        }
        publish()
    }
    private func installTap() {
        lastAttempt = ProcessInfo.processInfo.systemUptime
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | RemapEventCodec.auxiliaryEventMask
        // The existing physical monitor is listenOnly/head at the same session
        // stage, so it sees the original press before this tail filter consumes it.
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return autoreleasepool {
                    Unmanaged<RemapTapWorker>.fromOpaque(context).takeUnretainedValue()
                        .receive(proxy: proxy, type: type, event: event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            error = "全局改键未能启用，请检查辅助功能授权后重试。"; return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap); error = "无法建立全局改键事件源。"; return
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        error = CGEvent.tapIsEnabled(tap: tap) ? nil : "全局改键事件源未能启动。"
    }
    private func removeTap() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        consumerPresses.reset()
        source = nil; tap = nil
    }
    private func receive(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            refreshPhysicalSnapshot()
            post(state.releaseAll())
            resetDecoder()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            publish(); return Unmanaged.passUnretained(event)
        }
        guard !RemapEventMarker.isInjected(event) else { return Unmanaged.passUnretained(event) }
        // Respect secure input in the callback as well as the timer. We never
        // request access to protected fields or disable the system's protection.
        if IsSecureEventInputEnabled() {
            if !secure { secure = true; refreshPhysicalSnapshot(); post(state.releaseAll()); publish() }
            return Unmanaged.passUnretained(event)
        }
        guard !suspended else { return Unmanaged.passUnretained(event) }
        if type.rawValue == UInt32(NSEvent.EventType.systemDefined.rawValue) {
            guard let nativeEvent = NSEvent(cgEvent: event), let edge = decoder.decodeAuxiliary(nativeEvent) else {
                return Unmanaged.passUnretained(event)
            }
            return receiveConsumer(edge, event: event, proxy: proxy)
        }
        lastPhysicalFlags = event.flags
        let code = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        guard code <= 127 else { return Unmanaged.passUnretained(event) }
        guard let input = decoder.decode(type: type, code: code, flags: event.flags,
            isRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0) else {
            if enabled && !capturing {
                let flags = state.modifiersForPassthrough(RemapEventCodec.modifiers(from: event.flags))
                event.flags = RemapEventCodec.flags(flags, preserving: event.flags, keyCode: code,
                    heldModifierKeys: state.heldOutputKeys, suppressedPhysicalKeys: state.suppressedPhysicalModifierKeyCodes)
            }
            return Unmanaged.passUnretained(event)
        }
        if input.kind == .down && !input.isRepeat && code == 53
            && input.modifiers.isSuperset(of: [.control, .option, .command]) {
            forwardConsumedPhysicalEvent(type: type, event: event)
            post(state.releaseAll(), proxy: proxy)
            enabled = false
            report(Update(allowed: allowed, active: false, secure: secure,
                          layers: [], captured: nil, error: nil, emergencyDisabled: true))
            return nil
        }
        if capturing {
            if input.kind != .up && !input.isRepeat {
                publish(captured: .init(keyCode: code,
                    modifiers: input.modifiers.subtracting(RemapModifiers.forKeyCode(code))))
            }
            return Unmanaged.passUnretained(event)
        }
        guard enabled else { return Unmanaged.passUnretained(event) }
        let decision = state.process(input)
        if decision.suppressOriginal { forwardConsumedPhysicalEvent(type: type, event: event) }
        post(decision.outputs, proxy: proxy)
        publish()
        if decision.suppressOriginal { return nil }
        if let flags = decision.passthroughModifiers {
            event.flags = RemapEventCodec.flags(flags, preserving: event.flags, keyCode: code,
                heldModifierKeys: state.heldOutputKeys, suppressedPhysicalKeys: state.suppressedPhysicalModifierKeyCodes)
        }
        return Unmanaged.passUnretained(event)
    }
    private func receiveConsumer(_ edge: RemapInput, event: CGEvent, proxy: CGEventTapProxy) -> Unmanaged<CGEvent>? {
        var outputs: [RemapOutput] = []
        let suppress = consumerPresses.handle(edge) { press in
            if capturing {
                publish(captured: .init(keyCode: press.keyCode, modifiers: press.modifiers))
                return false
            }
            guard enabled else { return false }
            let decision = state.process(press)
            outputs = decision.outputs
            return decision.suppressOriginal
        }
        if suppress { forwardConsumedPhysicalEvent(type: event.type, event: event) }
        post(outputs, proxy: proxy)
        return suppress ? nil : Unmanaged.passUnretained(event)
    }
    private func forwardConsumedPhysicalEvent(type: CGEventType, event: CGEvent) {
        guard let physical = KeyboardPhysicalEvent(type: type, event: event) else { return }
        reportPhysicalInput(physical)
    }
    private func post(_ outputs: [RemapOutput], proxy: CGEventTapProxy? = nil) {
        let events = RemapEventCodec.outputEvents(outputs, source: eventSource, physicalFlags: lastPhysicalFlags,
            finalHeldKeys: state.heldOutputKeys, suppressedPhysicalKeys: state.suppressedPhysicalModifierKeyCodes)
        for event in events {
            if let proxy { event.tapPostEvent(proxy) }
            else { event.post(tap: .cgSessionEventTap) }
        }
    }
    private func resetDecoder() {
        if IsSecureEventInputEnabled() {
            lastPhysicalFlags = []
            decoder.reset(flags: [])
            return
        }
        let canReadPhysicalState = CGPreflightListenEventAccess()
        let flags = CGEventSource.flagsState(canReadPhysicalState ? .hidSystemState : .combinedSessionState)
        lastPhysicalFlags = flags
        if canReadPhysicalState {
            // Only at lifecycle boundaries: a normal key already held before the
            // tap starts is an existing target-app owner too. E.g. physical B
            // must survive pressing/releasing a newly enabled A → B mapping.
            let held = Set((UInt16(0)...UInt16(127)).filter {
                $0 != 57 && CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0))
            })
            post(state.releaseMissingKeys { held.contains($0) })
            decoder.reset(flags: flags, fnIsPhysicallyDown: held.contains(63))
            state.seedPhysicalKeys(held)
        } else {
            decoder.reset(flags: flags)
            state.seedPhysicalModifiers(decoder.heldPhysicalModifierKeyCodes)
        }
    }
    private func refreshPhysicalSnapshot() {
        if IsSecureEventInputEnabled() {
            // End only our outputs without polling protected physical input.
            lastPhysicalFlags = []
            _ = state.modifiersForPassthrough([])
            return
        }
        guard CGPreflightListenEventAccess() else { return }
        lastPhysicalFlags = CGEventSource.flagsState(.hidSystemState)
        _ = state.modifiersForPassthrough(RemapEventCodec.modifiers(from: lastPhysicalFlags))
        var states: [UInt16: Bool] = [:]
        func physicallyDown(_ code: UInt16) -> Bool {
            if let known = states[code] { return known }
            let value = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
            states[code] = value; return value
        }
        post(state.releaseMissingKeys(isPhysicallyDown: physicallyDown))
        decoder.releaseMissingModifiers(isPhysicallyDown: physicallyDown)
    }
    private func publish(captured: RemapCapturedKey? = nil) {
        let active = enabled && !capturing && !suspended && !secure && tap.map { CGEvent.tapIsEnabled(tap: $0) } == true
        let fingerprint = "\(allowed)-\(active)-\(secure)-\(state.activeLayerIDs)-\(error ?? "")"
        guard captured != nil || fingerprint != lastReport else { return }
        lastReport = fingerprint
        report(Update(allowed: allowed, active: active, secure: secure, layers: state.activeLayerIDs,
                      captured: captured, error: error))
    }
}
