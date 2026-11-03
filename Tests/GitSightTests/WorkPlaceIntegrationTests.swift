import Foundation
import GitSightCore

enum WorkPlaceIntegrationTests {
    /// A stash says which branch it was made on and sits on that commit in the graph, even after the branch is deleted.
    static func testStashesKnowTheirBranchAndCommit() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repositoryURL = fixture.repository
        let mainHead = try git(repositoryURL, ["rev-parse", "HEAD"])
        let mainShort = try git(repositoryURL, ["rev-parse", "--short", "HEAD"])
        try expectEqual(try RepositoryInspector().inspect(repositoryAt: repositoryURL).worktrees.map(\.head), [mainHead], "the only worktree is at main's commit")

        try runGit(in: repositoryURL, ["checkout", "-b", "feature/x"])
        try write("feature.txt", in: repositoryURL)
        try runGit(in: repositoryURL, ["add", "feature.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Add feature.txt"])
        let featureHead = try git(repositoryURL, ["rev-parse", "HEAD"])
        let featureShort = try git(repositoryURL, ["rev-parse", "--short", "HEAD"])
        try write("tracked.txt", "first try\n", in: repositoryURL)
        try runGit(in: repositoryURL, ["stash", "push"])
        try write("tracked.txt", "second try\n", in: repositoryURL)
        try runGit(in: repositoryURL, ["stash", "push", "-m", "try: again"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        try runGit(in: repositoryURL, ["branch", "-D", "feature/x"])
        try runGit(in: repositoryURL, ["checkout", "--detach"])
        try write("tracked.txt", "detached\n", in: repositoryURL)
        try runGit(in: repositoryURL, ["stash", "push"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        let linkedURL = fixture.root.appendingPathComponent("linked")
        try runGit(in: repositoryURL, ["worktree", "add", "-b", "linked", linkedURL.path, "main"])
        try write("linked.txt", in: linkedURL)
        try runGit(in: linkedURL, ["add", "linked.txt"])
        try runGit(in: linkedURL, ["commit", "-m", "Add linked.txt"])
        let linkedHead = try git(linkedURL, ["rev-parse", "HEAD"])

        let inspector = RepositoryInspector()
        let snapshot = try inspector.inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.worktrees.map(\.head), [mainHead, linkedHead], "each worktree is at its own commit")
        try expectEqual(snapshot.stashes.map(\.branch), [nil, "feature/x", "feature/x"], "a stash names the branch it was made on, none on a detached HEAD")
        try expectEqual(
            snapshot.stashes.map(\.text),
            ["\(mainShort) Initial", "try: again", "\(featureShort) Add feature.txt"],
            "a stash reads as its message, without the branch git writes before it"
        )
        try expectEqual(snapshot.stashes.map(\.base), [mainHead, featureHead, featureHead], "a stash knows the commit it was made on")

        let history = try inspector.repositoryHistory(in: repositoryURL)
        let featureCommit = history.first { $0.fullHash == featureHead }
        try expectEqual(featureCommit?.subject, "Add feature.txt", "the graph still has the commit a stash of a deleted branch sits on")
        try expectEqual(featureCommit?.isUnpushed, true, "and that commit exists only on this machine")
        try expectEqual(history.contains { commit in snapshot.stashes.contains { $0.hash == commit.fullHash } }, false, "stashes are not commits of the graph")
    }

    private static func git(_ repositoryURL: URL, _ arguments: [String]) throws -> String {
        try CommitTopologyIntegrationTests.gitOutput(in: repositoryURL, arguments)
    }

    private static func write(_ file: String, _ text: String? = nil, in directoryURL: URL) throws {
        try (text ?? "\(file)\n").write(to: directoryURL.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    private static func makeRepository() throws -> (root: URL, repository: URL) {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(in: rootURL, ["init", "--bare", "-b", "main", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try write("tracked.txt", "initial\n", in: repositoryURL)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        return (rootURL, repositoryURL)
    }
}
