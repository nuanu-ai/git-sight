import GitSightCore
import SwiftUI

/// Commits on fixed-height rows, drawn the way VS Code's Source Control graph draws them.
/// Clicking a commit opens its files right under it, and the lanes run on through them.
struct CommitGraph: View {
    let commits: [CommitSnapshot]
    @Binding var selection: String?
    /// Files of the selected commit; nil while they load.
    let files: [CommitFileSnapshot]?
    let filesError: String?
    /// The file whose diff is open, highlighted among the commit's files.
    var openFile: CommitFileSnapshot?
    var onOpenFile: ((CommitFileSnapshot) -> Void)?
    /// Called when the last row scrolls into view, to read further back.
    var onReachEnd: (() -> Void)?

    @AppStorage(TextRole.sizeKey) private var textSize = TextRole.standardSize
    /// 24 pt rows and 12 pt lanes at the standard text size, growing with it.
    private var rowHeight: CGFloat { (textSize * 1.6).rounded() }
    private var laneSpacing: CGFloat { (textSize * 0.8).rounded() }
    /// Radius of the turn where a line leaves or joins a row.
    private static let turn: CGFloat = 5
    // VS Code's graph palette: the first lane blue like the current branch, then scmGraph.foreground1–5.
    private static let laneColors: [Color] = [
        Color(red: 0.0, green: 0.48, blue: 0.8),
        Color(red: 1.0, green: 0.69, blue: 0.0),
        Color(red: 0.86, green: 0.15, blue: 0.5),
        Color(red: 0.25, green: 0.69, blue: 0.65),
        Color(red: 0.71, green: 0.43, blue: 1.0),
        Color(red: 0.6, green: 0.31, blue: 0.0)
    ]

    private enum Row {
        case commit(Int)
        case file(CommitFileSnapshot)
        /// Loading (nil) or a message in place of the files.
        case note(String?)
    }

    private var rows: [(id: String, row: Row)] {
        var rows: [(id: String, row: Row)] = []
        for (index, commit) in commits.enumerated() {
            rows.append((commit.fullHash, .commit(index)))
            guard commit.fullHash == selection else { continue }
            if let filesError {
                rows.append(("\(commit.fullHash)|error", .note(filesError)))
            } else if let files {
                if files.isEmpty { rows.append(("\(commit.fullHash)|empty", .note("Файлы не менялись"))) }
                rows += files.map { ("\(commit.fullHash)|\($0.path)", .file($0)) }
            } else {
                rows.append(("\(commit.fullHash)|loading", .note(nil)))
            }
        }
        return rows
    }

