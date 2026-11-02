import Foundation

public enum RepositoryScanPhase: String, Equatable {
    case discovery
    case inspection
}

public struct RepositoryScanProgress: Equatable {
    public let phase: RepositoryScanPhase
    public let scannedDirectories: Int
    public let processedRepositories: Int
    public let totalRepositories: Int
    public let fractionCompleted: Double

    public init(
        phase: RepositoryScanPhase,
        scannedDirectories: Int,
        processedRepositories: Int,
        totalRepositories: Int,
        fractionCompleted: Double
    ) {
        self.phase = phase
        self.scannedDirectories = scannedDirectories
        self.processedRepositories = processedRepositories
        self.totalRepositories = totalRepositories
        self.fractionCompleted = fractionCompleted
    }
}

public struct RepositoryScanFailure: Equatable {
    public let path: URL
    public let message: String

    public init(path: URL, message: String) {
        self.path = path
        self.message = message
    }
}

public struct RepositoryScanResult: Equatable {
    public let repositories: [RepositorySnapshot]
    public let failures: [RepositoryScanFailure]

    public init(repositories: [RepositorySnapshot], failures: [RepositoryScanFailure]) {
        self.repositories = repositories
        self.failures = failures
    }
}

public struct RepositoryScanner {
    public init() {}

    public func scan(
        under rootURL: URL,
        progress: (RepositoryScanProgress) -> Void = { _ in }
    ) async throws -> RepositoryScanResult {
        var scannedDirectories = 0
        var failures: [RepositoryScanFailure] = []
        let repositoryURLs = try RepositoryDiscovery().repositories(under: rootURL, progress: { discovery in
            scannedDirectories = discovery.scannedDirectories
            progress(RepositoryScanProgress(
                phase: .discovery,
                scannedDirectories: discovery.scannedDirectories,
                processedRepositories: 0,
                totalRepositories: discovery.discoveredRepositories,
                fractionCompleted: discovery.fractionCompleted / 2
            ))
        }, issue: { path, error in
            failures.append(RepositoryScanFailure(
                path: path,
                message: "Чтение каталога: \(error.domain) \(error.code): \(error.localizedDescription)"
            ))
        })

        // Each inspection runs git processes one after another, so this also bounds concurrent git processes.
        let width = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var snapshots: [RepositorySnapshot] = []
        var processed = 0
        try await withThrowingTaskGroup(of: (URL, Result<RepositorySnapshot, Error>).self) { group in
            var pending = repositoryURLs.makeIterator()
            for _ in 0..<width {
                guard let url = pending.next() else { break }
                group.addTask { (url, Result { try RepositoryInspector().inspect(repositoryAt: url) }) }
            }
            while let (url, result) = try await group.next() {
                try Task.checkCancellation()
                switch result {
                case .success(let snapshot):
                    snapshots.append(snapshot)
                case .failure(let error):
                    if error is CancellationError { throw error }
                    failures.append(RepositoryScanFailure(path: url, message: error.localizedDescription))
                }
                processed += 1
                progress(RepositoryScanProgress(
                    phase: .inspection,
                    scannedDirectories: scannedDirectories,
                    processedRepositories: processed,
                    totalRepositories: repositoryURLs.count,
                    fractionCompleted: 0.5 + Double(processed) / Double(repositoryURLs.count) / 2
                ))
                if let url = pending.next() {
                    group.addTask { (url, Result { try RepositoryInspector().inspect(repositoryAt: url) }) }
                }
            }
        }
        if repositoryURLs.isEmpty {
            progress(RepositoryScanProgress(
                phase: .inspection,
                scannedDirectories: scannedDirectories,
                processedRepositories: 0,
                totalRepositories: 0,
                fractionCompleted: 1
            ))
        }
        return RepositoryScanResult(
            repositories: snapshots.sorted { $0.path.path < $1.path.path },
            failures: failures.sorted { $0.path.path < $1.path.path }
        )
    }
}
