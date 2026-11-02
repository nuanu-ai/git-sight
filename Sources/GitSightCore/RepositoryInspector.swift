import Foundation

public struct RepositoryInspector {
    private let git = GitRunner()

    public init() {}

    public func inspect(repositoryAt repositoryURL: URL) throws -> RepositorySnapshot {
        let currentBranch = try git.optionalOutput(in: repositoryURL, [
            "symbolic-ref", "--quiet", "--short", "HEAD"
        ])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dirtyFileCount = try dirtyFiles(in: repositoryURL)
        let divergence = try aheadAndBehind(in: repositoryURL, reference: "HEAD")
        let worktrees = try worktrees(in: repositoryURL)
        let branches = try branches(in: repositoryURL, worktrees: worktrees)
        let stashes = try stashes(in: repositoryURL)
        let commits = try commits(in: repositoryURL)
        let edges = commits.flatMap { commit in
            commit.parents.map { CommitEdge(from: commit.fullHash, to: $0) }
        }
        let remote = try git.optionalOutput(in: repositoryURL, ["remote", "get-url", "origin"])
        let lastActivity = worktrees.compactMap(\.lastActivity).max() ?? commits.first?.date
        let assessment = RepositoryScore.evaluate(
            dirtyFileCount: dirtyFileCount,
            behind: divergence.behind,
            branches: branches,
            stashes: stashes
        )

        return RepositorySnapshot(
            dirtyFileCount: dirtyFileCount,
            path: repositoryURL,
            name: repositoryURL.lastPathComponent,
            currentBranch: currentBranch,
            ahead: divergence.ahead,
            behind: divergence.behind,
            worktrees: worktrees,
            branches: branches,
            stashes: stashes,
            commits: commits,
            edges: edges,
            remoteWebURL: remote.flatMap(webURL(from:)),
            lastActivity: lastActivity,
            score: assessment.score,
            severity: assessment.severity
        )
    }

