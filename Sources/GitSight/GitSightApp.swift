import AppKit
import SwiftUI

@main
@MainActor
struct GitSightApp: App {
    private let model = WorkspaceModel()

    var body: some Scene {
        Window("git-sight", id: "main") {
            MainWindowView(model: model)
                .onAppear { model.refreshIfStale() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshIfStale()
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Folder…", action: model.chooseRoot)
                    .keyboardShortcut("o")
                Button("Refresh", action: model.scan)
                    .keyboardShortcut("r")
                    .disabled(model.rootURL == nil || model.isScanning)
            }
            TextSizeCommands()
        }
    }
}
