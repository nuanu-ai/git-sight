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
    private let git = GitRunner()
    private var stream: FSEventStreamRef?

    public init(repositories: [RepositorySnapshot], onChange: @escaping @Sendable (Set<URL>) -> Void) {
        var folders: [(path: String, repository: URL)] = []
        for repository in repositories {
            // FSEvents reports real paths. This also strips /private, which `folder(of:)` handles.
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
        var written: [Int: Set<String>] = [:]
        for path in paths {
            if let (index, relative) = folder(of: path) {
                written[index, default: []].insert(relative)
            }
        }
        var repositories: Set<URL> = []
        for (index, relative) in written where !repositories.contains(folders[index].repository) {
            if !onlyIgnored(relative, in: folders[index].path) {
                repositories.insert(folders[index].repository)
            }
        }
        if !repositories.isEmpty { onChange(repositories) }
    }

    /// The watched folder a path is in and the path relative to it.
    private func folder(of path: String) -> (Int, String)? {
        // FSEvents names /var and /tmp as /private/var and /private/tmp.
        let candidates = path.hasPrefix("/private/") ? [path, String(path.dropFirst("/private".count))] : [path]
        for candidate in candidates {
            if let index = folders.firstIndex(where: { candidate == $0.path || candidate.hasPrefix($0.path + "/") }) {
                return (index, String(candidate.dropFirst(folders[index].path.count).drop { $0 == "/" }))
            }
        }
        return nil
    }

    /// True when every path is a file git ignores, such as build output. Anything inside .git
    /// counts as a change, and so does any path git cannot answer for.
    private func onlyIgnored(_ paths: Set<String>, in folder: String) -> Bool {
        if paths.contains(where: { $0.isEmpty || $0 == ".git" || $0.hasPrefix(".git/") }) { return false }
        let paths = Array(paths)
        // Chunks keep the argument list well under the system limit during a large build.
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            guard let result = try? git.run(in: URL(fileURLWithPath: folder), ["check-ignore", "--"] + chunk) else { return false }
            // check-ignore prints one line per ignored path, and nothing when it fails.
            let ignored = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n").count
            if ignored < chunk.count { return false }
        }
        return true
    }
}
