import CoreServices
import Foundation

/// Reports which repositories changed on disk, by watching their folders and worktrees.
/// One FSEvents stream covers them all; it only listens, so watching never touches a repository.
public final class RepositoryWatcher: @unchecked Sendable {
    /// Watched folders with the repository each belongs to, longest path first,
    /// so a repository nested inside another one's folder wins.
    private let folders: [(path: String, repository: URL)]
    private let onChange: @Sendable (Set<URL>) -> Void
    private let queue = DispatchQueue(label: "GitSight.RepositoryWatcher")
    private var stream: FSEventStreamRef?

    public init(repositories: [RepositorySnapshot], onChange: @escaping @Sendable (Set<URL>) -> Void) {
        var folders: [(path: String, repository: URL)] = []
        for repository in repositories {
            // FSEvents reports real paths, e.g. /private/tmp for /tmp.
            for url in [repository.path] + repository.worktrees.map(\.path) {
                folders.append((url.resolvingSymlinksInPath().path, repository.path))
            }
        }
        self.folders = folders.sorted { $0.path.count > $1.path.count }
        self.onChange = onChange
        guard !folders.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self).prefix(count).compactMap { $0 as? String }
            watcher.report(changed)
        }
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            Array(Set(folders.map(\.path))) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func report(_ paths: [String]) {
        var repositories: Set<URL> = []
        for path in paths {
            if let folder = folders.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                repositories.insert(folder.repository)
            }
        }
        if !repositories.isEmpty { onChange(repositories) }
    }
}
