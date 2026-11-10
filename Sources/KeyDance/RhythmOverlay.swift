import AppKit
import SwiftUI
import Combine

/// A desktop companion which never becomes the keyboard's destination.
@MainActor
final class RhythmOverlayController: NSObject, NSWindowDelegate {
    private let feedback: RhythmFeedbackModel
    private let defaults: UserDefaults
    private let onClose: () -> Void
    private var panel: NSPanel?
    private var clickThrough = false
    private var visualStyle: RhythmVisualStyle
    private var normalFrame: NSRect?
    private var applyingGeometry = false
    private var screenObserver: NSObjectProtocol?
    private var inputObservation: AnyCancellable?
    private var lastRoutedHit: TimeInterval?
    private let size = NSSize(width: 340, height: 224)
    private let edgeHeight: CGFloat = 144
    private let positionKey = "rhythmOverlayPosition"
    // Embedders and native integration tests can supply a target rectangle and
    // a real panel factory. Normal desktop presentation uses the live screens.
    private let screenFrame: (() -> NSRect)?
    private let makePanel: ((NSRect) -> NSPanel)?

    init(feedback: RhythmFeedbackModel, defaults: UserDefaults,
         screenFrame: (() -> NSRect)? = nil, makePanel: ((NSRect) -> NSPanel)? = nil,
         onClose: @escaping () -> Void) {
        self.screenFrame = screenFrame
        self.makePanel = makePanel
        self.feedback = feedback
        self.defaults = defaults
        self.onClose = onClose
        visualStyle = feedback.visualStyle
        super.init()
        inputObservation = feedback.$dynamics.sink { [weak self] state in
            guard let self, let hit = state.lastHit, hit != self.lastRoutedHit else { return }
            self.lastRoutedHit = hit
            if self.visualStyle == .edgeGlow, self.panel?.isVisible == true { self.positionAtScreenBottom() }
        }
    }

    func show() {
        if panel == nil { createPanel() }
        guard let panel else { return }
        if visualStyle == .edgeGlow { positionAtScreenBottom() }
        else { constrainToScreen(panel) }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        feedback.reset()
        lastRoutedHit = nil
    }

    /// Geometry belongs to the controller, separate from the shared renderer.
    func setVisualStyle(_ style: RhythmVisualStyle) {
        guard style != visualStyle else { return }
        let wasEdge = visualStyle == .edgeGlow
        if !wasEdge, let panel { normalFrame = panel.frame }
        visualStyle = style
        guard let panel else { return }
        // Ordinary style changes redraw through feedback; only entering or
        // leaving the screen-edge mode requires native content/geometry changes.
        guard wasEdge || style == .edgeGlow else { return }
        if style == .edgeGlow {
            panel.ignoresMouseEvents = true
            panel.acceptsMouseMovedEvents = false
        }
        applyingGeometry = true
        if style == .edgeGlow {
            positionAtScreenBottom()
        } else {
            let restored = normalFrame ?? NSRect(origin: defaultOrigin(), size: size)
            panel.setFrame(NSRect(origin: restored.origin, size: size), display: true)
            constrainToScreen(panel)
        }
        applyingGeometry = false
        panel.ignoresMouseEvents = style == .edgeGlow || clickThrough
        panel.acceptsMouseMovedEvents = style != .edgeGlow
        installContent()
        if style != .edgeGlow { normalFrame = panel.frame; savePosition(panel) }
    }

    func setClickThrough(_ value: Bool) {
        clickThrough = value
        panel?.ignoresMouseEvents = visualStyle == .edgeGlow || value
        if visualStyle != .edgeGlow { installContent() }
    }

    func resetPosition() {
        defaults.removeObject(forKey: positionKey)
        let restored = NSRect(origin: defaultOrigin(), size: size)
        normalFrame = restored
        guard let panel else { return }
        if visualStyle == .edgeGlow { positionAtScreenBottom() }
        else { panel.setFrame(restored, display: true); savePosition(panel) }
    }

