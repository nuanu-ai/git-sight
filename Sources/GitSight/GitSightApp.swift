import SwiftUI

@main
@MainActor
struct GitSightApp: App {
    private let model = WorkspaceModel()

    var body: some Scene {
        WindowGroup("git-sight") {
            MainWindowView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
    }
}
