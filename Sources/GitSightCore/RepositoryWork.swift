import Foundation

/// How bad one piece of work is, as the list says it.
public enum Verdict: Int, Comparable {
    /// Merged and left behind: nothing is lost.
    case clutter
    case inProgress
    case abandoned
    case forgotten

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One piece of work in a place: files, commits, a stash, or a branch left behind.
public struct WorkPiece: Equatable {
    public enum Kind: Equatable { case uncommitted, unpushed, detached, stash, unmerged, leftover }

    public let kind: Kind
    /// Files for uncommitted work; commits for unpushed, detached and unmerged; 1 for a stash or a leftover.
    public let amount: Int
    /// When the work last changed.
    public let date: Date
    /// The stash, for .stash.
    public let stash: StashSnapshot?
    /// For .unpushed: the branch's upstream was deleted on the server (likely squash-merged).
    public let upstreamGone: Bool

    public func verdict(now: Date = Date()) -> Verdict { .inProgress }

    public func weight(now: Date = Date()) -> Double { 0 }
}

/// Where work sits: a worktree with the branch checked out in it, a branch not checked out, or what is left of a deleted branch.
public struct WorkPlace: Equatable {
    /// The worktree, for a place in the "Worktrees" section.
    public let worktree: WorktreeSnapshot?
    /// The local branch: the one checked out in the worktree, or a branch not checked out anywhere.
    public let branch: BranchSnapshot?
    /// The branch's name, or for a stash whose branch no longer exists, that deleted branch's name.
    /// Nil for a worktree on a detached HEAD and for stashes made on no branch.
    public let branchName: String?
    /// In this order: uncommitted, detached, unpushed, unmerged, stashes newest first, leftover.
    public let pieces: [WorkPiece]

    public func weight(now: Date = Date()) -> Double { 0 }

    public func lead(now: Date = Date()) -> WorkPiece? { nil }
}

extension RepositorySnapshot {
    /// Every worktree first (the main worktree first, then linked ones in snapshot order), each with its branch's work;
    /// then branches not checked out anywhere that hold any piece, by name; then one place per deleted branch whose
    /// stashes remain (and one for stashes made on no branch), by name.
    public var places: [WorkPlace] { [] }

    public func weight(now: Date = Date()) -> Double { 0 }

    public func lead(now: Date = Date()) -> WorkPiece? { nil }
}
