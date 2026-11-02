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
    static func main() async {
        var failures = 0
        await run(
            name: "inspection never runs repository hooks",
            GitSafetyIntegrationTests.testInspectionNeverRunsRepositoryHooks,
            failures: &failures
        )
        await run(
            name: "gone upstream does not hide repository",
            GitSafetyIntegrationTests.testGoneUpstreamDoesNotHideRepository,
            failures: &failures
        )
        await run(
            name: "each branch is compared with its own upstream",
            RepositorySnapshotIntegrationTests.testEachBranchIsComparedWithItsOwnUpstream,
            failures: &failures
        )
        await run(name: "inspector reports untracked files", testInspectorReportsUntrackedFilesInRepository, failures: &failures)
        await run(
            name: "linked worktrees report through their main repository",
            RepositoryDiscoveryIntegrationTests.testLinkedWorktreesReportThroughTheirMainRepository,
            failures: &failures
        )
        await run(
            name: "broken repository does not cancel scan",
            RepositoryScannerIntegrationTests.testBrokenRepositoryDoesNotCancelScan,
            failures: &failures
        )
        await run(
            name: "cancellation stops blocked repository inspection",
            RepositoryScannerIntegrationTests.testCancellationStopsBlockedRepositoryInspection,
            failures: &failures
        )
        await run(
            name: "inspector reports repository objects without changing filesystem",
            RepositorySnapshotIntegrationTests.testReportsRepositoryObjectsWithoutChangingFilesystem,
            failures: &failures
        )
        await run(
            name: "missing linked worktree does not hide repository",
            RepositorySnapshotIntegrationTests.testMissingLinkedWorktreeDoesNotHideRepository,
            failures: &failures
        )
        await run(
            name: "inherited Git environment cannot redirect inspection",
            RepositorySnapshotIntegrationTests.testGitEnvironmentCannotRedirectInspection,
            failures: &failures
        )
        await run(
            name: "commit topology has stable parent edges and distinct rails",
            CommitTopologyIntegrationTests.testMergeCommitHasStableParentEdgesAndDistinctRails,
            failures: &failures
        )
        await run(
            name: "independent lane survives interleaved merge parents",
            CommitTopologyIntegrationTests.testIndependentLaneSurvivesInterleavedMergeParents,
            failures: &failures
        )
        await run(
            name: "inspector reports files changed by selected commit",
            ChangedFilesIntegrationTests.testReportsFilesChangedBySelectedCommit,
            failures: &failures
        )
        for (name, test) in [
            ("pushed and merged branches are not risk", RepositoryScoringIntegrationTests.testPushedAndMergedBranchesAreNotRisk),
            ("unpushed work ages from in progress to critical", RepositoryScoringIntegrationTests.testUnpushedWorkAgesFromInProgressToCritical),
            ("old uncommitted work is risk while origin is still", RepositoryScoringIntegrationTests.testOldUncommittedWorkIsRiskWhileOriginIsStill),
            ("worktrees matter only for work they hold", RepositoryScoringIntegrationTests.testWorktreesMatterOnlyForWorkTheyHold),
            ("repository without remote is flagged once", RepositoryScoringIntegrationTests.testRepositoryWithoutRemoteIsFlaggedOnce),
            ("branch deleted on the server is a notice", RepositoryScoringIntegrationTests.testBranchDeletedOnServerIsANotice),
            ("bare repository with worktrees is one repository", RepositoryScannerIntegrationTests.testBareRepositoryWithWorktreesIsOneRepository),
            ("scan inspects more repositories than cores", RepositoryScannerIntegrationTests.testScanInspectsMoreRepositoriesThanCores),
            ("history ends where work left the server", CommitTopologyIntegrationTests.testHistoryEndsWhereWorkLeftTheServer),
            ("uncommitted and stashed files are listed", ChangedFilesIntegrationTests.testReportsUncommittedAndStashedFiles)
        ] {
            await run(name: name, test, failures: &failures)
        }
        if failures > 0 { exit(1) }
    }

    private static func run(name: String, _ test: () async throws -> Void, failures: inout Int) async {
        do {
            try await test()
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

        let nestedURL = repositoryURL.appendingPathComponent("nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
        try "one\n".write(to: nestedURL.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two\n".write(to: nestedURL.appendingPathComponent("two.txt"), atomically: true, encoding: .utf8)

        let snapshot = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(snapshot.dirtyFileCount, 3, "untracked files are counted individually inside new directories")
    }
}
