import Foundation
import GitSightCore

enum RepositoryDiscoveryIntegrationTests {
    static func testFindsNestedRepositoriesAndLinkedWorktrees() throws {
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

        for relativePath in [
            "Projects/beta",
            "Projects/alpha/nested",
            ".hidden/gamma",
            "node_modules/delta",
            ".build/epsilon"
        ] {
            let repositoryURL = rootURL.appendingPathComponent(relativePath, isDirectory: true)
            try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
            try runGit(in: repositoryURL, ["init"])
        }

        let repositoryURLs = try RepositoryDiscovery().repositories(under: rootURL)
        let relativePaths = repositoryURLs.map { $0.path.replacingOccurrences(of: rootURL.path + "/", with: "") }
        try expectEqual(
            relativePaths,
            ["Projects/alpha", "Projects/beta", "Projects/linked"],
            "discovery finds nested and linked repositories while skipping excluded directories and nested repositories"
        )
    }
}
