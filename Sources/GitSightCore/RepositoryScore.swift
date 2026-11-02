import Foundation

enum RepositoryScore {
    static let warningThreshold = 40
    static let criticalThreshold = 80
    static let abandonedBranchAge: TimeInterval = 3 * 24 * 60 * 60
    static let abandonedWorktreeAge: TimeInterval = 3 * 24 * 60 * 60
    static let abandonedStashAge: TimeInterval = 24 * 60 * 60

    static func evaluate(
        dirtyFileCount: Int,
        behind: Int,
        worktrees: [WorktreeSnapshot],
        branches: [BranchSnapshot],
        stashes: [StashSnapshot]
    ) -> (score: Int, severity: Severity) {
        var score = 0
        if dirtyFileCount > 0, behind > 0 {
            score += 50 + min(behind * 5, 20)
        }
        for branch in branches {
            let isUnpublished = branch.upstream == nil
            guard isUnpublished || branch.ahead > 0,
                  let date = branch.lastCommitDate,
                  -date.timeIntervalSinceNow > abandonedBranchAge else { continue }
            score += 40
        }
        for worktree in worktrees where !worktree.isMain {
            if worktree.dirtyFileCount > 0, worktree.behind > 0 {
                score += 50 + min(worktree.behind * 5, 20)
            } else if worktree.dirtyFileCount == 0,
                      let date = worktree.lastActivity,
                      -date.timeIntervalSinceNow > abandonedWorktreeAge {
                score += 30
            }
        }
        for stash in stashes where -stash.date.timeIntervalSinceNow > abandonedStashAge {
            score += 50
        }
        score = min(score, 100)

        let severity: Severity
        if score >= criticalThreshold {
            severity = .critical
        } else if score >= warningThreshold {
            severity = .warning
        } else if score > 0 {
            severity = .attention
        } else {
            severity = .clean
        }
        return (score, severity)
    }
}
