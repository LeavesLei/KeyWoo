import AppKit
import SwiftUI
import Combine

/// A desktop companion which never becomes the keyboard's destination.
@MainActor
final class RhythmOverlayController: NSObject, NSWindowDelegate {
    private let feedback: RhythmFeedbackModel
    private let defaults: UserDefaults
    private let onClose: () -> Void
    private var panel: RhythmPanel?
    private var clickThrough = false
    private var screenObserver: NSObjectProtocol?
    private let size = NSSize(width: 340, height: 224)
    private let positionKey = "rhythmOverlayPosition"

    init(feedback: RhythmFeedbackModel, defaults: UserDefaults, onClose: @escaping () -> Void) {
        self.feedback = feedback
        self.defaults = defaults
        self.onClose = onClose
        super.init()
    }

    func show() {
        if panel == nil { createPanel() }
        guard let panel else { return }
        constrainToScreen(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        feedback.reset()
    }

    func setClickThrough(_ value: Bool) {
        clickThrough = value
        panel?.ignoresMouseEvents = value
        installContent()
    }

    func resetPosition() {
        defaults.removeObject(forKey: positionKey)
        guard let panel else { return }
        panel.setFrameOrigin(defaultOrigin())
        savePosition(panel)
    }

    private func createPanel() {
        let panel = RhythmPanel(contentRect: NSRect(origin: defaultOrigin(), size: size),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Dragging is explicit in RhythmInteractionView; SwiftUI background dragging
        // does not reliably receive events in a nonactivating transparent panel.
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = clickThrough
        panel.animationBehavior = .none
        panel.title = L("律动悬浮窗")
        panel.delegate = self
        self.panel = panel
        if let position = defaults.array(forKey: positionKey) as? [Double], position.count == 2,
           position.allSatisfy(\.isFinite) {
            panel.setFrameOrigin(NSPoint(x: position[0], y: position[1]))
        }
        installContent()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                self.constrainToScreen(panel)
            }
        }
    }

    private func installContent() {
        guard let panel else { return }
        panel.contentView = RhythmInteractionView(
            feedback: feedback, clickThrough: clickThrough, onClose: { [weak self] in self?.onClose() })
    }

    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
    }

    private func constrainToScreen(_ panel: NSPanel) {
        let screens = NSScreen.screens.map(\.visibleFrame)
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
        defaults.set([panel.frame.origin.x, panel.frame.origin.y], forKey: positionKey)
    }

    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
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
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !feedback.isAnimating)) { timeline in
            // The frame date is a value input to the Canvas view. Reading uptime
            // only inside its drawing closure can leave SwiftUI caching one frame.
            // Convert this scheduled frame using a fresh clock pair, so sleep
            // and wall-clock corrections cannot stale a persistent anchor.
            let frameTime = ProcessInfo.processInfo.systemUptime
                - max(0, Date().timeIntervalSince(timeline.date))
            RhythmFrameCanvas(dynamics: feedback.dynamics, time: frameTime,
                              intensity: feedback.intensity, reducedMotion: reduceMotion,
                              style: feedback.visualStyle, flashesEnabled: feedback.flashesEnabled)
        }
        .frame(width: 340, height: 224)
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

    var body: some View {
        Canvas { context, size in
            RhythmPainter.draw(context: &context, size: size, dynamics: dynamics,
                               time: time, intensity: intensity, reducedMotion: reducedMotion, style: style, flashesEnabled: flashesEnabled)
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
                     style: RhythmVisualStyle = .energy, flashesEnabled: Bool = true) {
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
