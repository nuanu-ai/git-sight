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
        let commit = try inspector.history(in: repositoryURL, revisions: ["refs/heads/main"]).first { $0.subject == "Change files" }!
        let files = try inspector.changedFiles(in: repositoryURL, commit: commit)
        try expectEqual(
            Set(files.map { "\($0.status)|\($0.path)" }),
            Set(["A|added.txt", "D|deleted.txt", "M|modified.txt"]),
            "expanded commit reports its actual added, deleted, and modified files"
        )
    }

    static func testReportsUncommittedAndStashedFiles() throws {
        let fileManager = FileManager.default
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repositoryURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "before\n".write(to: repositoryURL.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try "delete\n".write(to: repositoryURL.appendingPathComponent("deleted.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "."])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])

        let notesURL = repositoryURL.appendingPathComponent("notes", isDirectory: true)
        try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try "new\n".write(to: notesURL.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
        try "after\n".write(to: repositoryURL.appendingPathComponent("modified.txt"), atomically: true, encoding: .utf8)
        try fileManager.removeItem(at: repositoryURL.appendingPathComponent("deleted.txt"))

        let inspector = RepositoryInspector()
        try expectEqual(
            Set(try inspector.uncommittedFiles(in: repositoryURL).map { "\($0.status)|\($0.path)" }),
            Set(["D|deleted.txt", "M|modified.txt", "?|notes/draft.md"]),
            "uncommitted files are listed one by one with what happened to them"
        )

        try runGit(in: repositoryURL, ["stash", "push", "--include-untracked", "-m", "parked"])
        try expectEqual(
            Set(try inspector.stashFiles(in: repositoryURL, stash: "stash@{0}").map { "\($0.status)|\($0.path)" }),
            Set(["D|deleted.txt", "M|modified.txt", "A|notes/draft.md"]),
            "a stash lists the tracked and untracked files it holds"
        )
    }

    static func testStashKeepsItsFilesWhenAnotherIsPushed() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        for name in ["first.txt", "second.txt"] {
            try "before\n".write(to: repositoryURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try runGit(in: repositoryURL, ["add", "."])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try "after\n".write(to: repositoryURL.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["stash", "push", "-m", "first"])

        let inspector = RepositoryInspector()
        let stash = try inspector.inspect(repositoryAt: repositoryURL).stashes.first
        try "after\n".write(to: repositoryURL.appendingPathComponent("second.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["stash", "push", "-m", "second"])

        try expectEqual(
            try inspector.stashFiles(in: repositoryURL, stash: stash?.hash ?? "").map(\.path),
            ["first.txt"],
            "a stash read from an earlier scan still shows its own files after a new stash is pushed"
        )
    }
}
