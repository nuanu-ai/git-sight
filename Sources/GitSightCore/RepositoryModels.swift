import Foundation

public enum Severity: String, Equatable {
    case clean
    case attention
    case warning
    case critical
}

public struct WorktreeSnapshot: Equatable {
    public let path: URL
    public let name: String
    public let branch: String?
    public let isMain: Bool
    public let dirtyFileCount: Int
    public let lastActivity: Date?
    public let behind: Int

    public init(path: URL, name: String, branch: String?, isMain: Bool, dirtyFileCount: Int, lastActivity: Date?, behind: Int = 0) {
        self.path = path
        self.name = name
        self.branch = branch
        self.isMain = isMain
        self.dirtyFileCount = dirtyFileCount
        self.lastActivity = lastActivity
        self.behind = behind
    }
}

public struct BranchSnapshot: Equatable {
    public let name: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let lastCommitDate: Date?
    public let hasWorktree: Bool

    public init(name: String, upstream: String?, ahead: Int, behind: Int, lastCommitDate: Date?, hasWorktree: Bool) {
        self.name = name
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.lastCommitDate = lastCommitDate
        self.hasWorktree = hasWorktree
    }
}

public struct StashSnapshot: Equatable {
    public let name: String
    public let message: String
    public let date: Date

    public init(name: String, message: String, date: Date) {
        self.name = name
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
    public let refs: [String]
    public let lane: Int

    public init(fullHash: String, shortHash: String, subject: String, author: String, date: Date, parents: [String], refs: [String], lane: Int) {
        self.fullHash = fullHash
        self.shortHash = shortHash
        self.subject = subject
        self.author = author
        self.date = date
        self.parents = parents
        self.refs = refs
        self.lane = lane
    }
}

public struct CommitEdge: Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
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
    public let commits: [CommitSnapshot]
    public let edges: [CommitEdge]
    public let remoteWebURL: URL?
    public let lastActivity: Date?
    public let score: Int
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
        commits: [CommitSnapshot] = [],
        edges: [CommitEdge] = [],
        remoteWebURL: URL? = nil,
        lastActivity: Date? = nil,
        score: Int = 0,
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
        self.commits = commits
        self.edges = edges
        self.remoteWebURL = remoteWebURL
        self.lastActivity = lastActivity
        self.score = score
        self.severity = severity
    }
}
