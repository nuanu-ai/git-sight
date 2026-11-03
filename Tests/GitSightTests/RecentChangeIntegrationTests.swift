import Foundation
import GitSightCore

enum RecentChangeIntegrationTests {
    static func testLatestChangeFollowsTheNewestWork() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        let fileURL = repositoryURL.appendingPathComponent("tracked.txt")
        try "initial\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"], environment: gitDate(hoursAgo: 5))
        let inspector = RepositoryInspector()

        let committed = try inspector.inspect(repositoryAt: repositoryURL).latestChange
        try expectEqual(committed?.kind, .commit, "a repository with only commits last saw a commit")
        try expectEqual(committed?.place, "main", "the commit is on main")

        try "edit\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60 * 60)], ofItemAtPath: fileURL.path)
        let edited = try inspector.inspect(repositoryAt: repositoryURL).latestChange
        try expectEqual(edited?.kind, .uncommitted(files: 1), "an edit after the last commit is the latest change")
        try expectEqual(edited?.place, "main", "the edit is in the main worktree, named by its branch")

        try runGit(in: repositoryURL, ["stash", "push", "-m", "parked"], environment: gitDate(hoursAgo: 0.5))
        let stashed = try inspector.inspect(repositoryAt: repositoryURL).latestChange
        try expectEqual(stashed?.kind, .stash, "stashing the edit makes the stash the latest change")

        let worktreeURL = rootURL.appendingPathComponent("agent-worktree")
        try runGit(in: repositoryURL, ["worktree", "add", "-b", "agent/fix", worktreeURL.path])
        try "agent\n".write(to: worktreeURL.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
        try runGit(in: worktreeURL, ["add", "agent.txt"])
        try runGit(in: worktreeURL, ["commit", "-m", "Agent fix"])
        let agent = try inspector.inspect(repositoryAt: repositoryURL).latestChange
        try expectEqual(agent?.kind, .commit, "an agent's commit in its worktree is the latest change")
        try expectEqual(agent?.place, "agent-worktree", "a linked worktree is named by its folder")
    }

    private static func gitDate(hoursAgo: Double) -> [String: String] {
        let value = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -hoursAgo * 60 * 60))
        return ["GIT_AUTHOR_DATE": value, "GIT_COMMITTER_DATE": value]
    }
}
