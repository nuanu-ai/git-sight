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
        let rows = Dictionary(uniqueKeysWithValues: history.enumerated().map { ($0.element.fullHash, $0.offset) })
        var crossings: [String] = []
        for (row, commit) in history.enumerated() {
            try expectEqual(commit.parentLanes.count, commit.parents.count, "\(commit.subject) has a lane for every parent")
            for (parent, lane) in zip(commit.parents, commit.parentLanes) {
                guard let parentRow = rows[parent] else { continue }
                for between in history[(row + 1)..<parentRow] where between.lane == lane {
                    crossings.append("\(commit.subject)→\(history[parentRow].subject) crosses \(between.subject)")
                }
            }
        }
        try expectEqual(crossings, [], "a line to a parent passes no other commit's dot")
    }
}
