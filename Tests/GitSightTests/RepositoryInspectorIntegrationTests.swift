import Darwin
import Foundation
import GitSightCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ behavior: String) throws {
    guard actual == expected else {
        throw TestFailure(description: "\(behavior): expected \(expected), got \(actual)")
    }
}

func runGit(in repositoryURL: URL, _ arguments: [String], environment: [String: String] = [:]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = repositoryURL
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw TestFailure(description: "git \(arguments.joined(separator: " ")) failed")
    }
}

@main
enum RepositoryInspectorIntegrationTests {
    static func main() {
        var failures = 0
        run(name: "inspector reports untracked files", testInspectorReportsUntrackedFilesInRepository, failures: &failures)
        run(
            name: "discovery finds nested repositories and linked worktrees",
            RepositoryDiscoveryIntegrationTests.testFindsNestedRepositoriesAndLinkedWorktrees,
            failures: &failures
        )
        run(
            name: "inspector reports repository objects without changing filesystem",
            RepositorySnapshotIntegrationTests.testReportsRepositoryObjectsWithoutChangingFilesystem,
            failures: &failures
        )
        run(
            name: "commit topology has stable parent edges and distinct rails",
            CommitTopologyIntegrationTests.testMergeCommitHasStableParentEdgesAndDistinctRails,
            failures: &failures
        )
        run(
            name: "inspector reports files changed by selected commit",
            ChangedFilesIntegrationTests.testReportsFilesChangedBySelectedCommit,
            failures: &failures
        )
        run(
            name: "dirty work is neutral until origin moves",
            RepositoryScoringIntegrationTests.testDirtyWorkIsNeutralUntilOriginMoves,
            failures: &failures
        )
        run(
            name: "abandoned branches, worktrees, and stashes age into risk",
            RepositoryScoringIntegrationTests.testAbandonedWorkAgesIntoRisk,
            failures: &failures
        )
        if failures > 0 { exit(1) }
    }

    private static func run(name: String, _ test: () throws -> Void, failures: inout Int) {
        do {
            try test()
            print("PASS: \(name)")
        } catch {
            failures += 1
            FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
        }
    }

    private static func testInspectorReportsUntrackedFilesInRepository() throws {
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
        try runGit(in: repositoryURL, ["init"])
        try "uncommitted work\n".write(
            to: repositoryURL.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.dirtyFileCount, 1, "untracked file is reported as uncommitted work")
    }
}
