import Foundation
import GitSightCore

enum RepositorySnapshotIntegrationTests {
    static func testReportsRepositoryObjectsWithoutChangingFilesystem() throws {
        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootURL = projectRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("GitSightTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let originURL = rootURL.appendingPathComponent("origin.git", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("main", isDirectory: true)
        let otherURL = rootURL.appendingPathComponent("other", isDirectory: true)
        let linkedURL = rootURL.appendingPathComponent("linked", isDirectory: true)
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])

        try runGit(in: rootURL, ["clone", originURL.path, otherURL.path])
        try runGit(in: otherURL, ["config", "user.name", "Other User"])
        try runGit(in: otherURL, ["config", "user.email", "other@example.com"])
        try "origin\n".write(to: otherURL.appendingPathComponent("origin.txt"), atomically: true, encoding: .utf8)
        try runGit(in: otherURL, ["add", "origin.txt"])
        try runGit(in: otherURL, ["commit", "-m", "Origin movement"])
        try runGit(in: otherURL, ["push"])

        try "local\n".write(to: repositoryURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "local.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Local work"])
        try runGit(in: repositoryURL, ["fetch", "origin"])
        try runGit(in: repositoryURL, ["branch", "feature"])
        try runGit(in: repositoryURL, ["worktree", "add", linkedURL.path, "feature"])

        try "stashed\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["stash", "push", "-m", "saved work"])
        try "dirty\n".write(to: repositoryURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try "linked dirty\n".write(to: linkedURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["remote", "set-url", "origin", "git@github.com:example/git-sight.git"])

        let fingerprintBefore = try filesystemFingerprint(of: repositoryURL)
        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let fingerprintAfter = try filesystemFingerprint(of: repositoryURL)

        try expectEqual(snapshot.path, repositoryURL, "snapshot reports repository path")
        try expectEqual(snapshot.name, "main", "snapshot reports repository name")
        try expectEqual(snapshot.currentBranch, "main", "snapshot reports current branch")
        try expectEqual(snapshot.ahead, 1, "snapshot reports commits ahead of the local upstream ref")
        try expectEqual(snapshot.behind, 1, "snapshot reports commits behind the local upstream ref")
        try expectEqual(snapshot.dirtyFileCount, 1, "snapshot reports main worktree dirt")
        try expectEqual(snapshot.remoteWebURL, URL(string: "https://github.com/example/git-sight"), "snapshot converts SSH remote to web URL")

        let mainWorktree = snapshot.worktrees.first { $0.isMain }
        let linkedWorktree = snapshot.worktrees.first { $0.path == linkedURL }
        try expectEqual(mainWorktree?.branch, "main", "main worktree reports its branch")
        try expectEqual(mainWorktree?.dirtyFileCount, 1, "main worktree reports dirty files")
        try expectEqual(linkedWorktree?.branch, "feature", "linked worktree reports its branch")
        try expectEqual(linkedWorktree?.dirtyFileCount, 1, "linked worktree reports dirty files")
        try expectEqual(linkedWorktree?.isMain, false, "linked worktree is not marked main")

        let mainBranch = snapshot.branches.first { $0.name == "main" }
        let featureBranch = snapshot.branches.first { $0.name == "feature" }
        try expectEqual(mainBranch?.upstream, "origin/main", "branch reports its upstream")
        try expectEqual(mainBranch?.ahead, 1, "branch reports ahead count")
        try expectEqual(mainBranch?.behind, 1, "branch reports behind count")
        try expectEqual(mainBranch?.hasWorktree, true, "branch retains main worktree association")
        try expectEqual(featureBranch?.hasWorktree, true, "branch retains linked worktree association")
        try expectEqual(snapshot.stashes.count, 1, "snapshot reports stashes")
        try expectEqual(snapshot.stashes.first?.name, "stash@{0}", "stash reports its ref name")
        try expectEqual(snapshot.stashes.first?.message.contains("saved work"), true, "stash reports its message")
        try expectEqual(snapshot.commits.map(\.subject).contains("Local work"), true, "snapshot reports recent commits")
        try expectEqual(snapshot.commits.first { $0.subject == "Local work" }?.author, "Test User", "commit reports its author")
        try expectEqual(snapshot.lastActivity, snapshot.worktrees.compactMap(\.lastActivity).max(), "repository reports latest local worktree activity")
        try expectEqual(fingerprintAfter, fingerprintBefore, "inspection leaves every repository file and directory unchanged")
    }

    static func testEachBranchIsComparedWithItsOwnUpstream() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        let otherURL = rootURL.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["checkout", "-b", "feature"])
        try "feature\n".write(to: repositoryURL.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "feature.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Pushed feature"])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "feature"])
        try runGit(in: repositoryURL, ["checkout", "main"])

        try runGit(in: rootURL, ["clone", originURL.path, otherURL.path])
        try runGit(in: otherURL, ["config", "user.name", "Other User"])
        try runGit(in: otherURL, ["config", "user.email", "other@example.com"])
        for number in 1...2 {
            try "\(number)\n".write(to: otherURL.appendingPathComponent("origin-\(number).txt"), atomically: true, encoding: .utf8)
            try runGit(in: otherURL, ["add", "."])
            try runGit(in: otherURL, ["commit", "-m", "Origin movement \(number)"])
        }
        try runGit(in: otherURL, ["push", "origin", "main"])
        try runGit(in: repositoryURL, ["fetch", "origin"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let main = snapshot.branches.first { $0.name == "main" }
        let feature = snapshot.branches.first { $0.name == "feature" }
        try expectEqual(main?.behind, 2, "checked-out branch sees its upstream move")
        try expectEqual(feature?.ahead, 0, "pushed feature has nothing ahead of its own upstream")
        try expectEqual(feature?.behind, 0, "feature is not compared with the checked-out branch's upstream")
    }

    static func testMissingLinkedWorktreeDoesNotHideRepository() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let linkedURL = repositoryURL.deletingLastPathComponent().appendingPathComponent("linked-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL.deletingLastPathComponent()) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["worktree", "add", "--detach", linkedURL.path])
        try FileManager.default.removeItem(at: linkedURL)

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.name, repositoryURL.lastPathComponent, "repository remains inspectable")
        try expectEqual(snapshot.worktrees.map(\.path), [repositoryURL], "missing worktree is omitted without pruning repository metadata")
    }

    static func testGitEnvironmentCannotRedirectInspection() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let otherURL = rootURL.appendingPathComponent("other")
        let selectedURL = rootURL.appendingPathComponent("selected")
        for (url, branch) in [(otherURL, "other"), (selectedURL, "main")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try runGit(in: url, ["init", "-b", branch])
            try runGit(in: url, ["config", "user.name", "Test User"])
            try runGit(in: url, ["config", "user.email", "test@example.com"])
            try "initial\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try runGit(in: url, ["add", "tracked.txt"])
            try runGit(in: url, ["commit", "-m", "Initial"])
        }
        defer { try? FileManager.default.removeItem(at: rootURL) }
        setenv("GIT_DIR", otherURL.appendingPathComponent(".git").path, 1)
        setenv("GIT_WORK_TREE", otherURL.path, 1)
        defer {
            unsetenv("GIT_DIR")
            unsetenv("GIT_WORK_TREE")
        }

        let snapshot = try RepositoryInspector().inspect(repositoryAt: selectedURL)
        try expectEqual(snapshot.path, selectedURL, "snapshot retains selected repository path")
        try expectEqual(snapshot.currentBranch, "main", "inherited Git environment cannot redirect inspection to another repository")
    }
}

private func filesystemFingerprint(of rootURL: URL) throws -> String {
    var entries: [String] = []
    let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey
    ]
    let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: keys, options: [])!
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: Set(keys))
        let relativePath = url.path.replacingOccurrences(of: rootURL.path, with: "")
        let modificationTime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        var entry = "\(relativePath)|dir=\(values.isDirectory == true)|link=\(values.isSymbolicLink == true)|size=\(values.fileSize ?? 0)|mtime=\(modificationTime)"
        if values.isRegularFile == true {
            entry += "|content=" + (try Data(contentsOf: url)).base64EncodedString()
        } else if values.isSymbolicLink == true {
            entry += "|destination=" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        }
        entries.append(entry)
    }
    return entries.sorted().joined(separator: "\n")
}
