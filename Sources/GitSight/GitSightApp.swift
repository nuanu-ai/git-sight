import AppKit
import SwiftUI

@main
@MainActor
struct GitSightApp: App {
    private let model = WorkspaceModel()
    private let updater = AppUpdater()

    var body: some Scene {
        Window("Git Sight", id: "main") {
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
            CommandGroup(replacing: .appInfo) {
                Button("About Git Sight", action: Self.showAbout)
            }
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
            CommandGroup(before: .toolbar) {
                // Checked by default: the graph shows what VS Code shows. Unchecked, it shows every branch.
                Toggle("Only Checked-Out Branches", isOn: Binding(get: { !model.showsEveryBranch }, set: { model.showsEveryBranch = !$0 }))
                Divider()
            }
        }
    }

    /// The standard About panel with a link to the source under the copyright.
    private static func showAbout() {
        let link = "github.com/nuanu-ai/git-sight"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: link, attributes: [
            .link: URL(string: "https://\(link)")!,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .paragraphStyle: paragraph
        ])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}