    var body: some View {
        let rows = rows
        let lanes = rowLanes(rows)
        ScrollView {
            ZStack(alignment: .topLeading) {
                rails(rows: rows)
                    .frame(height: rowHeight * CGFloat(rows.count))
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                        row(item.row, indent: indent(lanes[index]))
                            .frame(height: rowHeight)
                            .onAppear {
                                if index == rows.count - 1 { onReachEnd?() }
                            }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Where a row's text starts: right after the rightmost line that crosses it, as in VS Code.
    private func indent(_ lane: Int) -> CGFloat {
        laneX(lane) + 12
    }

    @ViewBuilder
    private func row(_ row: Row, indent: CGFloat) -> some View {
        switch row {
        case .commit(let index):
            let commit = commits[index]
            CommitRow(commit: commit, laneColor: color(lane: commit.lane))
                .padding(.leading, indent)
                .contentShape(Rectangle())
                .onTapGesture {
                    selection = selection == commit.fullHash ? nil : commit.fullHash
                }
        case .file(let file):
            FileRow(file: file)
                .padding(.leading, indent + 18)
                .padding(.trailing, 14)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(file == openFile ? Color.accentColor.opacity(0.22) : .clear)
                        .padding(.leading, indent + 12)
                        .padding(.trailing, 8)
                )
                .contentShape(Rectangle())
                .onTapGesture { onOpenFile?(file) }
        case .note(let text):
            HStack {
                if let text {
                    Text(text).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .padding(.leading, indent + 18)
        }
    }

    /// The rightmost lane each row's lines reach: the commit's own and every edge passing through.
    private func rowLanes(_ rows: [(id: String, row: Row)]) -> [Int] {
        var rowOf: [String: Int] = [:]
        for (index, item) in rows.enumerated() {
            if case .commit(let commit) = item.row { rowOf[commits[commit].fullHash] = index }
        }
        // Lanes that start and stop crossing rows, swept from top to bottom.
        var opens = Array(repeating: [Int](), count: rows.count + 1)
        var closes = Array(repeating: [Int](), count: rows.count + 1)
        for commit in commits {
            guard let row = rowOf[commit.fullHash] else { continue }
            opens[row].append(commit.lane)
            closes[row + 1].append(commit.lane)
            for (offset, parent) in commit.parents.enumerated() {
                let lane = offset < commit.parentLanes.count ? commit.parentLanes[offset] : commit.lane
                opens[row].append(lane)
                // A parent past the history limit: the line runs off the bottom.
                closes[(rowOf[parent] ?? rows.count - 1) + 1].append(lane)
            }
        }
        var crossing: [Int: Int] = [:]
        return (0..<rows.count).map { row in
            for lane in closes[row] { crossing[lane, default: 0] -= 1 }
            for lane in opens[row] { crossing[lane, default: 0] += 1 }
            return crossing.filter { $0.value > 0 }.keys.max() ?? 0
        }
    }

    private func rails(rows: [(id: String, row: Row)]) -> some View {
        Canvas { context, size in
            var y: [String: CGFloat] = [:]
            for (index, item) in rows.enumerated() {
                if case .commit(let commit) = item.row {
                    y[commits[commit].fullHash] = (CGFloat(index) + 0.5) * rowHeight
                }
            }
            // Work that exists only on this machine sits on one band across the whole width, under the lines;
            // the files of a selected commit stay on its band.
            var owner: CommitSnapshot?
            let local = rows.map { item -> Bool in
                if case .commit(let index) = item.row { owner = commits[index] }
                return owner?.isUnpushed ?? false
            }
            var start: Int?
            for index in 0...rows.count {
                if index < rows.count, local[index] {
                    start = start ?? index
                } else if let first = start {
                    let band = CGRect(x: 4, y: CGFloat(first) * rowHeight, width: size.width - 12, height: CGFloat(index - first) * rowHeight)
                    context.fill(Path(roundedRect: band, cornerRadius: 5), with: .color(.orange.opacity(0.12)))
                    start = nil
                }
            }
            if let selectedY = selection.flatMap({ y[$0] }) {
                let row = CGRect(x: 4, y: selectedY - rowHeight / 2, width: size.width - 12, height: rowHeight)
                context.fill(Path(roundedRect: row, cornerRadius: 5), with: .color(.accentColor.opacity(0.22)))
            }
            for commit in commits {
                guard let childY = y[commit.fullHash] else { continue }
                let start = CGPoint(x: laneX(commit.lane), y: childY)
                for (offset, parentHash) in commit.parents.enumerated() {
                    // The core holds this lane for the parent until the parent's row, so nothing else sits on it.
                    let lane = offset < commit.parentLanes.count ? commit.parentLanes[offset] : commit.lane
                    let parent = commits.first { $0.fullHash == parentHash }.flatMap { parent in
                        y[parentHash].map { CGPoint(x: laneX(parent.lane), y: $0) }
                    }
                    let path = Self.edge(from: start, along: laneX(lane), to: parent, bottom: size.height)
                    context.stroke(path, with: .color(color(lane: lane)), lineWidth: 1.5)
                }
            }
            for commit in commits {
                guard let centerY = y[commit.fullHash] else { continue }
                let center = CGPoint(x: laneX(commit.lane), y: centerY)
                let color = color(lane: commit.lane)
                if commit.parents.count > 1 {
                    // A merge: a ring with a dot, as in VS Code.
                    context.stroke(Self.circle(center, 4.5), with: .color(color), lineWidth: 1.5)
                    context.fill(Self.circle(center, 2), with: .color(color))
                } else {
                    context.fill(Self.circle(center, 4), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A line from a commit to its parent: across the child's row to the held lane, down it,
    /// and across the parent's row into the parent, turning with a small radius like VS Code.
    private static func edge(from start: CGPoint, along x: CGFloat, to end: CGPoint?, bottom: CGFloat) -> Path {
        var path = Path()
        path.move(to: start)
        if x != start.x {
            let direction: CGFloat = x > start.x ? 1 : -1
            path.addLine(to: CGPoint(x: x - direction * turn, y: start.y))
            path.addQuadCurve(to: CGPoint(x: x, y: start.y + turn), control: CGPoint(x: x, y: start.y))
        }
        guard let end else {
            // The parent is past the history limit: the line runs off the bottom in its lane.
            path.addLine(to: CGPoint(x: x, y: bottom))
            return path
        }
        if x != end.x {
            let direction: CGFloat = end.x > x ? 1 : -1
            path.addLine(to: CGPoint(x: x, y: end.y - turn))
            path.addQuadCurve(to: CGPoint(x: x + direction * turn, y: end.y), control: CGPoint(x: x, y: end.y))
        }
        path.addLine(to: end)
        return path
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func laneX(_ lane: Int) -> CGFloat {
        12 + CGFloat(max(0, lane)) * laneSpacing
    }

    /// Text on a lane's color: dark on the light amber and teal, white on the rest.
    static func labelColor(on lane: Color) -> Color {
        lane == laneColors[1] || lane == laneColors[3] ? Color.black.opacity(0.85) : .white
    }

    private func color(lane: Int) -> Color {
        Self.laneColors[max(0, lane) % Self.laneColors.count]
    }
}

private struct CommitRow: View {
    let commit: CommitSnapshot
    let laneColor: Color

    var body: some View {
        // Only what VS Code shows: the subject and its labels. Hash, author and date are in the tooltip.
        SubjectAndLabels {
            Text(commit.subject)
                .lineLimit(1)
                .truncationMode(.tail)
            // Labels stay whole: three, then one, then only the count, as the column narrows.
            ViewThatFits(in: .horizontal) {
                labels(shown: 3)
                labels(shown: 1)
                labels(shown: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .frame(maxHeight: .infinity)
        .accessibilityValue(commit.isUnpushed ? "нет на сервере" : "")
        .padding(.trailing, 8)
        .help("\(commit.subject)\n\(commit.shortHash) · \(commit.author) · \(RepositoryText.fullDate(commit.date)), \(RepositoryText.ago(commit.date))"
              + (commit.isUnpushed ? "\nЭтого коммита нет на сервере" : ""))
    }

    /// Where you are first, then what is local, then what lives on the server.
    private var sortedRefs: [CommitRef] {
        let order: [CommitRef.Kind] = [.head, .branch, .worktree, .tag, .remoteBranch]
        return commit.refs.sorted {
            ($0.isHead ? -1 : order.firstIndex(of: $0.kind) ?? 0) < ($1.isHead ? -1 : order.firstIndex(of: $1.kind) ?? 0)
        }
    }

    private func labels(shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(sortedRefs.prefix(shown), id: \.self) { ref in
                RefBadge(ref: ref, color: laneColor)
            }
            if commit.refs.count > shown {
                Text(shown == 0 ? RepositoryText.counted(commit.refs.count, one: "метка", few: "метки", many: "меток") : "+\(commit.refs.count - shown)")
                    .textRole(.label)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .help(sortedRefs.dropFirst(shown).map(\.name).joined(separator: "\n"))
            }
        }
        .fixedSize()
    }
}

/// The subject, then its labels right after it. The labels take what they need first, but the
/// subject always keeps up to 120 pt, so a commit with many refs still says what it is.
private struct SubjectAndLabels: Layout {
    private let gap: CGFloat = 6
    private let subjectFloor: CGFloat = 120

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (subject, labels) = widths(proposal.width ?? .infinity, subviews)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: subject + gap + labels, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (subject, labels) = widths(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: subject, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + subject + gap, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: labels, height: bounds.height))
    }

    private func widths(_ available: CGFloat, _ subviews: Subviews) -> (subject: CGFloat, labels: CGFloat) {
        let ideal = subviews[0].sizeThatFits(.unspecified).width
        let labels = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, available - min(ideal, subjectFloor) - gap), height: nil)).width
        return (min(ideal, max(0, available - labels - gap)), labels)
    }
}

/// A branch or tag name on its commit, like VS Code's history item labels.
private struct RefBadge: View {
    let ref: CommitRef
    let color: Color

    var body: some View {
        // Local branches take the lane's color; what lives elsewhere stays grey.
        let isLocal = ref.kind != .remoteBranch && ref.kind != .tag
        HStack(spacing: 3) {
            Image(systemName: icon)
                .textRole(.label)
                .imageScale(.small)
                .fontWeight(.semibold)
            Text(ref.name)
                .textRole(.label)
                .fontWeight(ref.isHead ? .bold : .medium)
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(isLocal ? CommitGraph.labelColor(on: color) : Color.secondary)
        .background(Capsule().fill(isLocal ? color : Color.secondary.opacity(0.18)))
        .fixedSize()
        .help(help)
    }

    private var icon: String {
        switch ref.kind {
        case .branch: return "arrow.triangle.branch"
        case .remoteBranch: return "cloud"
        case .tag: return "tag"
        case .head: return "smallcircle.filled.circle"
        case .worktree: return "folder"
        }
    }

    private var help: String {
        switch ref.kind {
        case .branch: return ref.isHead ? "Ветка \(ref.name), текущая" : "Ветка \(ref.name)"
        case .remoteBranch: return "\(ref.name) на сервере"
        case .tag: return "Тег \(ref.name)"
        case .head: return "HEAD без ветки"
        case .worktree: return "Ворктри \(ref.name), HEAD без ветки"
        }
    }
}
