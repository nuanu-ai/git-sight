import Foundation
import GitSightCore

enum GitSafetyIntegrationTests {
    static func testInspectionNeverRunsRepositoryHooks() throws {
        let rootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
        let repositoryURL = rootURL.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try runGit(in: repositoryURL, ["init", "-b", "main"])
        try runGit(in: repositoryURL, ["config", "user.name", "Test User"])
        try runGit(in: repositoryURL, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])

        let markerURL = rootURL.appendingPathComponent("hook-fired")
        let hookURL = rootURL.appendingPathComponent("fsmonitor.sh")
        try "#!/bin/sh\nprintf fired > '\(markerURL.path)'\n".write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)
        try runGit(in: repositoryURL, ["config", "core.fsmonitor", hookURL.path])

        _ = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        try expectEqual(FileManager.default.fileExists(atPath: markerURL.path), false, "read-only inspection must not execute repository-controlled fsmonitor hooks")
    }

    static func testGoneUpstreamIsNotReportedAsZeroDivergence() throws {
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
        try runGit(in: repositoryURL, ["config", "branch.main.remote", "origin"])
        try runGit(in: repositoryURL, ["config", "branch.main.merge", "refs/heads/main"])
        try "initial\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "tracked.txt"])
        try runGit(in: repositoryURL, ["commit", "-m", "Initial"])

        var inspectionError: NSError?
        do {
            _ = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        } catch {
            inspectionError = error as NSError
        }
        try expectEqual(
            inspectionError?.localizedDescription.contains("not stored as a remote-tracking branch"),
            true,
            "a configured but missing upstream is an explicit error, not trustworthy zero divergence"
        )
        try expectEqual(
            inspectionError?.localizedDescription.contains(repositoryURL.path),
            true,
            "Git failure identifies the repository that needs attention"
        )
    }
}
