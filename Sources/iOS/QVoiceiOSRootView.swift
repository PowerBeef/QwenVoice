import SwiftUI
import QwenVoiceCore

/// Thin shell that owns the `AppModel` lifetime and injects it into the
/// environment. The real tab routing + screen content lives in
/// `Sources/iOS/App/RootView.swift`. Kept under this filename so the
/// existing app entry point + Xcode scheme don't need renaming.
///
/// iOS is compile-safe only on `main` (see CLAUDE.md "What this is").
struct QVoiceiOSRootView: View {
    let modelRegistry: ContractBackedModelRegistry

    @State private var appModel: AppModel

    init(modelRegistry: ContractBackedModelRegistry) {
        self.modelRegistry = modelRegistry
        _appModel = State(initialValue: AppModel(modelRegistry: modelRegistry))
    }

    var body: some View {
        RootView()
            .environment(appModel)
    }
}
