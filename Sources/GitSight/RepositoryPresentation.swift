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
    /// Both round down from the same calendar components, so a row and its header always agree.
    static func age(_ date: Date?, short: Bool = false) -> String {
        guard let date else { return "—" }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date, to: Date())
        let years = parts.year ?? 0, months = parts.month ?? 0, days = parts.day ?? 0
        let hours = parts.hour ?? 0, minutes = parts.minute ?? 0
        // Accusative forms: "неделю назад", "минуту без движения".
        if years > 0 { return short ? "\(years) г" : counted(years, one: "год", few: "года", many: "лет") }
        if months > 0 { return short ? "\(months) мес" : counted(months, one: "месяц", few: "месяца", many: "месяцев") }
        if days >= 7 { return short ? "\(days / 7) нед" : counted(days / 7, one: "неделю", few: "недели", many: "недель") }
        if days > 0 { return short ? "\(days) дн" : counted(days, one: "день", few: "дня", many: "дней") }
        if hours > 0 { return short ? "\(hours) ч" : counted(hours, one: "час", few: "часа", many: "часов") }
        if minutes > 0 { return short ? "\(minutes) мин" : counted(minutes, one: "минуту", few: "минуты", many: "минут") }
        return "сейчас"
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

    /// Color only where something is wrong; work in progress stays neutral.
    var tint: Color {
        self >= .warning ? color : .secondary
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
        /// `hash` addresses the stash; `name` (stash@{n}) shifts when another stash is pushed.
        case stash(directory: URL, name: String, hash: String)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let note: String?
    let date: Date?
    let location: URL
    let source: Source
    let severity: Severity
    /// Why it has that severity, in a few words.
    let reason: String

    init(
        id: String, kind: Kind, title: String, detail: String, note: String?, date: Date?,
        location: URL, source: Source, verdict: (work: UnsavedWork, lastChanged: Date?)
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.note = note
        self.date = date
        self.location = location
        self.source = source
        let lastChanged = verdict.lastChanged ?? Date()
        severity = Severity(of: verdict.work, lastChanged: lastChanged)
        if severity >= .warning {
            reason = "\(RepositoryText.age(lastChanged)) без движения"
        } else if verdict.work == .commits(upstreamGone: true) {
            reason = "ветку удалили на сервере"
        } else {
            reason = "изменено \(RepositoryText.ago(lastChanged))"
        }
    }

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
                source: .uncommitted(worktree: worktree.path),
                verdict: (.uncommitted, worktree.dirtyModifiedAt ?? worktree.lastActivity)
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
                    source: .history(directory: path, revisions: ["refs/heads/\(branch.name)", "--not", "--remotes"]),
                    verdict: (.commits(upstreamGone: branch.upstreamGone), branch.lastCommitDate)
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
                source: .history(directory: worktree.path, revisions: ["HEAD", "--not", "--remotes", "--branches", "--tags"]),
                verdict: (.commits(upstreamGone: false), worktree.lastActivity)
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
                id: "\(path.path)|stash:\(stash.hash)",
                kind: .stash,
                title: message,
                detail: detail,
                note: nil,
                date: stash.date,
                location: path,
                source: .stash(directory: stashDirectory, name: stash.name, hash: stash.hash),
                verdict: (.stash, stash.date)
            ))
        }
        return findings.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    /// Why the repository has its severity: the reason of its oldest worst finding.
    var reason: String {
        let worst = findings.filter { $0.severity == severity }.first
        return worst?.reason ?? (hasRemote ? "всё на сервере" : "нет remote, история только на этом компьютере")
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
            guard case .stash(_, let name, let hash) = finding.source else { break }
            lines.append("В репозитории \(RepositoryText.path(path)) есть стэш \(name) «\(finding.title)», создан \(ago). Его коммит: \(hash).")
            lines.append("Посмотри содержимое: `git stash show -p --include-untracked \(hash)`. Если работа нужна, перенеси её в отдельную ветку и запушь.")
        }
        lines.append("Ничего не удаляй без моего подтверждения.")
        return lines.joined(separator: "\n")
    }
}
