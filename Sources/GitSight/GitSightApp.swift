import AppKit
import SwiftUI

@main
@MainActor
struct GitSightApp: App {
    private let model = WorkspaceModel()
    private let updater = AppUpdater()

    var body: some Scene {
        Window("git-sight", id: "main") {
            MainWindowView(model: model)
                // Shows only when a newer version is out.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { UpdatePill(updater: updater) }
                }
                .onAppear { model.refreshIfStale() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.refreshIfStale()
                }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
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
