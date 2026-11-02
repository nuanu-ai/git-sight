import Foundation
import GitSightCore
import SwiftUI

enum RepositoryText {
    private static let locale = Locale(identifier: "ru_RU")

    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// How long ago, without "назад": "8 месяцев", or "8 мес" when `short`.
    static func age(_ date: Date?, short: Bool = false) -> String {
        guard let date else { return "—" }
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "сейчас" }
        if short {
            // The system's abbreviated Russian units turn both minutes and months into "м.".
            let minutes = Int(seconds / 60), hours = minutes / 60, days = hours / 24
            if hours < 1 { return "\(minutes) мин" }
            if days < 1 { return "\(hours) ч" }
            if days < 7 { return "\(days) дн" }
            if days < 30 { return "\(days / 7) нед" }
            if days < 365 { return "\(days / 30) мес" }
            return "\(days / 365) г"
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute]
        return formatter.string(from: date, to: Date()) ?? "—"
    }

    /// "8 месяцев назад", or "только что" within the first minute.
    static func ago(_ date: Date?) -> String {
        guard let date else { return "—" }
        return Date().timeIntervalSince(date) < 60 ? "только что" : "\(age(date)) назад"
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

    static func path(_ url: URL) -> String {
        NSString(string: url.path).abbreviatingWithTildeInPath
    }

    private static func counted(_ value: Int, one: String, few: String, many: String) -> String {
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

extension Severity {
    var color: Color {
        switch self {
        case .clean: return .green
        case .attention: return .yellow
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var title: String {
        switch self {
        case .clean: return "Чисто"
        case .attention: return "В работе"
        case .warning: return "Заброшено"
        case .critical: return "Забыто"
        }
    }
}

/// One piece of work that exists only on this machine.
struct Finding: Identifiable, Hashable {
    enum Kind: Hashable {
        case uncommitted
        case branch
        case detached
        case stash
    }

    /// Where the detail column reads this finding from.
    enum Source: Hashable {
        case history(directory: URL, revisions: [String])
        case uncommitted(worktree: URL)
        case stash(directory: URL, name: String)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let note: String?
    let date: Date?
    let location: URL
    let source: Source

    var systemImage: String {
        switch kind {
        case .uncommitted: return "pencil.line"
        case .branch: return "arrow.triangle.branch"
        case .detached: return "point.topleft.down.to.point.bottomright.curvepath"
        case .stash: return "tray"
        }
    }
}

extension RepositorySnapshot {
    /// Oldest first: the longer work is left, the more likely it is forgotten.
    var findings: [Finding] {
        var findings: [Finding] = []
        for worktree in worktrees where worktree.dirtyFileCount > 0 {
            findings.append(Finding(
                id: "uncommitted:\(worktree.path.path)",
                kind: .uncommitted,
                title: worktree.isMain ? (worktree.branch ?? "основной чекаут") : worktree.name,
                detail: "не закоммичено: \(RepositoryText.files(worktree.dirtyFileCount))",
                note: worktree.isMain ? nil : "ворктри · \(worktree.branch ?? "detached HEAD")",
                date: worktree.dirtyModifiedAt ?? worktree.lastActivity,
                location: worktree.path,
                source: .uncommitted(worktree: worktree.path)
            ))
        }
        if hasRemote {
            for branch in branches where branch.unpushedCommits > 0 {
                findings.append(Finding(
                    // Branch and stash names repeat across repositories; worktree paths do not.
                    id: "\(path.path)|branch:\(branch.name)",
                    kind: .branch,
                    title: branch.name,
                    detail: "нет на сервере: \(RepositoryText.commits(branch.unpushedCommits))",
                    note: branch.upstreamGone ? "удалена на сервере, вероятно влита" : nil,
                    date: branch.lastCommitDate,
                    location: worktrees.first { $0.branch == branch.name }?.path ?? path,
                    source: .history(directory: path, revisions: ["refs/heads/\(branch.name)", "--not", "--remotes"])
                ))
            }
        }
        for worktree in worktrees where worktree.unpushedCommits > 0 {
            findings.append(Finding(
                id: "detached:\(worktree.path.path)",
                kind: .detached,
                title: worktree.name,
                detail: "только в этом ворктри: \(RepositoryText.commits(worktree.unpushedCommits))",
                note: "detached HEAD",
                date: worktree.lastActivity,
                location: worktree.path,
                source: .history(directory: worktree.path, revisions: ["HEAD", "--not", "--remotes", "--branches", "--tags"])
            ))
        }
        // Stashes are shared by all worktrees; a bare repository can only list them from one.
        let stashDirectory = worktrees.first?.path ?? path
        for stash in stashes {
            // git writes "On <branch>: <message>" or "WIP on <branch>: <hash> <subject>".
            var message = stash.message
            var detail = stash.name
            if let separator = message.range(of: ": "), message.hasPrefix("On ") || message.hasPrefix("WIP on ") {
                let branch = message[..<separator.lowerBound].split(separator: " ").last.map(String.init) ?? ""
                message = String(message[separator.upperBound...])
                detail += " · \(branch)"
            }
            findings.append(Finding(
                id: "\(path.path)|stash:\(stash.name)",
                kind: .stash,
                title: message,
                detail: detail,
                note: nil,
                date: stash.date,
                location: path,
                source: .stash(directory: stashDirectory, name: stash.name)
            ))
        }
        return findings.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// One line for the sidebar: what is at stake.
    var summary: String {
        let findings = findings
        var parts: [String] = []
        let files = worktrees.reduce(0) { $0 + $1.dirtyFileCount }
        if files > 0 { parts.append("\(RepositoryText.files(files)) не закоммичено") }
        let unpushed = findings.filter { $0.kind == .branch || $0.kind == .detached }.count
        if unpushed > 0 { parts.append("\(unpushed) не на сервере") }
        if !stashes.isEmpty { parts.append("стэшей: \(stashes.count)") }
        if !hasRemote { parts.append("нет remote") }
        return parts.isEmpty ? "всё на сервере" : parts.joined(separator: " · ")
    }

    /// A self-contained request a coding agent can act on without opening git-sight.
    func agentTask(for finding: Finding, files: [CommitFileSnapshot]? = nil) -> String {
        let ago = RepositoryText.ago(finding.date)
        let place = RepositoryText.path(finding.location)
        var lines: [String] = []
        switch finding.kind {
        case .uncommitted:
            lines.append("В \(place) лежат незакоммиченные изменения: \(RepositoryText.files(worktrees.first { $0.path == finding.location }?.dirtyFileCount ?? 0)), последнее изменение \(ago).")
            if let files, !files.isEmpty {
                lines.append("Файлы: " + files.prefix(30).map(\.path).joined(separator: ", ") + (files.count > 30 ? " и ещё \(files.count - 30)." : "."))
            }
            lines.append("Разберись, что это. Нужное закоммить в отдельную ветку и запушь. То, что не должно попадать в git, предложи добавить в .gitignore.")
        case .branch:
            lines.append("В репозитории \(RepositoryText.path(path)) ветка `\(finding.title)`: \(finding.detail), последний коммит \(ago).")
            if finding.note != nil {
                lines.append("Ветку уже удалили на сервере. Проверь, влита ли эта работа в основную ветку (например, через squash).")
            }
            lines.append("Если работа нужна, запушь ветку и открой PR. Если она уже влита или не нужна, скажи мне, и ветку можно будет удалить.")
        case .detached:
            lines.append("В ворктри \(place) на detached HEAD есть коммиты, которых нет ни в одной ветке и ни на сервере (\(RepositoryText.commits(worktrees.first { $0.path == finding.location }?.unpushedCommits ?? 0))), последний \(ago).")
            lines.append("Создай для них ветку и запушь, либо объясни, почему их можно выбросить.")
        case .stash:
            guard case .stash(_, let name) = finding.source else { break }
            lines.append("В репозитории \(RepositoryText.path(path)) есть стэш \(name) «\(finding.title)», создан \(ago).")
            lines.append("Посмотри содержимое: `git stash show -p --include-untracked \(name)`. Если работа нужна, перенеси её в отдельную ветку и запушь.")
        }
        lines.append("Ничего не удаляй без моего подтверждения.")
        return lines.joined(separator: "\n")
    }
}
