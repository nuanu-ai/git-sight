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

        try (1...6000).map { "line \($0)" }.joined(separator: "\n").write(to: repositoryURL.appendingPathComponent("huge.txt"), atomically: true, encoding: .utf8)
        let huge = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "?", path: "huge.txt"), in: repositoryURL)
        try expectEqual(huge.lines.count, RepositoryInspector.diffLineLimit, "a huge diff is cut at the limit")
        try expectEqual(huge.isTruncated, true, "a cut diff says so")
    }

    /// Files as they come: Windows line endings, no final newline, names that look like globs,
    /// a root commit under log.showRoot=false, a nested repository nobody added.
    static func testDiffsReadAnyFileAsGitStoresIt() throws {
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
        try runGit(in: repositoryURL, ["config", "log.showRoot", "false"])
        func write(_ text: String, _ name: String) throws {
            try text.write(to: repositoryURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("one\r\ntwo\r\n", "windows.txt")
        try write("x", "last.txt")
        try write((1...20).map { "line \($0)" }.joined(separator: "\n") + "\n", "long.txt")
        try write("star\n", "a*.txt")
        try write("abc\n", "abc.txt")
        try runGit(in: repositoryURL, ["add", "."])
        try runGit(in: repositoryURL, ["commit", "-m", "Root"])
        let inspector = RepositoryInspector()
        let root = try inspector.history(of: ["HEAD"], in: repositoryURL)[0]
        try expectEqual(try inspector.diff(of: "last.txt", in: root, repositoryURL: repositoryURL).lines.map(\.text), ["@@ -0,0 +1 @@", "x"], "a root commit shows its files as new, whatever log.showRoot says")

        try write("star, edited\n", "a*.txt")
        try write("abc, edited\n", "abc.txt")
        try runGit(in: repositoryURL, ["commit", "-am", "Edit both"])
        let edit = try inspector.history(of: ["HEAD"], in: repositoryURL)[0]
        try expectEqual(try inspector.diff(of: "a*.txt", in: edit, repositoryURL: repositoryURL).lines.filter { $0.kind == .added }.map(\.text), ["star, edited"], "a file named like a glob shows only itself")
        try write("star, again\n", "a*.txt")
        try write("abc, again\n", "abc.txt")
        try expectEqual(try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "a*.txt"), in: repositoryURL).lines.filter { $0.kind == .added }.map(\.text), ["star, again"], "an uncommitted file named like a glob shows only itself")

        try write("one\r\n2\r\n", "windows.txt")
        try expectEqual(try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "windows.txt"), in: repositoryURL).lines.map(\.text), ["@@ -1,2 +1,2 @@", "one", "two", "2"], "Windows line endings split into lines like any others")

        try write("y", "last.txt")
        try expectEqual(try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "last.txt"), in: repositoryURL).lines, [
            DiffLine(kind: .hunk, oldLine: nil, newLine: nil, text: "@@ -1 +1 @@"),
            DiffLine(kind: .removed, oldLine: 1, newLine: nil, text: "x"),
            DiffLine(kind: .added, oldLine: nil, newLine: 1, text: "y")
        ], "a file without a final newline: one-line ranges, and git's note about it left out")

        try write((1...20).map { $0 == 2 ? "changed 2" : $0 == 19 ? "changed 19" : "line \($0)" }.joined(separator: "\n") + "\n", "long.txt")
        let long = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "long.txt"), in: repositoryURL).lines
        try expectEqual(long.filter { $0.kind == .added }.map(\.newLine), [2, 19], "each run of changes is numbered from its own start")

        try write("\u{301}accent\n", "abc.txt")
        try expectEqual(try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "abc.txt"), in: repositoryURL).lines.filter { $0.kind == .added }.map(\.text), ["\u{301}accent"], "a line that starts with a combining mark is still an added line")

        let nestedURL = repositoryURL.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try runGit(in: nestedURL, ["init", "-b", "main"])
        var nestedFailed = false
        do {
            _ = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "?", path: "nested/"), in: repositoryURL)
        } catch {
            nestedFailed = true
        }
        try expectEqual(nestedFailed, true, "a nested repository has no diff, and the pane says it could not read one")
    }
}
