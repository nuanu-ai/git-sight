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
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Выбрать папку…", action: model.chooseRoot)
                    .keyboardShortcut("o")
                Button("Обновить", action: model.scan)
                    .keyboardShortcut("r")
                    .disabled(model.rootURL == nil || model.isScanning)
            }
        }
    }
}
