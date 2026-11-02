import Foundation
import GitSightCore

enum RepositoryScoringIntegrationTests {
    static func testDirtyWorkIsNeutralUntilOriginMoves() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try "dirty\n".write(to: fixture.repository.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)

        let inspector = RepositoryInspector()
        let dirtyOnly = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(dirtyOnly.dirtyFileCount, 1, "fixture has uncommitted work")
        try expectEqual(dirtyOnly.behind, 0, "fixture starts level with origin")
        try expectEqual(dirtyOnly.score, 0, "uncommitted work alone is neutral")
        try expectEqual(dirtyOnly.severity, .clean, "uncommitted work alone stays clean")

        let otherURL = fixture.root.appendingPathComponent("other", isDirectory: true)
        try runGit(in: fixture.root, ["clone", fixture.origin.path, otherURL.path])
        try runGit(in: otherURL, ["config", "user.name", "Other User"])
        try runGit(in: otherURL, ["config", "user.email", "other@example.com"])
        try "origin\n".write(to: otherURL.appendingPathComponent("origin.txt"), atomically: true, encoding: .utf8)
        try runGit(in: otherURL, ["add", "origin.txt"])
        try runGit(in: otherURL, ["commit", "-m", "Origin movement"])
        try runGit(in: otherURL, ["push"])
        try runGit(in: fixture.repository, ["fetch", "origin"])

        let diverged = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(diverged.behind, 1, "local upstream ref observes origin movement")
        try expectEqual(diverged.dirtyFileCount, 1, "uncommitted work remains present")
        try expectEqual(diverged.severity, .warning, "dirty work on a moved origin becomes risky")
        try expectEqual(diverged.score > dirtyOnly.score, true, "origin movement adds integral risk")
    }

    static func testAbandonedWorkAgesIntoRisk() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try runGit(in: fixture.repository, ["checkout", "-b", "feature"])
        try "feature\n".write(to: fixture.repository.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(in: fixture.repository, ["add", "feature.txt"])
        try runGit(in: fixture.repository, ["commit", "-m", "Unpushed feature"])
        try runGit(in: fixture.repository, ["checkout", "main"])

        let inspector = RepositoryInspector()
        let freshBranch = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(freshBranch.branches.first { $0.name == "feature" }?.upstream, nil, "feature has not been pushed")
        try expectEqual(freshBranch.score, 0, "fresh unpushed work does not create noise")
        try expectEqual(freshBranch.severity, .clean, "fresh unpushed work stays clean")

        let oldBranchDate = gitDate(daysAgo: 4)
        try runGit(in: fixture.repository, ["checkout", "feature"])
        try runGit(in: fixture.repository, ["commit", "--amend", "--no-edit"], environment: oldBranchDate)
        try runGit(in: fixture.repository, ["checkout", "main"])
        let oldBranch = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(oldBranch.severity, .warning, "an unpushed branch older than three days needs attention")
        try expectEqual(oldBranch.score > freshBranch.score, true, "branch age adds risk")

        let auxiliaryURL = fixture.root.appendingPathComponent("auxiliary", isDirectory: true)
        try runGit(in: fixture.repository, ["worktree", "add", "-b", "auxiliary", auxiliaryURL.path, "main"])
        try "auxiliary\n".write(to: auxiliaryURL.appendingPathComponent("auxiliary.txt"), atomically: true, encoding: .utf8)
        try runGit(in: auxiliaryURL, ["add", "auxiliary.txt"])
        try runGit(in: auxiliaryURL, ["commit", "-m", "Old auxiliary work"], environment: oldBranchDate)
        let oldWorktree = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(oldWorktree.worktrees.count, 2, "fixture contains an auxiliary worktree")
        try expectEqual(oldWorktree.score > oldBranch.score, true, "an old auxiliary worktree adds risk even without dirty files")

        try "old stash\n".write(to: fixture.repository.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: fixture.repository, ["stash", "push", "-m", "old work"], environment: gitDate(daysAgo: 2))
        let oldStash = try inspector.inspect(repositoryAt: fixture.repository)
        try expectEqual(oldStash.stashes.count, 1, "old stash is visible")
        try expectEqual(oldStash.severity == .warning || oldStash.severity == .critical, true, "a stash older than one day creates at least warning risk")
        try expectEqual(oldStash.score > oldWorktree.score, true, "stash age contributes risk")
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
