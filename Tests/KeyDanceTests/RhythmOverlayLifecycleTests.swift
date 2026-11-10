import AppKit
import Foundation
import Testing
@testable import KeyDance

private final class OverlayFixtureDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "KeyWooOverlayFixture-\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func set(_ value: Any?, forKey key: String) {
        if let coordinates = value as? [CGFloat] { values[key] = coordinates.map(Double.init) }
        else { values[key] = value }
    }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private final class OffscreenRhythmPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Real NSPanel and NSHostingView integration, located entirely outside the
/// user's displays. No event tap, audio device or real preferences are used.
struct RhythmOverlayLifecycleTests {
    @Test @MainActor func nativePanelKeepsCorrectBoundsAcrossStyleChangesAndRepeatedShowHide() async throws {
        _ = NSApplication.shared
        let feedback = RhythmFeedbackModel()
        let defaults = OverlayFixtureDefaults()
        var screen = NSRect(x: -20_000, y: -20_000, width: 1280, height: 800)
        var created: [NSPanel] = []
        let controller = RhythmOverlayController(feedback: feedback, defaults: defaults,
            screenFrame: { screen }, makePanel: { frame in
                let panel = OffscreenRhythmPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                                backing: .buffered, defer: false)
                created.append(panel)
                return panel
            }, onClose: {})
        defer { controller.hide(); for panel in created { panel.close() } }
        controller.show()
        let panel = try #require(created.first)
        #expect(panel.isVisible && !panel.isKeyWindow && !panel.isMainWindow)
        #expect(panel.frame.size == NSSize(width: 340, height: 224))
        let ordinaryOrigin = panel.frame.origin
        for _ in 0..<3 {
            feedback.visualStyle = .edgeGlow
            controller.setVisualStyle(.edgeGlow)
            controller.show()
            try await Task.sleep(for: .milliseconds(30))
            panel.contentView?.layoutSubtreeIfNeeded()
            #expect(panel.isVisible && panel.ignoresMouseEvents)
            #expect(panel.frame == NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: 144))
            #expect(panel.contentView?.bounds.size == panel.frame.size)
            controller.hide()
            #expect(!panel.isVisible && !feedback.isAnimating)
            controller.show()
            #expect(panel.isVisible && panel.contentView?.bounds.size == panel.frame.size)
            feedback.visualStyle = .pulse
            controller.setVisualStyle(.pulse)
            try await Task.sleep(for: .milliseconds(30))
            #expect(panel.frame.size == NSSize(width: 340, height: 224))
            #expect(panel.frame.origin == ordinaryOrigin && !panel.ignoresMouseEvents)
            #expect(panel.contentView?.bounds.size == panel.frame.size)
        }
        // A display reconfiguration must not leave the full-width view using
        // the old display's dimensions or write a screen-edge frame as a widget position.
        screen.size.width = 960
        feedback.visualStyle = .edgeGlow
        controller.setVisualStyle(.edgeGlow)
        controller.show()
        try await Task.sleep(for: .milliseconds(30))
        #expect(panel.frame.width == 960 && panel.contentView?.bounds.width == 960)
        #expect(created.count == 1)
        let saved = try #require(defaults.array(forKey: "rhythmOverlayPosition") as? [Double])
        #expect(saved == [Double(ordinaryOrigin.x), Double(ordinaryOrigin.y)])
    }

    @Test @MainActor func actualEdgeHostingViewPaintsKeyboardFeedbackAndCanRecoverAfterHiding() async throws {
        _ = NSApplication.shared
        let feedback = RhythmFeedbackModel()
        feedback.visualStyle = .edgeGlow
        let defaults = OverlayFixtureDefaults()
        var fixturePanel: NSPanel?
        let screen = NSRect(x: -20_000, y: -20_000, width: 1280, height: 800)
        let controller = RhythmOverlayController(feedback: feedback, defaults: defaults,
            screenFrame: { screen }, makePanel: { frame in
                let panel = OffscreenRhythmPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                                backing: .buffered, defer: false)
                fixturePanel = panel
                return panel
            }, onClose: {})
        defer { controller.hide(); fixturePanel?.close() }
        for _ in 0..<2 {
            controller.show()
            let panel = try #require(fixturePanel)
            feedback.receiveKey(49, at: ProcessInfo.processInfo.systemUptime - 0.08)
            try await Task.sleep(for: .milliseconds(40))
            let view = try #require(panel.contentView)
            #expect(view.bounds.size == NSSize(width: 1280, height: 144))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var coloredPixels = 0
            // White/black opaque host backgrounds do not count as a painted glow.
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.01 else { continue }
                    let maximum = max(color.redComponent, color.greenComponent, color.blueComponent)
                    let minimum = min(color.redComponent, color.greenComponent, color.blueComponent)
                    if maximum - minimum > 0.08 { coloredPixels += 1 }
                }
            }
            #expect(coloredPixels > 100, "The actual full-width hosting view must render colored, nontransparent light after a key pulse.")
            controller.hide()
            #expect(!panel.isVisible && !feedback.isAnimating && feedback.dynamics.pulses.isEmpty)
        }
    }
}
