import AppKit
import GitSightCore
import SwiftUI

@main
@MainActor
enum VisualRenderer {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            throw NSError(domain: "VisualRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Usage: VisualRenderer <fixture-root> <output-directory>"])
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let fixtureRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let outputRoot = URL(fileURLWithPath: arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        let cases = [
            (name: "linear", width: 1180, height: 760, expanded: false),
            (name: "merge", width: 1180, height: 760, expanded: false),
            (name: "parallel", width: 1180, height: 760, expanded: false),
            (name: "interleaved", width: 1180, height: 760, expanded: false),
            (name: "interleaved", width: 900, height: 700, expanded: false),
            (name: "three-branches", width: 1180, height: 760, expanded: false),
            (name: "active-merge", width: 1180, height: 760, expanded: false),
            (name: "nested-merges", width: 1180, height: 760, expanded: false),
            (name: "long-content", width: 1180, height: 760, expanded: false),
            (name: "long-content", width: 900, height: 700, expanded: false),
            (name: "long-content", width: 1180, height: 760, expanded: true),
            (name: "long-content", width: 900, height: 700, expanded: true),
            (name: "history-limit", width: 1180, height: 3400, expanded: false)
        ]
        for testCase in cases {
            let name = testCase.name
            let repositoryURL = fixtureRoot.appendingPathComponent("\(name)/\(name)", isDirectory: true)
            let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
            let model = WorkspaceModel()
            model.select(snapshot)
            if testCase.expanded, let commit = snapshot.commits.first {
                model.toggleCommit(commit, in: snapshot)
                for _ in 0..<100 where model.commitFiles[commit.fullHash] == nil {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
            }
            let view = RepositoryDetailView(model: model, repository: snapshot)
                .frame(width: CGFloat(testCase.width), height: CGFloat(testCase.height))
                .background(Theme.background)
                .preferredColorScheme(.dark)
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: testCase.width, height: testCase.height)
            let window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = hostingView
            window.orderBack(nil)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
                throw NSError(domain: "VisualRenderer", code: 1)
            }
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "VisualRenderer", code: 1)
            }
            let suffix = testCase.expanded ? "-expanded" : ""
            let outputName = "\(name)-\(testCase.width)\(suffix)"
            try png.write(to: outputRoot.appendingPathComponent("\(outputName).png"))
            let lanes = snapshot.commits.enumerated().map { row, commit in
                "\(row): lane=\(commit.lane) parents=\(commit.parents.map { String($0.prefix(7)) }) \(commit.subject)"
            }.joined(separator: "\n")
            try lanes.write(to: outputRoot.appendingPathComponent("\(outputName).lanes.txt"), atomically: true, encoding: .utf8)
            window.close()
            print("\(outputName): \(snapshot.commits.count) commits, lanes \(snapshot.commits.map(\.lane))")
        }
    }
}
