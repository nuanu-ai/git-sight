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

    init(kind: Kind, amount: Int, date: Date, stash: StashSnapshot? = nil, upstreamGone: Bool = false) {
        self.kind = kind
        self.amount = amount
        self.date = date
        self.stash = stash
        self.upstreamGone = upstreamGone
    }

    public func verdict(now: Date = Date()) -> Verdict {
        let work: UnsavedWork
        switch kind {
        case .leftover: return .clutter
        case .uncommitted: work = .uncommitted
        case .detached: work = .commits(upstreamGone: false)
        case .unpushed: work = .commits(upstreamGone: upstreamGone)
        case .stash: work = .stash
        case .unmerged: work = .unmerged
        }
        switch Severity(of: work, lastChanged: date, now: now) {
        case .clean, .attention: return .inProgress
        case .warning: return .abandoned
        case .critical: return .forgotten
        }
    }

    /// How much this piece weighs: its size, growing slowly with age, by how much is at risk.
    /// Work that exists only here counts whole; work on the server a third; a merged leftover a fifth.
    public func weight(now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(date)) / 86_400
        let risk = kind == .unmerged ? 0.3 : kind == .leftover ? 0.2 : 1
        return Double(amount) * (1 + log2(1 + days / 3)) * risk
    }
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

    public func weight(now: Date = Date()) -> Double {
        pieces.reduce(0) { $0 + $1.weight(now: now) }
    }

    public func lead(now: Date = Date()) -> WorkPiece? {
        Self.lead(of: pieces, now: now)
    }

    /// The worst piece; of equally bad ones, the oldest.
    static func lead(of pieces: [WorkPiece], now: Date) -> WorkPiece? {
        pieces.max { lhs, rhs in
            let (left, right) = (lhs.verdict(now: now), rhs.verdict(now: now))
            return left != right ? left < right : lhs.date > rhs.date
        }
    }
}

extension RepositorySnapshot {
    /// Every worktree first (the main worktree first, then linked ones in snapshot order), each with its branch's work;
    /// then branches not checked out anywhere that hold any piece, by name; then one place per deleted branch whose
    /// stashes remain (and one for stashes made on no branch), by name.
    public var places: [WorkPlace] {
        let now = Date()
        // Without a server or a base there is nothing to merge into; inspect gives the repository one notice instead.
        let merge = hasRemote && baseBranch != nil ? RepositoryScore.mergeWork(branches: branches, worktrees: worktrees) : []
        func pieces(worktree: WorktreeSnapshot?, branch: BranchSnapshot?, stashes: [StashSnapshot]) -> [WorkPiece] {
            var pieces: [WorkPiece] = []
            if let worktree, worktree.dirtyFileCount > 0 {
                pieces.append(WorkPiece(kind: .uncommitted, amount: worktree.dirtyFileCount, date: worktree.dirtyModifiedAt ?? worktree.lastActivity ?? now))
            }
            if let worktree, worktree.unpushedCommits > 0 {
                pieces.append(WorkPiece(kind: .detached, amount: worktree.unpushedCommits, date: worktree.lastActivity ?? now))
            }
            if let branch, hasRemote, branch.unpushedCommits > 0 {
                pieces.append(WorkPiece(kind: .unpushed, amount: branch.unpushedCommits, date: branch.lastCommitDate ?? now, upstreamGone: branch.upstreamGone))
            }
            let kind = branch.flatMap { branch in merge.first { $0.branch.name == branch.name }?.kind }
            if let branch, kind == .unmerged {
                pieces.append(WorkPiece(kind: .unmerged, amount: branch.unmergedCommits, date: branch.lastCommitDate ?? now))
            }
            pieces += stashes.map { WorkPiece(kind: .stash, amount: 1, date: $0.date, stash: $0) }
            // A merged branch within the usual cleanup lag is no work yet, as in leftoverBranches.
            if let branch, kind == .leftover, Severity(of: .leftover, lastChanged: branch.lastCommitDate ?? now, now: now) > .clean {
                pieces.append(WorkPiece(kind: .leftover, amount: 1, date: branch.lastCommitDate ?? now))
            }
            return pieces
        }

        // `git stash list` lists the newest first.
        let stashesByBranch = Dictionary(grouping: stashes, by: \.branch)
        var placed: Set<String?> = []
        var places: [WorkPlace] = []
        for worktree in worktrees.filter(\.isMain) + worktrees.filter({ !$0.isMain }) {
            let name = worktree.branch
            let branch = branches.first { $0.name == name }
            // Two worktrees hold one branch only when forced to; its commits and stashes are counted under the first.
            let first = name.map { placed.insert($0).inserted } ?? false
            let work = pieces(worktree: worktree, branch: first ? branch : nil, stashes: first ? stashesByBranch[name] ?? [] : [])
            places.append(WorkPlace(worktree: worktree, branch: branch, branchName: name, pieces: work))
        }
        for branch in branches.sorted(by: { $0.name < $1.name }) where !placed.contains(branch.name) {
            placed.insert(branch.name)
            let work = pieces(worktree: nil, branch: branch, stashes: stashesByBranch[branch.name] ?? [])
            if !work.isEmpty {
                places.append(WorkPlace(worktree: nil, branch: branch, branchName: branch.name, pieces: work))
            }
        }
        let deleted = stashesByBranch.keys.compactMap { $0 }.filter { !placed.contains($0) }.sorted()
        for name in deleted {
            places.append(WorkPlace(worktree: nil, branch: nil, branchName: name, pieces: pieces(worktree: nil, branch: nil, stashes: stashesByBranch[name] ?? [])))
        }
        if let stashes = stashesByBranch[nil] {
            places.append(WorkPlace(worktree: nil, branch: nil, branchName: nil, pieces: pieces(worktree: nil, branch: nil, stashes: stashes)))
        }
        return places
    }

    public func weight(now: Date = Date()) -> Double {
        places.reduce(0) { $0 + $1.weight(now: now) }
    }

    public func lead(now: Date = Date()) -> WorkPiece? {
        WorkPlace.lead(of: places.flatMap(\.pieces), now: now)
    }
}
