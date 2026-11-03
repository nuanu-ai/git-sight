import Foundation
import GitSightCore

enum RepositoryScoringIntegrationTests {
    static func testEachPieceOfWorkHasItsOwnVerdict() throws {
        let now = Date()
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 24 * 60 * 60) }
        try expectEqual(Severity(of: .uncommitted, lastChanged: daysAgo(2), now: now), .attention, "uncommitted work from two days ago is in progress")
        try expectEqual(Severity(of: .uncommitted, lastChanged: daysAgo(4), now: now), .warning, "uncommitted work left for four days is abandoned")
        try expectEqual(Severity(of: .stash, lastChanged: daysAgo(2), now: now), .warning, "a stash is abandoned after a day")
        try expectEqual(Severity(of: .commits(upstreamGone: false), lastChanged: daysAgo(40), now: now), .critical, "unpushed commits left for over a month are forgotten")
        try expectEqual(Severity(of: .commits(upstreamGone: true), lastChanged: daysAgo(40), now: now), .attention, "a branch deleted on the server stays a notice however old")
    }

    static func testPushedAndMergedBranchesAreNotRisk() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = gitDate(daysAgo: 40)
        try commit("merged.txt", on: "merged", in: fixture.repository, environment: old)
        try runGit(in: fixture.repository, ["merge", "--ff-only", "merged"])
        try runGit(in: fixture.repository, ["push", "origin", "main"])
        try commit("pushed.txt", on: "pushed", in: fixture.repository, environment: old)
        try runGit(in: fixture.repository, ["push", "-u", "origin", "pushed"])
        try runGit(in: fixture.repository, ["checkout", "main"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: fixture.repository)
        try expectEqual(snapshot.branches.map(\.name), ["main", "merged", "pushed"], "fixture keeps every local branch")
        try expectEqual(snapshot.severity, .clean, "old branches whose commits are on the server hold no unsaved work")
    }

    static func testUnpushedWorkAgesFromInProgressToCritical() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try commit("feature.txt", on: "feature", in: fixture.repository)
        try runGit(in: fixture.repository, ["checkout", "main"])
        let inspector = RepositoryInspector()
        try expectEqual(try inspector.inspect(repositoryAt: fixture.repository).severity, .attention, "fresh unpushed commits are work in progress")

        for (days, severity) in [(4, Severity.warning), (40, .critical)] {
            try runGit(in: fixture.repository, ["checkout", "feature"])
            try runGit(in: fixture.repository, ["commit", "--amend", "--no-edit"], environment: gitDate(daysAgo: days))
            try runGit(in: fixture.repository, ["checkout", "main"])
            try expectEqual(try inspector.inspect(repositoryAt: fixture.repository).severity, severity, "unpushed commits \(days) days old")
        }

        let stashFixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: stashFixture.root) }
        try "stashed\n".write(to: stashFixture.repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: stashFixture.repository, ["stash", "push", "-m", "old work"], environment: gitDate(daysAgo: 2))
        try expectEqual(try inspector.inspect(repositoryAt: stashFixture.repository).severity, .warning, "a stash left for two days is abandoned")
    }

    static func testOldUncommittedWorkIsRiskWhileOriginIsStill() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let fileURL = fixture.repository.appendingPathComponent("draft.txt")
        try "draft\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let inspector = RepositoryInspector()
        let fresh = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(fresh.behind, 0, "origin has not moved")
        try expectEqual(fresh.severity, .attention, "fresh uncommitted files are work in progress")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -4 * 24 * 60 * 60)], ofItemAtPath: fileURL.path)
        try expectEqual(try inspector.inspect(repositoryAt: fixture.repository).severity, .warning, "uncommitted files untouched for four days are abandoned")

        let deletionFixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: deletionFixture.root) }
        try commit("old.txt", on: nil, in: deletionFixture.repository, environment: gitDate(daysAgo: 40))
        try runGit(in: deletionFixture.repository, ["push", "origin", "main"])
        try FileManager.default.removeItem(at: deletionFixture.repository.appendingPathComponent("old.txt"))
        try expectEqual(try inspector.inspect(repositoryAt: deletionFixture.repository).severity, .attention, "a file deleted today is fresh work, whatever the age of its last commit")
    }

    static func testBranchDeletedOnServerIsANotice() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try commit("feature.txt", on: "feature", in: fixture.repository, environment: gitDate(daysAgo: 40))
        try runGit(in: fixture.repository, ["push", "-u", "origin", "feature"])
        try runGit(in: fixture.repository, ["checkout", "main"])
        // Squash-merging a pull request and deleting its branch leaves exactly this state locally.
        try runGit(in: fixture.repository, ["push", "origin", "--delete", "feature"])
        try runGit(in: fixture.repository, ["fetch", "--prune", "origin"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: fixture.repository)
        try expectEqual(snapshot.branches.first { $0.name == "feature" }?.unpushedCommits, 1, "the branch commit is on no remote ref")
        try expectEqual(snapshot.severity, .attention, "a branch deleted on the server is most likely merged, so it is a notice rather than abandoned work")
    }

    static func testWorktreesMatterOnlyForWorkTheyHold() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = gitDate(daysAgo: 4)
        try commit("pushed.txt", on: "pushed", in: fixture.repository, environment: old)
        try runGit(in: fixture.repository, ["push", "-u", "origin", "pushed"])
        try runGit(in: fixture.repository, ["checkout", "main"])
        let cleanURL = fixture.root.appendingPathComponent("clean-worktree")
        try runGit(in: fixture.repository, ["worktree", "add", cleanURL.path, "pushed"])
        let inspector = RepositoryInspector()
        try expectEqual(try inspector.inspect(repositoryAt: fixture.repository).severity, .clean, "an old worktree of a pushed branch holds nothing unsaved")

        try runGit(in: fixture.repository, ["checkout", "--detach", "main"])
        try commit("tagged.txt", on: nil, in: fixture.repository, environment: old)
        try runGit(in: fixture.repository, ["tag", "v1"])
        try runGit(in: fixture.repository, ["push", "origin", "v1"])
        try runGit(in: fixture.repository, ["checkout", "main"])
        let tagURL = fixture.root.appendingPathComponent("tag-worktree")
        try runGit(in: fixture.repository, ["worktree", "add", "--detach", tagURL.path, "v1"])
        try expectEqual(try inspector.inspect(repositoryAt: fixture.repository).severity, .clean, "a worktree detached at a tag on the server holds nothing unsaved")

        let detachedURL = fixture.root.appendingPathComponent("detached-worktree")
        try runGit(in: fixture.repository, ["worktree", "add", "--detach", detachedURL.path, "main"])
        try "detached\n".write(to: detachedURL.appendingPathComponent("detached.txt"), atomically: true, encoding: .utf8)
        try runGit(in: detachedURL, ["add", "detached.txt"])
        try runGit(in: detachedURL, ["commit", "-m", "Work on detached HEAD"], environment: old)
        try expectEqual(try inspector.inspect(repositoryAt: fixture.repository).severity, .warning, "old commits reachable only from a detached worktree are abandoned")
    }

    static func testRepositoryWithoutRemoteIsFlaggedOnce() throws {
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
        try commit("local.txt", on: nil, in: repositoryURL, environment: gitDate(daysAgo: 40))
        try commit("side.txt", on: "side", in: repositoryURL, environment: gitDate(daysAgo: 40))

        let inspector = RepositoryInspector()
        try expectEqual(try inspector.inspect(repositoryAt: repositoryURL).severity, .attention, "a repository kept only locally is one notice, not abandoned branches")

        let draftURL = repositoryURL.appendingPathComponent("draft.txt")
        try "draft\n".write(to: draftURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -4 * 24 * 60 * 60)], ofItemAtPath: draftURL.path)
        try expectEqual(try inspector.inspect(repositoryAt: repositoryURL).severity, .warning, "old uncommitted files are abandoned with or without a remote")

        try FileManager.default.removeItem(at: draftURL)
        try "stashed\n".write(to: repositoryURL.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["stash", "push", "-m", "old work"], environment: gitDate(daysAgo: 2))
        try expectEqual(try inspector.inspect(repositoryAt: repositoryURL).severity, .warning, "an old stash is abandoned with or without a remote")
    }

    private static func commit(_ file: String, on branch: String?, in repositoryURL: URL, environment: [String: String] = [:]) throws {
        if let branch { try runGit(in: repositoryURL, ["checkout", "-b", branch]) }
        try "\(file)\n".write(to: repositoryURL.appendingPathComponent(file), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", file])
        try runGit(in: repositoryURL, ["commit", "-m", "Add \(file)"], environment: environment)
    }

    private static func gitDate(daysAgo: Int) -> [String: String] {
        let value = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: TimeInterval(-daysAgo * 24 * 60 * 60)))
        return ["GIT_AUTHOR_DATE": value, "GIT_COMMITTER_DATE": value]
    }

    private static func makeRepository() throws -> (root: URL, repository: URL, origin: URL) {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootURL = projectRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("GitSightTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        return (rootURL, repositoryURL, originURL)
    }
}
