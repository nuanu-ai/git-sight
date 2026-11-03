import Foundation
import GitSightCore

enum RepositoryWatcherIntegrationTests {
    static func testReportsOnlyTheRepositoryThatChanged() async throws {
        let rootURL = makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let quietURL = try makeRepository(at: rootURL.appendingPathComponent("quiet"))
        let busyURL = try makeRepository(at: rootURL.appendingPathComponent("busy"))
        let inspector = RepositoryInspector()
        let repositories = try [quietURL, busyURL].map { try inspector.inspect(repositoryAt: $0) }
        let changes = ChangeLog()
        let watcher = RepositoryWatcher(repositories: repositories) { changes.add($0) }
        try await Task.sleep(for: .milliseconds(500))

        // Reading a repository must not look like a change, or the app would rescan forever.
        _ = try inspector.inspect(repositoryAt: quietURL)
        _ = try inspector.uncommittedFiles(in: quietURL)
        try await Task.sleep(for: .seconds(1))
        try expectEqual(changes.paths, [], "reading a repository is not reported as a change")

        try "edit\n".write(to: busyURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await changes.wait()
        try expectEqual(changes.paths, [repositories[1].path], "an edit is reported for its repository only")
        withExtendedLifetime(watcher) {}
    }

    static func testReportsAWorktreeOutsideTheFolderAsItsRepository() async throws {
        let rootURL = makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = try makeRepository(at: rootURL.appendingPathComponent("folder/repository"))
        let worktreeURL = rootURL.appendingPathComponent("elsewhere/agent-worktree")
        try runGit(in: repositoryURL, ["worktree", "add", "--detach", worktreeURL.path])
        let repository = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let changes = ChangeLog()
        let watcher = RepositoryWatcher(repositories: [repository]) { changes.add($0) }
        try await Task.sleep(for: .milliseconds(500))

        try "agent edit\n".write(to: worktreeURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await changes.wait()
        try expectEqual(changes.paths, [repository.path], "an edit in a worktree outside the folder is reported for its repository")
        withExtendedLifetime(watcher) {}
    }

    private static func makeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/GitSightTests/\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeRepository(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(in: url, ["init", "-b", "main"])
        try runGit(in: url, ["config", "user.name", "Test User"])
        try runGit(in: url, ["config", "user.email", "test@example.com"])
        try "initial\n".write(to: url.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try runGit(in: url, ["add", "tracked.txt"])
        try runGit(in: url, ["commit", "-m", "Initial"])
        return url
    }
}

/// Collects what a watcher reports, from whatever thread it reports on.
private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reported: Set<URL> = []

    var paths: Set<URL> {
        lock.withLock { reported }
    }

    func add(_ paths: Set<URL>) {
        lock.withLock { reported.formUnion(paths) }
    }

    /// Waits for the first report, then a little longer so stray reports would show up too.
    func wait() async throws {
        for _ in 0..<50 where paths.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(700))
    }
}
