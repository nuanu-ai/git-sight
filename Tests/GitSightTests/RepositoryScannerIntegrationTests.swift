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
}
