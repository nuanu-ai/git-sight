import AppKit
import GitSightCore
import SwiftUI

/// Renders the main window offscreen to a PNG, for checking layout by eye without a screen recording permission.
/// The sidebar and toolbar glass do not draw offscreen; they come out blank.
@main
@MainActor
enum VisualRenderer {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 8, let width = Int(arguments[5]), let height = Int(arguments[6]) else {
            print("Usage: render <out.png> <folder> <repository|-> <uncommitted|unpushed|detached|stash|unmerged|leftover|-> <width> <height> <light|dark> [diff]")
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[1])
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: arguments[7] == "dark" ? .darkAqua : .aqua)
        // The renderer has its own defaults domain, so this does not move the app's folder.
        UserDefaults.standard.set(arguments[2], forKey: "rootPath")

        let model = WorkspaceModel()
        model.scan()
        while model.isScanning { try await Task.sleep(for: .milliseconds(50)) }
        // "-" leaves the overview on screen; a repository opens on its heaviest place, or on a piece of the given kind.
        if arguments[3] != "-", let repository = model.repositories.first(where: { $0.name == arguments[3] }) {
            model.open(repository)
            if arguments[4] != "-",
               let (place, piece) = repository.places.lazy.compactMap({ place in
                   place.pieces.first { "\($0.kind)" == arguments[4] }.map { (place, $0) }
               }).first {
                model.select(place, piece: piece)
            }
            for _ in 0..<100 where model.history == nil { try await Task.sleep(for: .milliseconds(50)) }
            for _ in 0..<60 where model.openRow != nil && model.rowFiles == nil { try await Task.sleep(for: .milliseconds(50)) }
            // "diff" also opens the first file's diff under the graph.
            if arguments.count > 8, arguments[8] == "diff", let file = model.rowFiles?.first {
                model.toggleDiff(of: file)
                for _ in 0..<60 where model.fileDiff == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: MainWindowView(model: model))
        window.setContentSize(NSSize(width: width, height: height))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(1500))

        // Live vibrancy samples the screen, which an offscreen capture does not have.
        func flatten(_ view: NSView) {
            if let effect = view as? NSVisualEffectView {
                effect.blendingMode = .withinWindow
                effect.state = .inactive
                effect.material = .windowBackground
            }
            view.subviews.forEach(flatten)
        }
        let frameView = window.contentView!.superview!
        flatten(frameView)
        try await Task.sleep(for: .milliseconds(300))
        let bitmap = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print(output.path)
        exit(0)
    }
}
