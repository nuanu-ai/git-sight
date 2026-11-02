import Foundation
import GitSightCore

enum ChangedFilesIntegrationTests {
    static func testReportsFilesChangedBySelectedCommit() throws {
        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryURL = projectRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("GitSightTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repositoryURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])

        try "before\n".write(to: repositoryURL.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try "delete\n".write(to: repositoryURL.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "."])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try "after\n".write(to: repositoryURL.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repositoryURL.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        try fileManager.removeItem(at: repositoryURL.appendingPathComponent("deleted.txt"))
        try runGit(in: repositoryURL, ["add", "-A"])
        try runGit(in: repositoryURL, ["commit", "-m", "Change files"])

        let inspector = RepositoryInspector()
        let snapshot = try inspector.inspect(repositoryAt: repositoryURL)
        let commit = snapshot.commits.first { $0.subject == "Change files" }!
        let files = try inspector.changedFiles(in: repositoryURL, commit: commit)
        try expectEqual(
            Set(files.map { "\($0.status)|\($0.path)" }),
            Set(["A|added.txt", "D|deleted.txt", "M|modified.txt"]),
            "expanded commit reports its actual added, deleted, and modified files"
        )
    }
}
