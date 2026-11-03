import Foundation
import GitSightCore
import SwiftUI

enum RepositoryText {
    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// How long ago, without "ago": "now", "5 min", "3 hours", "2 days", "3 weeks", "2 months", "1 year".
    /// Rounds down from calendar components, so a row and its header always agree.
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date, to: now)
        let years = parts.year ?? 0, months = parts.month ?? 0, days = parts.day ?? 0
        let hours = parts.hour ?? 0, minutes = parts.minute ?? 0
        if years > 0 { return counted(years, "year", "years") }
        if months > 0 { return counted(months, "month", "months") }
        if days >= 7 { return counted(days / 7, "week", "weeks") }
        if days > 0 { return counted(days, "day", "days") }
        if hours > 0 { return counted(hours, "hour", "hours") }
        if minutes > 0 { return "\(minutes) min" }
        return "now"
    }

    /// "3 days ago", or "just now" within the first minute.
    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        return now.timeIntervalSince(date) < 60 ? "just now" : "\(age(date, now: now)) ago"
    }

    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    static func counted(_ value: Int, _ one: String, _ many: String) -> String {
        "\(value.formatted()) \(value == 1 ? one : many)"
    }

    static func files(_ count: Int) -> String { counted(count, "file", "files") }
    static func commits(_ count: Int) -> String { counted(count, "commit", "commits") }

    static func weight(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    static func path(_ url: URL) -> String {
        NSString(string: url.path).abbreviatingWithTildeInPath
    }
}

extension Verdict {
    var title: String {
        switch self {
        case .inProgress: return "In progress"
        case .abandoned: return "Abandoned"
        case .forgotten: return "Forgotten"
        case .clutter: return "Clutter"
        }
    }

    /// Color only where something is wrong: work in progress stays gray, clutter is an outline.
    var color: Color {
        switch self {
        case .inProgress, .clutter: return .secondary
        case .abandoned: return .orange
        case .forgotten: return .red
        }
    }
}

/// A verdict as a dot: filled for work at risk, an outline for clutter or nothing at all.
struct VerdictDot: View {
    @Environment(\.backgroundProminence) private var prominence
    let verdict: Verdict?
    var size: CGFloat = 8

    var body: some View {
        // On a selected row the dot turns white, as macOS colors marks in Mail and Finder.
        let selected = prominence == .increased
        Group {
            if let verdict, verdict != .clutter {
                Circle().fill(selected ? Color.white : verdict == .inProgress ? Color.gray.opacity(0.7) : verdict.color)
            } else {
                Circle().strokeBorder(selected ? Color.white : Color.gray.opacity(0.55), lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .help(verdict?.title ?? "Clean")
        .accessibilityLabel(verdict?.title ?? "Clean")
    }
}

/// A small accent dot after a name that changed within the last few minutes.
struct LiveDot: View {
    let date: Date

    var body: some View {
        Circle()
            .selectableTint(.accentColor)
            .frame(width: 6, height: 6)
            .help("Changed \(RepositoryText.ago(date))")
            .accessibilityLabel("Changed \(RepositoryText.ago(date))")
    }
}

/// A color that turns white on a selected row: orange or blue on the selection's blue is hard to read.
private struct SelectableTint: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence
    let color: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color.white : color)
    }
}

extension View {
    func selectableTint(_ color: Color) -> some View {
        modifier(SelectableTint(color: color))
    }
}

/// The overview's columns: one per kind of work, as the window counts it.
enum WorkColumn: String, CaseIterable, Identifiable {
    case uncommitted, unpushed, stashes, unmerged, leftovers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uncommitted: return "Uncommitted"
        case .unpushed: return "Unpushed"
        case .stashes: return "Stashes"
        case .unmerged: return "Unmerged"
        case .leftovers: return "Leftovers"
        }
    }

    var systemImage: String {
        switch self {
        case .uncommitted: return "pencil"
        case .unpushed: return "arrow.up"
        case .stashes: return "tray"
        case .unmerged: return "arrow.triangle.pull"
        case .leftovers: return "checkmark"
        }
    }

    var unit: (one: String, many: String) {
        switch self {
        case .uncommitted: return ("file", "files")
        case .unpushed: return ("commit", "commits")
        case .stashes: return ("stash", "stashes")
        case .unmerged: return ("branch", "branches")
        case .leftovers: return ("leftover", "leftovers")
        }
    }

    func contains(_ kind: WorkPiece.Kind) -> Bool {
        switch self {
        case .uncommitted: return kind == .uncommitted
        case .unpushed: return kind == .unpushed || kind == .detached
        case .stashes: return kind == .stash
        case .unmerged: return kind == .unmerged
        case .leftovers: return kind == .leftover
        }
    }

    /// Files for uncommitted work, commits for unpushed ones, one per branch or stash for the rest.
    func count(_ piece: WorkPiece) -> Int {
        self == .uncommitted || self == .unpushed ? piece.amount : 1
    }

    /// What a cell's tooltip says about its pieces.
    func describe(_ value: Int, base: String) -> String {
        switch self {
        case .uncommitted: return "\(RepositoryText.files(value)) uncommitted"
        case .unpushed: return "\(RepositoryText.commits(value)) only on this Mac"
        case .stashes: return RepositoryText.counted(value, "stash", "stashes")
        case .unmerged: return "\(RepositoryText.counted(value, "branch", "branches")) not merged into \(base)"
        case .leftovers: return "\(RepositoryText.counted(value, "branch", "branches")) merged and safe to remove"
        }
    }
}

