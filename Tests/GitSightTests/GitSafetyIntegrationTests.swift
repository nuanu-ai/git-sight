import Foundation
import GitSightCore

enum GitSafetyIntegrationTests {
    static func testInspectionNeverRunsRepositoryHooks() throws {
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
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])

        let markerURL = rootURL.appendingPathComponent("hook-fired")
        let hookURL = rootURL.appendingPathComponent("fsmonitor.sh")
        try "#!/bin/sh\nprintf fired > '\(markerURL.path)'\n".write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
        try runGit(in: repositoryURL, ["config", "core.fsmonitor", hookURL.path])

        _ = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(FileManager.default.fileExists(atPath: markerURL.path), false, "read-only inspection must not execute repository-controlled fsmonitor hooks")
    }

    /// A repository's config can name programs for git to run while reading: a signature checker,
    /// clean and smudge filters, the same again inside a submodule. Reading must start none of them.
    static func testReadingNeverRunsProgramsFromRepositoryConfig() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("repository")
        let submoduleSourceURL = rootURL.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: submoduleSourceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let markerURL = rootURL.appendingPathComponent("program-ran")
        let programURL = rootURL.appendingPathComponent("program.sh")
        try "#!/bin/sh\ntouch '\(markerURL.path)'\ncat\n".write(to: programURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: programURL.path)

        for url in [repositoryURL, submoduleSourceURL] {
            try runGit(in: url, ["init", "-b", "main"])
            try runGit(in: url, ["config", "user.name", "Test User"])
            try runGit(in: url, ["config", "user.email", "test@example.com"])
            try "initial\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try runGit(in: url, ["add", "tracked.txt"])
            try runGit(in: url, ["commit", "-m", "Initial"])
        }
        try runGit(in: repositoryURL, ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSourceURL.path, "library"])
        try runGit(in: repositoryURL, ["commit", "-m", "Add library"])

        // A commit that claims a signature makes git ask gpg.program to check it.
        let head = try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, ["cat-file", "commit", "HEAD"])
        let signed = head.replacingOccurrences(of: "\n\n", with: "\ngpgsig -----BEGIN PGP SIGNATURE-----\n fake\n -----END PGP SIGNATURE-----\n\n")
        let objectURL = rootURL.appendingPathComponent("signed-commit")
        try signed.write(to: objectURL, atomically: true, encoding: .utf8)
        let signedHash = try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, ["hash-object", "-t", "commit", "-w", objectURL.path])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(in: repositoryURL, ["update-ref", "refs/heads/main", signedHash])
        try runGit(in: repositoryURL, ["config", "gpg.program", programURL.path])
        try runGit(in: repositoryURL, ["config", "log.showSignature", "true"])

        // Filters run when git compares a changed file with what it stored, here and in the submodule.
        let submoduleURL = repositoryURL.appendingPathComponent("library")
        for (url, driver) in [(repositoryURL, "tidy"), (submoduleURL, "pretty")] {
            try "*.txt filter=\(driver)\n".write(to: url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            for key in ["clean", "smudge", "process"] {
                try runGit(in: url, ["config", "filter.\(driver).\(key)", programURL.path])
            }
            try runGit(in: url, ["config", "filter.\(driver).required", "true"])
            try "changed\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        }

        let inspector = RepositoryInspector()
        _ = try inspector.inspect(repositoryAt: repositoryURL)
        let history = try inspector.repositoryHistory(in: repositoryURL)
        _ = try inspector.history(of: ["HEAD"], in: repositoryURL)
        _ = try inspector.changedFiles(in: repositoryURL, commit: history[0])
        _ = try inspector.diff(of: "tracked.txt", in: history[0], repositoryURL: repositoryURL)
        _ = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: "tracked.txt"), in: repositoryURL)
        try expectEqual(FileManager.default.fileExists(atPath: markerURL.path), false, "reading a repository never runs a program its config names")
    }

    static func testGoneUpstreamDoesNotHideRepository() throws {
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
        try runGit(in: repositoryURL, ["config", "branch.main.remote", "origin"])
        try runGit(in: repositoryURL, ["config", "branch.main.merge", "refs/heads/main"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])

        try runGit(in: repositoryURL, ["branch", "side"])
        try runGit(in: repositoryURL, ["config", "branch.side.remote", "origin"])
        try runGit(in: repositoryURL, ["config", "branch.side.merge", "refs/heads/side"])

        // A branch deleted on the server after its PR is merged is routine, so it must stay visible.
        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.branches.map(\.name), ["main", "side"], "branches with a deleted upstream stay visible")
        try expectEqual(snapshot.currentBranch, "main", "repository with a deleted upstream on HEAD is still inspected")
    }
}
