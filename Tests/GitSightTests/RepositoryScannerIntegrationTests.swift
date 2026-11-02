import Darwin
import Foundation
import GitSightCore

enum RepositoryScannerIntegrationTests {
    static func testBrokenRepositoryDoesNotCancelScan() throws {
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
        let result = try RepositoryScanner().scan(under: rootURL) { updates.append($0) }
        try expectEqual(result.repositories.map(\.path.path), [validURL.path], "valid repository survives another repository's failure")
        try expectEqual(result.failures.map(\.path.path), [brokenURL.path], "broken repository is reported without cancelling the scan")
        try expectEqual(updates.last?.fractionCompleted, 1, "scan reaches a determinate finished state")
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
        defer {
            // Unblock a failing old implementation, then prevent later Git commands from blocking again.
            let writer = open(headURL.path, O_WRONLY | O_NONBLOCK)
            try? FileManager.default.removeItem(at: headURL)
            if writer >= 0 { close(writer) }
            try? FileManager.default.removeItem(at: rootURL)
        }

        let scan = Task.detached { try RepositoryScanner().scan(under: rootURL) }
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
        usleep(200_000)
        scan.cancel()

        try expectEqual(finished.wait(timeout: .now() + 3), .success, "cancellation stops Git instead of waiting for blocked input")
        try expectEqual(unexpectedResult == nil, true, "cancelled scan does not return a successful result")
        try expectEqual(unexpectedError == nil, true, "cancelled scan reports cancellation rather than a repository failure")
    }
}
