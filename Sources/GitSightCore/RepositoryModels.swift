import Foundation

public enum Severity: Int, Comparable {
    /// Nothing exists only on this machine.
    case clean
    /// Work in progress, or a repository with no remote at all.
    case attention
    /// Unsaved work untouched long enough to count as abandoned.
    case warning
    /// Abandoned for over a month.
    case critical

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct WorktreeSnapshot: Equatable {
    public let path: URL
    public let name: String
    public let branch: String?
    public let isMain: Bool
    public let dirtyFileCount: Int
    /// Latest modification among uncommitted files.
    public let dirtyModifiedAt: Date?
    public let lastActivity: Date?
    public let behind: Int
    /// Commits on a detached HEAD that no branch or remote contains.
    public let unpushedCommits: Int

    public init(
        path: URL,
        name: String,
        branch: String?,
        isMain: Bool,
        dirtyFileCount: Int,
        dirtyModifiedAt: Date? = nil,
        lastActivity: Date?,
        behind: Int = 0,
        unpushedCommits: Int = 0
    ) {
        self.path = path
        self.name = name
        self.branch = branch
        self.isMain = isMain
        self.dirtyFileCount = dirtyFileCount
        self.dirtyModifiedAt = dirtyModifiedAt
        self.lastActivity = lastActivity
        self.behind = behind
        self.unpushedCommits = unpushedCommits
    }
}

public struct BranchSnapshot: Equatable {
    public let name: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let lastCommitDate: Date?
    public let hasWorktree: Bool
    /// Commits on this branch that no remote-tracking ref contains.
    public let unpushedCommits: Int
    /// The upstream was deleted on the server, usually after its pull request was merged.
    public let upstreamGone: Bool
    /// The branch work is merged into: the server's default branch, or the local main without a server.
    public let isBase: Bool
    /// Commits the base does not have. A branch squash-merged into the base counts as merged: zero.
    public let unmergedCommits: Int
    /// No history in common with the base, like a gh-pages branch: neither merged nor unfinished.
    public let isUnrelated: Bool

    public init(
        name: String,
        upstream: String?,
        ahead: Int,
        behind: Int,
        lastCommitDate: Date?,
        hasWorktree: Bool,
        unpushedCommits: Int = 0,
        upstreamGone: Bool = false,
        isBase: Bool = false,
        unmergedCommits: Int = 0,
        isUnrelated: Bool = false
    ) {
        self.name = name
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.lastCommitDate = lastCommitDate
        self.hasWorktree = hasWorktree
        self.unpushedCommits = unpushedCommits
        self.upstreamGone = upstreamGone
        self.isBase = isBase
        self.unmergedCommits = unmergedCommits
        self.isUnrelated = isUnrelated
    }
}

public struct StashSnapshot: Equatable {
    public let name: String
    /// Unlike `name`, stays with this stash when another one is pushed.
    public let hash: String
    public let message: String
    public let date: Date

    public init(name: String, hash: String, message: String, date: Date) {
        self.name = name
        self.hash = hash
        self.message = message
        self.date = date
    }
}

public struct CommitSnapshot: Equatable {
    public let fullHash: String
    public let shortHash: String
    public let subject: String
    public let author: String
    public let date: Date
    public let parents: [String]
    public internal(set) var refs: [CommitRef]
    public let lane: Int
    /// The lane each parent's line runs down, in `parents` order. A lane stays held
    /// for its parent until the parent's row, so a line drawn down it crosses no other commit.
    public let parentLanes: [Int]
    /// The commit is outside the requested range and only marks where it starts, e.g. the fork point.
    public let isBoundary: Bool
    /// On no remote-tracking branch; set only in the history of a whole repository that has a remote.
    public internal(set) var isUnpushed = false

    public init(
        fullHash: String,
        shortHash: String,
        subject: String,
        author: String,
        date: Date,
        parents: [String],
        refs: [CommitRef],
        lane: Int,
        parentLanes: [Int] = [],
        isBoundary: Bool = false
    ) {
        self.fullHash = fullHash
        self.shortHash = shortHash
        self.subject = subject
        self.author = author
        self.date = date
        self.parents = parents
        self.refs = refs
        self.lane = lane
        self.parentLanes = parentLanes
        self.isBoundary = isBoundary
    }
}

/// A branch or tag that points at a commit.
public struct CommitRef: Hashable {
    public enum Kind: Hashable {
        case branch
        case remoteBranch
        case tag
        /// A detached HEAD.
        case head
        /// A linked worktree on no branch, named by its folder.
        case worktree
    }

    public let kind: Kind
    /// Short name, e.g. "main", "origin/main", "v1.0".
    public let name: String
    /// The branch HEAD is on.
    public let isHead: Bool

    public init(kind: Kind, name: String, isHead: Bool = false) {
        self.kind = kind
        self.name = name
        self.isHead = isHead
    }
}

/// One line of a unified diff, numbered on the side or sides it exists on.
public struct DiffLine: Equatable {
    public enum Kind: Equatable {
        /// "@@ -1,3 +1,4 @@", where a run of changes starts.
        case hunk
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let oldLine: Int?
    public let newLine: Int?
    public let text: String

    public init(kind: Kind, oldLine: Int?, newLine: Int?, text: String) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

public struct FileDiff: Equatable {
    public let lines: [DiffLine]
    public let isBinary: Bool
    /// Cut at `RepositoryInspector.diffLineLimit` lines.
    public let isTruncated: Bool

    public init(lines: [DiffLine], isBinary: Bool = false, isTruncated: Bool = false) {
        self.lines = lines
        self.isBinary = isBinary
        self.isTruncated = isTruncated
    }
}

public struct CommitFileSnapshot: Equatable {
    public let status: String
    public let path: String

    public init(status: String, path: String) {
        self.status = status
        self.path = path
    }
}

public struct RepositorySnapshot: Equatable {
    public let path: URL
    public let name: String
    public let currentBranch: String?
    public let ahead: Int
    public let behind: Int
    public let dirtyFileCount: Int
    public let worktrees: [WorktreeSnapshot]
    public let branches: [BranchSnapshot]
    public let stashes: [StashSnapshot]
    public let remoteWebURL: URL?
    public let lastActivity: Date?
    public let hasRemote: Bool
    /// The branch work is merged into, e.g. "main"; nil when the repository has none to tell.
    public let baseBranch: String?
    /// Date of the oldest work that exists only on this machine.
    public let oldestUnsavedWork: Date?
    public let severity: Severity

    public init(
        dirtyFileCount: Int,
        path: URL = URL(fileURLWithPath: ""),
        name: String = "",
        currentBranch: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        worktrees: [WorktreeSnapshot] = [],
        branches: [BranchSnapshot] = [],
        stashes: [StashSnapshot] = [],
        remoteWebURL: URL? = nil,
        lastActivity: Date? = nil,
        hasRemote: Bool = true,
        baseBranch: String? = nil,
        oldestUnsavedWork: Date? = nil,
        severity: Severity = .clean
    ) {
        self.path = path
        self.name = name
        self.currentBranch = currentBranch
        self.ahead = ahead
        self.behind = behind
        self.dirtyFileCount = dirtyFileCount
        self.worktrees = worktrees
        self.branches = branches
        self.stashes = stashes
        self.remoteWebURL = remoteWebURL
        self.lastActivity = lastActivity
        self.hasRemote = hasRemote
        self.baseBranch = baseBranch
        self.oldestUnsavedWork = oldestUnsavedWork
        self.severity = severity
    }
}
