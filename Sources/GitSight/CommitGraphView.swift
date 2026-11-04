import GitSightCore
import SwiftUI

/// Uncommitted files or a stash, drawn as a row of its own right above the commit it sits on.
struct GraphExtra {
    enum Kind { case uncommitted, stash }

    let id: GraphRowID
    let kind: Kind
    /// The commit it sits on: a worktree's HEAD, or the commit a stash was made on.
    let anchor: String
    let text: String
    let date: Date
}

/// Every branch of a repository on fixed-height rows, drawn the way VS Code's Source Control graph draws them,
/// with uncommitted work and stashes on rows of their own. Clicking a row lists its files right under it.
struct RepositoryGraph: View {
    let commits: [CommitSnapshot]
    let extras: [GraphExtra]
    /// Worktree folders by the commit their branch is at, shown as labels next to the branch.
    let folders: [String: [String]]
    /// Rows of the selected worktree or branch.
    let highlighted: Set<GraphRowID>
    let openRow: GraphRowID?
    /// Files of the open row; nil while they load.
    let files: [CommitFileSnapshot]?
    let filesError: String?
    /// The file whose diff is open, highlighted among the files.
    let openFile: CommitFileSnapshot?
    @Binding var focus: GraphRowID?
    /// Hidden until the first scroll to `focus`.
    @Binding var waitsForFocus: Bool
    let onToggle: (GraphRowID) -> Void
    let onOpenFile: (CommitFileSnapshot) -> Void
    /// Called when the last row scrolls into view, to read further back.
    let onReachEnd: () -> Void

    @AppStorage(TextRole.sizeKey) private var textSize = TextRole.standardSize
    /// 24 pt rows and 12 pt lanes at the standard text size, growing with it.
    private var rowHeight: CGFloat { (textSize * 1.6).rounded() }
    private var laneSpacing: CGFloat { (textSize * 0.8).rounded() }
    /// Radius of the turn where a line leaves or joins a row.
    private static let turn: CGFloat = 5
    /// Lane colors with a little gray in them, so they tell lanes apart without glaring;
    /// orange and red stay with the verdicts.
    static let laneColors: [Color] = [
        Color(red: 0.24, green: 0.5, blue: 0.82),
        Color(red: 0.58, green: 0.4, blue: 0.84),
        Color(red: 0.16, green: 0.6, blue: 0.56),
        Color(red: 0.8, green: 0.36, blue: 0.58),
        Color(red: 0.38, green: 0.6, blue: 0.28),
        Color(red: 0.4, green: 0.42, blue: 0.82)
    ]

    private enum Row {
        case commit(Int)
        case extra(Int)
        case file(CommitFileSnapshot)
        /// Loading (nil) or a message in place of the files.
        case note(String?)
    }

    private struct Layout {
        var rows: [(id: String, row: Row)] = []
        /// Where each commit and extra sits, by row index.
        var commitRow: [String: Int] = [:]
        /// Where each commit is in `commits`, by hash.
        var commitIndex: [String: Int] = [:]
        var extraRow: [Int: Int] = [:]
        var extraLane: [Int: Int] = [:]
        /// Where each row's text starts: after the rightmost line crossing it.
        var indent: [CGFloat] = []
        /// The unpushed commit each row belongs to, for the band of work only this Mac has.
        var local: [Bool] = []
    }

    private func key(_ id: GraphRowID) -> String {
        switch id {
        case .commit(let hash): return hash
        case .uncommitted(let url): return "uncommitted:\(url.path)"
        case .stash(let hash): return "stash:\(hash)"
        }
    }

