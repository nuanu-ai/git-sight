import Foundation
import GitSightCore

enum RepositoryDiscoveryIntegrationTests {
    static func testFolderDeletedDuringTheWalkIsNotAProblem() throws {
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let doomedURL = rootURL.appendingPathComponent("doomed", isDirectory: true)
        let keptURL = rootURL.appendingPathComponent("kept", isDirectory: true)
        try fileManager.createDirectory(at: doomedURL.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: keptURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }
        try runGit(in: keptURL, ["init"])

        // Something else deletes the folder after the walk listed it and before it got there,
        // as an agent's rm -rf does while a scan runs.
        var problems: [String] = []
        let found = try RepositoryDiscovery().repositories(under: rootURL, progress: { progress in
            if progress.scannedDirectories == 1 { try? fileManager.removeItem(at: doomedURL) }
        }, issue: { url, _ in problems.append(url.lastPathComponent) })

        try expectEqual(found.map(\.lastPathComponent), ["kept"], "the rest of the folder is still searched")
        try expectEqual(problems, [], "a folder that is gone has nothing to read, so it is no problem")
    }

    static func testLinkedWorktreesReportThroughTheirMainRepository() throws {
        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootURL = projectRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("GitSightTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectsURL = rootURL.appendingPathComponent("Projects", isDirectory: true)
        try fileManager.createDirectory(at: projectsURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let alphaURL = projectsURL.appendingPathComponent("alpha", isDirectory: true)
        try fileManager.createDirectory(at: alphaURL, withIntermediateDirectories: true)
        try runGit(in: alphaURL, ["init"])
        try runGit(in: alphaURL, ["config", "user.name", "Test User"])
        try runGit(in: alphaURL, ["config", "user.email", "test@example.com"])
        try "tracked\n".write(to: alphaURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: alphaURL, ["add", "tracked.txt"])
        try runGit(in: alphaURL, ["commit", "-m", "Initial"])

        let linkedURL = projectsURL.appendingPathComponent("linked", isDirectory: true)
        try runGit(in: alphaURL, ["worktree", "add", linkedURL.path])

        // Discovery skips hidden directories, so this repository is reachable only through its linked worktree.
        let omegaURL = rootURL.appendingPathComponent(".hidden/omega", isDirectory: true)
        try fileManager.createDirectory(at: omegaURL, withIntermediateDirectories: true)
        try runGit(in: omegaURL, ["init"])
        try runGit(in: omegaURL, ["config", "user.name", "Test User"])
        try runGit(in: omegaURL, ["config", "user.email", "test@example.com"])
        try runGit(in: omegaURL, ["commit", "--allow-empty", "-m", "Initial"])
        try runGit(in: omegaURL, ["worktree", "add", projectsURL.appendingPathComponent("omega-linked").path])

        for relativePath in [
            "Projects/beta",
            "Projects/alpha/nested",
            ".hidden/gamma",
            "node_modules/delta",
            ".build/epsilon",
            "Library/zeta"
        ] {
            let repositoryURL = rootURL.appendingPathComponent(relativePath, isDirectory: true)
            try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            try runGit(in: repositoryURL, ["init"])
        }

        var progressUpdates: [RepositoryDiscoveryProgress] = []
        let repositoryURLs = try RepositoryDiscovery().repositories(under: rootURL) { progressUpdates.append($0) }
        let relativePaths = repositoryURLs.map { $0.path.replacingOccurrences(of: rootURL.path + "/", with: "") }
        try expectEqual(
            relativePaths,
            [".hidden/omega", "Projects/alpha", "Projects/beta"],
            "linked worktrees report through their main repository, once, while excluded and nested directories are skipped"
        )
        try expectEqual(progressUpdates.last?.fractionCompleted, 1, "discovery reports a complete progress bar")
        try expectEqual(
            zip(progressUpdates, progressUpdates.dropFirst()).allSatisfy { $0.fractionCompleted <= $1.fractionCompleted },
            true,
            "discovery progress never moves backwards as new directories are found"
        )
        try expectEqual(progressUpdates.last?.discoveredRepositories, 3, "discovery progress reports every repository found")
        try expectEqual(progressUpdates.contains { $0.scannedDirectories > 0 }, true, "discovery reports visited directories")
    }
}
