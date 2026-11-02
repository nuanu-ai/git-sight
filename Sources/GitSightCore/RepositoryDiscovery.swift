import Foundation

public struct RepositoryDiscoveryProgress: Equatable {
    public let scannedDirectories: Int
    public let discoveredRepositories: Int
    public let fractionCompleted: Double

    public init(scannedDirectories: Int, discoveredRepositories: Int, fractionCompleted: Double) {
        self.scannedDirectories = scannedDirectories
        self.discoveredRepositories = discoveredRepositories
        self.fractionCompleted = fractionCompleted
    }
}

public struct RepositoryDiscovery {
    public init() {}

    public func repositories(
        under rootURL: URL,
        progress: (RepositoryDiscoveryProgress) -> Void = { _ in }
    ) throws -> [URL] {
        var pending: [URL] = [rootURL]
        var scanned = 0
        var repositories: [URL] = []
        let excludedDirectories: Set<String> = ["Library", "node_modules"]

        while !pending.isEmpty {
            try Task.checkCancellation()
            let directoryURL = pending.removeFirst()
            scanned += 1
            let gitURL = directoryURL.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitURL.path) {
                repositories.append(directoryURL)
            } else {
                let children: [URL]?
                if scanned == 1 {
                    children = try FileManager.default.contentsOfDirectory(
                        at: directoryURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: []
                    )
                } else {
                    children = try? FileManager.default.contentsOfDirectory(
                        at: directoryURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: []
                    )
                }
                for child in (children ?? []).sorted(by: { $0.path < $1.path }) {
                    let name = child.lastPathComponent
                    guard !name.hasPrefix("."), !excludedDirectories.contains(name) else { continue }
                    guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                          values.isDirectory == true,
                          values.isSymbolicLink != true else { continue }
                    pending.append(child)
                }
            }
            progress(RepositoryDiscoveryProgress(
                scannedDirectories: scanned,
                discoveredRepositories: repositories.count,
                fractionCompleted: Double(scanned) / Double(scanned + pending.count)
            ))
        }
        return repositories.sorted { $0.path < $1.path }
    }
}
