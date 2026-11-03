import Foundation

public struct RepositoryInspector {
    private let git = GitRunner()

    public init() {}

    public func inspect(repositoryAt repositoryURL: URL) throws -> RepositorySnapshot {
        let currentBranch = try git.optionalOutput(in: repositoryURL, [
            "symbolic-ref", "--quiet", "--short", "HEAD"
        ])?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBare = try git.output(in: repositoryURL, ["rev-parse", "--is-bare-repository"])
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        let dirtyFileCount = isBare ? 0 : try dirtyFiles(in: repositoryURL).count
        let worktreeEntries = try worktreeEntries(in: repositoryURL)
        let branches = try branches(in: repositoryURL, checkedOut: Set(worktreeEntries.compactMap(\.branch)))
        let worktrees = try worktrees(worktreeEntries, in: repositoryURL, branches: branches)
        let currentBranchSnapshot = branches.first { $0.name == currentBranch }
        let divergence = (ahead: currentBranchSnapshot?.ahead ?? 0, behind: currentBranchSnapshot?.behind ?? 0)
        // Stashes are shared by all worktrees, but `git stash` refuses to run in a bare repository.
        let stashes = try (isBare ? worktrees.first?.path : repositoryURL).map { try self.stashes(in: $0) } ?? []
        let remote = try git.optionalOutput(in: repositoryURL, ["remote", "get-url", "origin"], expectedStatus: 2)
        let hasRemote = try !git.output(in: repositoryURL, ["remote"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let lastActivity = worktrees.compactMap(\.lastActivity).max()
        let assessment = RepositoryScore.evaluate(
            hasRemote: hasRemote,
            worktrees: worktrees,
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
            remoteWebURL: remote.flatMap(webURL(from:)),
            lastActivity: lastActivity,
            hasRemote: hasRemote,
            oldestUnsavedWork: assessment.oldestUnsavedWork,
            severity: assessment.severity
        )
    }

    public func changedFiles(in repositoryURL: URL, commit: CommitSnapshot) throws -> [CommitFileSnapshot] {
        try nameStatus(in: repositoryURL, [
            "diff-tree", "--no-commit-id", "--name-status", "-r", "--root", "--no-renames", "--diff-merges=first-parent",
            "--format=", "-z", commit.fullHash
        ])
    }

    /// Files a stash holds, including the untracked ones it saved.
    public func stashFiles(in repositoryURL: URL, stash: String) throws -> [CommitFileSnapshot] {
        try nameStatus(in: repositoryURL, [
            "stash", "show", "--include-untracked", "--name-status", "--no-renames", "-z", stash
        ])
    }

    /// Uncommitted files of one worktree; untracked files have status "?".
    public func uncommittedFiles(in worktreeURL: URL) throws -> [CommitFileSnapshot] {
        let result = try git.run(in: worktreeURL, [
            "status", "--porcelain=v1", "--untracked-files=all", "-z"
        ])
        guard result.status == 0 else {
            throw NSError(
                domain: "GitSight.RepositoryInspector",
                code: Int(result.status),
                userInfo: [NSLocalizedDescriptionKey: result.standardError]
            )
        }
        var files: [CommitFileSnapshot] = []
        var skipOriginalPath = false
        for record in result.standardOutput.split(separator: 0) {
            if skipOriginalPath {
                skipOriginalPath = false
                continue
            }
            let code = String(decoding: record.prefix(2), as: UTF8.self)
            skipOriginalPath = code.contains("R") || code.contains("C")
            files.append(CommitFileSnapshot(
                status: code == "??" ? "?" : String(code.first { $0 != " " } ?? "M"),
                path: String(decoding: record.dropFirst(3), as: UTF8.self)
            ))
        }
        return files
    }

    /// Commits `git log` reaches from `revisions`, newest first, with graph lanes.
    /// Boundary commits mark where the range starts, e.g. what the server already has.
    public func history(in repositoryURL: URL, revisions: [String]) throws -> [CommitSnapshot] {
        let format = "%m%x1F%H%x1F%h%x1F%s%x1F%an%x1F%cI%x1F%P%x1F%D%x1E"
        let limit = 300
        // "--" keeps a file named like a revision, e.g. HEAD, from making git log ambiguous.
        let output = try git.output(in: repositoryURL, [
            "log", "--topo-order", "--boundary", "--decorate=full", "-n", String(limit), "--date=iso-strict", "--pretty=format:\(format)"
        ] + revisions + ["--"])
        var commits = try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 8, let date = Self.date(from: fields[5]) else { throw Self.parseError(record) }
            return CommitSnapshot(
                fullHash: fields[1],
                shortHash: fields[2],
                subject: fields[3],
                author: fields[4],
                date: date,
                parents: fields[6].split(whereSeparator: \.isWhitespace).map(String.init),
                refs: Self.refs(fields[7]),
                lane: 0,
                isBoundary: fields[0] == "-"
            )
        }
        // At the limit git marks the cut-off parents as boundary too, so a boundary no longer means "the server has it".
        if commits.count(where: { !$0.isBoundary }) >= limit {
            commits.removeAll(where: \.isBoundary)
        }
        return Self.laidOut(commits)
    }

    /// The whole history behind `tips`, with commits that no remote branch holds marked.
    public func history(of tips: [String], in repositoryURL: URL) throws -> [CommitSnapshot] {
        try marked(history(in: repositoryURL, revisions: tips), tips: tips, in: repositoryURL)
    }

    /// Marks the commits reachable from `tips` that no remote branch holds.
    private func marked(_ history: [CommitSnapshot], tips: [String], in repositoryURL: URL) throws -> [CommitSnapshot] {
        // Without a remote nothing could be pushed, so marking every commit would say nothing.
        guard try !git.output(in: repositoryURL, ["remote"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return history
        }
        let unpushed = Set(try git.output(in: repositoryURL, ["rev-list"] + tips + ["--not", "--remotes", "--"]).split(separator: "\n").map(String.init))
        var commits = history
        for index in commits.indices where unpushed.contains(commits[index].fullHash) {
            commits[index].isUnpushed = true
        }
        return commits
    }

    /// Every branch, remote branch and tag, and linked worktrees on no branch, as one graph.
    public func repositoryHistory(in repositoryURL: URL) throws -> [CommitSnapshot] {
        // Linked worktrees on no branch hold commits no ref reaches, often an agent's.
        // The first entry is the main worktree, whose HEAD the history reads anyway, or a bare repository.
        // A worktree folder deleted by hand is skipped, as inspect skips it.
        let detached = try worktreeEntries(in: repositoryURL).dropFirst().compactMap { entry in
            entry.branch == nil && FileManager.default.fileExists(atPath: entry.path.path)
                ? entry.head.map { (name: entry.path.lastPathComponent, head: $0) } : nil
        }
        // An orphan branch with no commits yet leaves HEAD pointing nowhere, and naming it would fail the log.
        let head = try git.optionalOutput(in: repositoryURL, ["rev-parse", "--verify", "--quiet", "HEAD"]) == nil ? [] : ["HEAD"]
        let tips = ["--branches"] + head + detached.map(\.head)
        var commits = try marked(history(in: repositoryURL, revisions: tips + ["--remotes", "--tags"]), tips: tips, in: repositoryURL)
        for (name, head) in detached {
            if let index = commits.firstIndex(where: { $0.fullHash == head }) {
                commits[index].refs.append(CommitRef(kind: .worktree, name: name))
            }
        }
        return commits
    }

    /// Reads %D written with --decorate=full, e.g. "HEAD -> refs/heads/main, refs/remotes/origin/main, tag: refs/tags/v1".
    static func refs(_ decoration: String) -> [CommitRef] {
        // Entries are separated by ", "; a ref name may contain a comma but never a space.
        decoration.components(separatedBy: ", ").compactMap { part in
            var name = part.trimmingCharacters(in: .whitespaces)
            let isHead = name.hasPrefix("HEAD -> ")
            if isHead { name.removeFirst("HEAD -> ".count) }
            if name.hasPrefix("tag: ") { name.removeFirst("tag: ".count) }
            if name == "HEAD" { return CommitRef(kind: .head, name: name, isHead: true) }
            for (prefix, kind) in [("refs/heads/", CommitRef.Kind.branch), ("refs/remotes/", .remoteBranch), ("refs/tags/", .tag)]
            where name.hasPrefix(prefix) {
                let short = String(name.dropFirst(prefix.count))
                // origin/HEAD only repeats which branch the server calls default.
                if kind == .remoteBranch, short.hasSuffix("/HEAD") { return nil }
                return CommitRef(kind: kind, name: short, isHead: isHead)
            }
            // Other refs, such as refs/stash, are not branches.
            return nil
        }
    }

    private func nameStatus(in repositoryURL: URL, _ arguments: [String]) throws -> [CommitFileSnapshot] {
        let result = try git.run(in: repositoryURL, arguments)
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

    private func dirtyFiles(in repositoryURL: URL) throws -> (count: Int, modifiedAt: Date?) {
        let files = try uncommittedFiles(in: repositoryURL)
        var modifiedAt: Date?
        for file in files {
            // A deleted file has no date of its own; deleting it updated its directory.
            let fileURL = repositoryURL.appendingPathComponent(file.path)
            let attributes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))
                ?? (try? FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path))
            if let date = attributes?[.modificationDate] as? Date {
                modifiedAt = max(modifiedAt ?? date, date)
            }
        }
        return (files.count, modifiedAt)
    }

