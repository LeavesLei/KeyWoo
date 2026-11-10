import SwiftUI
import AppKit

struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityProbe {
        let view = WindowVisibilityProbe()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowVisibilityProbe, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: WindowVisibilityProbe, coordinator: ()) {
        nsView.stopObserving()
    }
}

@MainActor
final class WindowVisibilityProbe: NSView {
    var onChange: ((Bool) -> Void)?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var revision = 0
    private var lastVisibility: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        observedWindow = window
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification,
                         NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification,
                         NSWindow.didBecomeKeyNotification,
                         NSWindow.willCloseNotification] {
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        self?.scheduleUpdate(forceHidden: note.name == NSWindow.willCloseNotification)
                    }
                }
                observers.append(token)
            }
        }
        scheduleUpdate()
    }

    private func scheduleUpdate(forceHidden: Bool = false) {
        revision += 1
        let expectedRevision = revision
        // Avoid changing SwiftUI state during NSView attachment/update. Reading
        // on the next run-loop turn also sees the final order/close state.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == expectedRevision else { return }
            let visible: Bool
            if let window = self.observedWindow {
                // A covered window must keep its controls for accessibility
                // and focus restoration. Only truly hidden/miniaturized windows
                // release the presentation subtree.
                visible = !forceHidden && window.isVisible && !window.isMiniaturized && !NSApp.isHidden
            } else {
                visible = false
            }
            guard self.lastVisibility != visible else { return }
            self.lastVisibility = visible
            self.onChange?(visible)
        }
    }

    func stopObserving() {
        removeObservers()
        observedWindow = nil
        onChange = nil
    }

    private func removeObservers() {
        revision += 1
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }
}