    private func createPanel() {
        let frame = NSRect(origin: defaultOrigin(), size: size)
        let panel = makePanel?(frame) ?? RhythmPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = visualStyle != .edgeGlow
        panel.ignoresMouseEvents = visualStyle == .edgeGlow || clickThrough
        panel.animationBehavior = .none
        panel.title = L("律动悬浮窗")
        panel.delegate = self
        self.panel = panel
        if let position = defaults.array(forKey: positionKey) as? [Double], position.count == 2,
           position.allSatisfy(\.isFinite) {
            applyingGeometry = true
            panel.setFrameOrigin(NSPoint(x: position[0], y: position[1]))
            applyingGeometry = false
        }
        normalFrame = panel.frame
        if visualStyle == .edgeGlow { positionAtScreenBottom() }
        installContent()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if self.visualStyle == .edgeGlow { self.positionAtScreenBottom() }
                else { self.constrainToScreen(panel) }
            }
        }
    }

    private func installContent() {
        guard let panel else { return }
        if visualStyle == .edgeGlow {
            // No interaction wrapper: no 0.004-alpha hit backing, tracking area,
            // close button, or hover chrome spans the user's desktop.
            let host = NSHostingView(rootView: RhythmOverlayView(feedback: feedback))
            host.frame = NSRect(origin: .zero, size: panel.frame.size)
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
        } else {
            panel.contentView = RhythmInteractionView(
                feedback: feedback, clickThrough: clickThrough, onClose: { [weak self] in self?.onClose() })
        }
    }

    private func positionAtScreenBottom() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSApplication.shared.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screenBounds = screenFrame?() ?? screen?.frame else { return }
        // The physical frame includes the Dock region; visibleFrame would float
        // the glow above it. Keep the normal floating level and click-through.
        let frame = NSRect(x: screenBounds.minX, y: screenBounds.minY,
                           width: screenBounds.width, height: min(edgeHeight, screenBounds.height))
        guard panel.frame != frame else { return }
        let wasApplying = applyingGeometry
        applyingGeometry = true
        panel.setFrame(frame, display: true)
        applyingGeometry = wasApplying
    }

    private func defaultOrigin() -> NSPoint {
        let screen = screenFrame?() ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
    }

    private func constrainToScreen(_ panel: NSPanel) {
        let screens = screenFrame.map { [$0()] } ?? NSScreen.screens.map(\.visibleFrame)
        let screen = screens.max { a, b in
            let ia = a.intersection(panel.frame), ib = b.intersection(panel.frame)
            return max(0, ia.width) * max(0, ia.height) < max(0, ib.width) * max(0, ib.height)
        } ?? NSScreen.main?.visibleFrame
        guard let screen else { return }
        let origin = NSPoint(x: min(max(panel.frame.minX, screen.minX), max(screen.minX, screen.maxX - size.width)),
                             y: min(max(panel.frame.minY, screen.minY), max(screen.minY, screen.maxY - size.height)))
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    private func savePosition(_ panel: NSWindow) {
        guard visualStyle != .edgeGlow, !applyingGeometry else { return }
        defaults.set([panel.frame.origin.x, panel.frame.origin.y], forKey: positionKey)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel, visualStyle != .edgeGlow, !applyingGeometry else { return }
        normalFrame = panel.frame
        savePosition(panel)
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

private final class RhythmPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// AppKit owns the entire hit surface. SwiftUI is only a renderer here: neither
/// hosting-view event routing nor key-window hover behavior can intercept drags.
private final class RhythmInteractionView: NSView {
    private let hosting: NSHostingView<RhythmOverlayView>
    private let controls = RhythmControlBar()
    private let label = NSTextField(labelWithString: "")
    private let closeButton = RhythmCloseButton()
    private let clickThrough: Bool
    private let onClose: () -> Void
    private var tracking: NSTrackingArea?
    private var languageObservation: AnyCancellable?

    init(feedback: RhythmFeedbackModel, clickThrough: Bool, onClose: @escaping () -> Void) {
        hosting = NSHostingView(rootView: RhythmOverlayView(feedback: feedback))
        self.clickThrough = clickThrough
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 224))
        autoresizingMask = [.width, .height]
        wantsLayer = true
        // A virtually clear backing gives WindowServer a continuous hit region,
        // including the gaps between the translucent filaments.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.004).cgColor
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)

        controls.isHidden = true
        addSubview(controls)
        let hand = NSImageView()
        hand.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: nil)
        hand.contentTintColor = NSColor.white.withAlphaComponent(0.86)
        hand.frame = NSRect(x: 10, y: 7, width: 14, height: 14)
        controls.addSubview(hand)

        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.86)
        label.isSelectable = false
        label.setAccessibilityElement(false)
        controls.addSubview(label)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        closeButton.target = self
        closeButton.action = #selector(closeOverlay)
        closeButton.setAccessibilityIdentifier("rhythm-overlay-close")
        controls.addSubview(closeButton)
        updateLabels()
        languageObservation = feedback.objectWillChange.sink { [weak self] _ in
            self?.updateLabels()
        }
        setAccessibilityLabel(L("律动悬浮窗"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !clickThrough, !isHidden, bounds.contains(local) else { return nil }
        if !controls.isHidden {
            let inControls = controls.convert(local, from: self)
            if closeButton.frame.contains(inControls) { return closeButton }
        }
        return self
    }

    override func layout() {
        super.layout()
        placeControls()
    }

    private func updateLabels() {
        let text = L("拖动以移动")
        guard label.stringValue != text else { return }
        label.stringValue = text
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 30, y: 7)
        closeButton.toolTip = L("关闭律动悬浮窗")
        closeButton.setAccessibilityLabel(L("关闭律动悬浮窗"))
        setAccessibilityLabel(L("律动悬浮窗"))
        placeControls()
    }

    private func placeControls() {
        let width = max(128, label.frame.width + 66)
        controls.frame = NSRect(x: (bounds.width - width) / 2, y: 9, width: width, height: 28)
        closeButton.frame = NSRect(x: width - 29, y: 3, width: 23, height: 22)
        controls.needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !clickThrough { addCursorRect(bounds, cursor: .openHand) }
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { controls.isHidden = clickThrough }
    override func mouseExited(with event: NSEvent) { controls.isHidden = true }
    override func mouseMoved(with event: NSEvent) { controls.isHidden = clickThrough }

    override func mouseDown(with event: NSEvent) {
        guard !clickThrough, let window else { return }
        controls.isHidden = false
        NSCursor.closedHand.set()
        window.performDrag(with: event)
        let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        controls.isHidden = !bounds.contains(location)
        NSCursor.openHand.set()
    }

    @objc private func closeOverlay() { onClose() }
}

private final class RhythmCloseButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class RhythmControlBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.62).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        capsule.lineWidth = 0.5
        capsule.stroke()
        let separator = NSBezierPath()
        separator.move(to: NSPoint(x: bounds.width - 33, y: 8))
        separator.line(to: NSPoint(x: bounds.width - 33, y: 20))
        NSColor.white.withAlphaComponent(0.2).setStroke()
        separator.lineWidth = 0.5
        separator.stroke()
    }
}

