import Foundation
import GitSightCore

enum UnfinishedWorkIntegrationTests {
    /// Work on the server is not done until it is in the default branch, here called trunk. A branch merged with a merge commit or
    /// squashed into one commit is done; one that never got there is unfinished and goes stale.
    static func testWorkNotInTheBaseBranchIsUnfinished() throws {
        let rootURL = scratchURL()
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", "-b", "trunk", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "trunk"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        let daysAgo = { (days: Int) in
            let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-Double(days) * 86_400))
            return ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date]
        }
        func commit(_ name: String, _ text: String, days: Int) throws {
            try text.write(to: repositoryURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
            try runGit(in: repositoryURL, ["add", name])
            try runGit(in: repositoryURL, ["commit", "-m", "\(name): \(text)"], environment: daysAgo(days))
        }
        try commit("readme.txt", "start\n", days: 40)
        try commit("legacy-a.txt", "old\n", days: 40)
        try commit("legacy-b.txt", "old\n", days: 40)
        try commit("legacy-c.txt", "old\n", days: 40)
        try commit("run.sh", "echo run\n", days: 40)
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "trunk"])
        // The server says which branch is the default, as a clone records it.
        try runGit(in: repositoryURL, ["remote", "set-head", "origin", "trunk"])

        for (branch, days) in [("open", 20), ("merged", 30), ("squashed", 30)] {
            try runGit(in: repositoryURL, ["checkout", "-b", branch, "trunk"])
            try commit("\(branch).txt", "first\n", days: days)
            try commit("\(branch).txt", "first\nsecond\n", days: days)
            try runGit(in: repositoryURL, ["push", "-u", "origin", branch])
        }
        // The squashed branch also adds notes the base never touches again.
        try runGit(in: repositoryURL, ["checkout", "squashed"])
        try commit("squashed-notes.txt", "notes\n", days: 30)
        try runGit(in: repositoryURL, ["push", "origin", "squashed"])
        // Only the first of its two files is carried over to trunk, as a cherry-pick does.
        try runGit(in: repositoryURL, ["checkout", "-b", "partial", "trunk"])
        try commit("partial-a.txt", "a\n", days: 20)
        try commit("partial-b.txt", "b\n", days: 20)
        try runGit(in: repositoryURL, ["push", "-u", "origin", "partial"])
        // Deleting a file is work too: each of these branches adds one file and deletes another.
        for (branch, deleted) in [("cleanup", "legacy-a.txt"), ("trimmed", "legacy-b.txt")] {
            try runGit(in: repositoryURL, ["checkout", "-b", branch, "trunk"])
            try commit("\(branch).txt", "first\n", days: 30)
            try runGit(in: repositoryURL, ["rm", "-q", deleted])
            try runGit(in: repositoryURL, ["commit", "-m", "Delete \(deleted)"], environment: daysAgo(30))
            try runGit(in: repositoryURL, ["push", "-u", "origin", branch])
        }
        // A branch that only deletes, never merged.
        try runGit(in: repositoryURL, ["checkout", "-b", "prune", "trunk"])
        try runGit(in: repositoryURL, ["rm", "-q", "legacy-c.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Delete legacy-c.txt"], environment: daysAgo(20))
        try runGit(in: repositoryURL, ["push", "-u", "origin", "prune"])
        // Making a script executable is work too, though not a line of it changes.
        try runGit(in: repositoryURL, ["checkout", "-b", "executable", "trunk"])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repositoryURL.appendingPathComponent("run.sh").path)
        try runGit(in: repositoryURL, ["commit", "-am", "Make run.sh executable"], environment: daysAgo(20))
        try runGit(in: repositoryURL, ["push", "-u", "origin", "executable"])
        try runGit(in: repositoryURL, ["checkout", "trunk"])
        try runGit(in: repositoryURL, ["cherry-pick", "partial~1"], environment: daysAgo(19))
        // trunk takes the new file of cleanup but keeps the file it deleted.
        try runGit(in: repositoryURL, ["cherry-pick", "cleanup~1"], environment: daysAgo(19))
        // trimmed is squashed in whole, its deletion too, and trunk edits its new file again.
        try runGit(in: repositoryURL, ["merge", "--squash", "trimmed"])
        try runGit(in: repositoryURL, ["commit", "-m", "Squash trimmed"], environment: daysAgo(25))
        try commit("trimmed.txt", "first\nmore\n", days: 24)
        try runGit(in: repositoryURL, ["merge", "--no-ff", "merged", "-m", "Merge merged"], environment: daysAgo(25))
        try runGit(in: repositoryURL, ["merge", "--squash", "squashed"])
        try runGit(in: repositoryURL, ["commit", "-m", "Squash squashed"], environment: daysAgo(25))
        // trunk moves on after the squash, editing the squashed file again.
        try commit("squashed.txt", "first\nsecond\nthird\n", days: 24)
        try runGit(in: repositoryURL, ["push", "origin", "trunk"])
        // Deleted on the server after a squash merge git cannot see, with commits only here: a notice that
        // never turns into forgotten work, however old, and not stale unfinished work on top of that.
        try runGit(in: repositoryURL, ["checkout", "-b", "gone", "trunk"])
        try commit("gone.txt", "work\n", days: 70)
        try runGit(in: repositoryURL, ["push", "-u", "origin", "gone"])
        try runGit(in: repositoryURL, ["push", "origin", "--delete", "gone"])
        try runGit(in: repositoryURL, ["fetch", "--prune"])
        // Started from the server's trunk, which makes origin/trunk its upstream, and pushed under its own name.
        try runGit(in: repositoryURL, ["checkout", "-b", "fix", "origin/trunk"])
        try commit("fix.txt", "fix\n", days: 1)
        try runGit(in: repositoryURL, ["push", "origin", "fix"])
        // Branches from trunk as it is now with nothing to merge: an empty commit, and a change taken back.
        try runGit(in: repositoryURL, ["checkout", "-b", "noop", "trunk"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Nothing"])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "noop"])
        try runGit(in: repositoryURL, ["checkout", "-b", "undone", "trunk"])
        try commit("readme.txt", "start\nmore\n", days: 1)
        try runGit(in: repositoryURL, ["revert", "--no-edit", "HEAD"])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "undone"])
        // A site published from a branch with no history in common with trunk: never merged, never unfinished.
        try runGit(in: repositoryURL, ["checkout", "--orphan", "pages"])
        try runGit(in: repositoryURL, ["rm", "-rq", "--cached", "."])
        try commit("index.html", "site\n", days: 90)
        try runGit(in: repositoryURL, ["push", "-u", "origin", "pages"])
        try runGit(in: repositoryURL, ["checkout", "-f", "trunk"])
        try runGit(in: repositoryURL, ["clean", "-fdq"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let branches = Dictionary(uniqueKeysWithValues: snapshot.branches.map { ($0.name, $0) })
        try expectEqual(snapshot.baseBranch, "trunk", "the server's default branch is the base, whatever its name")
        try expectEqual(branches["trunk"]?.isBase, true, "the local trunk is the base")
        try expectEqual(branches["open"]?.isBase, false, "a feature branch is not the base")
        try expectEqual(branches["open"]?.unmergedCommits, 2, "a branch never merged has its commits outside the base")
        try expectEqual(branches["merged"]?.unmergedCommits, 0, "a branch merged with a merge commit is in the base")
        try expectEqual(branches["squashed"]?.unmergedCommits, 0, "a branch squashed into the base is in it too, though the base edited it since")
        try expectEqual(branches["partial"]?.unmergedCommits, 2, "a branch the base has only part of is not merged")
        try expectEqual(branches["cleanup"]?.unmergedCommits, 2, "a branch whose deletion the base lacks is not merged")
        try expectEqual(branches["prune"]?.unmergedCommits, 1, "a branch that only deletes is not merged until the base deletes too")
        try expectEqual(branches["trimmed"]?.unmergedCommits, 0, "a branch squashed with its deletion is merged, though the base edited it since")
        try expectEqual(branches["executable"]?.unmergedCommits, 1, "a branch that only makes a script executable is not merged until the base does too")
        try expectEqual(branches["noop"]?.unmergedCommits, 0, "a branch of one empty commit has nothing to merge")
        try expectEqual(branches["undone"]?.unmergedCommits, 0, "nor has one that took its change back")
        try expectEqual(branches["fix"]?.isBase, false, "a branch that tracks the server's trunk is not the base")
        try expectEqual(branches["fix"]?.unmergedCommits, 1, "and its work is not in the base")
        try expectEqual(branches["pages"]?.isUnrelated, true, "a branch with no history in common with the base is apart from it")
        try expectEqual(snapshot.severity, .warning, "unfinished work left for 20 days is abandoned, though the server has it; a three-month-old site is not forgotten work")

        let now = Date()
        let days = { (count: Double) in now.addingTimeInterval(-count * 86_400) }
        try expectEqual(Severity(of: .unmerged, lastChanged: days(13), now: now), .attention, "unfinished work is in progress for two weeks")
        try expectEqual(Severity(of: .unmerged, lastChanged: days(15), now: now), .warning, "after two weeks it is abandoned")
        try expectEqual(Severity(of: .unmerged, lastChanged: days(61), now: now), .critical, "after two months it is forgotten")
        try expectEqual(Severity(of: .leftover, lastChanged: days(13), now: now), .clean, "a branch merged two weeks ago is normal cleanup lag")
        try expectEqual(Severity(of: .leftover, lastChanged: days(15), now: now), .warning, "older leftovers are clutter")
        try expectEqual(Severity(of: .leftover, lastChanged: days(400), now: now), .warning, "clutter loses nothing, so it is never forgotten work")
    }

    /// In a fork, work is merged into the repository it was forked from, not into the fork's own stale main.
    static func testForkMergesIntoTheRepositoryItForked() throws {
        let rootURL = scratchURL()
        let canonicalURL = rootURL.appendingPathComponent("canonical.git")
        let forkURL = rootURL.appendingPathComponent("fork.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", "-b", "main", canonicalURL.path])
        try runGit(in: rootURL, ["init", "--bare", "-b", "main", forkURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "start\n".write(to: repositoryURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "readme.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Start"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", forkURL.path])
        try runGit(in: repositoryURL, ["remote", "add", "upstream", canonicalURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["push", "upstream", "main"])
        try runGit(in: repositoryURL, ["checkout", "-b", "feature"])
        try "start\nfeature\n".write(to: repositoryURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["commit", "-am", "Feature"])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "feature"])
        // The pull request lands in the canonical repository; the fork's main stays where it was.
        try runGit(in: repositoryURL, ["push", "upstream", "feature:main"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        try runGit(in: repositoryURL, ["fetch", "upstream"])
        try runGit(in: repositoryURL, ["remote", "set-head", "origin", "main"])
        try runGit(in: repositoryURL, ["remote", "set-head", "upstream", "main"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let feature = snapshot.branches.first { $0.name == "feature" }
        try expectEqual(feature?.unmergedCommits, 0, "a branch merged into the forked repository is done")
    }

    /// Merged branches younger than the cleanup lag are not work at all, so they give the repository no age.
    static func testFreshLeftoversGiveNoAge() throws {
        let rootURL = scratchURL()
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", "-b", "main", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "start\n".write(to: repositoryURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "readme.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Start"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["branch", "done"])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "done"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.severity, .clean, "a branch merged today is normal cleanup lag")
        try expectEqual(snapshot.oldestUnsavedWork, nil, "and the repository has no work to date")
    }

    /// A partial clone fetches missing trees from the server on demand, writing them into the repository.
    /// Reading branches must not: the clone keeps exactly the objects it had.
    static func testPartialClonesFetchNothing() throws {
        let rootURL = scratchURL()
        let originURL = rootURL.appendingPathComponent("origin")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: originURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: originURL, ["init", "-b", "main"])
        try runGit(in: originURL, ["config", "user.name", "Test User"])
        try runGit(in: originURL, ["config", "user.email", "test@example.com"])
        try runGit(in: originURL, ["config", "uploadpack.allowFilter", "true"])
        try "start\n".write(to: originURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: originURL, ["add", "readme.txt"])
        try runGit(in: originURL, ["commit", "-m", "Start"])
        try runGit(in: originURL, ["checkout", "-b", "feature"])
        try "start\nfeature\n".write(to: originURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: originURL, ["commit", "-am", "Feature"])
        try runGit(in: originURL, ["checkout", "main"])
        try runGit(in: rootURL, ["clone", "--filter=tree:0", "--no-local", "file://\(originURL.path)", repositoryURL.path])
        try runGit(in: repositoryURL, ["branch", "feature", "origin/feature"])
        let objectsBefore = try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, ["count-objects", "-v"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.branches.first { $0.name == "feature" }?.unmergedCommits, 1, "work it cannot compare file by file still counts as not merged")
        try expectEqual(try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, ["count-objects", "-v"]), objectsBefore, "inspecting a partial clone fetches no objects")
    }

    /// A merged branch someone is on, in the main worktree or under uncommitted edits, is in use, not left behind.
    /// One an agent's clean worktree still holds is.
    static func testBranchesInUseAreNotLeftovers() throws {
        let rootURL = scratchURL()
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let monthAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-30 * 86_400))
        try runGit(in: rootURL, ["init", "--bare", "-b", "main", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "start\n".write(to: repositoryURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "readme.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Start"], environment: ["GIT_AUTHOR_DATE": monthAgo, "GIT_COMMITTER_DATE": monthAgo])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        for name in ["held", "busy"] {
            try runGit(in: repositoryURL, ["worktree", "add", rootURL.appendingPathComponent(name).path, "-b", name])
        }
        try "edited\n".write(to: rootURL.appendingPathComponent("busy/readme.txt"), atomically: true, encoding: .utf8)
        // Just started from main, whose last commit is a month old.
        try runGit(in: repositoryURL, ["switch", "-c", "wip"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.leftoverBranches.map(\.name), ["held"], "only the branch in an idle worktree is left behind")
    }

    /// A branch read once as unmerged is read again when the base takes it in: the answer for a branch
    /// stands only while neither it nor the base moves.
    static func testMergeIsReadAgainWhenTheBaseMoves() throws {
        let rootURL = scratchURL()
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", "-b", "main", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        func commit(_ name: String) throws {
            try "\(name)\n".write(to: repositoryURL.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
            try runGit(in: repositoryURL, ["add", "\(name).txt"])
            try runGit(in: repositoryURL, ["commit", "-m", name])
        }
        try commit("start")
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["switch", "-c", "feature"])
        try commit("feature")
        try runGit(in: repositoryURL, ["push", "-u", "origin", "feature"])
        try runGit(in: repositoryURL, ["switch", "main"])
        try commit("other")
        try runGit(in: repositoryURL, ["push", "origin", "main"])
        let unmerged = { try RepositoryInspector().inspect(repositoryAt: repositoryURL).branches.first { $0.name == "feature" }?.unmergedCommits }
        try expectEqual(try unmerged(), 1, "the base has none of the branch yet")

        try runGit(in: repositoryURL, ["merge", "--squash", "feature"])
        try runGit(in: repositoryURL, ["commit", "-m", "Squash feature"])
        try runGit(in: repositoryURL, ["push", "origin", "main"])
        try expectEqual(try unmerged(), 0, "once the base squashes it in, the branch reads as merged")
    }

    /// A shallow clone cuts history where a branch and the base meet, so the branch looks apart from the
    /// base. Deepened, with neither branch moved, the branch is read again and is unmerged work.
    static func testDeepenedCloneIsReadAgain() throws {
        let rootURL = scratchURL()
        let originURL = rootURL.appendingPathComponent("origin")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: originURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: originURL, ["init", "-b", "main"])
        try runGit(in: originURL, ["config", "user.name", "Test User"])
        try runGit(in: originURL, ["config", "user.email", "test@example.com"])
        try "start\n".write(to: originURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: originURL, ["add", "readme.txt"])
        try runGit(in: originURL, ["commit", "-m", "Start"])
        try runGit(in: originURL, ["checkout", "-b", "feature"])
        try "start\nfeature\n".write(to: originURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: originURL, ["commit", "-am", "Feature"])
        try runGit(in: originURL, ["checkout", "main"])
        try runGit(in: rootURL, ["clone", "--depth", "1", "--no-single-branch", "file://\(originURL.path)", repositoryURL.path])
        try runGit(in: repositoryURL, ["branch", "feature", "origin/feature"])
        let feature = { try RepositoryInspector().inspect(repositoryAt: repositoryURL).branches.first { $0.name == "feature" } }
        try expectEqual(try feature()?.isUnrelated, true, "cut at one commit each, the branch and the base share no history")

        try runGit(in: repositoryURL, ["fetch", "--unshallow"])
        let deepened = try feature()
        try expectEqual(deepened?.isUnrelated, false, "deepened, they do")
        try expectEqual(deepened?.unmergedCommits, 1, "and the branch's commit is work the base lacks")
    }

    /// A branch file written by hand may name a file's contents, not a commit. git counts nothing for it,
    /// and the rest of the repository is read as usual.
    static func testBranchNamingNoCommitLeavesTheRestReadable() throws {
        let rootURL = scratchURL()
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "start\n".write(to: repositoryURL.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "readme.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Start"])
        let blob = try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, ["hash-object", "-w", "readme.txt"])
        try "\(blob)\n".write(to: repositoryURL.appendingPathComponent(".git/refs/heads/odd"), atomically: false, encoding: .utf8)

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.branches.map(\.name), ["main", "odd"], "every branch is listed")
        try expectEqual(snapshot.branches.first { $0.name == "odd" }?.unmergedCommits, 0, "a branch that names no commit holds no work")
    }

    private static func scratchURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
    }
}