extension WorkPiece.Kind {
    var systemImage: String {
        switch self {
        case .uncommitted: return "pencil"
        case .unpushed, .detached: return "arrow.up"
        case .stash: return "tray"
        case .unmerged: return "arrow.triangle.pull"
        case .leftover: return "checkmark"
        }
    }
}

extension WorkPiece {
    /// The stash's own words, without git's "On main:" prefix.
    var stashText: String { stash?.text ?? "" }
}

/// What the weight is made of, for the popover next to it.
enum WeightScale {
    static let ages: [(String, Double)] = [("today", 0), ("a week", 7), ("a month", 30), ("three months", 90)].map { ($0.0, factor(days: $0.1)) }
    static let risks: [(String, Double)] = [("only on this Mac", 1), ("on the server, not merged", 0.3), ("merged leftovers", 0.2)]

    static func factor(days: Double) -> Double { 1 + log2(1 + days / 3) }
}

extension RepositorySnapshot {
    /// Changes newer than this count as live.
    static let liveWindow: TimeInterval = 15 * 60

    /// The newest change, if it happened within the live window.
    func liveChange(now: Date = Date()) -> RecentChange? {
        latestChange.flatMap { abs(now.timeIntervalSince($0.date)) < Self.liveWindow ? $0 : nil }
    }

    var base: String { baseBranch ?? "main" }

    /// The pieces each column of the overview counts.
    func column(_ column: WorkColumn, now: Date = Date()) -> (value: Int, lead: WorkPiece?) {
        let pieces = places.flatMap(\.pieces).filter { column.contains($0.kind) }
        // The worst verdict, and within it the oldest piece.
        let lead = pieces.max { ($0.verdict(now: now), $1.date) < ($1.verdict(now: now), $0.date) }
        return (pieces.reduce(0) { $0 + column.count($1) }, lead)
    }
}

extension WorkPlace {
    /// Stable across rescans: the worktree's folder, or the branch's name.
    var id: String {
        if let worktree { return "worktree:\(worktree.path.path)" }
        if branch != nil { return "branch:\(branchName ?? "")" }
        return "deleted:\(branchName ?? "")"
    }

    var isMainWorktree: Bool { worktree?.isMain ?? false }

    /// A stash whose branch is gone, the only kind of place with neither worktree nor branch.
    var isDeletedBranch: Bool { worktree == nil && branch == nil }

    /// How a list row names the branch, or what HEAD is on.
    var branchLabel: String { branchName ?? (isDeletedBranch ? "no branch" : "detached HEAD") }
}

// MARK: - Sentences about work

enum WorkText {
    /// One line per piece above the graph.
    static func fact(_ piece: WorkPiece, in place: WorkPlace, repository: RepositorySnapshot, now: Date = Date()) -> String {
        switch piece.kind {
        case .uncommitted:
            let live = now.timeIntervalSince(piece.date) < 5 * 60
            return "\(RepositoryText.files(piece.amount)) uncommitted, " + (live ? "changing right now" : "last edit \(RepositoryText.ago(piece.date, now: now))")
        case .unpushed:
            let commits = "\(RepositoryText.commits(piece.amount)) only on this Mac"
            return piece.upstreamGone ? "\(commits). The branch is gone from the server, so it may be merged already" : commits
        case .detached:
            return "\(RepositoryText.commits(piece.amount)) on no branch. Removing the worktree would lose them"
        case .unmerged:
            return "\(RepositoryText.commits(piece.amount)) on the server that \(repository.base) doesn't have"
        case .stash:
            return "Stash \"\(piece.stashText)\", \(RepositoryText.ago(piece.date, now: now))"
        case .leftover:
            let rest = place.worktree == nil ? "The branch can be deleted" : "Nothing else is in the worktree, so it and the branch can go"
            return "Merged into \(repository.base) \(RepositoryText.ago(piece.date, now: now)). \(rest)"
        }
    }

