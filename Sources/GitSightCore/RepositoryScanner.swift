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
    ) throws -> RepositoryScanResult {
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

        let inspector = RepositoryInspector()
        var snapshots: [RepositorySnapshot] = []
        for (index, repositoryURL) in repositoryURLs.enumerated() {
            try Task.checkCancellation()
            do {
                snapshots.append(try inspector.inspect(repositoryAt: repositoryURL))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(RepositoryScanFailure(
                    path: repositoryURL,
                    message: error.localizedDescription
                ))
            }
            progress(RepositoryScanProgress(
                phase: .inspection,
                scannedDirectories: scannedDirectories,
                processedRepositories: index + 1,
                totalRepositories: repositoryURLs.count,
                fractionCompleted: 0.5 + Double(index + 1) / Double(repositoryURLs.count) / 2
            ))
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
        return RepositoryScanResult(repositories: snapshots, failures: failures)
    }
}
