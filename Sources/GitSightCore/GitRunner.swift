import Foundation

struct GitResult {
    let status: Int32
    let standardOutput: Data
    let standardError: String
}

struct GitRunner {
    func run(in repositoryURL: URL, _ arguments: [String]) throws -> GitResult {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", repositoryURL.path] + arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C",
            "LANG": "C"
        ]) { _, new in new }

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return GitResult(
            status: process.terminationStatus,
            standardOutput: output,
            standardError: String(decoding: error, as: UTF8.self)
        )
    }

    func output(in repositoryURL: URL, _ arguments: [String]) throws -> String {
        let result = try run(in: repositoryURL, arguments)
        guard result.status == 0 else {
            throw NSError(
                domain: "GitSight.GitRunner",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.standardError]
            )
        }
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    func optionalOutput(in repositoryURL: URL, _ arguments: [String]) throws -> String? {
        let result = try run(in: repositoryURL, arguments)
        return result.status == 0 ? String(decoding: result.standardOutput, as: UTF8.self) : nil
    }
}
