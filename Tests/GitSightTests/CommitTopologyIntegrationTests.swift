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
        let history = try inspector.history(in: repositoryURL, revisions: ["refs/heads/main"])
        let repeatedHistory = try inspector.history(in: repositoryURL, revisions: ["refs/heads/main"])
        let merge = history.first { $0.subject == "Merge feature" }
        let mainCommit = history.first { $0.subject == "Main advance" }
        let featureCommit = history.first { $0.subject == "Feature work" }

        try expectEqual(merge?.parents.count, 2, "merge commit reports both parents")
        try expectEqual(merge?.parents[0], mainCommit?.fullHash, "first parent remains on main")
        try expectEqual(merge?.parents[1], featureCommit?.fullHash, "second parent remains on feature")
        try expectEqual(merge?.lane, 0, "first tip starts on the first graph rail")
        try expectEqual(mainCommit?.lane == featureCommit?.lane, false, "parallel parents occupy distinct graph rails")
        try expectEqual(repeatedHistory, history, "commit rails remain stable across inspection")
        let mergeFiles = try inspector.changedFiles(in: repositoryURL, commit: merge!)
        try expectEqual(mergeFiles.map(\.path), ["feature.txt"], "expanding a merge shows changes against its first parent")
    }

    static func testIndependentLaneSurvivesInterleavedMergeParents() throws {
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

        func commit(_ file: String, _ subject: String, _ date: String) throws {
            try "\(subject)\n".write(to: repositoryURL.appendingPathComponent(file), atomically: true, encoding: .utf8)
            try runGit(in: repositoryURL, ["add", file])
            try runGit(in: repositoryURL, ["commit", "-m", subject], environment: [
                "GIT_AUTHOR_DATE": date,
                "GIT_COMMITTER_DATE": date
            ])
        }

        try commit("root", "Initial", "2026-01-01T00:00:00Z")
        try runGit(in: repositoryURL, ["branch", "side"])
        try commit("main", "Main advance", "2026-01-02T00:00:00Z")
        try runGit(in: repositoryURL, ["checkout", "side"])
        try commit("side", "Side work", "2026-01-03T00:00:00Z")
        try runGit(in: repositoryURL, ["checkout", "main"])
        try runGit(in: repositoryURL, ["merge", "--no-ff", "side", "-m", "Merge side"], environment: [
            "GIT_AUTHOR_DATE": "2026-01-04T00:00:00Z",
            "GIT_COMMITTER_DATE": "2026-01-04T00:00:00Z"
        ])

        let history = try RepositoryInspector().history(in: repositoryURL, revisions: ["refs/heads/main"])
        try expectEqual(
            history.map(\.subject),
            ["Merge side", "Side work", "Main advance", "Initial"],
            "fixture has interleaved merge parents"
        )
        let side = history.first { $0.subject == "Side work" }
        let main = history.first { $0.subject == "Main advance" }
        let base = history.first { $0.subject == "Initial" }
        try expectEqual(side?.lane, 1, "second merge parent starts on lane 1")
        try expectEqual(main?.lane, 0, "first merge parent remains on lane 0")
        try expectEqual(base?.lane, main?.lane, "the shared root continues the first-parent line, and the side line joins it")
    }

    static func testHistoryEndsWhereWorkLeftTheServer() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        for subject in ["Older", "Pushed"] {
            try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", subject])
        }
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["checkout", "-b", "feature"])
        for subject in ["Local one", "Local two"] {
            try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", subject])
        }

        let history = try RepositoryInspector().history(in: repositoryURL, revisions: ["refs/heads/feature", "--not", "--remotes"])
        try expectEqual(history.map(\.subject), ["Local two", "Local one", "Pushed"], "history shows unsaved commits and stops at the commit the server has")
        try expectEqual(history.map(\.isBoundary), [false, false, true], "the commit the server has is marked as the fork point")
    }

    static func testCutOffHistoryDoesNotClaimTheServerHasIt() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Pushed"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["checkout", "-b", "feature"])
        for index in 1...305 {
            try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Local \(index)"])
        }

        let history = try RepositoryInspector().history(in: repositoryURL, revisions: ["refs/heads/feature", "--not", "--remotes"])
        try expectEqual(history.first?.subject, "Local 305", "long history starts at the branch tip")
        try expectEqual(history.filter(\.isBoundary).map(\.subject), [], "a commit cut off by the history limit is not shown as the one the server has")
    }

    static func testHistoryReadsRevisionsShadowedByFileNames() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Pushed"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["checkout", "--detach"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Detached work"])
        try "not a revision\n".write(to: repositoryURL.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

        let history = try RepositoryInspector().history(
            in: repositoryURL,
            revisions: ["HEAD", "--not", "--remotes", "--branches", "--tags"]
        )
        try expectEqual(history.map(\.subject), ["Detached work", "Pushed"], "a file named HEAD in the worktree does not hide the history")
    }

    static func testParentLinesCrossNoOtherCommit() throws {
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
        func commit(_ subject: String) throws {
            try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", subject])
        }

        // The everyday shape: main is merged into a feature, then the feature into main.
        try commit("c0")
        try commit("c1")
        try runGit(in: repositoryURL, ["branch", "feature"])
        try commit("c2")
        try runGit(in: repositoryURL, ["checkout", "feature"])
        try commit("c4")
        try runGit(in: repositoryURL, ["merge", "--no-ff", "main", "-m", "c5"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        try commit("c3")
        try runGit(in: repositoryURL, ["merge", "--no-ff", "feature", "-m", "c6"])

        let history = try RepositoryInspector().history(in: repositoryURL, revisions: ["refs/heads/main"])
        try expectEqual(crossings(in: history), [], "a line to a parent passes no other commit's dot")
    }

    static func testRandomHistoriesDrawWithoutCrossings() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        let emptyTree = try gitOutput(in: repositoryURL, ["hash-object", "-t", "tree", "/dev/null"])

        // A fixed seed keeps the histories the same on every run.
        var seed: UInt64 = 0x5EED
        func random(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        var found: [String] = []
        for shape in 0..<40 {
            var commits: [String] = []
            for index in 0..<16 {
                var parents: [String] = []
                if !commits.isEmpty {
                    // Mostly continue a recent line, sometimes fork from older work, sometimes merge.
                    parents.append(commits[commits.count - 1 - random(min(3, commits.count))])
                    if commits.count > 2, random(10) < 4 {
                        let other = commits[random(commits.count)]
                        if other != parents[0] { parents.append(other) }
                    }
                }
                commits.append(try gitOutput(
                    in: repositoryURL,
                    ["commit-tree", emptyTree, "-m", "s\(shape)c\(index)"] + parents.flatMap { ["-p", $0] },
                    environment: ["GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.com", "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.com"]
                ))
            }
            let history = try RepositoryInspector().history(in: repositoryURL, revisions: commits)
            found += crossings(in: history)
        }
        try expectEqual(found, [], "lines in forty generated histories pass no other commit's dot")
    }

    private static func crossings(in history: [CommitSnapshot]) -> [String] {
        let rows = Dictionary(uniqueKeysWithValues: history.enumerated().map { ($0.element.fullHash, $0.offset) })
        var crossings: [String] = []
        for (row, commit) in history.enumerated() {
            if commit.parentLanes.count != commit.parents.count {
                crossings.append("\(commit.subject) has no lane for some parents")
                continue
            }
            for (parent, lane) in zip(commit.parents, commit.parentLanes) {
                guard let parentRow = rows[parent] else { continue }
                for between in history[(row + 1)..<parentRow] where between.lane == lane {
                    crossings.append("\(commit.subject)→\(history[parentRow].subject) crosses \(between.subject)")
                }
            }
        }
        return crossings
    }

    private static func gitOutput(in repositoryURL: URL, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repositoryURL.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain: "gitOutput", code: Int(process.terminationStatus)) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func testCommitsNameTheirBranchesAndTags() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Released"])
        try runGit(in: repositoryURL, ["tag", "v1.0"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        try runGit(in: repositoryURL, ["remote", "set-head", "origin", "main"])
        try runGit(in: repositoryURL, ["checkout", "-b", "feature"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Feature"])
        try "draft\n".write(to: repositoryURL.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["stash", "push", "--include-untracked", "-m", "parked"])
        // A branch named like a remote's branch is still a local branch.
        try runGit(in: repositoryURL, ["branch", "origin/look-alike", "main"])
        // git separates decorations with ", ", and a branch name may hold a comma.
        try runGit(in: repositoryURL, ["branch", "fix,typo", "main"])

        let history = try RepositoryInspector().history(in: repositoryURL, revisions: ["--all"])
        try expectEqual(Set(history.first { $0.subject == "Feature" }?.refs ?? []), [CommitRef(kind: .branch, name: "feature", isHead: true)], "the checked-out branch is marked as HEAD")
        try expectEqual(
            Set(history.first { $0.subject == "Released" }?.refs ?? []),
            [
                CommitRef(kind: .branch, name: "main"),
                CommitRef(kind: .branch, name: "origin/look-alike"),
                CommitRef(kind: .branch, name: "fix,typo"),
                CommitRef(kind: .remoteBranch, name: "origin/main"),
                CommitRef(kind: .tag, name: "v1.0")
            ],
            "local branches, remote branches and tags are told apart by their full names"
        )
        try expectEqual(history.first { $0.subject == "On feature: parked" }?.refs, [], "a stash is not a branch")

        try runGit(in: repositoryURL, ["checkout", "--detach", "main"])
        let detached = try RepositoryInspector().history(in: repositoryURL, revisions: ["--all"])
        try expectEqual(detached.first { $0.subject == "Released" }?.refs.filter { $0.kind == .head }, [CommitRef(kind: .head, name: "HEAD", isHead: true)], "a detached HEAD is named on its commit")
    }

    static func testRepositoryHistoryShowsEveryBranchAndWhatIsNotOnTheServer() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let originURL = rootURL.appendingPathComponent("origin.git")
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: rootURL, ["init", "--bare", originURL.path])
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Pushed"])
        try runGit(in: repositoryURL, ["remote", "add", "origin", originURL.path])
        try runGit(in: repositoryURL, ["push", "-u", "origin", "main"])
        // A colleague's branch that exists only on the server.
        try runGit(in: repositoryURL, ["checkout", "-b", "colleague"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Colleague"])
        try runGit(in: repositoryURL, ["push", "origin", "colleague"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        try runGit(in: repositoryURL, ["branch", "-D", "colleague"])
        try runGit(in: repositoryURL, ["checkout", "-b", "feature"])
        try runGit(in: repositoryURL, ["commit", "--allow-empty", "-m", "Local feature"])
        try runGit(in: repositoryURL, ["checkout", "main"])
        let worktreeURL = rootURL.appendingPathComponent("agent-worktree")
        try runGit(in: repositoryURL, ["worktree", "add", "--detach", worktreeURL.path])
        try runGit(in: worktreeURL, ["commit", "--allow-empty", "-m", "Agent work"])
        try "draft\n".write(to: repositoryURL.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["stash", "push", "--include-untracked", "-m", "parked"])

        let history = try RepositoryInspector().repositoryHistory(in: repositoryURL)
        try expectEqual(Set(history.map(\.subject)), ["Pushed", "Colleague", "Local feature", "Agent work"], "every branch, remote branch and worktree is in the graph, and stashes are not")
        try expectEqual(
            Set(history.filter(\.isUnpushed).map(\.subject)),
            ["Local feature", "Agent work"],
            "commits on no remote branch are marked, including a detached worktree's"
        )
        try expectEqual(
            history.first { $0.subject == "Agent work" }?.refs,
            [CommitRef(kind: .worktree, name: "agent-worktree")],
            "a detached worktree is named on its commit"
        )
        try expectEqual(history.filter(\.isBoundary), [], "a whole repository has no range to stop at")

        try runGit(in: repositoryURL, ["checkout", "--detach", "main"])
        let detachedMain = try RepositoryInspector().repositoryHistory(in: repositoryURL).first { $0.subject == "Pushed" }
        try expectEqual(detachedMain?.refs.filter { $0.kind == .worktree }, [], "a detached main worktree is HEAD, not a linked worktree")

        let localURL = rootURL.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)
        try runGit(in: localURL, ["init", "-b", "main"])
        try runGit(in: localURL, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Only here"])
        try expectEqual(try RepositoryInspector().repositoryHistory(in: localURL).filter(\.isUnpushed), [], "without a remote nothing is marked, since nothing could be pushed")

        // An orphan branch with no commits yet leaves HEAD pointing nowhere.
        try runGit(in: localURL, ["checkout", "--orphan", "pages"])
        try expectEqual(try RepositoryInspector().repositoryHistory(in: localURL).map(\.subject), ["Only here"], "an unborn HEAD does not hide the other branches")

        // A worktree folder deleted by hand leaves git a stale entry; the findings skip it, so the graph does too.
        try FileManager.default.removeItem(at: worktreeURL)
        let pruned = try RepositoryInspector().repositoryHistory(in: repositoryURL)
        try expectEqual(pruned.flatMap(\.refs).filter { $0.kind == .worktree }, [], "a deleted worktree gets no label")
    }
}
