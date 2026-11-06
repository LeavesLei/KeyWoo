import Testing
@testable import KeyDance

/// Keeps the legacy OfflineSoundRenderer input-lifetime fixtures valid without
/// opening devices, monitors, or user storage. These explicitly routed legacy
/// events do not describe the live app's physical-key whitelist. Current DJ
/// routing is checked through SoundEngine/AppModel and actual music PCM graphs.
struct HeldTypingIntegrationTests {
    private struct InputTrace {
        var filter = KeyboardPressFilter()
        var events: [OfflineSoundRenderer.Event] = []
        var pressCount = 0

        mutating func receive(_ kind: KeyboardPressFilter.EventKind, code: UInt16, at time: Double, repeating: Bool = false) {
            switch filter.transition(kind: kind, code: code, isRepeat: repeating) {
            case .down:
                pressCount += 1
                events.append(.init(time: time, keyCode: code, action: .keyDown))
            case .up:
                events.append(.init(time: time, keyCode: code, action: .keyUp))
            case .tap:
                pressCount += 1
                events.append(.init(time: time, keyCode: code, action: .keyDown))
                events.append(.init(time: time, keyCode: code, action: .keyUp))
            case nil: break
            }
        }

        mutating func reset(at time: Double) {
            filter.reset(flags: 0)
            events.append(.init(time: time, keyCode: 0, action: .releaseAll))
        }
    }

    private let rate = 16_000.0
    private func rms(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let first = Int(start * rate) * 2
        let last = min(samples.count, Int(end * rate) * 2)
        return (samples[first..<last].reduce(0.0) { $0 + Double($1 * $1) } / Double(last - first)).squareRoot()
    }

    @Test func realHoldWithAutorepeatProducesOneCountAndOneContinuousRenderedNote() {
        var trace = InputTrace()
        trace.receive(.keyDown, code: 0, at: 0.1)
        for i in 1..<50 { trace.receive(.keyDown, code: 0, at: 0.1 + Double(i) * 0.04, repeating: true) }
        trace.receive(.keyUp, code: 0, at: 2.1)
        #expect(trace.pressCount == 1)
        #expect(trace.events.count == 2)
        #expect(trace.filter.heldKeys.isEmpty)
        let rendered = OfflineSoundRenderer.render(events: trace.events, duration: 3, sampleRate: rate)
        let canonical = OfflineSoundRenderer.render(events: [.init(time: 0.1, keyCode: 0, action: .keyDown),
                                                              .init(time: 2.1, keyCode: 0, action: .keyUp)],
                                                    duration: 3, sampleRate: rate)
        #expect(rendered == canonical, "Autorepeat must not change pitch, articulation, or the rendered waveform.")
        #expect(rms(rendered, from: 1.8, to: 2.0) > 0, "A held key keeps a quiet texture, without replaying its attack.")
        #expect(rms(rendered, from: 2.8, to: 3.0) == 0)
    }

    @Test func lostReleaseResetSilencesAudioAndRequiresAFreshPhysicalPress() {
        var trace = InputTrace()
        trace.receive(.keyDown, code: 0, at: 0.1)
        // Mirrors a secure-input, focus-loss, permission-loss, or sleep reset.
        trace.reset(at: 0.8)
        trace.receive(.keyDown, code: 0, at: 1.0, repeating: true)
        trace.receive(.keyUp, code: 0, at: 1.2)
        trace.receive(.keyDown, code: 0, at: 1.8)
        trace.receive(.keyUp, code: 0, at: 2.2)
        #expect(trace.pressCount == 2)
        #expect(trace.events.count == 4)
        for style in SoundStyle.allCases {
            let rendered = OfflineSoundRenderer.render(events: trace.events, style: style, duration: 3, sampleRate: rate)
            // In this legacy fixture a press starts one attack and a sustained
            // texture. Holding it must not generate repeated attacks.
            #expect(rms(rendered, from: 0.1, to: 0.7) > 0)
            // Allow the quiet held texture to fade, then require exact silence
            // despite the late repeat at 1.0 and physical release at 1.2.
            #expect(rms(rendered, from: 1.2, to: 1.7) == 0, "Reset must not be undone by a late repeat or release.")
            #expect(rms(rendered, from: 1.8, to: 2.1) > 0)
            #expect(rms(rendered, from: 2.9, to: 3.0) == 0)
        }
    }
}
