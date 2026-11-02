import Foundation
import GitSightCore

enum CommitTopologyIntegrationTests {
    static func testMergeCommitHasStableParentEdgesAndDistinctRails() throws {
        let fileManager = FileManager.default
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryURL = projectRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("GitSightTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repositoryURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])

        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["branch", "feature"])
        try "main\n".write(to: repositoryURL.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "main.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Main advance"])
        try runGit(in: repositoryURL, ["checkout", "feature"])
        try "feature\n".write(to: repositoryURL.appendingPathComponent("feature.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "feature.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Feature work"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        try runGit(in: repositoryURL, ["merge", "--no-ff", "feature", "-m", "Merge feature"])

        let inspector = RepositoryInspector()
        let snapshot = try inspector.inspect(repositoryAt: repositoryURL)
        let repeatedSnapshot = try inspector.inspect(repositoryAt: repositoryURL)
        let merge = snapshot.commits.first { $0.subject == "Merge feature" }
        let mainCommit = snapshot.commits.first { $0.subject == "Main advance" }
        let featureCommit = snapshot.commits.first { $0.subject == "Feature work" }

        try expectEqual(merge?.parents.count, 2, "merge commit reports both parents")
        try expectEqual(merge?.parents[0], mainCommit?.fullHash, "first parent remains on main")
        try expectEqual(merge?.parents[1], featureCommit?.fullHash, "second parent remains on feature")
        try expectEqual(merge?.lane, 0, "first tip starts on the first graph rail")
        try expectEqual(mainCommit?.lane == featureCommit?.lane, false, "parallel parents occupy distinct graph rails")
        try expectEqual(
            Set(snapshot.edges.filter { $0.from == merge?.fullHash }.map { "\($0.from)->\($0.to)" }),
            Set([
                "\(merge!.fullHash)->\(mainCommit!.fullHash)",
                "\(merge!.fullHash)->\(featureCommit!.fullHash)"
            ]),
            "merge has independent edges to both real parents"
        )
        try expectEqual(repeatedSnapshot.commits, snapshot.commits, "commit rails remain stable across inspection")
        try expectEqual(repeatedSnapshot.edges, snapshot.edges, "parent edges remain stable across inspection")
    }

    static func testHistoryIncludesWorkOutsideCurrentBranch() throws {
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
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])
        try runGit(in: repositoryURL, ["checkout", "-b", "side"])
        try "side\n".write(to: repositoryURL.appendingPathComponent("side.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "side.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Side branch only"])
        try runGit(in: repositoryURL, ["checkout", "main"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.currentBranch, "main", "fixture is viewed from the main branch")
        try expectEqual(snapshot.commits.contains { $0.subject == "Side branch only" }, true, "graph includes work that exists only on another branch")
    }
}
