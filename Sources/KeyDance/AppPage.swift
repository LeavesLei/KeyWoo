import SwiftUI

enum AppPage: String, CaseIterable {
    case studio = "音乐空间", remapping = "改键", statistics = "按键统计"
    case effects = "桌面特效", settings = "偏好设置"

    static let primaryPages: [AppPage] = [.studio, .effects, .remapping, .statistics]

    var symbol: String {
        switch self {
        case .studio: return "waveform"
        case .effects: return "sparkles"
        case .remapping: return "keyboard"
        case .statistics: return "chart.xyaxis.line"
        case .settings: return "slider.horizontal.3"
        }
    }

    var shortcut: Character {
        switch self {
        case .studio: return "1"
        case .remapping: return "2"
        case .statistics: return "3"
        case .effects: return "5"
        case .settings: return ","
        }
    }

    var shortcutLabel: String { "⌘" + String(shortcut) }
}

/// Drafts and browsing choices live above the visible window subtree. Closing
/// or translating the workspace never resets filters or reloads audio engines.
@MainActor
final class WorkspacePresentationState: ObservableObject {
    let statistics = StatisticsPresentationState()
    let sound: KeyboardSoundPresentationState
    let effects = EffectsPresentationState()

    init(category: KeyboardSoundCategory) {
        sound = KeyboardSoundPresentationState(category: category)
    }
}