    private func worktreeEntries(in repositoryURL: URL) throws -> [(path: URL, head: String?, branch: String?, isBare: Bool)] {
        let output = try git.output(in: repositoryURL, ["worktree", "list", "--porcelain"])
        var entries: [(path: URL, head: String?, branch: String?, isBare: Bool)] = []
        for block in output.components(separatedBy: "\n\n") where !block.isEmpty {
            var path: String?
            var head: String?
            var branch: String?
            var isBare = false
            for line in block.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("HEAD ") {
                    head = String(line.dropFirst("HEAD ".count))
                } else if line.hasPrefix("branch refs/heads/") {
                    branch = String(line.dropFirst("branch refs/heads/".count))
                } else if line == "bare" {
                    isBare = true
                }
            }
            guard let path else { continue }
            entries.append((URL(fileURLWithPath: path, isDirectory: true), head, branch, isBare))
        }
        return entries
    }

    private func worktrees(
        _ entries: [(path: URL, head: String?, branch: String?, isBare: Bool)],
        in repositoryURL: URL,
        branches: [BranchSnapshot]
    ) throws -> [WorktreeSnapshot] {
        var snapshots: [WorktreeSnapshot] = []
        // A bare repository is listed first but has no files; its linked worktrees are not main.
        for (index, entry) in entries.enumerated() where !entry.isBare {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            var date: Date?
            if let head = entry.head, head.contains(where: { $0 != "0" }) {
                let dateString = try git.output(in: entry.path, ["show", "-s", "--format=%cI", head])
                date = Self.date(from: dateString.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            var detachedCommits = 0
            if entry.branch == nil, let head = entry.head, head.contains(where: { $0 != "0" }) {
                detachedCommits = try Self.count(git.output(in: repositoryURL, [
                    "rev-list", "--count", head, "--not", "--remotes", "--branches", "--tags"
                ]))
            }
            let dirty = try dirtyFiles(in: entry.path)
            snapshots.append(WorktreeSnapshot(
                path: entry.path,
                name: entry.path.lastPathComponent,
                branch: entry.branch,
                isMain: index == 0,
                dirtyFileCount: dirty.count,
                dirtyModifiedAt: dirty.modifiedAt,
                lastActivity: date,
                behind: branches.first { $0.name == entry.branch }?.behind ?? 0,
                unpushedCommits: detachedCommits
            ))
        }
        return snapshots
    }

    private func branches(in repositoryURL: URL, checkedOut: Set<String>) throws -> [BranchSnapshot] {
        let format = "%(refname:lstrip=2)%1F%(upstream:short)%1F%(committerdate:iso-strict)%1F%(upstream:track)%1F%(refname)%1E"
        let output = try git.output(in: repositoryURL, [
            "for-each-ref", "--sort=refname", "--format=\(format)", "refs/heads"
        ])
        return try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 5 else { throw Self.parseError(record) }
            let unpushed = try git.output(in: repositoryURL, ["rev-list", "--count", fields[4], "--not", "--remotes"])
            return BranchSnapshot(
                name: fields[0],
                upstream: fields[1].isEmpty ? nil : fields[1],
                ahead: Self.trackCount("ahead", in: fields[3]),
                behind: Self.trackCount("behind", in: fields[3]),
                lastCommitDate: Self.date(from: fields[2]),
                hasWorktree: checkedOut.contains(fields[0]),
                unpushedCommits: try Self.count(unpushed),
                upstreamGone: fields[3] == "[gone]"
            )
        }
    }

    private static func count(_ output: String) throws -> Int {
        guard let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw parseError(output) }
        return value
    }

    /// Reads one count from `%(upstream:track)`, e.g. "[ahead 2, behind 3]".
    private static func trackCount(_ word: String, in track: String) -> Int {
        guard let range = track.range(of: "\(word) ") else { return 0 }
        return Int(track[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    private func stashes(in repositoryURL: URL) throws -> [StashSnapshot] {
        let output = try git.output(in: repositoryURL, [
            "stash", "list", "--pretty=format:%gd%x1F%H%x1F%gs%x1F%cI%x1E"
        ])
        return try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 4, let date = Self.date(from: fields[3]) else { throw Self.parseError(record) }
            return StashSnapshot(name: fields[0], hash: fields[1], message: fields[2], date: date)
        }
    }

    /// Assigns each commit a graph lane; `commits` must list children before parents.
    private static func laidOut(_ commits: [CommitSnapshot]) -> [CommitSnapshot] {
        var activeLanes: [String?] = []
        var laidOutCommits: [CommitSnapshot] = []
        for commit in commits {
            let matchingLanes = activeLanes.indices.filter { activeLanes[$0] == commit.fullHash }
            let lane = matchingLanes.first ?? activeLanes.firstIndex(of: nil) ?? activeLanes.count
            if lane == activeLanes.count {
                activeLanes.append(nil)
            }
            for matchingLane in matchingLanes {
                activeLanes[matchingLane] = nil
            }
            activeLanes[lane] = nil

            var parentLanes: [Int] = []
            for (offset, parent) in commit.parents.enumerated() {
                if offset == 0 {
                    // The first parent continues this line even when a side line already waits for it;
                    // the parent then takes the leftmost of the lanes waiting for it.
                    activeLanes[lane] = parent
                    parentLanes.append(lane)
                } else if let waiting = activeLanes.firstIndex(of: parent) {
                    parentLanes.append(waiting)
                } else {
                    let parentLane = activeLanes.firstIndex(of: nil) ?? activeLanes.count
                    if parentLane == activeLanes.count {
                        activeLanes.append(parent)
                    } else {
                        activeLanes[parentLane] = parent
                    }
                    parentLanes.append(parentLane)
                }
            }
            laidOutCommits.append(CommitSnapshot(
                fullHash: commit.fullHash,
                shortHash: commit.shortHash,
                subject: commit.subject,
                author: commit.author,
                date: commit.date,
                parents: commit.parents,
                refs: commit.refs,
                lane: lane,
                parentLanes: parentLanes,
                isBoundary: commit.isBoundary
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
