import Foundation

/// Reports which repositories changed on disk, by watching their folders and worktrees.
public final class RepositoryWatcher: @unchecked Sendable {
    public init(repositories: [RepositorySnapshot], onChange: @escaping @Sendable (Set<URL>) -> Void) {}
}
