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
        var work: [(date: Date, kind: UnsavedWork)] = []
        // Without a remote every commit is local by choice; the repository gets one notice instead.
        if hasRemote {
            for branch in branches where branch.unpushedCommits > 0 {
                work.append((branch.lastCommitDate ?? now, .commits(upstreamGone: branch.upstreamGone)))
            }
        }
        for worktree in worktrees {
            if worktree.dirtyFileCount > 0 {
                work.append((worktree.dirtyModifiedAt ?? worktree.lastActivity ?? now, .uncommitted))
            }
            if worktree.unpushedCommits > 0 {
                work.append((worktree.lastActivity ?? now, .commits(upstreamGone: false)))
            }
        }
        for stash in stashes {
            work.append((stash.date, .stash))
        }

        // The repository is as bad as its worst piece of work.
        let worst = work.map { Severity(of: $0.kind, lastChanged: $0.date, now: now) }.max()
        return (worst ?? (hasRemote ? .clean : .attention), work.map(\.date).min())
    }
}

/// A piece of work that exists only on this machine.
public enum UnsavedWork: Equatable {
    case uncommitted
    /// Commits on no remote; `upstreamGone` when the branch's upstream was deleted on the server.
    case commits(upstreamGone: Bool)
    case stash
}

extension Severity {
    /// How bad one piece of unsaved work is, by how long it has been left alone.
    public init(of work: UnsavedWork, lastChanged: Date, now: Date = Date()) {
        let abandonedAfter: TimeInterval
        switch work {
        case .uncommitted, .commits(upstreamGone: false):
            abandonedAfter = RepositoryScore.abandonedAge
        case .commits(upstreamGone: true):
            // Squash merges leave exactly this: commits on no remote, upstream deleted.
            // Reachability cannot tell that from lost work, so it stays a notice.
            abandonedAfter = .infinity
        case .stash:
            abandonedAfter = RepositoryScore.abandonedStashAge
        }
        let age = now.timeIntervalSince(lastChanged)
        if age <= abandonedAfter {
            self = .attention
        } else if age > RepositoryScore.criticalAge {
            self = .critical
        } else {
            self = .warning
        }
    }
}
