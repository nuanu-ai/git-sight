import Foundation
import GitSightCore

enum FileDiffIntegrationTests {
    static func testDiffsShowWhatChangedLineByLine() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        let fileURL = repositoryURL.appendingPathComponent("notes.txt")
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "notes.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Notes"])
        try "one\n2\nthree\nfour\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["commit", "-am", "Edit notes"])
        let inspector = RepositoryInspector()
        let edit = try inspector.history(of: ["HEAD"], in: repositoryURL)[0]

        let expected = [
            DiffLine(kind: .hunk, oldLine: nil, newLine: nil, text: "@@ -1,3 +1,4 @@"),
            DiffLine(kind: .context, oldLine: 1, newLine: 1, text: "one"),
            DiffLine(kind: .removed, oldLine: 2, newLine: nil, text: "two"),
            DiffLine(kind: .added, oldLine: nil, newLine: 2, text: "2"),
            DiffLine(kind: .context, oldLine: 3, newLine: 3, text: "three"),
            DiffLine(kind: .added, oldLine: nil, newLine: 4, text: "four")
        ]
        try expectEqual(try inspector.diff(of: "notes.txt", in: edit, repositoryURL: repositoryURL).lines, expected, "a commit's file diff is numbered on both sides")

        // A diff driver in the repository's own config would run a command just to show a diff.
        let markerURL = rootURL.appendingPathComponent("textconv-ran")
        try "*.txt diff=shout\n".write(to: repositoryURL.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["config", "diff.shout.textconv", "touch \(markerURL.path); cat"])
        try runGit(in: repositoryURL, ["config", "diff.external", "touch \(markerURL.path); true"])

        try "one\n2\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let uncommitted = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "notes.txt"), in: repositoryURL)
        try expectEqual(uncommitted.lines.filter { $0.kind == .removed }.map(\.text), ["three", "four"], "an uncommitted edit is diffed against HEAD")
        try expectEqual(FileManager.default.fileExists(atPath: markerURL.path), false, "showing a diff never runs the repository's diff programs")

        try "draft\n".write(to: repositoryURL.appendingPathComponent("draft.md"), atomically: true, encoding: .utf8)
        let untracked = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "?", path: "draft.md"), in: repositoryURL)
        try expectEqual(untracked.lines.filter { $0.kind != .hunk }, [DiffLine(kind: .added, oldLine: nil, newLine: 1, text: "draft")], "an untracked file is all new")

        try runGit(in: repositoryURL, ["stash", "push", "--include-untracked", "-m", "parked"])
        let stash = try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, ["rev-parse", "stash@{0}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try expectEqual(try inspector.stashDiff(of: CommitFileSnapshot(status: "M", path: "notes.txt"), stash: stash, in: repositoryURL).lines.filter { $0.kind == .removed }.map(\.text), ["three", "four"], "a stashed edit is diffed against the commit it was stashed on")
        try expectEqual(try inspector.stashDiff(of: CommitFileSnapshot(status: "A", path: "draft.md"), stash: stash, in: repositoryURL).lines.filter { $0.kind == .added }.map(\.text), ["draft"], "an untracked file in a stash is all new")
        try expectEqual(FileManager.default.fileExists(atPath: markerURL.path), false, "a stash diff never runs the repository's diff programs")

        try Data([0, 1, 2, 0, 255]).write(to: repositoryURL.appendingPathComponent("blob.bin"))
        try runGit(in: repositoryURL, ["add", "blob.bin"])
        try runGit(in: repositoryURL, ["commit", "-m", "Binary"])
        let binary = try inspector.history(of: ["HEAD"], in: repositoryURL)[0]
        try expectEqual(try inspector.diff(of: "blob.bin", in: binary, repositoryURL: repositoryURL).isBinary, true, "a binary file is reported as binary")
    }
}