    private func layout() -> Layout {
        var layout = Layout()
        let extrasByAnchor = Dictionary(grouping: extras.indices, by: { extras[$0].anchor })
        var owners: [Bool] = []
        func appendFiles(after id: GraphRowID, local: Bool) {
            guard id == openRow else { return }
            let owner = key(id)
            if let filesError {
                layout.rows.append(("\(owner)|error", .note(filesError)))
            } else if let files {
                if files.isEmpty { layout.rows.append(("\(owner)|empty", .note("No files changed"))) }
                layout.rows += files.map { ("\(owner)|\($0.path)", .file($0)) }
            } else {
                layout.rows.append(("\(owner)|loading", .note(nil)))
            }
            while owners.count < layout.rows.count { owners.append(local) }
        }
        for (index, commit) in commits.enumerated() {
            for extra in extrasByAnchor[commit.fullHash] ?? [] {
                layout.extraRow[extra] = layout.rows.count
                layout.rows.append((key(extras[extra].id), .extra(extra)))
                owners.append(false)
                appendFiles(after: extras[extra].id, local: false)
            }
            layout.commitRow[commit.fullHash] = layout.rows.count
            layout.commitIndex[commit.fullHash] = index
            layout.rows.append((commit.fullHash, .commit(index)))
            owners.append(commit.isUnpushed)
            appendFiles(after: .commit(commit.fullHash), local: commit.isUnpushed)
        }
        layout.local = owners

        // Lanes that start and stop crossing rows, swept from top to bottom.
        let count = layout.rows.count
        var opens = Array(repeating: [Int](), count: count + 1)
        var closes = Array(repeating: [Int](), count: count + 1)
        for commit in commits {
            guard let row = layout.commitRow[commit.fullHash] else { continue }
            opens[row].append(commit.lane)
            closes[row + 1].append(commit.lane)
            for (offset, parent) in commit.parents.enumerated() {
                let lane = offset < commit.parentLanes.count ? commit.parentLanes[offset] : commit.lane
                opens[row].append(lane)
                // A parent past the history limit: the line runs off the bottom.
                closes[(layout.commitRow[parent] ?? count - 1) + 1].append(lane)
            }
        }
        var crossing: [Int: Int] = [:]
        var reach = (0..<count).map { row -> Int in
            for lane in closes[row] { crossing[lane, default: 0] -= 1 }
            for lane in opens[row] { crossing[lane, default: 0] += 1 }
            return crossing.filter { $0.value > 0 }.keys.max() ?? 0
        }
        // The extras over one commit stack to the right of every line they cross, the top one furthest out,
        // so each dashed line runs down past the ones below it.
        for (anchor, stack) in extrasByAnchor {
            guard let anchorRow = layout.commitRow[anchor], let top = stack.compactMap({ layout.extraRow[$0] }).min() else { continue }
            let base = reach[top...anchorRow].max() ?? 0
            for (position, extra) in stack.enumerated() {
                guard let row = layout.extraRow[extra] else { continue }
                let lane = base + stack.count - position
                layout.extraLane[extra] = lane
                // The commit's own row too: the dashed line turns into it there, and its labels start past the turn.
                for crossed in row...anchorRow { reach[crossed] = max(reach[crossed], lane) }
            }
        }
        layout.indent = reach.map { laneX($0) + 12 }
        return layout
    }

    var body: some View {
        let layout = layout()
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    rails(layout)
                        .frame(height: rowHeight * CGFloat(layout.rows.count))
                    LazyVStack(spacing: 0) {
                        ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, item in
                            row(item.row, indent: layout.indent[index])
                                .frame(height: rowHeight)
                                .id(item.id)
                                .onAppear {
                                    if index == layout.rows.count - 1 { onReachEnd() }
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .opacity(waitsForFocus ? 0 : 1)
            .onChange(of: focus, initial: true) { _, target in scroll(to: target, in: layout, proxy: proxy) }
            .onChange(of: layout.rows.count) { _, _ in scroll(to: focus, in: layout, proxy: proxy) }
            // The diff pane takes the lower part; the clicked file scrolls back into view.
            .onChange(of: openFile?.path) { _, path in
                guard let path, let openRow else { return }
                DispatchQueue.main.async {
                    withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo("\(key(openRow))|\(path)") }
                }
            }
        }
    }

