import Foundation

enum RepositoryScore {
    static let abandonedAge: TimeInterval = 3 * 24 * 60 * 60
    static let abandonedStashAge: TimeInterval = 24 * 60 * 60
    static let criticalAge: TimeInterval = 30 * 24 * 60 * 60
    /// A branch deleted on the server is most likely merged: a notice for two weeks, then leftover.
    static let goneUpstreamAge: TimeInterval = 14 * 24 * 60 * 60
    /// Unfinished work on the server is in progress this long, as is a merged leftover before it counts as clutter.
    static let unfinishedAge: TimeInterval = 14 * 24 * 60 * 60
    static let unfinishedCriticalAge: TimeInterval = 60 * 24 * 60 * 60

    /// Rates work that exists only on this machine by how long it has been left alone.
    static func evaluate(
        hasRemote: Bool,
        hasBase: Bool = false,
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
        // Branches the server has but the base does not: unfinished, or merged and left behind.
        // Unpushed ones are counted above already; a repository without a server gets its one notice instead.
        if hasRemote, hasBase {
            for branch in branches where !branch.isBase && !branch.isUnrelated && branch.unpushedCommits == 0 {
                work.append((branch.lastCommitDate ?? now, branch.unmergedCommits > 0 ? .unmerged : .leftover))
            }
        }

        // The repository is as bad as its worst piece of work; a merged branch within its cleanup lag is no work.
        let rated = work.map { (date: $0.date, severity: Severity(of: $0.kind, lastChanged: $0.date, now: now)) }
        let worst = rated.map(\.severity).max()
        return (worst ?? (hasRemote ? .clean : .attention), rated.filter { $0.severity > .clean }.map(\.date).min())
    }
}

/// A piece of work at risk: it exists only on this machine, or it never made it into the base branch.
public enum UnsavedWork: Equatable {
    case uncommitted
    /// Commits on no remote; `upstreamGone` when the branch's upstream was deleted on the server.
    case commits(upstreamGone: Bool)
    case stash
    /// A branch on the server that was never merged into the base: unfinished work that goes stale.
    case unmerged
    /// A branch already merged, or a worktree with nothing of its own: clutter to clean up.
    case leftover
}

extension Severity {
    /// How bad one piece of unsaved work is, by how long it has been left alone.
    public init(of work: UnsavedWork, lastChanged: Date, now: Date = Date()) {
        let age = now.timeIntervalSince(lastChanged)
        switch work {
        case .unmerged:
            self = age <= RepositoryScore.unfinishedAge ? .attention : age > RepositoryScore.unfinishedCriticalAge ? .critical : .warning
            return
        case .leftover:
            // Nothing is lost, so clutter never becomes forgotten work.
            self = age <= RepositoryScore.unfinishedAge ? .clean : .warning
            return
        case .uncommitted, .commits, .stash:
            break
        }
        let abandonedAfter: TimeInterval
        switch work {
        case .uncommitted, .commits(upstreamGone: false):
            abandonedAfter = RepositoryScore.abandonedAge
        case .commits(upstreamGone: true):
            // Squash merges leave exactly this: commits on no remote, upstream deleted.
            // Reachability cannot tell that from lost work, so it never becomes critical.
            abandonedAfter = RepositoryScore.goneUpstreamAge
        case .stash, .unmerged, .leftover:
            abandonedAfter = RepositoryScore.abandonedStashAge
        }
        if age <= abandonedAfter {
            self = .attention
        } else if age > RepositoryScore.criticalAge, work != .commits(upstreamGone: true) {
            self = .critical
        } else {
            self = .warning
        }
    }
}

/// The newest thing that happened in a repository, for watching work as it goes.
public struct RecentChange: Equatable {
    public enum Kind: Equatable {
        case uncommitted(files: Int)
        case commit
        case stash
    }

    public let date: Date
    /// The branch or worktree it happened in; nil for a stash.
    public let place: String?
    public let kind: Kind

    public init(date: Date, place: String?, kind: Kind) {
        self.date = date
        self.place = place
        self.kind = kind
    }
}

extension RepositorySnapshot {
    public var latestChange: RecentChange? {
        var latest: RecentChange?
        func consider(_ date: Date?, _ place: String?, _ kind: RecentChange.Kind) {
            guard let date, date > (latest?.date ?? .distantPast) else { return }
            latest = RecentChange(date: date, place: place, kind: kind)
        }
        for worktree in worktrees {
            let place = worktree.isMain ? (worktree.branch ?? "detached HEAD") : worktree.name
            // dirtyModifiedAt is nil when nothing is uncommitted.
            consider(worktree.dirtyModifiedAt, place, .uncommitted(files: worktree.dirtyFileCount))
            consider(worktree.lastActivity, place, .commit)
        }
        for branch in branches {
            consider(branch.lastCommitDate, branch.name, .commit)
        }
        for stash in stashes {
            consider(stash.date, nil, .stash)
        }
        return latest
    }
}
