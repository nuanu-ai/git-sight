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

    static func branchesWithoutWorktrees(_ count: Int) -> String {
        counted(count, one: "ветка без ворктри", few: "ветки без ворктри", many: "веток без ворктри")
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
    var shortSignal: String {
        let signals = issueSignals
        if signals.isEmpty { return "всё чисто" }
        return signals.prefix(2).joined(separator: " · ")
    }

    var fullReason: String {
        let signals = issueSignals
        if signals.isEmpty { return "Заброшенной работы нет." }
        return signals.joined(separator: " · ")
    }

    private var issueSignals: [String] {
        var signals: [String] = []
        if dirtyFileCount > 0 {
            signals.append("незакоммичено: \(RepositoryText.files(dirtyFileCount))")
        }
        if ahead > 0 { signals.append("upstream +\(ahead)") }
        if behind > 0 { signals.append("upstream −\(behind)") }
        let additionalWorktrees = worktrees.filter { !$0.isMain }
        if !additionalWorktrees.isEmpty {
            signals.append("\(additionalWorktrees.count) ворктри")
        }
        let looseBranches = branches.filter { !$0.hasWorktree }
        if !looseBranches.isEmpty {
            signals.append(RepositoryText.branchesWithoutWorktrees(looseBranches.count))
        }
        if let oldestStash = stashes.min(by: { $0.date < $1.date }) {
            signals.append("стэш \(RepositoryText.relative(oldestStash.date))")
        }
        return signals
    }
}