    static func clean(_ place: WorkPlace) -> String {
        place.worktree == nil ? "Nothing here is at risk." : "Everything here is committed and pushed."
    }

    /// A short phrase per piece, for the clean-up task.
    private static func brief(_ piece: WorkPiece, repository: RepositorySnapshot) -> String {
        switch piece.kind {
        case .uncommitted: return "\(RepositoryText.files(piece.amount)) uncommitted"
        case .unpushed: return "\(RepositoryText.commits(piece.amount)) not on the server"
        case .detached: return "\(RepositoryText.commits(piece.amount)) on no branch"
        case .unmerged: return "\(RepositoryText.commits(piece.amount)) not merged into \(repository.base)"
        case .stash: return "stash \"\(piece.stashText)\""
        case .leftover: return "merged into \(repository.base)"
        }
    }

    private static func name(_ place: WorkPlace) -> String {
        if let worktree = place.worktree {
            return "worktree \(RepositoryText.path(worktree.path)) (\(place.branchLabel))"
        }
        return place.isDeletedBranch ? "deleted branch \(place.branchLabel)" : "branch \(place.branchLabel)"
    }

    /// A request an agent can act on without opening git-sight. `files` are the uncommitted files, when loaded.
    static func task(for place: WorkPlace, in repository: RepositorySnapshot, files: [CommitFileSnapshot]? = nil, now: Date = Date()) -> String {
        var lines = ["In \(RepositoryText.path(repository.path)), the \(name(place)) has work that may be abandoned:"]
        for piece in place.pieces {
            switch piece.kind {
            case .uncommitted:
                lines.append("- \(RepositoryText.files(piece.amount)) uncommitted, last edited \(RepositoryText.ago(piece.date, now: now)).")
                if let files, !files.isEmpty {
                    lines.append("  Files: " + files.prefix(30).map(\.path).joined(separator: ", ") + (files.count > 30 ? ", and \(files.count - 30) more." : "."))
                }
            case .unpushed:
                lines.append("- \(RepositoryText.commits(piece.amount)) that aren't on the server, the latest from \(RepositoryText.ago(piece.date, now: now)).")
                if piece.upstreamGone {
                    lines.append("  The branch was deleted on the server. Check whether this work was merged already, for example as a squash.")
                }
            case .detached:
                lines.append("- \(RepositoryText.commits(piece.amount)) on a detached HEAD that no branch holds, the latest from \(RepositoryText.ago(piece.date, now: now)).")
            case .unmerged:
                lines.append("- \(RepositoryText.commits(piece.amount)) on the server that \(repository.base) doesn't have, the latest from \(RepositoryText.ago(piece.date, now: now)).")
            case .stash:
                if let stash = piece.stash {
                    lines.append("- The stash \"\(stash.text)\" from \(RepositoryText.ago(piece.date, now: now)). Its commit is \(stash.hash); `git stash show -p --include-untracked \(stash.hash)` shows it.")
                }
            case .leftover:
                lines.append("- The branch is already merged into \(repository.base)" + (place.worktree == nil ? "." : ", and the worktree holds nothing else."))
            }
        }
        lines.append("Find out what this is and what is worth keeping. Commit and push what's needed. For what can go, list the commands (`git worktree remove`, `git branch -d`, `git stash drop`) and wait for me to confirm before running them. Don't use -D or --force.")
        return lines.joined(separator: "\n")
    }

    /// Everything in one repository, heaviest first.
    static func task(for repository: RepositorySnapshot, now: Date = Date()) -> String {
        let places = repository.places.filter { !$0.pieces.isEmpty }.sorted { $0.weight(now: now) > $1.weight(now: now) }
        var lines = ["Abandoned work in \(RepositoryText.path(repository.path)):"]
        for place in places {
            let idle = place.lead(now: now).map { "; idle for \(RepositoryText.age($0.date, now: now))" } ?? ""
            lines.append("- \(name(place)): " + place.pieces.map { brief($0, repository: repository) }.joined(separator: ", ") + idle)
        }
        lines.append("Go through it in this order and show me a plan first: what to keep, what to merge, what can go. Don't delete anything until I confirm.")
        return lines.joined(separator: "\n")
    }
}
