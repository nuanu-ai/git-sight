import Foundation
import GitSightCore

enum UnfinishedWorkIntegrationTests {
    /// Work on the server is not done until it is in the default branch, here called trunk. A branch merged with a merge commit or
    /// squashed into one commit is done; one that never got there is unfinished and goes stale.
    static func testWorkNotInTheBaseBranchIsUnfinished() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
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
        // trunk moves on after the squash, in a file the squashed branch never touched.
        try commit("readme.txt", "start\nlater\n", days: 24)
        try runGit(in: repositoryURL, ["push", "origin", "trunk"])
        // Deleted on the server after a squash merge git cannot see, with commits only here: a notice that
        // never turns into forgotten work, however old, and not stale unfinished work on top of that.
        try runGit(in: repositoryURL, ["checkout", "-b", "gone", "trunk"])
        try commit("gone.txt", "work\n", days: 70)
        try runGit(in: repositoryURL, ["push", "-u", "origin", "gone"])
        try runGit(in: repositoryURL, ["push", "origin", "--delete", "gone"])
        try runGit(in: repositoryURL, ["fetch", "--prune"])
        try runGit(in: repositoryURL, ["checkout", "trunk"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let branches = Dictionary(uniqueKeysWithValues: snapshot.branches.map { ($0.name, $0) })
        try expectEqual(snapshot.baseBranch, "trunk", "the server's default branch is the base, whatever its name")
        try expectEqual(branches["trunk"]?.isBase, true, "the local trunk is the base")
        try expectEqual(branches["open"]?.isBase, false, "a feature branch is not the base")
        try expectEqual(branches["open"]?.unmergedCommits, 2, "a branch never merged has its commits outside the base")
        try expectEqual(branches["merged"]?.unmergedCommits, 0, "a branch merged with a merge commit is in the base")
        try expectEqual(branches["squashed"]?.unmergedCommits, 0, "a branch squashed into the base is in it too")
        try expectEqual(snapshot.severity, .warning, "unfinished work left for 20 days is abandoned, though the server has it")

        let now = Date()
        let days = { (count: Double) in now.addingTimeInterval(-count * 86_400) }
        try expectEqual(Severity(of: .unmerged, lastChanged: days(13), now: now), .attention, "unfinished work is in progress for two weeks")
        try expectEqual(Severity(of: .unmerged, lastChanged: days(15), now: now), .warning, "after two weeks it is abandoned")
        try expectEqual(Severity(of: .unmerged, lastChanged: days(61), now: now), .critical, "after two months it is forgotten")
        try expectEqual(Severity(of: .leftover, lastChanged: days(13), now: now), .clean, "a branch merged two weeks ago is normal cleanup lag")
        try expectEqual(Severity(of: .leftover, lastChanged: days(15), now: now), .warning, "older leftovers are clutter")
        try expectEqual(Severity(of: .leftover, lastChanged: days(400), now: now), .warning, "clutter loses nothing, so it is never forgotten work")
    }
}