    /// Scrolls a row near the top once it is in the graph, then forgets it.
    private func scroll(to target: GraphRowID?, in layout: Layout, proxy: ScrollViewProxy) {
        let id = target.map(key)
        guard let id, layout.rows.contains(where: { $0.id == id }) else {
            // Nothing to scroll to: show the graph where it is.
            if waitsForFocus { DispatchQueue.main.async { waitsForFocus = false } }
            return
        }
        DispatchQueue.main.async {
            proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.12))
            focus = nil
            waitsForFocus = false
        }
    }

    @ViewBuilder
    private func row(_ row: Row, indent: CGFloat) -> some View {
        switch row {
        case .commit(let index):
            let commit = commits[index]
            CommitRow(commit: commit, laneColor: color(lane: commit.lane), folders: folders[commit.fullHash] ?? [])
                .padding(.leading, indent)
                .contentShape(Rectangle())
                .onTapGesture { onToggle(.commit(commit.fullHash)) }
        case .extra(let index):
            let extra = extras[index]
            HStack(spacing: 6) {
                Image(systemName: extra.kind == .uncommitted ? "pencil" : "tray")
                    .imageScale(.small)
                Text(extra.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(RepositoryText.age(extra.date))
                    .textRole(.secondary)
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .padding(.leading, indent + 6)
            .padding(.trailing, 14)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { onToggle(extra.id) }
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
                .onTapGesture { onOpenFile(file) }
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

    private func rails(_ layout: Layout) -> some View {
        Canvas { context, size in
            func y(_ row: Int) -> CGFloat { (CGFloat(row) + 0.5) * rowHeight }
            func shape(_ rows: Range<Int>) -> Path {
                let rect = CGRect(x: Self.bandInset, y: CGFloat(rows.lowerBound) * rowHeight,
                                  width: size.width - Self.bandInset * 2, height: CGFloat(rows.count) * rowHeight)
                return Path(roundedRect: rect, cornerRadius: 6)
            }
            /// Neighbouring rows that pass the test, as one block each, so a band has one pair of rounded corners.
            func runs(_ test: (Int) -> Bool) -> [Range<Int>] {
                var runs: [Range<Int>] = []
                var start: Int?
                for index in 0...layout.rows.count {
                    let inside = index < layout.rows.count && test(index)
                    if inside, start == nil { start = index }
                    if !inside, let first = start { runs.append(first..<index); start = nil }
                }
                return runs
            }
            var owner: GraphRowID?
            let selected = layout.rows.map { item -> Bool in
                switch item.row {
                case .commit(let commit): owner = .commit(commits[commit].fullHash)
                case .extra(let extra): owner = extras[extra].id
                case .file, .note: break
                }
                return owner.map(highlighted.contains) ?? false
            }
            // Work only this Mac has gets a warm band; the selected place's rows the accent band over it.
            // The orange edge runs inside the band's rounded corner and shows through the selection.
            for run in runs({ layout.local[$0] && !selected[$0] }) {
                context.fill(shape(run), with: .color(.orange.opacity(0.1)))
            }
            for run in runs({ selected[$0] }) {
                context.fill(shape(run), with: .color(.accentColor.opacity(0.16)))
            }
            for run in runs({ layout.local[$0] }) {
                context.drawLayer { layer in
                    layer.clip(to: shape(run))
                    let edge = CGRect(x: Self.bandInset, y: CGFloat(run.lowerBound) * rowHeight, width: 3, height: CGFloat(run.count) * rowHeight)
                    layer.fill(Path(edge), with: .color(.orange))
                }
            }
            for commit in commits {
                guard let row = layout.commitRow[commit.fullHash] else { continue }
                let start = CGPoint(x: laneX(commit.lane), y: y(row))
                for (offset, parentHash) in commit.parents.enumerated() {
                    // The core holds this lane for the parent until the parent's row, so nothing else sits on it.
                    let lane = offset < commit.parentLanes.count ? commit.parentLanes[offset] : commit.lane
                    let parent = layout.commitIndex[parentHash].flatMap { index in
                        layout.commitRow[parentHash].map { CGPoint(x: laneX(commits[index].lane), y: y($0)) }
                    }
                    let path = Self.edge(from: start, along: laneX(lane), to: parent, bottom: size.height)
                    context.stroke(path, with: .color(color(lane: lane)), lineWidth: 1.5)
                }
            }
            for (index, extra) in extras.enumerated() {
                guard let row = layout.extraRow[index], let lane = layout.extraLane[index],
                      let anchorRow = layout.commitRow[extra.anchor],
                      let anchor = layout.commitIndex[extra.anchor].map({ commits[$0] }) else { continue }
                // One color for everything on a commit, its lane's; the node's shape tells files from a stash.
                let color = color(lane: anchor.lane)
                let center = CGPoint(x: laneX(lane), y: y(row))
                // Drawn out from the commit, so where two lines share the way in, their dashes fall on the same spots.
                let commit = CGPoint(x: laneX(anchor.lane), y: y(anchorRow))
                var path = Path()
                path.move(to: commit)
                path.addLine(to: CGPoint(x: center.x - Self.turn, y: commit.y))
                path.addQuadCurve(to: CGPoint(x: center.x, y: commit.y - Self.turn), control: CGPoint(x: center.x, y: commit.y))
                path.addLine(to: center)
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                if extra.kind == .uncommitted {
                    context.fill(Self.circle(center, 4.5), with: .color(Color(nsColor: .textBackgroundColor)))
                    context.stroke(Self.circle(center, 4.5), with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                } else {
                    let square = Path(roundedRect: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9), cornerRadius: 2)
                    context.fill(square, with: .color(Color(nsColor: .textBackgroundColor)))
                    context.stroke(square, with: .color(color), lineWidth: 1.5)
                }
            }
            for commit in commits {
                guard let row = layout.commitRow[commit.fullHash] else { continue }
                let center = CGPoint(x: laneX(commit.lane), y: y(row))
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

    /// The bands keep clear of the pane's edges; the first lane sits inside them, clear of the orange edge.
    private static let bandInset: CGFloat = 8

    private func laneX(_ lane: Int) -> CGFloat {
        Self.bandInset + 12 + CGFloat(max(0, lane)) * laneSpacing
    }

    private func color(lane: Int) -> Color {
        Self.laneColors[max(0, lane) % Self.laneColors.count]
    }
}

private struct CommitRow: View {
    let commit: CommitSnapshot
    let laneColor: Color
    let folders: [String]

    var body: some View {
        HStack(spacing: 8) {
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
            Text(RepositoryText.age(commit.date))
                .textRole(.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(maxHeight: .infinity)
        .accessibilityValue(commit.isUnpushed ? "only on this Mac" : "")
        .help("\(commit.subject)\n\(commit.shortHash) · \(commit.author) · \(RepositoryText.fullDate(commit.date)), \(RepositoryText.ago(commit.date))"
              + (commit.isUnpushed ? "\nThis commit is only on this Mac" : ""))
    }

    /// A local branch and its remote twin at the same commit read as one label with a cloud.
    private var labels: [GraphLabel] {
        let local = Set(commit.refs.filter { $0.kind == .branch }.map(\.name))
        let synced = Set(commit.refs.filter { $0.kind == .remoteBranch }.compactMap { ref -> String? in
            guard let slash = ref.name.firstIndex(of: "/") else { return nil }
            let name = String(ref.name[ref.name.index(after: slash)...])
            return local.contains(name) ? name : nil
        })
        var labels: [GraphLabel] = []
        for ref in commit.refs where ref.kind == .head { labels.append(.head(commit.shortHash)) }
        for ref in commit.refs where ref.kind == .branch { labels.append(.branch(ref.name, onServer: synced.contains(ref.name), current: ref.isHead)) }
        for ref in commit.refs where ref.kind == .worktree { labels.append(.head(commit.shortHash)); labels.append(.folder(ref.name)) }
        labels += folders.map(GraphLabel.folder)
        for ref in commit.refs where ref.kind == .tag { labels.append(.tag(ref.name)) }
        for ref in commit.refs where ref.kind == .remoteBranch {
            let name = ref.name.firstIndex(of: "/").map { String(ref.name[ref.name.index(after: $0)...]) } ?? ref.name
            if !synced.contains(name) { labels.append(.remote(ref.name)) }
        }
        return labels
    }

    private func labels(shown: Int) -> some View {
        let all = labels
        return HStack(spacing: 4) {
            ForEach(Array(all.prefix(shown).enumerated()), id: \.offset) { _, label in
                LabelPill(label: label, color: laneColor)
            }
            if all.count > shown {
                Text(shown == 0 ? RepositoryText.counted(all.count, "label", "labels") : "+\(all.count - shown)")
                    .textRole(.label)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .help(all.dropFirst(shown).map(\.name).joined(separator: "\n"))
            }
        }
        .fixedSize()
    }
}

/// What a label on a commit names.
enum GraphLabel: Hashable {
    case branch(String, onServer: Bool, current: Bool)
    case remote(String)
    case folder(String)
    /// A detached HEAD, by its short hash.
    case head(String)
    case tag(String)

    var name: String {
        switch self {
        case .branch(let name, _, _), .remote(let name), .folder(let name), .head(let name), .tag(let name): return name
        }
    }
}

/// A label on a commit. Branches are filled with their lane's color; worktrees get an outline; the rest stays gray.
struct LabelPill: View {
    let label: GraphLabel
    let color: Color
    var role: TextRole = .label

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(iconColor)
            Text(label.name)
                .lineLimit(1)
            if case .branch(_, true, _) = label {
                Image(systemName: "cloud")
                    .imageScale(.small)
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .foregroundStyle(isBranch ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .textRole(role)
        .fontWeight(.medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(background)
        .fixedSize()
        .help(help)
    }

    private var icon: String {
        switch label {
        case .branch: return "arrow.triangle.branch"
        case .remote: return "cloud"
        case .folder: return "folder"
        case .head: return "smallcircle.filled.circle"
        case .tag: return "tag"
        }
    }

    private var isBranch: Bool {
        if case .branch = label { return true }
        return false
    }

    private var iconColor: Color {
        isBranch ? .white.opacity(0.85) : .secondary
    }

    /// Circular ends: the default continuous capsule draws stray ticks at the ends of short pills on macOS 26.
    @ViewBuilder
    private var background: some View {
        switch label {
        case .branch: Capsule(style: .circular).fill(color)
        case .folder: Capsule(style: .circular).strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
        case .remote, .head, .tag: Capsule(style: .circular).fill(Color.secondary.opacity(0.14))
        }
    }

    private var help: String {
        switch label {
        case .branch(let name, let onServer, let current):
            return "Branch \(name)" + (current ? ", checked out here" : "") + (onServer ? ". The server has it at the same commit." : ".")
        case .remote(let name): return "\(name), where the server has this branch"
        case .folder(let name): return "Worktree \(name)"
        case .head(let hash): return "Detached HEAD at \(hash)"
        case .tag(let name): return "Tag \(name)"
        }
    }
}

/// The subject, then its labels right after it. The labels take what they need first, but the
/// subject always keeps up to 120 pt, so a commit with many labels still says what it is.
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
        // Labels first, as VS Code puts them before the subject.
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: labels, height: bounds.height))
        subviews[0].place(at: CGPoint(x: bounds.minX + labels + (labels > 0 ? gap : 0), y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: subject, height: bounds.height))
    }

    private func widths(_ available: CGFloat, _ subviews: Subviews) -> (subject: CGFloat, labels: CGFloat) {
        let ideal = subviews[0].sizeThatFits(.unspecified).width
        let labels = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, available - min(ideal, subjectFloor) - gap), height: nil)).width
        return (min(ideal, max(0, available - labels - gap)), labels)
    }
}
