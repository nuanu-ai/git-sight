import Foundation

public struct RepositoryInspector {
    public init() {}

    public func inspect(repositoryAt repositoryURL: URL) throws -> RepositorySnapshot {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = [
            "--no-optional-locks",
            "-C", repositoryURL.path,
            "status", "--porcelain=v1", "--untracked-files=normal"
        ]
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C"
        ]) { _, new in new }

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitSight.RepositoryInspector",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }

        let lines = output.split(whereSeparator: \.isNewline)
        return RepositorySnapshot(dirtyFileCount: lines.count)
    }
}
