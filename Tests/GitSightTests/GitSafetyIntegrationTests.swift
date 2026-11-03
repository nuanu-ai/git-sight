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
        try "aaaa\n".write(to: repositoryURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "same\n".write(to: repositoryURL.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "notes.md", "same.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Add library"])
        // The library moves twice: once in a commit of the repository, once more not yet committed.
        let submoduleURL = repositoryURL.appendingPathComponent("library")
        try runGit(in: submoduleURL, ["config", "user.name", "Test User"])
        try runGit(in: submoduleURL, ["config", "user.email", "test@example.com"])
        for step in ["two", "three"] {
            try "\(step)\n".write(to: submoduleURL.appendingPathComponent("\(step).txt"), atomically: true, encoding: .utf8)
            try runGit(in: submoduleURL, ["add", "\(step).txt"])
            try runGit(in: submoduleURL, ["commit", "-m", step])
            if step == "two" {
                try runGit(in: repositoryURL, ["add", "library"])
                try runGit(in: repositoryURL, ["commit", "-m", "Bump library"])
            }
        }

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

        // diff.submodule=diff makes git diff the library inside it, under the library's own config.
        try runGit(in: repositoryURL, ["config", "diff.submodule", "diff"])
        try runGit(in: submoduleURL, ["config", "diff.external", programURL.path])

        // Filters run when git compares a changed file with what it stored, here and in the submodule.
        // A driver may have an empty name: "filter=" in .gitattributes and [filter ""] in config.
        try "*.md filter=\n".write(to: repositoryURL.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        let configURL = repositoryURL.appendingPathComponent(".git/config")
        try (String(contentsOf: configURL, encoding: .utf8) + "[filter \"\"]\n\tclean = \(programURL.path)\n\tsmudge = \(programURL.path)\n")
            .write(to: configURL, atomically: true, encoding: .utf8)
        try "bbbb\n".write(to: repositoryURL.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        for (url, driver) in [(repositoryURL, "tidy"), (submoduleURL, "pretty")] {
            try "*.txt filter=\(driver)\n".write(to: url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
            for key in ["clean", "smudge", "process"] {
                try runGit(in: url, ["config", "filter.\(driver).\(key)", programURL.path])
            }
            try runGit(in: url, ["config", "filter.\(driver).required", "true"])
            try "changed\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        }

        // A file touched but not changed makes porcelain git diff rewrite the index to note its new time.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: repositoryURL.appendingPathComponent("same.txt").path)
        let indexPath = repositoryURL.appendingPathComponent(".git/index").path
        let indexBefore = try FileManager.default.attributesOfItem(atPath: indexPath)

        let inspector = RepositoryInspector()
        _ = try inspector.inspect(repositoryAt: repositoryURL)
        let history = try inspector.repositoryHistory(in: repositoryURL)
        _ = try inspector.history(of: ["HEAD"], in: repositoryURL)
        _ = try inspector.changedFiles(in: repositoryURL, commit: history[0])
        _ = try inspector.diff(of: "library", in: history[0], repositoryURL: repositoryURL)
        _ = try inspector.diff(of: "tracked.txt", in: history[1], repositoryURL: repositoryURL)
        for path in ["tracked.txt", "notes.md", "library", "same.txt"] {
            _ = try inspector.uncommittedDiff(of: CommitFileSnapshot(status: "M", path: path), in: repositoryURL)
        }
        try expectEqual(FileManager.default.fileExists(atPath: markerURL.path), false, "reading a repository never runs a program its config names")
        let indexAfter = try FileManager.default.attributesOfItem(atPath: indexPath)
        try expectEqual(indexAfter[.systemFileNumber] as? Int, indexBefore[.systemFileNumber] as? Int, "reading a repository never rewrites its index")
        try expectEqual(indexAfter[.modificationDate] as? Date, indexBefore[.modificationDate] as? Date, "reading a repository never rewrites its index")
    }

    /// Filters from the user's own git config, such as Git LFS, are the user's choice and keep working:
    /// a file only touched is not reported as changed.
    static func testFiltersTheUserSetUpStillApply() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let homeURL = rootURL.appendingPathComponent("home")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try "[filter \"upper\"]\n\tclean = tr a-z A-Z\n\tsmudge = cat\n".write(to: homeURL.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        // git reads the user's config from HOME, and from XDG_CONFIG_HOME when set.
        let saved = ["HOME", "XDG_CONFIG_HOME"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("HOME", homeURL.path, 1)
        setenv("XDG_CONFIG_HOME", homeURL.path, 1)
        defer {
            for (name, value) in saved {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "*.dat filter=upper\n".write(to: repositoryURL.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        let fileURL = repositoryURL.appendingPathComponent("f.dat")
        try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", ".gitattributes", "f.dat"])
        try runGit(in: repositoryURL, ["commit", "-m", "Data"])
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: fileURL.path)

        try expectEqual(try RepositoryInspector().uncommittedFiles(in: repositoryURL), [], "a file only touched under the user's own filter is unchanged")
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
