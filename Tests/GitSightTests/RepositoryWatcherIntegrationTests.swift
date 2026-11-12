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

    static func testIgnoredFilesAreNotChanges() async throws {
        let rootURL = makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = try makeRepository(at: rootURL.appendingPathComponent("repository"))
        // Ignores everything it does not track, as dotfile repositories do; that pattern also matches .git.
        try "*\n".write(to: repositoryURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try runGit(in: repositoryURL, ["add", "--force", ".gitignore"])
        try runGit(in: repositoryURL, ["commit", "-m", "Ignore build output"])
        let repository = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let changes = ChangeLog()
        let watcher = RepositoryWatcher(repositories: [repository]) { changes.add($0) }
        try await Task.sleep(for: .milliseconds(500))

        // A build writing its output must not reread the repository over and over.
        let buildURL = repositoryURL.appendingPathComponent("build/objects")
        try FileManager.default.createDirectory(at: buildURL, withIntermediateDirectories: true)
        for number in 0..<20 {
            try "object \(number)\n".write(to: buildURL.appendingPathComponent("\(number).o"), atomically: true, encoding: .utf8)
        }
        try await Task.sleep(for: .seconds(1))
        try expectEqual(changes.paths, [], "writes to ignored files are not reported")

        try "edit\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await changes.wait()
        try expectEqual(changes.paths, [repository.path], "an edit next to ignored files is still reported")

        changes.clear()
        try runGit(in: repositoryURL, ["commit", "--all", "-m", "Edit"])
        try await changes.wait()
        try expectEqual(changes.paths, [repository.path], "a commit is reported even when .git matches an ignore rule")
        withExtendedLifetime(watcher) {}
    }

    static func testReportsARepositoryInTheTemporaryFolder() async throws {
        // FSEvents names /var/folders as /private/var/folders.
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("GitSightTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = try makeRepository(at: rootURL.appendingPathComponent("repository"))
        let repository = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let changes = ChangeLog()
        let watcher = RepositoryWatcher(repositories: [repository]) { changes.add($0) }
        try await Task.sleep(for: .milliseconds(500))

        try "edit\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await changes.wait()
        try expectEqual(changes.paths, [repository.path], "an edit in the temporary folder is reported")
        withExtendedLifetime(watcher) {}
    }

    static func testDroppedWatcherStopsReporting() async throws {
        let rootURL = makeRoot()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let repositoryURL = try makeRepository(at: rootURL.appendingPathComponent("repository"))
        let repository = try RepositoryInspector().inspect(repositoryAt: repositoryURL)
        let changes = ChangeLog()
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        // Stands for the app's model: what the report closure holds must go once the watcher does.
        var model: ChangeLog? = ChangeLog()
        weak let heldModel = model
        var watcher: RepositoryWatcher? = RepositoryWatcher(repositories: [repository]) { [model] paths in
            model?.add(paths)
            if changes.paths.isEmpty {
                changes.add(paths)
                entered.signal()
                gate.wait()
            } else {
                changes.add(paths)
            }
        }
        model = nil
        try await Task.sleep(for: .milliseconds(500))

        // The app drops its watcher after every scan, sometimes while a report is still running.
        try "edit\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        guard entered.wait(timeout: .now() + 5) == .success else {
            throw TestFailure(description: "the watcher never reported the edit")
        }
        watcher = nil
        gate.signal()
        withExtendedLifetime(watcher) {}
        try await Task.sleep(for: .milliseconds(300))
        changes.clear()

        try "later edit\n".write(to: repositoryURL.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(1))
        try expectEqual(changes.paths, [], "a dropped watcher reports nothing more")
        try expectEqual(heldModel == nil, true, "a dropped watcher lets go of what its report closure held")
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

    func clear() {
        lock.withLock { reported = [] }
    }

    /// Waits for the first report, then a little longer so stray reports would show up too.
    func wait() async throws {
        for _ in 0..<50 where paths.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(700))
    }
}
