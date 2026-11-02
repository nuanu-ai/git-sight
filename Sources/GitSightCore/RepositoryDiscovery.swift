import Foundation

public struct RepositoryDiscovery {
    public init() {}

    public func repositories(under rootURL: URL) throws -> [URL] {
        try search(rootURL).sorted { $0.path < $1.path }
    }

    private func search(_ directoryURL: URL) throws -> [URL] {
        let gitURL = directoryURL.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitURL.path) {
            return [directoryURL]
        }

        var repositories: [URL] = []
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        )
        for child in children {
            let name = child.lastPathComponent
            guard !name.hasPrefix("."), name != "node_modules", name != ".build" else { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            repositories.append(contentsOf: try search(child))
        }
        return repositories
    }
}
