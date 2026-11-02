import Foundation

enum RepositoryScore {
    static let warningThreshold = 40
    static let criticalThreshold = 80
    static let oldObjectAge: TimeInterval = 30 * 24 * 60 * 60
    static let veryOldObjectAge: TimeInterval = 90 * 24 * 60 * 60

    static func evaluate(
        dirtyFileCount: Int,
        behind: Int,
        branches: [BranchSnapshot],
        stashes: [StashSnapshot]
    ) -> (score: Int, severity: Severity) {
        var score = 0
        if dirtyFileCount > 0, behind > 0 {
            score += 50 + min(behind * 5, 20)
        }
        for branch in branches {
            let isUnpublished = branch.upstream == nil && branch.name != "main" && branch.name != "master"
            guard isUnpublished || branch.ahead > 0 else { continue }
            score += 20 + min(branch.ahead * 5, 20)
            if let date = branch.lastCommitDate, -date.timeIntervalSinceNow > oldObjectAge {
                score += 10
            }
        }
        for stash in stashes {
            let age = -stash.date.timeIntervalSinceNow
            if age > oldObjectAge { score += 25 }
            if age > veryOldObjectAge { score += 25 }
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
