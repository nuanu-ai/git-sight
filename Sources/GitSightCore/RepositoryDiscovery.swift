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
        progress: (RepositoryDiscoveryProgress) -> Void = { _ in },
        issue: (URL, NSError) -> Void = { _, _ in }
    ) throws -> [URL] {
        var pending: [URL] = [rootURL]
        var scanned = 0
        var lastFractionCompleted = 0.0
        var repositories: [URL] = []
        var seen: Set<String> = []
        let excludedDirectories: Set<String> = ["Library", "node_modules"]

        while !pending.isEmpty {
            try Task.checkCancellation()
            let directoryURL = pending.removeFirst()
            scanned += 1
            let gitURL = directoryURL.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: gitURL.path) {
                let repositoryURL = Self.mainRepository(ofLinkedWorktreeAt: gitURL) ?? directoryURL
                if seen.insert(repositoryURL.resolvingSymlinksInPath().path).inserted {
                    repositories.append(repositoryURL)
                }
            } else {
                let children: [URL]?
                do {
                    children = try FileManager.default.contentsOfDirectory(
                        at: directoryURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                        options: []
                    )
                } catch {
                    let nsError = error as NSError
                    if scanned == 1 {
                        throw NSError(
                            domain: "GitSight.RepositoryDiscovery.Root",
                            code: nsError.code,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Could not read \(directoryURL.path): \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)",
                                NSUnderlyingErrorKey: error
                            ]
                        )
                    }
                    if !Self.isGone(nsError) { issue(directoryURL, nsError) }
                    children = nil
                }
                for child in (children ?? []).sorted(by: { $0.path < $1.path }) {
                    let name = child.lastPathComponent
                    guard !name.hasPrefix("."), !excludedDirectories.contains(name) else { continue }
                    do {
                        let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                        pending.append(child)
                    } catch {
                        issue(child, error as NSError)
                    }
                }
            }
            lastFractionCompleted = max(lastFractionCompleted, Double(scanned) / Double(scanned + pending.count))
            progress(RepositoryDiscoveryProgress(
                scannedDirectories: scanned,
                discoveredRepositories: repositories.count,
                fractionCompleted: lastFractionCompleted
            ))
        }
        return repositories.sorted { $0.path < $1.path }
    }

    /// A folder deleted after the walk listed it, as an agent's rm -rf does mid-scan:
    /// nothing is left to read, so there is nothing to report. A missing root still fails the scan above.
    private static func isGone(_ error: NSError) -> Bool {
        (error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// A linked worktree's `.git` file points at `<main>/.git/worktrees/<name>`, or at
    /// `<bare>/worktrees/<name>` for a bare repository. That repository already reports
    /// every worktree, so the linked one maps to it.
    private static func mainRepository(ofLinkedWorktreeAt gitURL: URL) -> URL? {
        guard let contents = try? String(contentsOf: gitURL, encoding: .utf8),
              contents.hasPrefix("gitdir: ") else { return nil }
        let path = contents.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory = URL(fileURLWithPath: path, relativeTo: gitURL.deletingLastPathComponent()).standardizedFileURL
        let worktrees = gitDirectory.deletingLastPathComponent()
        let commonDirectory = worktrees.deletingLastPathComponent()
        guard worktrees.lastPathComponent == "worktrees" else { return nil }
        return commonDirectory.lastPathComponent == ".git" ? commonDirectory.deletingLastPathComponent() : commonDirectory
    }
}