    public func changedFiles(in repositoryURL: URL, commit: CommitSnapshot) throws -> [CommitFileSnapshot] {
        let result = try git.run(in: repositoryURL, [
            "diff-tree", "--no-commit-id", "--name-status", "-r", "--root", "--no-renames",
            "--format=", "-z", commit.fullHash
        ])
        guard result.status == 0 else {
            throw NSError(
                domain: "GitSight.RepositoryInspector",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.standardError]
            )
        }
        let fields = result.standardOutput.split(separator: 0)
        var files: [CommitFileSnapshot] = []
        var index = 0
        while index + 1 < fields.count {
            files.append(CommitFileSnapshot(
                status: String(decoding: fields[index], as: UTF8.self),
                path: String(decoding: fields[index + 1], as: UTF8.self)
            ))
            index += 2
        }
        return files
    }

    private func dirtyFiles(in repositoryURL: URL) throws -> Int {
        let result = try git.run(in: repositoryURL, [
            "status", "--porcelain=v1", "--untracked-files=normal", "-z"
        ])
        guard result.status == 0 else {
            throw NSError(
                domain: "GitSight.RepositoryInspector",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.standardError]
            )
        }
        var count = 0
        var skipOriginalPath = false
        for record in result.standardOutput.split(separator: 0) {
            if skipOriginalPath {
                skipOriginalPath = false
                continue
            }
            let status = String(decoding: record.prefix(2), as: UTF8.self)
            count += 1
            skipOriginalPath = status.contains("R") || status.contains("C")
        }
        return count
    }

    private func aheadAndBehind(in repositoryURL: URL, reference: String) throws -> (ahead: Int, behind: Int) {
        guard let output = try git.optionalOutput(in: repositoryURL, [
            "rev-list", "--left-right", "--count", "\(reference)...@{upstream}"
        ]) else { return (0, 0) }
        let counts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.count == 2 else { return (0, 0) }
        return (counts[0], counts[1])
    }

    private func worktrees(in repositoryURL: URL) throws -> [WorktreeSnapshot] {
        let output = try git.output(in: repositoryURL, ["worktree", "list", "--porcelain"])
        var snapshots: [WorktreeSnapshot] = []
        for block in output.components(separatedBy: "\n\n") where !block.isEmpty {
            var path: String?
            var head: String?
            var branch: String?
            for line in block.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                }
            }
            guard let path else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            var date: Date?
            if let head, let dateString = try git.optionalOutput(in: url, ["show", "-s", "--format=%cI", head]) {
                date = Self.date(from: dateString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            snapshots.append(WorktreeSnapshot(
                path: url,
                name: url.lastPathComponent,
                branch: branch,
                isMain: snapshots.isEmpty,
                dirtyFileCount: try dirtyFiles(in: url),
                lastActivity: date
            ))
        }
        return snapshots
    }

    private func branches(in repositoryURL: URL, worktrees: [WorktreeSnapshot]) throws -> [BranchSnapshot] {
        let format = "%(refname:short)%1F%(upstream:short)%1F%(committerdate:iso-strict)%1E"
        let output = try git.output(in: repositoryURL, [
            "for-each-ref", "--sort=refname", "--format=\(format)", "refs/heads"
        ])
        let worktreeBranches = Set(worktrees.compactMap(\.branch))
        return try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 3 else { throw Self.parseError(record) }
            let upstream = fields[1].isEmpty ? nil : fields[1]
            let divergence = try aheadAndBehind(in: repositoryURL, reference: fields[0])
            return BranchSnapshot(
                name: fields[0],
                upstream: upstream,
                ahead: upstream == nil ? 0 : divergence.ahead,
                behind: upstream == nil ? 0 : divergence.behind,
                lastCommitDate: Self.date(from: fields[2]),
                hasWorktree: worktreeBranches.contains(fields[0])
            )
        }
    }

    private func stashes(in repositoryURL: URL) throws -> [StashSnapshot] {
        let output = try git.output(in: repositoryURL, [
            "stash", "list", "--pretty=format:%gd%x1F%gs%x1F%cI%x1E"
        ])
        return try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 3, let date = Self.date(from: fields[2]) else { throw Self.parseError(record) }
            return StashSnapshot(name: fields[0], message: fields[1], date: date)
        }
    }

    private func commits(in repositoryURL: URL) throws -> [CommitSnapshot] {
        guard try git.optionalOutput(in: repositoryURL, ["rev-parse", "--verify", "HEAD"]) != nil else {
            return []
        }
        let format = "%H%x1F%h%x1F%s%x1F%an%x1F%cI%x1F%P%x1F%D%x1E"
        let output = try git.output(in: repositoryURL, [
            "log", "--topo-order", "-n", "100", "--date=iso-strict", "--pretty=format:\(format)"
        ])
        let parsedCommits = try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 7, let date = Self.date(from: fields[4]) else { throw Self.parseError(record) }
            return CommitSnapshot(
                fullHash: fields[0],
                shortHash: fields[1],
                subject: fields[2],
                author: fields[3],
                date: date,
                parents: fields[5].split(whereSeparator: \.isWhitespace).map(String.init),
                refs: fields[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
                lane: 0
            )
        }

        var activeLanes: [String] = []
        var laidOutCommits: [CommitSnapshot] = []
        for commit in parsedCommits {
            let lane = activeLanes.firstIndex(of: commit.fullHash) ?? activeLanes.count
            if !activeLanes.contains(commit.fullHash) {
                activeLanes.append(commit.fullHash)
            }
            activeLanes.removeAll { $0 == commit.fullHash }
            for (offset, parent) in commit.parents.enumerated() where !activeLanes.contains(parent) {
                activeLanes.insert(parent, at: min(lane + offset, activeLanes.count))
            }
            laidOutCommits.append(CommitSnapshot(
                fullHash: commit.fullHash,
                shortHash: commit.shortHash,
                subject: commit.subject,
                author: commit.author,
                date: commit.date,
                parents: commit.parents,
                refs: commit.refs,
                lane: lane
            ))
        }
        return laidOutCommits
    }

    private func webURL(from remote: String) -> URL? {
        let remote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if var components = URLComponents(string: remote), let scheme = components.scheme {
            if scheme == "http" || scheme == "https" {
                components.user = nil
                components.password = nil
                components.path = Self.removingGitSuffix(components.path)
                return components.url
            }
            if scheme == "ssh", let host = components.host {
                return URL(string: "https://\(host)\(Self.removingGitSuffix(components.path))")
            }
            return nil
        }

        let hostAndPath = remote.contains("@") ? String(remote.split(separator: "@", maxSplits: 1)[1]) : remote
        guard let colon = hostAndPath.firstIndex(of: ":") else { return nil }
        let host = String(hostAndPath[..<colon])
        let path = String(hostAndPath[hostAndPath.index(after: colon)...])
        return URL(string: "https://\(host)/\(Self.removingGitSuffix(path))")
    }

    private static func removingGitSuffix(_ path: String) -> String {
        path.hasSuffix(".git") ? String(path.dropLast(4)) : path
    }

    private static func records(_ output: String) -> [String] {
        output.split(separator: "\u{1E}").compactMap {
            let record = $0.trimmingCharacters(in: .newlines)
            return record.isEmpty ? nil : record
        }
    }

    private static func fields(_ record: String) -> [String] {
        record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
    }

    private static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func parseError(_ record: String) -> NSError {
        NSError(domain: "GitSight.RepositoryInspector", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Unexpected git output: \(record)"
        ])
    }
}
