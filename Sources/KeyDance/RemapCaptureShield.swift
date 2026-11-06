import Foundation

/// In-app recording consumes the physical down, so keep consuming that same
/// hold's repeats/up after the editor completes. Otherwise a long Command-Q
/// recording could quit the app on its first autorepeat after capture ended.
/// Only current swallowed holds are retained, never text or completed key order.
struct RemapCaptureShield {
    private(set) var heldKeys = Set<UInt16>()
    var isDraining: Bool { !heldKeys.isEmpty }
    mutating func shouldSuppress(_ input: RemapInput, isCapturing: Bool) -> Bool {
        guard !input.isInjected else { return false }
        let code = input.physicalCode
        if isCapturing {
            switch input.kind {
            case .down: heldKeys.insert(code)
            case .up: heldKeys.remove(code)
            case .tap: break
            }
            return true
        }
        guard heldKeys.contains(code) else { return false }
        switch input.kind {
        case .up:
            heldKeys.remove(code)
            return true
        case .down:
            if input.isRepeat { return true }
            // A genuinely fresh down proves an up was missed while another app
            // had focus. Do not block the user's next independent key press.
            heldKeys.remove(code)
            return false
        case .tap:
            heldKeys.remove(code)
            return false
        }
    }
    mutating func reset() { heldKeys.removeAll() }
}
