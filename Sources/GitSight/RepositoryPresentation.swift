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

    static func counted(_ value: Int, one: String, few: String, many: String) -> String {
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

extension Color {
    /// Text on a filled badge: dark on the light yellow and green, where white does not read.
    var badgeText: Color {
        self == .yellow || self == .green ? Color.black.opacity(0.8) : .white
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
struct Finding: Identifiable {
    enum Kind: Hashable {
        case uncommitted
        case branch
        case detached
        case stash
        /// A branch the server has and the base never got.
        case unmerged
        /// Merged branches left lying around, with the worktrees that hold them.
        case leftover
    }

    /// Where the detail column reads this finding from.
    enum Source: Hashable {
        /// The whole history behind the tips, with what the server lacks marked.
        case history(directory: URL, tips: [String])
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
    let work: UnsavedWork
    let severity: Severity
    /// Why it has that severity, in a few words.
    let reason: String

    /// Leftovers lose nothing, so they get a gray label of their own instead of a verdict.
    var badge: (title: String, color: Color) {
        kind == .leftover ? ("Мусор", .gray) : (severity.title, severity.color)
    }

    var tint: Color { kind == .leftover ? .secondary : severity.tint }

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
        work = verdict.work
        let lastChanged = verdict.lastChanged ?? Date()
        severity = Severity(of: verdict.work, lastChanged: lastChanged)
        if verdict.work == .leftover {
            reason = "можно убрать"
        } else if severity >= .warning {
            reason = "\(RepositoryText.age(lastChanged)) без движения"
        } else if verdict.work == .commits(upstreamGone: true) {
            reason = "вероятно, уже влита"
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
        case .unmerged: return "arrow.triangle.pull"
        case .leftover: return "archivebox"
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
                    note: branch.upstreamGone ? "удалена на сервере" : nil,
                    date: branch.lastCommitDate,
                    location: worktrees.first { $0.branch == branch.name }?.path ?? path,
                    source: .history(directory: path, tips: ["refs/heads/\(branch.name)"]),
                    verdict: (.commits(upstreamGone: branch.upstreamGone), branch.lastCommitDate)
                ))
            }
        }
        for branch in unfinishedBranches {
            findings.append(Finding(
                id: "\(path.path)|unmerged:\(branch.name)",
                kind: .unmerged,
                title: branch.name,
                detail: "не влито в \(baseBranch ?? "main"): \(RepositoryText.commits(branch.unmergedCommits))",
                note: branch.upstreamGone ? "удалена на сервере" : nil,
                date: branch.lastCommitDate,
                location: worktrees.first { $0.branch == branch.name }?.path ?? path,
                source: .history(directory: path, tips: ["refs/heads/\(branch.name)"]),
                verdict: (.unmerged, branch.lastCommitDate)
            ))
        }
        let leftovers = leftoverBranches
        if !leftovers.isEmpty {
            let held = leftoverWorktrees.count
            let oldest = leftovers.compactMap(\.lastCommitDate).min()
            findings.append(Finding(
                id: "\(path.path)|leftovers",
                kind: .leftover,
                title: "Хвосты",
                detail: [RepositoryText.counted(leftovers.count, one: "ветка влита", few: "ветки влиты", many: "веток влито") + " в \(baseBranch ?? "main")",
                         held > 0 ? "\(held) ворктри" : nil].compactMap { $0 }.joined(separator: " · "),
                note: nil,
                date: oldest,
                location: path,
                source: .history(directory: path, tips: leftovers.map { "refs/heads/\($0.name)" }),
                verdict: (.leftover, oldest)
            ))
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
                source: .history(directory: worktree.path, tips: ["HEAD"]),
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

    /// Linked worktrees that hold nothing but a leftover branch.
    var leftoverWorktrees: [WorktreeSnapshot] {
        let names = Set(leftoverBranches.map(\.name))
        return worktrees.filter { names.contains($0.branch ?? "") }
    }

    /// "сейчас на main · 21 ветка, 13 не влиты · 4 ворктри", the same in the list and above the graph:
    /// how much is lying around locally.
    var branchesSummary: String {
        var branchCount = RepositoryText.counted(branches.count, one: "ветка", few: "ветки", many: "веток")
        let unfinished = unfinishedBranches.count
        if unfinished > 0 { branchCount += ", " + RepositoryText.counted(unfinished, one: "не влита", few: "не влиты", many: "не влиты") }
        let linked = worktrees.filter { !$0.isMain }.count
        return [currentBranch.map { "сейчас на \($0)" }, branchCount, linked > 0 ? "\(linked) ворктри" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// What happened last, e.g. "main: 2 файла не закоммичено".
    var latestChangeText: (date: Date, text: String)? {
        latestChange.map { change in
            let place = change.place.map { "\($0): " } ?? ""
            switch change.kind {
            case .uncommitted(let files): return (change.date, "\(place)\(RepositoryText.files(files)) не закоммичено")
            case .commit: return (change.date, "\(place)новый коммит")
            case .stash: return (change.date, "новый стэш")
            }
        }
    }

    /// One line for the sidebar: what is at stake.
    var summary: String {
        var parts: [String] = []
        let files = worktrees.reduce(0) { $0 + $1.dirtyFileCount }
        if files > 0 { parts.append("\(RepositoryText.files(files)) не закоммичено") }
        let unpushedBranches = hasRemote ? branches.filter { $0.unpushedCommits > 0 }.count : 0
        if unpushedBranches > 0 {
            parts.append("\(RepositoryText.counted(unpushedBranches, one: "ветка", few: "ветки", many: "веток")) не на сервере")
        }
        let detached = worktrees.filter { $0.unpushedCommits > 0 }.count
        if detached > 0 { parts.append("\(detached) ворктри с коммитами вне веток") }
        if !stashes.isEmpty { parts.append(RepositoryText.counted(stashes.count, one: "стэш", few: "стэша", many: "стэшей")) }
        let unfinished = unfinishedBranches.count
        if unfinished > 0 { parts.append(RepositoryText.counted(unfinished, one: "не влита", few: "не влиты", many: "не влиты")) }
        let leftovers = leftoverBranches.count
        if leftovers > 0 { parts.append("хвосты: \(leftovers)") }
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
        case .unmerged:
            lines.append("В репозитории \(RepositoryText.path(path)) ветка `\(finding.title)` есть на сервере, но не влита в \(baseBranch ?? "main"): \(RepositoryText.commits(branches.first { $0.name == finding.title }?.unmergedCommits ?? 0)), последний коммит \(ago).")
            lines.append("Выясни, что с этой работой. Если она нужна, доведи её до PR и влей. Если устарела или уже не нужна, скажи мне, и ветку можно будет удалить локально и на сервере.")
        case .leftover:
            let names = leftoverBranches.map { "`\($0.name)`" }.joined(separator: ", ")
            lines.append("В репозитории \(RepositoryText.path(path)) лежат ветки, уже влитые в \(baseBranch ?? "main"): \(names). Последний коммит в самой старой \(ago).")
            let held = leftoverWorktrees.map { RepositoryText.path($0.path) }
            if !held.isEmpty {
                lines.append("Они открыты в ворктри: \(held.joined(separator: ", ")).")
            }
            lines.append("Проверь, что каждая действительно влита, и предложи список на удаление: `git worktree remove <путь>` для ворктри, `git branch -d <ветка>` для веток. Не используй `-D` и `--force`: если git отказывается удалять, покажи мне почему.")
        case .stash:
            guard case .stash(_, let name, let hash) = finding.source else { break }
            lines.append("В репозитории \(RepositoryText.path(path)) есть стэш \(name) «\(finding.title)», создан \(ago). Его коммит: \(hash).")
            lines.append("Посмотри содержимое: `git stash show -p --include-untracked \(hash)`. Если работа нужна, перенеси её в отдельную ветку и запушь.")
        }
        lines.append("Ничего не удаляй без моего подтверждения.")
        return lines.joined(separator: "\n")
    }
}
