import Darwin
import Foundation

struct GitResult {
    let status: Int32
    let standardOutput: Data
    let standardError: String
}

struct GitRunner {
    /// `config` goes through GIT_CONFIG_KEY_n and GIT_CONFIG_VALUE_n, which take any key as is,
    /// where `-c key=value` would split a key that contains "=".
    func run(in repositoryURL: URL, _ arguments: [String], config: [(key: String, value: String)] = []) throws -> GitResult {
        let executable = Self.executable
        // A signed commit would make git log run gpg.program, which the repository's config may point anywhere.
        let command = [
            executable, "--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
            "-c", "log.showSignature=false", "-C", repositoryURL.path
        ] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        // A partial clone would fetch missing objects from the server and write them in; reading fails instead.
        environment.merge(["GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1", "LC_ALL": "C", "LANG": "C"]) { _, new in new }
        if !config.isEmpty {
            environment["GIT_CONFIG_COUNT"] = String(config.count)
            for (index, entry) in config.enumerated() {
                environment["GIT_CONFIG_KEY_\(index)"] = entry.key
                environment["GIT_CONFIG_VALUE_\(index)"] = entry.value
            }
        }

        func launchError(_ code: Int32) -> NSError {
            let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            return NSError(
                domain: "GitSight.GitRunner.ProcessLaunch",
                code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) в \(repositoryURL.path): \(underlying.domain) \(underlying.code): \(underlying.localizedDescription)",
                    NSUnderlyingErrorKey: underlying
                ]
            )
        }

        let outputPipe = try Self.makePipe()
        let errorPipe: (read: Int32, write: Int32)
        do {
            errorPipe = try Self.makePipe()
        } catch {
            close(outputPipe.read)
            close(outputPipe.write)
            throw error
        }

        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }
        let setupResults = [
            posix_spawn_file_actions_addclose(&fileActions, outputPipe.read),
            posix_spawn_file_actions_addclose(&fileActions, errorPipe.read),
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe.write, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&fileActions, errorPipe.write, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&fileActions, outputPipe.write),
            posix_spawn_file_actions_addclose(&fileActions, errorPipe.write),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        ]
        if let code = setupResults.first(where: { $0 != 0 }) {
            close(outputPipe.read)
            close(outputPipe.write)
            close(errorPipe.read)
            close(errorPipe.write)
            throw launchError(code)
        }

        let argv = command.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid = pid_t()
        let spawnResult = posix_spawn(&pid, executable, &fileActions, &attributes, argv, envp)
        guard spawnResult == 0 else {
            close(outputPipe.read)
            close(outputPipe.write)
            close(errorPipe.read)
            close(errorPipe.write)
            throw launchError(spawnResult)
        }
        close(outputPipe.write)
        close(errorPipe.write)
        defer {
            close(outputPipe.read)
            close(errorPipe.read)
        }
        guard Self.makeNonblocking(outputPipe.read), Self.makeNonblocking(errorPipe.read) else {
            let code = errno
            Self.terminateAndWait(pid)
            throw launchError(code)
        }

        // The kernel wakes the loop when git writes or exits, so a call returns the moment git ends.
        // Polling with a sleep added up to 10 ms to each of a scan's thousand calls.
        let queue = kqueue()
        guard queue >= 0 else {
            let code = errno
            Self.terminateAndWait(pid)
            throw launchError(code)
        }
        defer { close(queue) }
        var pipes = [Self.event(outputPipe.read, EVFILT_READ, EV_ADD), Self.event(errorPipe.read, EVFILT_READ, EV_ADD)]
        var exit = Self.event(pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, fflags: NOTE_EXIT)
        // A process that exited before this cannot be watched; waitpid below finds it either way.
        guard kevent(queue, &pipes, Int32(pipes.count), nil, 0, nil) == 0 else {
            let code = errno
            Self.terminateAndWait(pid)
            throw launchError(code)
        }
        _ = kevent(queue, &exit, 1, nil, 0, nil)

        var output = Data()
        var errorOutput = Data()
        var status = Int32()
        var didCancel = false
        var didTimeOut = false
        let deadline = DispatchTime.now().uptimeNanoseconds + 60 * 1_000_000_000
        var events = Array(repeating: Self.event(0, 0, 0), count: 3)
        // The timeout only paces the cancellation and deadline checks.
        var pace = timespec(tv_sec: 0, tv_nsec: 50_000_000)
        while true {
            let count = kevent(queue, nil, 0, &events, Int32(events.count), &pace)
            if count == -1, errno != EINTR {
                let code = errno
                Self.terminateAndWait(pid)
                throw launchError(code)
            }
            do {
                try Self.readAvailable(outputPipe.read, into: &output)
                try Self.readAvailable(errorPipe.read, into: &errorOutput)
            } catch {
                Self.terminateAndWait(pid)
                throw error
            }
            // A pipe at its end stays readable; unwatched, it cannot wake the loop again and again.
            for event in events.prefix(Int(max(count, 0))) where event.filter == Int16(EVFILT_READ) && event.flags & UInt16(EV_EOF) != 0 {
                var unwatch = Self.event(Int32(event.ident), EVFILT_READ, EV_DELETE)
                _ = kevent(queue, &unwatch, 1, nil, 0, nil)
            }
            if Task.isCancelled {
                didCancel = true
                Self.terminate(pid)
                break
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                didTimeOut = true
                Self.terminate(pid)
                break
            }
            let waitResult = waitpid(pid, &status, WNOHANG)
            if waitResult == pid { break }
            if waitResult == -1 {
                if errno == EINTR { continue }
                let code = errno
                Self.terminateAndWait(pid)
                throw launchError(code)
            }
        }
        if didCancel || didTimeOut { Self.waitForExit(pid, &status) }
        try Self.readAvailable(outputPipe.read, into: &output)
        try Self.readAvailable(errorPipe.read, into: &errorOutput)
        if didCancel { throw CancellationError() }
        if didTimeOut {
            throw NSError(
                domain: "GitSight.GitRunner.Timeout",
                code: Int(ETIMEDOUT),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) в \(repositoryURL.path): процесс остановлен через 60 секунд"]
            )
        }
        return GitResult(
            status: (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f),
            standardOutput: output,
            standardError: String(decoding: errorOutput, as: UTF8.self)
        )
    }

    /// /usr/bin/git is xcrun's shim: it looks up the developer folder anew on every call, which doubled
    /// the cost of each of a scan's thousand calls. The folder is read once here, where the shim reads it:
    /// DEVELOPER_DIR, else the one xcode-select chose. Anything else still goes through the shim.
    private static let executable: String = {
        let folder = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
            ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
        let git = folder.map { $0 + "/usr/bin/git" }
        return git.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/usr/bin/git"
    }()

    private static func event(_ identifier: Int32, _ filter: Int32, _ flags: Int32, fflags: UInt32 = 0) -> kevent {
        kevent(ident: UInt(identifier), filter: Int16(filter), flags: UInt16(flags), fflags: fflags, data: 0, udata: nil)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return (descriptors[0], descriptors[1])
    }

    private static func makeNonblocking(_ descriptor: Int32) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0
    }

    private static func readAvailable(_ descriptor: Int32, into data: inout Data) throws {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // Bound each drain so a continuously writing descendant cannot block cancellation.
        for _ in 0..<16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func terminate(_ pid: pid_t) {
        if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    }

    private static func waitForExit(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>) {
        while waitpid(pid, status, 0) == -1 && errno == EINTR {}
    }

    private static func terminateAndWait(_ pid: pid_t) {
        terminate(pid)
        var status = Int32()
        waitForExit(pid, &status)
    }

    func output(in repositoryURL: URL, _ arguments: [String], config: [(key: String, value: String)] = []) throws -> String {
        try output(from: run(in: repositoryURL, arguments, config: config), in: repositoryURL, arguments)
    }

    func data(in repositoryURL: URL, _ arguments: [String]) throws -> Data {
        try checked(run(in: repositoryURL, arguments), in: repositoryURL, arguments)
    }

    func output(from result: GitResult, in repositoryURL: URL, _ arguments: [String]) throws -> String {
        String(decoding: try checked(result, in: repositoryURL, arguments), as: UTF8.self)
    }

    private func checked(_ result: GitResult, in repositoryURL: URL, _ arguments: [String]) throws -> Data {
        guard result.status == 0 else {
            let details = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "GitSight.GitRunner.Command",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) в \(repositoryURL.path): статус \(result.status): \(details.isEmpty ? "без сообщения" : details)"]
            )
        }
        return result.standardOutput
    }

    func optionalOutput(in repositoryURL: URL, _ arguments: [String], expectedStatus: Int32 = 1) throws -> String? {
        let result = try run(in: repositoryURL, arguments)
        if result.status == expectedStatus { return nil }
        return try output(from: result, in: repositoryURL, arguments)
    }
}