private struct RhythmOverlayView: View {
    @ObservedObject var feedback: RhythmFeedbackModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60,
                                paused: !feedback.isAnimating
                                    && max(feedback.musicSpectrum.level, feedback.musicSpectrum.contour?.level ?? 0) < 0.001)) { timeline in
            // The frame date is a value input to the Canvas view. Reading uptime
            // only inside its drawing closure can leave SwiftUI caching one frame.
            // Convert this scheduled frame using a fresh clock pair, so sleep
            // and wall-clock corrections cannot stale a persistent anchor.
            let frameTime = ProcessInfo.processInfo.systemUptime
                - max(0, Date().timeIntervalSince(timeline.date))
            RhythmFrameCanvas(dynamics: feedback.dynamics, time: frameTime,
                              intensity: feedback.intensity, reducedMotion: reduceMotion,
                              style: feedback.visualStyle, flashesEnabled: feedback.flashesEnabled,
                              spectrum: feedback.musicSpectrum)
                .opacity(feedback.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct RhythmFrameCanvas: View {
    let dynamics: RhythmDynamics
    let time: TimeInterval
    let intensity: Double
    let reducedMotion: Bool
    let style: RhythmVisualStyle
    let flashesEnabled: Bool
    let spectrum: AudioSpectrum

    var body: some View {
        Canvas { context, size in
            RhythmPainter.draw(context: &context, size: size, dynamics: dynamics,
                               time: time, intensity: intensity, reducedMotion: reducedMotion, style: style, flashesEnabled: flashesEnabled, spectrum: spectrum)
        }
    }
}

/// Pure geometry for the music-only layer. Normalized horizontal bounds keep
/// both regions outside a central dark gap, even during the strongest beat.
enum EdgeMusicGeometry {
    enum Profile: Equatable { case bass, detail }

    struct Region: Equatable {
        let centerX: Double
        let radiusX: Double
        let bodyHeight: Double
        let bodyOpacity: Double
        let crestX: Double
        let crestRadiusX: Double
        let crestHeight: Double
        let crestOpacity: Double
        let hue: Double
        let profile: Profile
        let shoulder: Double
    }

    static func regions(spectrum: AudioSpectrum, time: TimeInterval, intensity: Double,
                        keyboardDrive: Double, reducedMotion: Bool, keyboardEnergy: Double? = nil) -> [Region] {
        let low = spectrum.low, mid = spectrum.mid, high = spectrum.high
        let level = max(spectrum.level, low * 0.55 + mid * 0.30 + high * 0.15)
        let beat = spectrum.beat
        // Static fixtures can omit the contour. Its live beat has already been
        // perceptually mapped before smoothing; never exponentiate it again.
        let shape = spectrum.contour ?? AudioContour(low: low, mid: mid, high: high,
                                                     level: level, beat: pow(beat, 0.70))
        let shapeLevel = max(shape.level, shape.low * 0.55 + shape.mid * 0.30 + shape.high * 0.15)
        guard max(max(level, beat), max(shapeLevel, shape.beat)) > 0.001 else { return [] }
        let gain = min(1.35, max(0.4, intensity))
        // Live rendering supplies the continuous typing envelope. The fallback
        // keeps standalone geometry callers independent of keyboard dynamics.
        let engagement = min(1, max(0, keyboardEnergy ?? keyboardDrive))
        let room = 1 - engagement * 0.65
        let typingComfort = 1 - engagement * 0.28
        // Anchors never follow beat or time. Each side gets its own spectral
        // shape; total loudness must not overwrite the difference between them.
        let transient = pow(beat, 0.70) * sqrt(level)
        func band(low: Double, mid: Double, high: Double, left: Bool) -> Double {
            // The normalized soft mapping leaves headroom in loud mixtures.
            let right = (low * 0.08 + mid * 0.48 + high * 0.68) / 1.24
            return left ? low * 0.86 + mid * 0.12 + high * 0.02
                        : right * 1.20 / (1 + right * 0.20)
        }
        return (0..<2).map { side in
            let left = side == 0
            let rawBand = band(low: low, mid: mid, high: high, left: left)
            let shapeBand = band(low: shape.low, mid: shape.mid, high: shape.high, left: left)
            let rawBody = pow(max(0, (rawBand - 0.025) / 0.975), 1.22)
            let body = pow(max(0, (shapeBand - 0.025) / 0.975), 1.22)
            let center = left ? 0.16 : 0.84
            let radius = reducedMotion ? (left ? 0.12 : 0.10)
                                       : (left ? 0.105 + body * 0.048 : 0.090 + body * 0.037)
            let steadyLight = 0.26 * pow(rawBody, 0.72)
            let localBeat = transient * (0.22 + 0.78 * sqrt(rawBand))
            let shapeBeat = shape.beat * sqrt(shapeLevel) * (0.22 + 0.78 * sqrt(shapeBand))
            // Onsets lift the existing rounded contour vertically. No control
            // point travels sideways. Continuous typing energy gently reduces
            // the motion, without letting an individual key jerk its height.
            let rawLift = (left ? 22 : 20) * shapeBeat * sqrt(gain)
            // Enter the upper range with a continuous slope instead of hitting
            // a flat cap and suddenly releasing all its velocity at once.
            let excess = min(12, max(0, rawLift - 16))
            let softLift = rawLift <= 16 ? rawLift : 16 + excess - excess * excess / 24
            let beatLift = reducedMotion ? 0 : softLift * typingComfort
            let shoulder = reducedMotion ? (left ? 0.48 : 0.46)
                : (left ? 0.44 + shape.mid * 0.12 : 0.28 + 0.38 * shape.mid / (shape.mid + shape.high + 0.10))
            return Region(centerX: center, radiusX: radius,
                          bodyHeight: reducedMotion ? 24 : (left ? 14 + body * 42 : 12 + body * 36) + beatLift * 0.42,
                          bodyOpacity: min(0.23, 0.22 * pow(rawBody, 0.80) * gain * room),
                          crestX: center,
                          crestRadiusX: reducedMotion ? (left ? 0.11 : 0.095)
                              : (left ? 0.106 + body * 0.038 : 0.080 + body * 0.037),
                          crestHeight: reducedMotion ? 19
                              : (left ? 10 + body * 48 : 12 + body * 43) * sqrt(gain) + beatLift,
                          crestOpacity: min(0.54, (steadyLight + localBeat * 0.26) * gain * room),
                          hue: left ? 0.51 + mid * 0.035 : 0.72 + high * 0.045,
                          profile: left ? .bass : .detail, shoulder: shoulder)
        }
    }
}

/// Desktop forms share the same clock and bounded key dynamics.
/// Neither form stacks independently drawn key paths or leaves a scrolling trail.
enum RhythmPainter {
    private static let cyan = Color(red: 0.31, green: 0.89, blue: 0.94)
    private static let violet = Color(red: 0.64, green: 0.59, blue: 0.97)

    static func draw(context: inout GraphicsContext, size: CGSize, dynamics: RhythmDynamics,
                     time: TimeInterval, intensity: Double, reducedMotion: Bool,
                     style: RhythmVisualStyle = .energy, flashesEnabled: Bool = true, spectrum: AudioSpectrum = .silent) {
        switch style {
        case .energy:
            drawEnergy(context: &context, size: size, dynamics: dynamics, time: time, intensity: intensity,
                       movingLight: flashesEnabled && !reducedMotion)
        case .pulse:
            drawPulse(context: &context, size: size, dynamics: dynamics, time: time,
                      intensity: intensity, reducedMotion: reducedMotion,
                      flashesEnabled: flashesEnabled)
        case .burst:
            drawBurst(context: &context, size: size, dynamics: dynamics, time: time,
                      intensity: intensity, reducedMotion: reducedMotion, flashesEnabled: flashesEnabled)
        case .edgeGlow:
            drawEdgeGlow(context: &context, size: size, dynamics: dynamics, time: time,
                         intensity: intensity, reducedMotion: reducedMotion, flashesEnabled: flashesEnabled, spectrum: spectrum)
        }
    }

    /// A screen-bottom atmosphere made from only a few analytical color plumes.
    /// Radial gradients are transformed into ellipses, so every upper boundary
    /// fades to zero instead of leaving a rectangular edge or a painted line.
    private static func drawEdgeGlow(context: inout GraphicsContext, size: CGSize, dynamics: RhythmDynamics,
                                     time: TimeInterval, intensity: Double, reducedMotion: Bool, flashesEnabled: Bool,
                                     spectrum: AudioSpectrum) {
        // Use the energy bar's slower hold and release for the lingering light,
        // and give each key a short attack on top of that continuous envelope.
        let energy = dynamics.meterEnergy(at: time)
        var taps = 0.0
        var accent = 0.0
        var ripples: [(origin: Double, position: Double, width: Double, light: Double)] = []
        for pulse in dynamics.pulses {
            let age = max(0, time - pulse.time)
            let gain = pulse.strength / pulse.profile.impact
            let origin: Double
            let duration: Double
            let reach: Double
            let width: Double
            let light: Double
            switch pulse.profile.kind {
            case .space:
                origin = 0
                accent += 0.84 * gain * strikeEnvelope(age, attack: 0.008, release: 0.28)
                duration = 0.62 + 0.10 * pulse.accentCharge
                reach = 0.92 + 0.08 * pulse.accentCharge
                width = 0.15
                light = 1.32 * gain
            case .returnKey:
                origin = 0
                accent += 0.61 * gain * strikeEnvelope(age, attack: 0.008, release: 0.23)
                duration = 0.49 + 0.07 * pulse.accentCharge
                reach = 0.64 + 0.12 * pulse.accentCharge
                width = 0.13
                light = 0.90 * gain
            default:
                origin = min(0.64, max(-0.64, (pulse.profile.lane - 0.5) * 1.35))
                taps += pulse.strength * strikeEnvelope(age, attack: 0.006, release: 0.10)
                duration = 0.30
                reach = 0.35
                width = 0.10
                light = 1.70 * pulse.strength
            }
            if !reducedMotion && age < duration {
                let progress = age / duration
                let travel = progress * (2 - progress)
                let envelope = min(1, age / 0.032) * pow(1 - progress, 1.1)
                ripples.append((origin, reach * travel, width + 0.04 * progress, light * envelope))
            }
        }
        let tapLevel = tanh(taps)
        let accentLevel = tanh(accent)
        let keyboardDrive = 1 - exp(-(energy * 1.55 + tapLevel * 0.85 + accentLevel * 1.05) * intensity)
        // Music is rendered in its own two edge-local regions, below the
        // untouched keyboard layer. Silence contributes no drawing commands.
        drawEdgeMusic(context: &context, size: size, spectrum: spectrum, time: time,
                      intensity: intensity, keyboardDrive: keyboardDrive,
                      keyboardEnergy: energy, reducedMotion: reducedMotion, flashesEnabled: flashesEnabled)
        let drive = keyboardDrive
        guard drive > 0.001 else { return }
        let movement = reducedMotion ? 0.0 : 1.0
        let phase = time.truncatingRemainder(dividingBy: 24) / 24 * .pi * 2
        let rise = 52 + (drive * 38 + tapLevel * 8 + accentLevel * 28) * movement
        let spread = 0.34 + (drive * 0.12 + accentLevel * 0.08) * movement
        let colors = [Color(red: 0.12, green: 0.76, blue: 0.98),
                      Color(red: 0.30, green: 0.48, blue: 1),
                      Color(red: 0.70, green: 0.35, blue: 0.98)]

        func plume(center: CGPoint, horizontal: Double, vertical: Double, color: Color, opacity: Double) {
            var layer = context
            layer.translateBy(x: center.x, y: center.y)
            layer.scaleBy(x: horizontal / vertical, y: 1)
            let circle = Path(ellipseIn: CGRect(x: -vertical, y: -vertical, width: vertical * 2, height: vertical * 2))
            layer.fill(circle, with: .radialGradient(Gradient(stops: [
                .init(color: color.opacity(opacity), location: 0),
                .init(color: color.opacity(opacity * 0.70), location: 0.24),
                .init(color: color.opacity(opacity * 0.22), location: 0.63),
                .init(color: .clear, location: 1)
            ]), center: .zero, startRadius: 0, endRadius: vertical))
        }
        for index in 0..<3 {
            let drift = sin(phase + Double(index) * 1.9) * 0.025 * movement * drive
            let x = size.width * (0.20 + Double(index) * 0.30 + drift)
            plume(center: CGPoint(x: x, y: size.height + 8), horizontal: size.width * spread,
                  vertical: min(size.height + 4, rise * (index == 1 ? 1.0 : 0.88)),
                  color: colors[index], opacity: 0.66 * drive)
        }

        // Each ripple has two mirrored crests. Blend their light before drawing
        // the ribbon so fast typing can overlap without stacking bright layers.
        var ribbon = Path()
        ribbon.move(to: CGPoint(x: -16, y: size.height + 14))
        var stops: [Gradient.Stop] = []
        let samples = 56
        for index in 0...samples {
            let t = Double(index) / Double(samples)
            let sum = ripples.reduce(0.0) { total, ripple in
                let distance = abs(t * 2 - 1 - ripple.origin)
                let offset = (distance - ripple.position) / ripple.width
                return total + ripple.light * exp(-0.5 * offset * offset)
            }
            let light = 1 - exp(-sum * intensity)
            let taper = pow(max(0, sin(.pi * t)), 0.30)
            let wave = 0.83 + 0.17 * sin(t * .pi * 3.4 + phase * movement)
            let baseLift = (5 + (drive * 18 + tapLevel * 6 + accentLevel * 10) * movement) * wave
            let lift = (baseLift + 38 * light) * taper
            ribbon.addLine(to: CGPoint(x: t * (size.width + 32) - 16, y: size.height - lift))
            let tint = Color(hue: 0.52 + 0.25 * t, saturation: 0.80 - 0.38 * light, brightness: 1)
            let baseOpacity = drive * (0.49 + 0.08 * taper)
            let crestOpacity = light * (flashesEnabled ? 0.76 : 0.58)
            let opacity = baseOpacity + (1 - baseOpacity) * crestOpacity
            stops.append(.init(color: tint.opacity(opacity), location: t))
        }
        ribbon.addLine(to: CGPoint(x: size.width + 16, y: size.height + 14))
        ribbon.closeSubpath()
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 8))
            layer.fill(ribbon, with: .linearGradient(
                Gradient(stops: stops),
                startPoint: CGPoint(x: -16, y: size.height), endPoint: CGPoint(x: size.width + 16, y: size.height)))
        }
    }

    private static func drawEdgeMusic(context: inout GraphicsContext, size: CGSize, spectrum: AudioSpectrum,
                                      time: TimeInterval, intensity: Double, keyboardDrive: Double, keyboardEnergy: Double,
                                      reducedMotion: Bool, flashesEnabled: Bool) {
        let regions = EdgeMusicGeometry.regions(spectrum: spectrum, time: time, intensity: intensity,
                                                keyboardDrive: keyboardDrive, reducedMotion: reducedMotion,
                                                keyboardEnergy: keyboardEnergy)
        // Fixed, asymmetric shoulders read as a low rolling wave instead of
        // two identical circles. The right shoulder follows mid/high balance;
        // its anchor and every horizontal control point remain stationary.
        func wave(center: Double, radius: Double, height: Double, region: EdgeMusicGeometry.Region) -> Path {
            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: center + radius * x, y: size.height - height * y)
            }
            var path = Path()
            path.move(to: point(-1, 0))
            if region.profile == .bass {
                path.addCurve(to: point(-0.32, 0.88), control1: point(-0.78, 0.02), control2: point(-0.50, 0.88))
                path.addCurve(to: point(0.16, 0.62), control1: point(-0.14, 0.88), control2: point(0, 0.62))
                path.addCurve(to: point(0.57, region.shoulder), control1: point(0.30, 0.62),
                              control2: point(0.40, region.shoulder))
                path.addCurve(to: point(1, 0), control1: point(0.74, region.shoulder), control2: point(0.90, 0))
            } else {
                path.addCurve(to: point(-0.45, region.shoulder), control1: point(-0.81, 0),
                              control2: point(-0.68, region.shoulder))
                path.addCurve(to: point(-0.08, region.shoulder * 0.90), control1: point(-0.30, region.shoulder),
                              control2: point(-0.23, region.shoulder * 0.90))
                path.addCurve(to: point(0.29, 0.91), control1: point(0.08, region.shoulder * 0.90), control2: point(0.13, 0.91))
                path.addCurve(to: point(1, 0), control1: point(0.58, 0.91), control2: point(0.69, 0))
            }
            path.addLine(to: CGPoint(x: center + radius, y: size.height + 10))
            path.addLine(to: CGPoint(x: center - radius, y: size.height + 10))
            path.closeSubpath()
            return path
        }
        for region in regions {
            let color = Color(hue: region.hue, saturation: 0.74, brightness: 1)
            let center = size.width * region.crestX
            let radius = size.width * region.crestRadiusX
            if region.bodyOpacity > 0.001 {
                let body = wave(center: size.width * region.centerX, radius: size.width * region.radiusX,
                                height: region.bodyHeight, region: region)
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 11))
                    layer.fill(body, with: .linearGradient(
                        Gradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: color.opacity(region.bodyOpacity), location: 0.56),
                                         .init(color: color.opacity(region.bodyOpacity * 0.24), location: 1)]),
                        startPoint: CGPoint(x: center, y: size.height - region.bodyHeight),
                        endPoint: CGPoint(x: center, y: size.height + 8)))
                }
            }
            guard region.crestOpacity > 0.001 else { continue }
            let crestHeight = min(size.height - 12, region.crestHeight)
            let crest = wave(center: center, radius: radius, height: crestHeight, region: region)
            let contourLight = region.crestOpacity * (flashesEnabled && !reducedMotion ? 1 : 0.82)
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4.5))
                layer.fill(crest, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: color.opacity(contourLight * 0.40), location: 0),
                        .init(color: color.opacity(contourLight), location: 0.34),
                        .init(color: color.opacity(contourLight * 0.36), location: 0.76),
                        .init(color: .clear, location: 1)
                    ]), startPoint: CGPoint(x: center, y: size.height - crestHeight),
                    endPoint: CGPoint(x: center, y: size.height + 9)))
            }
            // Colored contours carry the attack without a moving hotspot,
            // white flash, opaque baseline, or music spanning the dark center.
        }
    }

    private static func drawEnergy(context: inout GraphicsContext, size: CGSize, dynamics: RhythmDynamics,
                                   time: TimeInterval, intensity: Double, movingLight: Bool) {
        let storedMeter = min(1, max(0, dynamics.meterEnergy(at: time)))
        let meter = 1 - pow(1 - storedMeter, intensity)
        let high = dynamics.highEnergyLevel(at: time)
        let width = 8 + 238 * meter
        let thickness = 7 + high
        let fill = CGRect(x: (size.width - 246) / 2, y: size.height * 0.47 - thickness / 2,
                          width: width, height: thickness)
        let shape = Path(roundedRect: fill, cornerRadius: thickness / 2)
        let start = CGPoint(x: fill.minX, y: fill.midY)
        let end = CGPoint(x: fill.minX + 246, y: fill.midY)
        let base = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Color(red: 0.17, green: 0.80, blue: 0.94),
                              Color(red: 0.37, green: 0.64, blue: 1),
                              Color(red: 0.66, green: 0.43, blue: 0.98)]), startPoint: start, endPoint: end)
        // Only the colored beam is drawn. Its empty portion is fully transparent;
        // there is no track, outline, gray bed, or hard-edged surrounding card.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 5 + high * 2))
            layer.opacity = 0.24 + high * 0.16
            layer.fill(shape, with: base)
        }
        context.fill(shape, with: base)

        if high > 0.001 {
            // A constant-speed phase survives both subsequent keys and short
            // high-mode reentries; the independent high-level envelope fades it.
            let phase = movingLight ? time.truncatingRemainder(dividingBy: 3.4) * .pi * 2 / 3.4 : 0
            let stops = (0...10).map { index -> Gradient.Stop in
                let position = Double(index) / 10
                let hue = 0.61 + 0.14 * sin(phase - position * 4.4)
                return .init(color: Color(hue: hue, saturation: 0.56, brightness: 1), location: position)
            }
            let flow = GraphicsContext.Shading.linearGradient(Gradient(stops: stops), startPoint: start, endPoint: end)
            context.drawLayer { layer in
                layer.opacity = high * 0.90
                layer.fill(shape, with: flow)
            }
            if movingLight {
                // A narrow soft highlight passes once every 2.6 seconds. The
                // whole strip never strobes or flashes on and off.
                let progress = time.truncatingRemainder(dividingBy: 2.6) / 2.6
                let glintX = fill.minX - 40 + progress * 326
                context.drawLayer { layer in
                    layer.clip(to: shape)
                    layer.fill(Path(fill), with: .linearGradient(
                        Gradient(colors: [.clear, .white.opacity(high * 0.48), .clear]),
                        startPoint: CGPoint(x: glintX - 24, y: fill.minY),
                        endPoint: CGPoint(x: glintX + 24, y: fill.maxY)))
                }
            }
        }
        if movingLight {
            let accent = accentLight(dynamics: dynamics, at: time) * min(1.2, intensity)
            if accent > 0.002 {
                let cap = CGPoint(x: fill.maxX - thickness / 2, y: fill.midY)
                let radius = 5 + accent * 4
                context.fill(Path(ellipseIn: CGRect(x: cap.x - radius, y: cap.y - radius,
                                                   width: radius * 2, height: radius * 2)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(accent * 0.26), .clear]),
                                                   center: cap, startRadius: 0, endRadius: radius))
            }
        }
    }

    private static func drawPulse(context: inout GraphicsContext, size: CGSize, dynamics: RhythmDynamics,
                                  time: TimeInterval, intensity: Double, reducedMotion: Bool, flashesEnabled: Bool) {
        var ordinary = 0.0, accents = 0.0
        for pulse in dynamics.pulses {
            let age = max(0, time - pulse.time)
            guard time >= pulse.time else { continue }
            let capturedGain = pulse.strength / pulse.profile.impact
            switch pulse.profile.kind {
            case .space:
                accents += 34 * capturedGain * strikeEnvelope(age, attack: 0.009, release: 0.22)
            case .returnKey:
                accents += 27 * capturedGain * strikeEnvelope(age, attack: 0.008, release: 0.19)
            default:
                ordinary += (5.5 + pulse.profile.lane)
                    * strikeEnvelope(age, attack: 0.007, release: 0.10 + pulse.profile.frequency * 0.005)
            }
        }
        // All ordinary input shares a small bounce budget. Accents lift that
        // same body, preserving its current motion instead of replacing it.
        let smallBounce = 12 * tanh(ordinary / 12)
        let maximum = min(62, 52 * intensity)
        let amplitude = maximum * tanh((smallBounce + accents) * intensity / max(1, maximum))
        let height = amplitude * (reducedMotion ? 0.20 : 1)
        let center = CGPoint(x: size.width / 2, y: size.height * 0.47)
        let halfWidth = 34 + height * 0.22
        let left = center.x - 123, right = center.x + 123
        var line = Path()
        let samples = 164
        for index in 0...samples {
            let x = left + (right - left) * Double(index) / Double(samples)
            let u = (x - center.x) / halfWidth
            let arch = abs(u) < 1 ? pow(0.5 + 0.5 * cos(.pi * u), 1.6) : 0
            let point = CGPoint(x: x, y: center.y - height * arch)
            if index == 0 { line.move(to: point) }
            else { line.addLine(to: point) }
        }
        let gradient = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: cyan.opacity(0.06), location: 0),
                .init(color: cyan.opacity(0.82), location: 0.30),
                .init(color: Color(red: 0.61, green: 0.80, blue: 1), location: 0.52),
                .init(color: violet.opacity(0.84), location: 0.74),
                .init(color: violet.opacity(0.06), location: 1)
            ]), startPoint: CGPoint(x: left, y: center.y), endPoint: CGPoint(x: right, y: center.y))
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            layer.stroke(line, with: .color(.black.opacity(0.20)), lineWidth: 3)
        }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.opacity = 0.25
            layer.stroke(line, with: gradient, lineWidth: 2.5)
        }
        context.stroke(line, with: gradient, style: StrokeStyle(lineWidth: 1.85, lineCap: .round, lineJoin: .round))
        let accent = flashesEnabled && !reducedMotion ? accentLight(dynamics: dynamics, at: time) : 0
        if accent > 0.002 {
            let apex = CGPoint(x: center.x, y: center.y - height)
            let radius = 6 + accent * 7
            context.fill(Path(ellipseIn: CGRect(x: apex.x - radius, y: apex.y - radius,
                                               width: radius * 2, height: radius * 2)),
                         with: .radialGradient(Gradient(colors: [cyan.opacity(accent * 0.34), .clear]),
                                               center: apex, startRadius: 0, endRadius: radius))
            var tip = Path()
            for index in 0...12 {
                let x = center.x - 5 + Double(index) * 10 / 12
                let u = (x - center.x) / halfWidth
                let y = center.y - height * pow(0.5 + 0.5 * cos(.pi * u), 1.6)
                if index == 0 { tip.move(to: CGPoint(x: x, y: y)) }
                else { tip.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(tip, with: .color(.white.opacity(accent * 0.62)),
                           style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }

    /// A temporary line of physical key glyphs. One short outgoing group and
    /// a bounded set of colored fragments leave room for the next input.
    private static func drawBurst(context: inout GraphicsContext, size: CGSize, dynamics: RhythmDynamics,
                                  time: TimeInterval, intensity: Double, reducedMotion: Bool, flashesEnabled: Bool) {
        let baseline = Double(size.height) * 0.57
        let left = 29.0

        func ease(_ value: Double) -> Double {
            let p = min(1, max(0, value))
            return 1 - pow(1 - p, 3)
        }
        func capSize(_ count: Double) -> Double { 44 - min(9, max(0, count - 1)) * 20 / 9 }
        func layout(_ keys: [RhythmPulse], index: Int, at timestamp: Double) -> (CGPoint, Double, Double) {
            let count = keys.count
            let newestAge = max(0, timestamp - (keys.last?.time ?? timestamp))
            // Below capacity the whole row eases to its new size. At capacity
            // dimensions remain fixed while the oldest physical key drops out.
            let progress = count >= 10 || reducedMotion ? 1 : ease(newestAge / 0.12)
            let effectiveCount = max(1, Double(count - 1) + progress)
            let edge = capSize(effectiveCount)
            let gap = 6 - min(1, (effectiveCount - 1) / 9) * 2.5
            let key = keys[index]
            let jitter = reducedMotion ? 0 : Double((key.id * 7 + Int(key.profile.code)) % 5 - 2) * 0.75
            let angle = reducedMotion ? 0 : Double((key.id * 11 + Int(key.profile.code)) % 9 - 4)
            return (CGPoint(x: left + edge / 2 + Double(index) * (edge + gap),
                            y: baseline - edge / 2 + jitter), edge, angle)
        }
        func keyColor(_ key: RhythmPulse) -> Color {
            let hues = [0.49, 0.62, 0.75, 0.88, 0.40, 0.10]
            let index = (Int(key.profile.code) * 7 + key.id * 3) % hues.count
            return Color(hue: hues[index], saturation: 0.68, brightness: 1)
        }
        func label(_ code: UInt16) -> String {
            switch code {
            case 49: return "␣"
            case 36, 76: return "↵"
            case 51, 117: return "⌫"
            case 48: return "⇥"
            case 53: return "esc"
            case 56, 60: return "⇧"
            case 57: return "⇪"
            case 54, 55: return "⌘"
            case 58, 61: return "⌥"
            case 59, 62: return "⌃"
            case 63: return "fn"
            default:
                let value = KeyLayout.label(for: code)
                if value.hasPrefix("keypad ") { return String(value.dropFirst(7)) }
                if value.hasPrefix("key ") { return "•" }
                return value.count <= 3 ? value.uppercased() : "◇"
            }
        }
        func placement(_ keys: [RhythmPulse], index: Int, at timestamp: Double) -> (CGPoint, Double, Double, Double, Double) {
            var (center, edge, angle) = layout(keys, index: index, at: timestamp)
            let entered = ease(max(0, timestamp - keys[index].time) / 0.085)
            if !reducedMotion {
                center.x += (1 - entered) * 5
                center.y += (1 - entered) * 7
            }
            return (center, edge, angle, reducedMotion ? 1 : 0.86 + entered * 0.14, 0.52 + entered * 0.48)
        }
        func drawGlyph(_ key: RhythmPulse, center: CGPoint, edge: Double, angle: Double,
                       opacity: Double, glow: Double, scale: Double = 1) {
            guard opacity > 0.002 else { return }
            var layer = context
            layer.opacity *= opacity
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(angle))
            layer.scaleBy(x: scale, y: scale)
            let color = keyColor(key)
            let text = label(key.profile.code)
            let fontSize = min(edge * 0.64, edge * 1.55 / Double(max(1, text.count)))
            let glyph = Text(text).font(.system(size: fontSize, weight: .bold, design: .rounded))
            // A fine ink edge defines saturated glyphs on white desktops;
            // every layer follows the glyph itself, with no keycap or backdrop.
            layer.drawLayer { shadow in
                shadow.addFilter(.blur(radius: 0.8))
                shadow.draw(glyph.foregroundColor(.black.opacity(0.84)), at: CGPoint(x: 0, y: 0.65))
            }
            for offset in [CGPoint(x: -0.45, y: 0), CGPoint(x: 0.45, y: 0), CGPoint(x: 0, y: -0.45)] {
                layer.draw(glyph.foregroundColor(.black.opacity(0.38)), at: offset)
            }
            layer.drawLayer { light in
                light.addFilter(.blur(radius: 3.2 + glow * 1.8))
                light.draw(glyph.foregroundColor(color.opacity(0.42 + glow * 0.24)), at: .zero)
            }
            layer.draw(glyph.foregroundColor(color), at: .zero)
            layer.draw(glyph.foregroundColor(.white.opacity(0.12 + glow * 0.10)), at: .zero)
        }

        // The old glyphs break down in under 100ms; sparse shards finish within
        // 260ms. The next queue is drawn last and never waits for this group.
        if let burst = dynamics.keyBurst {
            let age = max(0, time - burst.strike.time)
            let isSpace = burst.strike.profile.kind == .space
            let charge = burst.strike.accentCharge
            let keys = burst.keys.isEmpty ? [burst.strike] : burst.keys
            let glyphLifetime = reducedMotion ? 0.22 : (isSpace ? 0.095 : 0.14)
            let p = min(1, age / glyphLifetime)
            let rowCenter = keys.indices.map { placement(keys, index: $0, at: burst.strike.time).0.x }
                .reduce(0, +) / Double(keys.count)
            if p < 1 {
                for index in keys.indices {
                    let key = keys[index]
                    let (origin, edge, angle, entryScale, entryOpacity) = placement(keys, index: index, at: burst.strike.time)
                    let direction = keys.count > 1 ? Double(index) / Double(keys.count - 1) * 2 - 1 : 0
                    let travel = ease(p)
                    var center = origin
                    var rotation = angle
                    if !reducedMotion {
                        if isSpace {
                            center.x += direction * (8 + charge * 9) * travel
                            center.y -= (12 + charge * 10) * travel
                            rotation += direction * 14 * travel
                        } else {
                            center.x += (rowCenter - origin.x) * 0.17 * travel
                            center.y -= (13 + charge * 6) * travel
                            rotation += direction * 5 * travel
                        }
                    }
                    let flash = flashesEnabled && !reducedMotion ? (1 - p) * (0.25 + charge * 0.4) : 0
                    let opacity = RhythmDynamics.keyOpacity(key, at: burst.strike.time) * entryOpacity * pow(1 - p, 1.45)
                    drawGlyph(key, center: center, edge: edge, angle: rotation, opacity: opacity,
                              glow: 0.18 + flash, scale: entryScale * (reducedMotion ? 1 : 1 - travel * 0.40))
                }
            }
            if isSpace && !reducedMotion && age < 0.26 {
                let count = min(20, max(6, keys.count * 2))
                let fragmentProgress = min(1, age / 0.26)
                let travel = ease(fragmentProgress)
                let fade = min(1, age / 0.018) * pow(1 - fragmentProgress, 1.4)
                let force = min(1.3, intensity) * (0.72 + charge * 0.50)
                for fragment in 0..<count {
                    let index = min(keys.count - 1, fragment * keys.count / count)
                    let key = keys[index]
                    let seed = fragment * 17 + key.id * 7 + Int(key.profile.code)
                    let (origin, edge, _, entryScale, entryOpacity) = placement(keys, index: index, at: burst.strike.time)
                    let position = count > 1 ? Double(fragment) / Double(count - 1) * 2 - 1 : 0
                    let jitter = Double(seed % 7 - 3) / 3
                    let start = CGPoint(x: origin.x + jitter * edge * 0.13 * entryScale,
                                        y: origin.y + Double(seed % 5 - 2) * edge * 0.065 * entryScale)
                    // Clamp the destination, not each moving frame, so shards
                    // approach the visible edge smoothly without sudden stops.
                    let endX = min(size.width - 12, max(12, start.x + (position * 0.82 + jitter * 0.35) * (35 + charge * 35) * force))
                    let endY = max(18, start.y - (30 + Double(seed % 5) * 7 + charge * 20) * force)
                    let point = CGPoint(x: start.x + (endX - start.x) * travel,
                                        y: start.y + (endY - start.y) * travel + 10 * fragmentProgress * fragmentProgress)
                    let opacity = fade * RhythmDynamics.keyOpacity(key, at: burst.strike.time) * entryOpacity
                    guard opacity > 0.002 else { continue }
                    let angle = atan2(endY - start.y, endX - start.x)
                    let length = (2.6 + Double(seed % 3) * 1.25) * (1 - fragmentProgress * 0.30)
                    var shard = Path()
                    shard.move(to: CGPoint(x: point.x - cos(angle) * length / 2, y: point.y - sin(angle) * length / 2))
                    shard.addLine(to: CGPoint(x: point.x + cos(angle) * length / 2, y: point.y + sin(angle) * length / 2))
                    context.stroke(shard, with: .color(.black.opacity(opacity * 0.22)),
                                   style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    context.stroke(shard, with: .color(keyColor(key).opacity(opacity * 0.94)),
                                   style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                    if flashesEnabled && age < 0.07 && fragment % 4 == 0 {
                        context.stroke(shard, with: .color(.white.opacity(opacity * (1 - age / 0.07) * 0.52)),
                                       style: StrokeStyle(lineWidth: 0.7, lineCap: .round))
                    }
                }
            }
        }

        for index in dynamics.queuedKeys.indices {
            let key = dynamics.queuedKeys[index]
            let (center, edge, angle, scale, opacity) = placement(dynamics.queuedKeys, index: index, at: time)
            let age = max(0, time - key.time)
            let fresh = flashesEnabled && !reducedMotion ? max(0, 1 - age / 0.18) * 0.45 : 0
            drawGlyph(key, center: center, edge: edge, angle: angle,
                      opacity: RhythmDynamics.keyOpacity(key, at: time) * opacity, glow: 0.18 + fresh, scale: scale)
        }
        let outgoingVisible = dynamics.keyBurst.map { max(0, time - $0.strike.time) < (reducedMotion ? 0.22 : 0.26) } ?? false
        let queuedVisible = dynamics.queuedKeys.contains { RhythmDynamics.keyOpacity($0, at: time) > 0.01 }
        if !queuedVisible && !outgoingVisible {
            // A quiet three-light placeholder keeps the transparent widget findable.
            for index in 0..<3 {
                let dot = CGRect(x: left + Double(index) * 7, y: baseline - 7, width: 3, height: 3)
                context.fill(Path(ellipseIn: dot), with: .color((index == 1 ? violet : cyan).opacity(0.48)))
            }
        }
    }

    /// A fast rise followed by a longer exponential return. Parameters place
    /// the peak roughly 20–30 ms after a key, with no discontinuity at onset.
    private static func strikeEnvelope(_ age: Double, attack: Double, release: Double) -> Double {
        guard age >= 0, age < 2 else { return 0 }
        let peak = log(release / attack) / (1 / attack - 1 / release)
        let normalizer = exp(-peak / release) - exp(-peak / attack)
        return (exp(-age / release) - exp(-age / attack)) / normalizer
    }

    private static func accentLight(dynamics: RhythmDynamics, at time: TimeInterval) -> Double {
        var total = 0.0
        for pulse in dynamics.pulses where pulse.profile.kind == .space || pulse.profile.kind == .returnKey {
            let age = time - pulse.time
            guard age >= 0, age < 0.4 else { continue }
            total += (0.25 + pulse.accentCharge * 0.4) * strikeEnvelope(age, attack: 0.006, release: 0.10) * (1 - age / 0.4)
        }
        return min(1, total)
    }
}
