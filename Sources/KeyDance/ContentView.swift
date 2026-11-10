import SwiftUI

struct ContentView: View {
    // The shell deliberately does not observe the model. Hidden windows keep
    // only this background and the AppKit visibility probe in the view graph.
    let model: AppModel
    @State private var windowVisible = false
    @StateObject private var presentation: WorkspacePresentationState

    init(model: AppModel) {
        self.model = model
        _presentation = StateObject(wrappedValue: WorkspacePresentationState(category: model.keyboardSoundStyle.category))
    }

    var body: some View {
        ZStack {
            Palette.background
            if windowVisible {
                WorkspaceView(model: model, presentation: presentation)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            WindowVisibilityObserver { visible in
                if windowVisible != visible { windowVisible = visible }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
