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
        try runGit(in: repositoryURL, ["checkout", "trunk"])
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

    private static func scratchURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
    }
}
