import Foundation
import GitSightCore

enum RepositoryText {
    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .short
        return formatter
    }()

    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        return relative(date)
    }

    /// "3 дня", "2 месяца": how long work has been left, without "назад".
    static func age(_ date: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.calendar?.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute]
        return formatter.string(from: date, to: Date()) ?? "—"
    }

    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    static func files(_ count: Int) -> String {
        counted(count, one: "файл", few: "файла", many: "файлов")
    }

    static func commits(_ count: Int) -> String {
        counted(count, one: "коммит", few: "коммита", many: "коммитов")
    }

    static func repositories(_ count: Int) -> String {
        counted(count, one: "репозиторий", few: "репозитория", many: "репозиториев")
    }

    static func branches(_ count: Int) -> String {
        counted(count, one: "ветка", few: "ветки", many: "веток")
    }

    static func stashes(_ count: Int) -> String {
        counted(count, one: "стэш", few: "стэша", many: "стэшей")
    }

    static func path(_ url: URL) -> String {
        NSString(string: url.path).abbreviatingWithTildeInPath
    }

    private static func counted(
        _ value: Int,
        one: String,
        few: String,
        many: String
    ) -> String {
        let remainder100 = value % 100
        let remainder10 = value % 10
        let word: String
        if (11...14).contains(remainder100) {
            word = many
        } else if remainder10 == 1 {
            word = one
        } else if (2...4).contains(remainder10) {
            word = few
        } else {
            word = many
        }
        return "\(value) \(word)"
    }
}

extension RepositorySnapshot {
    var unpushedBranches: [BranchSnapshot] {
        hasRemote ? branches.filter { $0.unpushedCommits > 0 } : []
    }

    var dirtyWorktrees: [WorktreeSnapshot] {
        worktrees.filter { $0.dirtyFileCount > 0 }
    }

    var detachedWorktrees: [WorktreeSnapshot] {
        worktrees.filter { $0.unpushedCommits > 0 }
    }

    /// Without unsaved work, attention can only mean the repository has no remote.
    var statusLabel: String {
        severity == .attention && oldestUnsavedWork == nil ? "без remote" : severity.label
    }

    var shortSignal: String {
        let signals = issueSignals
        if signals.isEmpty { return "всё на сервере" }
        return signals.prefix(2).joined(separator: " · ")
    }

    var fullReason: String {
        let signals = issueSignals
        if signals.isEmpty { return "Всё, что есть локально, есть и на сервере." }
        var reason = signals.joined(separator: " · ")
        if let oldestUnsavedWork {
            reason += " · самому старому \(RepositoryText.age(oldestUnsavedWork))"
        }
        return reason
    }

    private var issueSignals: [String] {
        var signals: [String] = []
        let dirtyCount = dirtyWorktrees.reduce(0) { $0 + $1.dirtyFileCount }
        if dirtyCount > 0 {
            signals.append("не закоммичено: \(RepositoryText.files(dirtyCount))")
        }
        let unpushedCount = unpushedBranches.count + detachedWorktrees.count
        if unpushedCount > 0 {
            signals.append("не запушено: \(RepositoryText.branches(unpushedCount))")
        }
        if !stashes.isEmpty {
            signals.append(RepositoryText.stashes(stashes.count))
        }
        if !hasRemote {
            signals.append("нет remote")
        }
        return signals
    }
}
