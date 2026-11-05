import Foundation

public struct RepositoryInspector {
    private let git = GitRunner()

    public init() {}

    public func inspect(repositoryAt repositoryURL: URL) throws -> RepositorySnapshot {
        let config = try config(in: repositoryURL)
        let refs = try refs(in: repositoryURL)
        let worktreeEntries = try worktreeEntries(in: repositoryURL, head: refs.head, config: config)
        // The first entry is the repository itself: its main worktree, or a bare repository.
        let isBare = worktreeEntries.first?.isBare ?? false
        // git remote also finds remotes in the files of git's first years; only an empty config needs it to look.
        let hasRemote = try !config.remotes.isEmpty
            || !git.output(in: repositoryURL, ["remote"]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let (branches, base) = try branches(
            refs.branches, in: repositoryURL, hasRemote: hasRemote,
            checkedOut: Set(worktreeEntries.compactMap(\.branch)), lines: refs.lines
        )
        let worktrees = try worktrees(worktreeEntries, in: repositoryURL, branches: branches, mainFilters: config.filtersOff)
        // A bare repository has no worktree of its own; its HEAD still names a branch.
        let currentBranch = isBare ? refs.head?.name : worktreeEntries.first?.branch
        let currentBranchSnapshot = branches.first { $0.name == currentBranch }
        let divergence = (ahead: currentBranchSnapshot?.ahead ?? 0, behind: currentBranchSnapshot?.behind ?? 0)
        // Stashes are shared by all worktrees, but `git stash` refuses to run in a bare repository.
        let stashes = refs.hasStash ? try (isBare ? worktrees.first?.path : repositoryURL).map { try self.stashes(in: $0) } ?? [] : []
        let lastActivity = worktrees.compactMap(\.lastActivity).max()
        let assessment = RepositoryScore.evaluate(
            hasRemote: hasRemote,
            hasBase: base != nil,
            worktrees: worktrees,
            branches: branches,
            stashes: stashes
        )

        return RepositorySnapshot(
            dirtyFileCount: worktrees.first { $0.isMain }?.dirtyFileCount ?? 0,
            path: repositoryURL,
            name: repositoryURL.lastPathComponent,
            currentBranch: currentBranch,
            ahead: divergence.ahead,
            behind: divergence.behind,
            worktrees: worktrees,
            branches: branches,
            stashes: stashes,
            remoteWebURL: config.origin.flatMap(webURL(from:)),
            lastActivity: lastActivity,
            hasRemote: hasRemote,
            baseBranch: base?.name,
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

    /// A diff longer than this is cut; nobody reads past it in a side pane.
    public static let diffLineLimit = 5000
    /// Diffs show the file as stored: no external diff tools or text converters from the repository's config.
    /// They run on plumbing, which ignores diff.submodule and so never diffs inside a submodule under its config.
    private static let diffOptions = ["--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=dirty"]

    /// How one file changed in a commit, against its first parent, as its file list counts it.
    public func diff(of path: String, in commit: CommitSnapshot, repositoryURL: URL) throws -> FileDiff {
        try shownDiff(of: path, in: commit.fullHash, repositoryURL: repositoryURL)
    }

    /// How one uncommitted file differs from HEAD; an untracked file is all new.
    public func uncommittedDiff(of file: CommitFileSnapshot, in worktreeURL: URL) throws -> FileDiff {
        // Before the first commit there is no HEAD to diff against, so every file is new.
        let hasHead = try git.optionalOutput(in: worktreeURL, ["rev-parse", "--verify", "--quiet", "HEAD"]) != nil
        guard file.status != "?", hasHead else {
            let arguments = ["diff"] + Self.diffOptions + ["--no-index", "--", "/dev/null", file.path]
            let result = try git.run(in: worktreeURL, arguments, config: filtersOff(in: worktreeURL))
            // --no-index exits with 1 when the files differ, which they always do here;
            // with nothing printed it failed, as on a nested repository.
            if result.status == 1, !result.standardOutput.isEmpty { return Self.fileDiff(String(decoding: result.standardOutput, as: UTF8.self)) }
            return Self.fileDiff(try git.output(from: result, in: worktreeURL, arguments))
        }
        // Plumbing: porcelain git diff rewrites the index to note a touched file, --no-optional-locks or not.
        return Self.fileDiff(try git.output(in: worktreeURL, ["diff-index", "-p"] + Self.diffOptions + ["HEAD", "--", Self.literal(file.path)], config: filtersOff(in: worktreeURL)))
    }

    /// How one file in a stash differs from the commit it was stashed on.
    /// Untracked files live in the stash's third parent, a commit of their own.
    public func stashDiff(of file: CommitFileSnapshot, stash: String, in repositoryURL: URL) throws -> FileDiff {
        let untracked = try git.optionalOutput(in: repositoryURL, ["rev-parse", "--verify", "--quiet", "\(stash)^3:\(file.path)"]) != nil
        return try shownDiff(of: file.path, in: untracked ? "\(stash)^3" : stash, repositoryURL: repositoryURL)
    }

    /// One path of a commit, as diff-tree lists its files: a root commit all new, a merge against its first parent.
    private func shownDiff(of path: String, in revision: String, repositoryURL: URL) throws -> FileDiff {
        Self.fileDiff(try git.output(in: repositoryURL, [
            "diff-tree", "-p", "--root", "--no-commit-id", "--diff-merges=first-parent", "--no-renames"
        ] + Self.diffOptions + [revision, "--", Self.literal(path)]))
    }

    /// A path as a name, never a glob: "a*.txt" means only that file.
    private static func literal(_ path: String) -> String {
        ":(literal)\(path)"
    }

    /// Reads a unified diff of one file into numbered lines. Headers before the first hunk are skipped.
    static func fileDiff(_ output: String) -> FileDiff {
        // Split on "\n" itself: Swift reads "\r\n" as one Character, which a Character split never breaks.
        var rawLines = output.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        var lines: [DiffLine] = []
        var isBinary = false
        var inHunk = false
        var old = 0
        var new = 0
        for raw in rawLines {
            if lines.count >= diffLineLimit { return FileDiff(lines: lines, isTruncated: true) }
            if raw.hasPrefix("@@ ") {
                // "@@ -12,3 +12,4 @@ heading": where each side's run starts.
                let ranges = raw.split(separator: " ")
                old = ranges.count > 1 ? Int(ranges[1].dropFirst().prefix { $0 != "," }) ?? 0 : 0
                new = ranges.count > 2 ? Int(ranges[2].dropFirst().prefix { $0 != "," }) ?? 0 : 0
                inHunk = true
                lines.append(DiffLine(kind: .hunk, oldLine: nil, newLine: nil, text: String(raw)))
                continue
            }
            guard inHunk else {
                if raw.hasPrefix("Binary files ") { isBinary = true }
                continue
            }
            // The marker is the first scalar; a combining mark after it would fold both into one Character.
            var scalars = raw.unicodeScalars.dropFirst()
            // A Windows line ending is not part of the line.
            if scalars.last == "\r" { scalars.removeLast() }
            let text = String(String.UnicodeScalarView(scalars))
            switch raw.unicodeScalars.first {
            case "+":
                lines.append(DiffLine(kind: .added, oldLine: nil, newLine: new, text: text))
                new += 1
            case "-":
                lines.append(DiffLine(kind: .removed, oldLine: old, newLine: nil, text: text))
                old += 1
            case "\\":
                // "\ No newline at end of file"
                continue
            default:
                // A context line; diff.suppressBlankEmpty writes an empty one without its leading space.
                lines.append(DiffLine(kind: .context, oldLine: old, newLine: new, text: text))
                old += 1
                new += 1
            }
        }
        return FileDiff(lines: lines, isBinary: isBinary)
    }

    /// Files a stash holds, including the untracked ones it saved.
    public func stashFiles(in repositoryURL: URL, stash: String) throws -> [CommitFileSnapshot] {
        try nameStatus(in: repositoryURL, [
            "stash", "show", "--include-untracked", "--name-status", "--no-renames", "-z", stash
        ])
    }

    /// Config that turns off every filter the repository's own config defines. git runs a filter's clean
    /// command when it compares a changed file with the index, so status and diff would otherwise run it.
    /// Filters from the user's global and system config, such as Git LFS, are the user's and stay on.
    private func filtersOff(in worktreeURL: URL) throws -> [(key: String, value: String)] {
        try config(in: worktreeURL).filtersOff
    }

    /// What inspect reads from config, in one call: the filters to turn off, the remotes, origin's URL as
    /// git remote get-url gives it, and whether core.bare may make the repository bare.
    private func config(in worktreeURL: URL) throws -> (filtersOff: [(key: String, value: String)], remotes: Set<String>, origin: String?, mayBeBare: Bool) {
        // "<scope>\0<key>\n<value>\0" for each entry; a key set with no value has no newline.
        let output = try git.optionalOutput(in: worktreeURL, [
            "config", "-z", "--show-scope", "--get-regexp", #"^(filter\..*\.(clean|smudge|process|required)|remote\..+\..+|url\..+\.insteadof|core\.bare)$"#
        ]) ?? ""
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: false)
        var drivers: Set<String> = []
        var remotes: Set<String> = []
        var origin: String?
        var rewrites: [(base: String, prefix: String)] = []
        var mayBeBare = false
        for index in stride(from: 0, to: tokens.count - 1, by: 2) {
            let entry = tokens[index + 1].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = entry[0]
            let value = entry.count > 1 ? String(entry[1]) : nil
            // "<section>.<subsection>.<name>", where the subsection may be empty or contain dots.
            let subsection = key.split(separator: ".", omittingEmptySubsequences: false).dropFirst().dropLast().joined(separator: ".")
            if key.hasPrefix("filter.") {
                if tokens[index] != "global", tokens[index] != "system" { drivers.insert(subsection) }
            } else if key.hasPrefix("remote.") {
                remotes.insert(subsection)
                if key == "remote.origin.url", origin == nil { origin = value }
            } else if key.hasPrefix("url.") {
                rewrites.append((subsection, value ?? ""))
            } else {
                mayBeBare = mayBeBare || !["false", "no", "off", "0"].contains(value?.lowercased() ?? "true")
            }
        }
        // url.<base>.insteadOf: the longest prefix that matches is replaced by its base; the first of equals wins.
        if let url = origin, let rewrite = rewrites.filter({ url.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }) {
            origin = rewrite.base + url.dropFirst(rewrite.prefix.count)
        }
        let filtersOff = drivers.sorted().flatMap { driver in
            ["clean", "smudge", "process"].map { (key: "filter.\(driver).\($0)", value: "") }
                + [(key: "filter.\(driver).required", value: "false")]
        }
        return (filtersOff, remotes, origin, mayBeBare)
    }

    /// Uncommitted files of one worktree; untracked files have status "?".
    public func uncommittedFiles(in worktreeURL: URL) throws -> [CommitFileSnapshot] {
        try uncommittedFiles(in: worktreeURL, filtersOff: filtersOff(in: worktreeURL))
    }

    private func uncommittedFiles(in worktreeURL: URL, filtersOff: [(key: String, value: String)]) throws -> [CommitFileSnapshot] {
        // A submodule's own worktree is not looked into: its config and filters are its own.
        let result = try git.run(in: worktreeURL, [
            "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=dirty", "-z"
        ], config: filtersOff)
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

    /// How many commits a history reads at first and adds each time the user scrolls to its end.
    public static let historyPage = 300

    /// Commits `git log` reaches from `revisions`, newest first, with graph lanes, at most `limit` of them.
    /// Boundary commits mark where the range starts, e.g. what the server already has.
    public func history(in repositoryURL: URL, revisions: [String], limit: Int = historyPage) throws -> [CommitSnapshot] {
        let format = "%m%x1F%H%x1F%h%x1F%s%x1F%an%x1F%cI%x1F%P%x1F%D%x1E"
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
    public func history(of tips: [String], in repositoryURL: URL, limit: Int = historyPage) throws -> [CommitSnapshot] {
        try marked(history(in: repositoryURL, revisions: tips, limit: limit), tips: tips, in: repositoryURL)
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
    public func repositoryHistory(in repositoryURL: URL, limit: Int = historyPage) throws -> [CommitSnapshot] {
        // Linked worktrees on no branch hold commits no ref reaches, often an agent's.
        // The first entry is the main worktree, whose HEAD the history reads anyway, or a bare repository.
        // A worktree folder deleted or emptied by hand is skipped, as inspect skips it.
        let detached = try worktreeEntries(in: repositoryURL).dropFirst().compactMap { entry in
            entry.branch == nil && Self.isCheckedOut(entry.path)
                ? entry.head.map { (name: entry.path.lastPathComponent, head: $0) } : nil
        }
        // An orphan branch with no commits yet leaves HEAD pointing nowhere, and naming it would fail the log.
        let head = try git.optionalOutput(in: repositoryURL, ["rev-parse", "--verify", "--quiet", "HEAD"]) == nil ? [] : ["HEAD"]
        // The commit each stash was made on, its first parent, stays in the graph after its branch is deleted.
        // git log reads the stash list in a bare repository too, where git stash refuses; no stash prints nothing.
        let stashBases = try git.output(in: repositoryURL, ["log", "--walk-reflogs", "--ignore-missing", "--format=%P", "refs/stash", "--"])
            .split(separator: "\n").compactMap { $0.split(separator: " ").first.map(String.init) }
        let tips = ["--branches"] + head + detached.map(\.head) + stashBases
        var commits = try marked(history(in: repositoryURL, revisions: tips + ["--remotes", "--tags"], limit: limit), tips: tips, in: repositoryURL)
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

    /// At most three of a scan's status calls run at once. Each reads every file of a worktree, and more at a
    /// time only fight over the disk: a full scan took a sixth longer and twice the system's CPU. A status
    /// that waits over a second runs anyway, so one stuck on a network drive does not hold up the rest.
    /// The files of a worktree the user opens are read at once, without a turn.
    private static let statusTurns = DispatchSemaphore(value: 3)

    private func dirtyFiles(in repositoryURL: URL, filtersOff: [(key: String, value: String)]) throws -> (count: Int, modifiedAt: Date?) {
        let files: [CommitFileSnapshot]
        do {
            let turn = Self.statusTurns.wait(timeout: .now() + 1) == .success
            defer { if turn { Self.statusTurns.signal() } }
            files = try uncommittedFiles(in: repositoryURL, filtersOff: filtersOff)
        }
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

    /// The main worktree on a branch with no linked worktrees is all `worktree list` would print, so it is
    /// put together here, as git does: the real path of .git, less "/.git". Anything else asks git.
    private func worktreeEntries(
        in repositoryURL: URL, head: (name: String, commit: String)?, config: (filtersOff: [(key: String, value: String)], remotes: Set<String>, origin: String?, mayBeBare: Bool)
    ) throws -> [(path: URL, head: String?, branch: String?, isBare: Bool)] {
        let gitURL = repositoryURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if let head, !config.mayBeBare,
           FileManager.default.fileExists(atPath: gitURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
           (try? FileManager.default.contentsOfDirectory(atPath: gitURL.appendingPathComponent("worktrees").path))?.isEmpty ?? true,
           let real = realpath(gitURL.path, nil) {
            defer { free(real) }
            let path = String(cString: real)
            return [(URL(fileURLWithPath: path.hasSuffix("/.git") ? String(path.dropLast("/.git".count)) : path, isDirectory: true), head.commit, head.name, false)]
        }
        return try worktreeEntries(in: repositoryURL)
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

    /// Whether a worktree git still lists is a checkout: its folder holds its .git. A folder deleted or emptied
    /// by hand is not; git status there fails, or worse, reads whatever repository encloses the folder.
    private static func isCheckedOut(_ path: URL) -> Bool {
        FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path)
    }

    private func worktrees(
        _ entries: [(path: URL, head: String?, branch: String?, isBare: Bool)],
        in repositoryURL: URL,
        branches: [BranchSnapshot],
        mainFilters: [(key: String, value: String)]
    ) throws -> [WorktreeSnapshot] {
        // A bare repository is listed first but has no files; its linked worktrees are not main.
        let present = entries.enumerated().filter { _, entry in !entry.isBare && Self.isCheckedOut(entry.path) }
        let branchDates = Dictionary(branches.map { ($0.name, $0.lastCommitDate) }) { first, _ in first }
        // A worktree on a branch was last active at the branch's last commit; one call dates every other HEAD.
        let undated = present.compactMap { _, entry -> String? in
            guard let head = entry.head, head.contains(where: { $0 != "0" }), entry.branch.flatMap({ branchDates[$0] ?? nil }) == nil else { return nil }
            return head
        }
        var headDates: [String: Date] = [:]
        if !undated.isEmpty {
            for line in try git.output(in: repositoryURL, ["show", "-s", "--format=%H%x1F%cI"] + undated).split(separator: "\n") {
                let fields = line.split(separator: "\u{1F}")
                if fields.count == 2 { headDates[String(fields[0])] = Self.date(from: String(fields[1])) }
            }
        }
        return try present.map { index, entry in
            var detachedCommits = 0
            if entry.branch == nil, let head = entry.head, head.contains(where: { $0 != "0" }) {
                detachedCommits = try Self.count(git.output(in: repositoryURL, [
                    "rev-list", "--count", head, "--not", "--remotes", "--branches", "--tags"
                ]))
            }
            // The main worktree's config is the one already read; a linked worktree may have its own.
            let dirty = try dirtyFiles(in: entry.path, filtersOff: index == 0 ? mainFilters : filtersOff(in: entry.path))
            return WorktreeSnapshot(
                path: entry.path,
                name: entry.path.lastPathComponent,
                branch: entry.branch,
                isMain: index == 0,
                dirtyFileCount: dirty.count,
                dirtyModifiedAt: dirty.modifiedAt,
                lastActivity: entry.branch.flatMap { branchDates[$0] ?? nil } ?? entry.head.flatMap { headDates[$0] },
                behind: branches.first { $0.name == entry.branch }?.behind ?? 0,
                unpushedCommits: detachedCommits,
                // A branch with no commits yet is listed at a hash of zeros.
                head: entry.head.flatMap { $0.contains { $0 != "0" } ? $0 : nil }
            )
        }
    }

    /// Local branches, the branch work is merged into, whether there is a stash, and the branch HEAD names,
    /// from one for-each-ref. Each branch reads: name, commit, symref, HEAD mark, upstream, date, track,
    /// upstream's full name.
    private func refs(in repositoryURL: URL) throws -> (branches: [[String]], lines: [Base], hasStash: Bool, head: (name: String, commit: String)?) {
        // Of remote branches only those a base can be: a repository may hold thousands.
        let remoteRefs = ["upstream", "origin"].flatMap { remote in
            (["HEAD", "main", "master"] + Self.integrationNames).map { "refs/remotes/\(remote)/\($0)" }
        }
        let format = "%(refname)%1F%(objectname)%1F%(symref)%1F%(HEAD)%1F%(upstream:short)%1F%(committerdate:iso-strict)%1F%(upstream:track)%1F%(upstream)%1E"
        let output = try git.output(in: repositoryURL, ["for-each-ref", "--sort=refname", "--format=\(format)", "refs/heads", "refs/stash"] + remoteRefs)
        let records = try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 8 else { throw Self.parseError(record) }
            return fields
        }
        let listed = Dictionary(records.map { ($0[0], $0) }) { first, _ in first }
        // The server's default branch as the clone recorded it, else its main or master, else a local main
        // or master. A fork's work lands in the repository it was forked from, so upstream goes before origin.
        var bases: [(ref: String, commit: String)] = []
        for remote in ["upstream", "origin"] {
            // for-each-ref leaves out a HEAD that points at no ref.
            if let head = listed["refs/remotes/\(remote)/HEAD"], !head[2].isEmpty { bases.append((head[2], head[1])) }
            bases += ["main", "master"].compactMap { listed["refs/remotes/\(remote)/\($0)"].map { ($0[0], $0[1]) } }
        }
        bases += ["main", "master"].compactMap { listed["refs/heads/\($0)"].map { ($0[0], $0[1]) } }
        // Pull requests may land in an integration branch on the same server, which the default branch takes at a release.
        if let base = bases.first, let remote = ["upstream", "origin"].first(where: { base.ref.hasPrefix("refs/remotes/\($0)/") }) {
            bases = [base] + Self.integrationNames.compactMap { listed["refs/remotes/\(remote)/\($0)"].map { ($0[0], $0[1]) } }
        } else {
            bases = Array(bases.prefix(1))
        }
        let lines = bases.map { base in
            // refs/heads/<name> or refs/remotes/<remote>/<name>; the name may have slashes of its own.
            let parts = base.ref.split(separator: "/", maxSplits: base.ref.hasPrefix("refs/heads/") ? 2 : 3)
            return Base(ref: base.ref, name: String(parts[parts.count - 1]), commit: base.commit)
        }
        let branches = records.filter { $0[0].hasPrefix("refs/heads/") }
        let head = branches.first { $0[3] == "*" }.map { (name: String($0[0].dropFirst("refs/heads/".count)), commit: $0[1]) }
        return (branches, lines, listed["refs/stash"] != nil, head)
    }

    private static let integrationNames = ["develop", "dev", "staging"]

    private struct Base {
        let ref: String
        let name: String
        let commit: String
    }

    private func branches(
        _ records: [[String]], in repositoryURL: URL, hasRemote: Bool, checkedOut: Set<String>, lines: [Base]
    ) throws -> (branches: [BranchSnapshot], base: Base?) {
        // A branch level with or behind its upstream on a remote has no commits only here.
        let synced = records.map { $0[7].hasPrefix("refs/remotes/") && $0[6] != "[gone]" && !$0[6].contains("ahead") }
        let unpushed = hasRemote && synced.contains(false) ? try unpushedCounts(in: repositoryURL) : nil
        let unpushedCounts = try zip(records, synced).map { fields, synced in
            synced ? 0 : try unpushed?(fields[1]) ?? Self.count(git.output(in: repositoryURL, ["rev-list", "--count", fields[0], "--not", "--remotes"]))
        }
        // The local branch of a line's name is that line itself, not work. Not every branch tracking it is:
        // one started from origin/main tracks origin/main too.
        let isBase = records.map { fields in lines.contains { fields[0] == "refs/heads/\($0.name)" } }
        // Work on no remote is counted as such; only work the server has is checked against the base.
        let checked = records.indices.map { !isBase[$0] && unpushedCounts[$0] == 0 }
        var base = lines.first
        var ahead = try checked.contains(true) ? base.flatMap { try commitsAhead(of: $0.ref, in: repositoryURL) } : nil
        // The base is the line the branches here hold the fewest commits beyond: the one their work lands in.
        // An older git cannot count them in one pass, and keeps the default branch.
        if var fewest = ahead {
            let total = { (counts: [String: Int]) in records.indices.reduce(0) { $0 + (checked[$1] ? counts[records[$1][0]] ?? 0 : 0) } }
            for line in lines.dropFirst() {
                if let counts = try commitsAhead(of: line.ref, in: repositoryURL), total(counts) < total(fewest) {
                    (base, fewest) = (line, counts)
                }
            }
            ahead = fewest
        }
        let candidates = checked.contains(true) ? base : nil
        // An older git lists the branches the base lacks anything of, and those get their commits counted one by one.
        let notMerged = try candidates.flatMap { base in
            ahead != nil ? nil : Set(try git.output(in: repositoryURL, ["for-each-ref", "--no-merged=\(base.ref)", "--format=%(refname)", "refs/heads"])
                .split(separator: "\n").map(String.init))
        } ?? []
        let counted = try records.indices.map { index in
            let fields = records[index]
            let ref = fields[0]
            var unmerged = 0
            if let base, checked[index] {
                unmerged = try ahead.map { $0[ref] ?? 0 }
                    ?? (notMerged.contains(ref) ? Self.count(git.output(in: repositoryURL, ["rev-list", "--count", ref, "--not", base.ref, "--"])) : 0)
            }
            return (fields: fields, name: String(ref.dropFirst("refs/heads/".count)), unpushed: unpushedCounts[index], isBase: isBase[index], unmerged: unmerged)
        }
        let merges = try base.map { base in
            try self.merges(of: counted.filter { $0.unmerged > 0 }.map { (ref: $0.fields[0], commit: $0.fields[1]) }, into: base, in: repositoryURL)
        } ?? [:]
        return (counted.map { branch in
            let fields = branch.fields
            return BranchSnapshot(
                name: branch.name,
                upstream: fields[4].isEmpty ? nil : fields[4],
                ahead: Self.trackCount("ahead", in: fields[6]),
                behind: Self.trackCount("behind", in: fields[6]),
                lastCommitDate: Self.date(from: fields[5]),
                hasWorktree: checkedOut.contains(branch.name),
                unpushedCommits: branch.unpushed,
                upstreamGone: fields[6] == "[gone]",
                isBase: branch.isBase,
                unmergedCommits: merges[fields[0]] == .squashed ? 0 : branch.unmerged,
                isUnrelated: merges[fields[0]] == .unrelated
            )
        }, base)
    }

    /// For each branch, the commits it holds that no remote branch does: one list of every such commit with
    /// its parents, walked from each branch's commit, instead of a rev-list per branch.
    private func unpushedCounts(in repositoryURL: URL) throws -> (String) -> Int {
        let graph = Self.graph(try git.data(in: repositoryURL, ["rev-list", "--parents", "--branches", "--not", "--remotes"]))
        return { Self.reachable(from: $0, in: graph).count }
    }

    /// The lines of rev-list --parents, "<commit> <parent>…", as each commit's parents.
    private static func graph(_ output: Data) -> [String: [String]] {
        output.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [String: [String]] in
            var graph: [String: [String]] = [:]
            // Split by byte: by Character, the lines of a long history take tens of milliseconds.
            for line in bytes.split(separator: UInt8(ascii: "\n")) {
                let commits = line.split(separator: UInt8(ascii: " ")).map { String(decoding: $0, as: UTF8.self) }
                graph[commits[0]] = Array(commits.dropFirst())
            }
            return graph
        }
    }

    /// The commits of `graph` that `tip` reaches, itself included; the walk stops at commits outside it.
    private static func reachable(from tip: String, in graph: [String: [String]]) -> Set<String> {
        var seen: Set<String> = []
        var pending = [tip]
        while let commit = pending.popLast() {
            guard let parents = graph[commit], seen.insert(commit).inserted else { continue }
            pending += parents
        }
        return seen
    }

    /// The commits each branch has that `base` lacks, which git 2.41 counts for all branches in one pass;
    /// nil from an older git, which fails the format.
    private func commitsAhead(of base: String, in repositoryURL: URL) throws -> [String: Int]? {
        let result = try git.run(in: repositoryURL, ["for-each-ref", "--format=%(refname)%1F%(ahead-behind:\(base))", "refs/heads"])
        guard result.status == 0 else { return nil }
        var counts: [String: Int] = [:]
        for line in String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n") {
            // "<ahead> <behind>", empty for a ref that names no commit, as one written by hand may.
            let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw Self.parseError(String(line)) }
            if fields[1].isEmpty { continue }
            guard let count = Int(fields[1].prefix { $0 != " " }) else { throw Self.parseError(String(line)) }
            counts[String(fields[0])] = count
        }
        return counts
    }

    private enum Merge { case open, squashed, unrelated }

    /// Merge checks already made, by repository, branch commit and base commit. What one commit holds of
    /// another never changes, so an answer stands until either branch moves.
    private final class KnownMerges: @unchecked Sendable {
        private let lock = NSLock()
        private var merges: [String: Merge] = [:]

        subscript(key: String) -> Merge? {
            get {
                lock.lock()
                defer { lock.unlock() }
                return merges[key]
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                // Answers for commits long gone would pile up over weeks; starting over costs one scan's checks.
                if merges.count > 10_000 { merges.removeAll() }
                merges[key] = newValue
            }
        }
    }

    private static let knownMerges = KnownMerges()

    /// For branches with commits the base lacks: whether each is in the base after all, as after a squash
    /// merge, or has no history in common with it. Merged means every file the branch changed or deleted
    /// since it left the base read, after some commit of the base's own line since, as the branch left it.
    /// Only reads, unlike a trial merge, which writes objects. A branch that touched over a thousand files,
    /// or one git cannot compare, as in a partial clone missing the trees, is left as not merged.
    private func merges(of candidates: [(ref: String, commit: String)], into base: Base, in repositoryURL: URL) throws -> [String: Merge] {
        var merges: [String: Merge] = [:]
        var pending: [(ref: String, key: String, commit: String, mergeBase: String, held: [String: String], wanted: [String: String], paths: Set<String>)] = []
        func settle(_ ref: String, _ key: String, _ merge: Merge) {
            merges[ref] = merge
            Self.knownMerges[key] = merge
        }
        for (ref, commit) in candidates {
            let key = "\(repositoryURL.path)\0\(commit)\0\(base.commit)"
            if let known = Self.knownMerges[key] {
                merges[ref] = known
                continue
            }
            guard let output = try git.optionalOutput(in: repositoryURL, ["merge-base", base.commit, commit]) else {
                // Not kept: a shallow clone, once deepened, may find the history in common with no commit moved.
                merges[ref] = .unrelated
                continue
            }
            let mergeBase = output.trimmingCharacters(in: .whitespacesAndNewlines)
            // Each file as the branch found it and as it left it: a deleted file is in held only, a new one in wanted only.
            let changed = try git.run(in: repositoryURL, ["diff-tree", "-r", "--raw", "--no-abbrev", "--no-renames", "-z", mergeBase, commit])
            guard changed.status == 0 else { continue }
            let changes = Self.rawCommits(changed.standardOutput)[0].changes
            var held: [String: String] = [:]
            var wanted: [String: String] = [:]
            for change in changes {
                held[change.path] = change.before
                wanted[change.path] = change.after
            }
            let paths = Set(changes.map(\.path))
            if paths.isEmpty {
                settle(ref, key, .squashed)
            } else if mergeBase == base.commit || paths.count > 1000 {
                // Nothing reached the base since the branch left it, or the branch is too big to compare.
                settle(ref, key, .open)
            } else {
                pending.append((ref, key, commit, mergeBase, held, wanted, paths))
            }
        }
        guard !pending.isEmpty else { return merges }

        // One walk of the base's own line serves every branch, from the oldest point any of them left it.
        // git log lists every change faster than it matches a thousand paths.
        let mergeBases = Array(Set(pending.map(\.mergeBase)))
        let oldest = mergeBases.count == 1
            ? mergeBases[0]
            : try git.optionalOutput(in: repositoryURL, ["merge-base", "--octopus"] + mergeBases)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every commit since, side branches too: a branch that left a side branch merged in later holds part of the line.
        let graph = try oldest.map { Self.graph(try git.data(in: repositoryURL, ["rev-list", "--parents", "-n", "100000", base.commit, "--not", $0])) }
        var length = 0
        var next = graph.map { _ in base.commit }
        while let commit = next, let parents = graph?[commit] {
            length += 1
            next = parents.first
        }
        var line: [(commit: String, parent: String?, changes: [Change])]?
        // A line too long to list whole is read per branch, for its files only.
        if let oldest, let graph, graph.count < 100_000, length <= 5000 {
            let walk = try git.run(in: repositoryURL, [
                "log", "--first-parent", "--diff-merges=first-parent", "--reverse", "--raw", "--no-abbrev", "--no-renames", "-z",
                "--format=%x01%H %P", base.commit, "--not", oldest
            ])
            if walk.status == 0 {
                // Only the files some branch changed are kept.
                let kept = pending.reduce(into: Set<String>()) { $0.formUnion($1.paths) }
                line = Self.rawCommits(walk.standardOutput, keeping: kept).dropFirst().compactMap { commit in
                    commit.header.first.map { ($0, commit.header.dropFirst().first, commit.changes) }
                }
            }
        }
        for branch in pending {
            let merged: Bool?
            if let line, let graph {
                // The part of the line the branch's start holds comes first; the base's work since is the rest.
                let left = Self.reachable(from: branch.mergeBase, in: graph)
                let start = line.prefix { left.contains($0.commit) }.count
                // The walk ends at the base's tip only for a branch that left from the line itself; another is
                // checked at the tip as well.
                let fromLine = (start == 0 ? line.first?.parent : line[start - 1].commit) == branch.mergeBase
                let reached = Self.reaches(branch.wanted, from: branch.held, through: line[start...].map(\.changes), paths: branch.paths)
                merged = reached || fromLine ? reached : try holdsAtTip(branch.commit, paths: branch.paths, base: base.commit, in: repositoryURL)
            } else {
                merged = try isSquashed(branch.commit, held: branch.held, wanted: branch.wanted, paths: branch.paths, since: branch.mergeBase, into: base.commit, in: repositoryURL)
            }
            if let merged { settle(branch.ref, branch.key, merged ? .squashed : .open) }
        }
        return merges
    }

    /// Whether the base's tip reads every one of `paths` as `branch` does; nil when git cannot compare.
    /// A failed or cancelled call throws, so no answer is kept from it.
    private func holdsAtTip(_ branch: String, paths: Set<String>, base: String, in repositoryURL: URL) throws -> Bool? {
        let result = try git.run(in: repositoryURL, ["diff-tree", "--quiet", "-r", base, branch, "--"] + paths.map { ":(literal)\($0)" })
        return result.status == 0 ? true : result.status == 1 ? false : nil
    }

    /// The check for one branch alone: the base's tip, then the base's line since the branch left it, read
    /// for the branch's files only. nil when git cannot compare.
    private func isSquashed(
        _ branch: String, held: [String: String], wanted: [String: String], paths: Set<String>,
        since mergeBase: String, into base: String, in repositoryURL: URL
    ) throws -> Bool? {
        guard let atTip = try holdsAtTip(branch, paths: paths, base: base, in: repositoryURL) else { return nil }
        if atTip { return true }
        // The base may have edited those files again since.
        let walk = try git.run(in: repositoryURL, [
            "log", "--first-parent", "--diff-merges=first-parent", "--reverse", "--raw", "--no-abbrev", "--no-renames", "-z",
            "--format=%x01", base, "--not", mergeBase, "--"
        ] + paths.map { ":(literal)\($0)" })
        guard walk.status == 0 else { return nil }
        let line = Self.rawCommits(walk.standardOutput).dropFirst().map(\.changes)
        return Self.reaches(wanted, from: held, through: line, paths: paths)
    }

    /// Whether files that start as `held` read as `wanted` after one of `commits`, applied in order.
    private static func reaches(
        _ wanted: [String: String], from held: [String: String], through commits: [[Change]], paths: Set<String>
    ) -> Bool {
        var held = held
        var differing = paths.filter { held[$0] != wanted[$0] }
        for changes in commits {
            for change in changes where paths.contains(change.path) {
                held[change.path] = change.after
                if held[change.path] == wanted[change.path] {
                    differing.remove(change.path)
                } else {
                    differing.insert(change.path)
                }
            }
            if differing.isEmpty { return true }
        }
        return false
    }

    /// A file before and after a change, as its mode and blob: making a script executable changes it too.
    private typealias Change = (before: String?, after: String?, path: String)

    /// `--raw -z` output in commits, where the format starts each with \u{1}, then its hash and parents;
    /// changes before any such start come first, under no header. A change is ":<old mode> <new mode>
    /// <old blob> <new blob> <status>", then the path. A blob of zeros, as on the missing side of an added
    /// or deleted file, reads as nil. With `kept`, changes to other paths are left out.
    private static func rawCommits(_ output: Data, keeping kept: Set<String>? = nil) -> [(header: [String], changes: [Change])] {
        output.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [(header: [String], changes: [Change])] in
            var commits: [(header: [String], changes: [Change])] = [([], [])]
            func text(_ field: Slice<UnsafeRawBufferPointer>) -> String { String(decoding: field, as: UTF8.self) }
            var change: Slice<UnsafeRawBufferPointer>?
            // Split by byte: by Character, the megabytes a long walk prints take a tenth of a second.
            for token in bytes.split(separator: 0, omittingEmptySubsequences: false) {
                if let fields = change.map({ $0.split(separator: UInt8(ascii: " ")) }) {
                    change = nil
                    let path = text(token)
                    guard fields.count == 5, kept?.contains(path) ?? true else { continue }
                    let file = { (mode: Slice<UnsafeRawBufferPointer>, blob: Slice<UnsafeRawBufferPointer>) in
                        blob.allSatisfy { $0 == UInt8(ascii: "0") } ? nil : text(mode) + " " + text(blob)
                    }
                    commits[commits.count - 1].changes.append((file(fields[0].dropFirst(), fields[2]), file(fields[1], fields[3]), path))
                    continue
                }
                let token = token.drop { $0 == UInt8(ascii: "\n") }
                if token.first == 1 {
                    commits.append((token.dropFirst().split(separator: UInt8(ascii: " ")).map(text), []))
                } else if token.first == UInt8(ascii: ":") {
                    // Its path is the next field, whatever it holds.
                    change = token
                }
            }
            return commits
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
            "stash", "list", "--pretty=format:%gd%x1F%H%x1F%gs%x1F%cI%x1F%P%x1E"
        ])
        return try Self.records(output).map { record in
            let fields = Self.fields(record)
            guard fields.count >= 5, let date = Self.date(from: fields[3]) else { throw Self.parseError(record) }
            // The first parent is the commit the stash was made on.
            let base = fields[4].split(separator: " ").first.map(String.init)
            return StashSnapshot(name: fields[0], hash: fields[1], message: fields[2], date: date, base: base)
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
