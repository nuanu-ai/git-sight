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

    /// Work is listed where it sits: under the worktree whose branch holds it, under a branch not checked out,
    /// or under the name of a deleted branch whose stash is all that is left of it.
    static func testWorkIsListedWhereItSits() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repositoryURL = fixture.repository
        let featureURL = fixture.root.appendingPathComponent("feature-tree")
        try runGit(in: repositoryURL, ["worktree", "add", "-b", "feature", featureURL.path, "main"])
        try write("feature.txt", in: featureURL)
        try runGit(in: featureURL, ["add", "feature.txt"])
        try runGit(in: featureURL, ["commit", "-m", "Add feature.txt"])
        try write("tracked.txt", "half done\n", in: featureURL)
        try runGit(in: featureURL, ["stash", "push", "-m", "half done"])
        try write("notes.txt", in: featureURL)

        try runGit(in: repositoryURL, ["checkout", "-b", "parked"])
        for file in ["parked-a.txt", "parked-b.txt"] {
            try write(file, in: repositoryURL)
            try runGit(in: repositoryURL, ["add", file])
            try runGit(in: repositoryURL, ["commit", "-m", "Add \(file)"])
        }
        try runGit(in: repositoryURL, ["checkout", "-b", "spike/old", "main"])
        try write("tracked.txt", "spike\n", in: repositoryURL)
        try runGit(in: repositoryURL, ["stash", "push"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        try runGit(in: repositoryURL, ["branch", "-D", "spike/old"])

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(
            snapshot.places.map { place in
                "\(place.worktree?.name ?? "-") \(place.branchName ?? "-"): " + place.pieces.map { "\($0.kind) \($0.amount)" }.joined(separator: ", ")
            },
            [
                "repository main: ",
                "feature-tree feature: uncommitted 1, unpushed 1, stash 1",
                "- parked: unpushed 2",
                "- spike/old: stash 1"
            ],
            "each piece of work is listed once, under the place it belongs to"
        )
        try expectEqual(snapshot.places[1].pieces.last?.stash?.text, "half done", "the stash made in the worktree is the one listed there")
        try expectEqual(snapshot.places.last?.branch, nil, "a deleted branch has no branch left")
    }

    /// The weight of a repository says how much is at risk: more files, more age and work only here weigh more.
    /// The lead is the worst piece, which says how bad the repository is.
    static func testWeightAndLeadSayHowBadItIs() throws {
        let now = Date()
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        func repository(dirtyFiles: Int = 0, branches: [BranchSnapshot], stashes: [StashSnapshot] = []) -> RepositorySnapshot {
            let worktree = WorktreeSnapshot(
                path: URL(fileURLWithPath: "/work/app"), name: "app", branch: "main", isMain: true,
                dirtyFileCount: dirtyFiles, dirtyModifiedAt: dirtyFiles > 0 ? now : nil, lastActivity: daysAgo(90)
            )
            let main = BranchSnapshot(name: "main", upstream: "origin/main", ahead: 0, behind: 0, lastCommitDate: daysAgo(90), hasWorktree: true, isBase: true)
            return RepositorySnapshot(dirtyFileCount: dirtyFiles, worktrees: [worktree], branches: [main] + branches, stashes: stashes, hasRemote: true, baseBranch: "main")
        }
        func branch(_ name: String, daysAgo days: Double, unmerged: Int) -> BranchSnapshot {
            BranchSnapshot(name: name, upstream: "origin/\(name)", ahead: 0, behind: 0, lastCommitDate: daysAgo(days), hasWorktree: false, unmergedCommits: unmerged)
        }

        let weighed = repository(dirtyFiles: 2, branches: [branch("open", daysAgo: 3, unmerged: 3)])
        try expectEqual(weighed.places.map { rounded($0.weight(now: now)) }, [2.0, 1.8], "two files changed now weigh 2; three commits on the server, three days old, weigh 1.8")
        try expectEqual(rounded(weighed.weight(now: now)), 3.8, "a repository weighs what its places weigh")

        let stash = StashSnapshot(name: "stash@{0}", hash: "1111111111111111111111111111111111111111", message: "On main: try", date: daysAgo(31))
        let lead = repository(branches: [branch("open", daysAgo: 50, unmerged: 1)], stashes: [stash]).lead(now: now)
        try expectEqual(lead?.kind, .stash, "a forgotten stash leads over older abandoned work")
        try expectEqual(lead?.verdict(now: now), .forgotten, "a stash left for a month is forgotten")

        let leftover = repository(branches: [branch("done", daysAgo: 20, unmerged: 0)]).lead(now: now)
        try expectEqual(leftover?.kind, .leftover, "a merged branch left for weeks is the only work")
        try expectEqual(leftover?.verdict(now: now), .clutter, "and it is clutter, nothing lost")
        try expectEqual(repository(branches: [branch("done", daysAgo: 5, unmerged: 0)]).lead(now: now), nil, "a branch merged days ago is normal cleanup lag, no work")
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
