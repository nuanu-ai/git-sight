import Foundation

public struct RepositorySnapshot {
    public let dirtyFileCount: Int

    public init(dirtyFileCount: Int) {
        self.dirtyFileCount = dirtyFileCount
    }
}

public struct RepositoryInspector {
    public init() {}

    public func inspect(repositoryAt repositoryURL: URL) throws -> RepositorySnapshot {
        RepositorySnapshot(dirtyFileCount: 0)
    }
}
