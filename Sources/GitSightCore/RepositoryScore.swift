import Foundation

enum RepositoryScore {
    static let abandonedAge: TimeInterval = 3 * 24 * 60 * 60
    static let abandonedStashAge: TimeInterval = 24 * 60 * 60
    static let criticalAge: TimeInterval = 30 * 24 * 60 * 60

    /// Rates work that exists only on this machine by how long it has been left alone.
    static func evaluate(
        hasRemote: Bool,
        worktrees: [WorktreeSnapshot],
        branches: [BranchSnapshot],
        stashes: [StashSnapshot],
        now: Date = Date()
    ) -> (severity: Severity, oldestUnsavedWork: Date?) {
        var work: [(date: Date, abandonedAfter: TimeInterval)] = []
        // Without a remote every commit is local by choice; the repository gets one notice instead.
        if hasRemote {
            for branch in branches where branch.unpushedCommits > 0 {
                // Squash merges leave exactly this: commits on no remote, upstream deleted.
                // Reachability cannot tell that from lost work, so it stays a notice.
                work.append((branch.lastCommitDate ?? now, branch.upstreamGone ? .infinity : abandonedAge))
            }
        }
        for worktree in worktrees {
            if worktree.dirtyFileCount > 0 {
                work.append((worktree.dirtyModifiedAt ?? worktree.lastActivity ?? now, abandonedAge))
            }
            if worktree.unpushedCommits > 0 {
                work.append((worktree.lastActivity ?? now, abandonedAge))
            }
        }
        for stash in stashes {
            work.append((stash.date, abandonedStashAge))
        }

        let abandonedAges = work
            .map { (age: now.timeIntervalSince($0.date), abandonedAfter: $0.abandonedAfter) }
            .filter { $0.age > $0.abandonedAfter }
            .map(\.age)
        let severity: Severity
        if abandonedAges.contains(where: { $0 > criticalAge }) {
            severity = .critical
        } else if !abandonedAges.isEmpty {
            severity = .warning
        } else if !work.isEmpty || !hasRemote {
            severity = .attention
        } else {
            severity = .clean
        }
        return (severity, work.map(\.date).min())
    }
}
