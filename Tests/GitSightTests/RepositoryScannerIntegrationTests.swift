import Darwin
import Foundation
import GitSightCore

enum RepositoryScannerIntegrationTests {
    static func testBrokenRepositoryDoesNotCancelScan() async throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let validURL = rootURL.appendingPathComponent("valid")
        let brokenURL = rootURL.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: validURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brokenURL, withIntermediateDirectories: true)
        try "not a git repository\n".write(to: brokenURL.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: validURL, ["init", "-b", "main"])
        try runGit(in: validURL, ["config", "user.name", "Test User"])
        try runGit(in: validURL, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: validURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: validURL, ["add", "tracked.txt"])
        try runGit(in: validURL, ["commit", "-m", "Initial"])

        var updates: [RepositoryScanProgress] = []
        let result = try await RepositoryScanner().scan(under: rootURL) { updates.append($0) }
        try expectEqual(result.repositories.map(\.path.path), [validURL.path], "valid repository survives another repository's failure")
        try expectEqual(result.failures.map(\.path.path), [brokenURL.path], "broken repository is reported without cancelling the scan")
        try expectEqual(updates.last?.fractionCompleted, 1, "scan reaches a determinate finished state")
        try expectEqual(
            zip(updates, updates.dropFirst()).allSatisfy { $0.fractionCompleted <= $1.fractionCompleted },
            true,
            "the shared scan progress bar does not reset between discovery and inspection"
        )
    }

    static func testCancellationStopsBlockedRepositoryInspection() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("blocked")
        let gitURL = repositoryURL.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
        let headURL = gitURL.appendingPathComponent("HEAD")
        guard mkfifo(headURL.path, 0o600) == 0 else {
            throw TestFailure(description: "could not create blocking HEAD fixture")
        }
        var writer = Int32(-1)
        defer {
            // Unblock a failing old implementation, then prevent later Git commands from blocking again.
            if writer < 0 { writer = open(headURL.path, O_WRONLY | O_NONBLOCK) }
            try? FileManager.default.removeItem(at: headURL)
            if writer >= 0 { close(writer) }
            try? FileManager.default.removeItem(at: rootURL)
        }

        let scan = Task.detached { try await RepositoryScanner().scan(under: rootURL) }
        let finished = DispatchSemaphore(value: 0)
        var unexpectedResult: RepositoryScanResult?
        var unexpectedError: String?
        Task {
            defer { finished.signal() }
            do {
                unexpectedResult = try await scan.value
            } catch is CancellationError {
                return
            } catch {
                unexpectedError = error.localizedDescription
            }
        }
        let readerDeadline = DispatchTime.now().uptimeNanoseconds + 3 * 1_000_000_000
        while writer < 0 && DispatchTime.now().uptimeNanoseconds < readerDeadline {
            writer = open(headURL.path, O_WRONLY | O_NONBLOCK)
            if writer < 0 { usleep(10_000) }
        }
        try expectEqual(writer >= 0, true, "Git actually blocks on HEAD before the test requests cancellation")
        scan.cancel()

        try expectEqual(finished.wait(timeout: .now() + 3), .success, "cancellation stops Git instead of waiting for blocked input")
        try expectEqual(unexpectedResult == nil, true, "cancelled scan does not return a successful result")
        try expectEqual(unexpectedError == nil, true, "cancelled scan reports cancellation rather than a repository failure")
    }

    static func testBareRepositoryWithWorktreesIsOneRepository() async throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("source")
        let scanURL = rootURL.appendingPathComponent("scan")
        let bareURL = scanURL.appendingPathComponent("project.git")
        try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scanURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: sourceURL, ["init", "-b", "main"])
        try runGit(in: sourceURL, ["config", "user.name", "Test User"])
        try runGit(in: sourceURL, ["config", "user.email", "test@example.com"])
        try runGit(in: sourceURL, ["commit", "--allow-empty", "-m", "Initial"])
        try runGit(in: scanURL, ["clone", "--bare", sourceURL.path, bareURL.path])
        let worktreeURL = scanURL.appendingPathComponent("main")
        try runGit(in: bareURL, ["worktree", "add", worktreeURL.path, "main"])
        try "draft\n".write(to: worktreeURL.appendingPathComponent("draft.txt"), atomically: true, encoding: .utf8)
        try runGit(in: bareURL, ["worktree", "add", "--detach", scanURL.appendingPathComponent("review").path, "main"])

        let result = try await RepositoryScanner().scan(under: scanURL)
        try expectEqual(result.failures.map(\.message), [], "a bare repository with worktrees inspects without failures")
        try expectEqual(result.repositories.count, 1, "the bare repository and its worktree are one repository")
        try expectEqual(
            result.repositories.first?.worktrees.map(\.dirtyFileCount),
            [1, 0],
            "each worktree of a bare repository reports its own uncommitted files"
        )
    }
}
