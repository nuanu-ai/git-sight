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
    /// The base's full ref; its line is drawn gray.
    let baseRef: String?
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
    /// Radius of the turn where a line leaves or joins a row: a quarter circle a lane wide, as in VS Code.
    private var turn: CGFloat { min(laneSpacing, rowHeight / 2) }
    /// Radius of the bends where a line moves over into a lane freed on its left.
    private var bend: CGFloat { min(rowHeight / 4, laneSpacing / 2) }
    /// Lines are thin, as in VS Code; the dots carry the weight.
    private static let lineWidth: CGFloat = 1
    /// Branch label colors with a little gray in them, so labels read without glaring. The hues are VS Code's graph
    /// palette, made to tell apart with color blindness too, in an order that never puts two alike side by side.
    /// Orange and red stay with the verdicts, so VS Code's amber is a gold here. The first is the current branch's.
    static let laneColors: [Color] = [
        Color(red: 0.24, green: 0.5, blue: 0.82),
        Color(red: 0.78, green: 0.22, blue: 0.49),
        Color(red: 0.16, green: 0.6, blue: 0.56),
        Color(red: 0.66, green: 0.53, blue: 0.1),
        Color(red: 0.58, green: 0.4, blue: 0.84),
        Color(red: 0.36, green: 0.58, blue: 0.24)
    ]
    /// The same colors at full strength for the thin lines, as bright as VS Code's.
    private static let lineColors: [Color] = [
        Color(red: 0.22, green: 0.58, blue: 1),
        Color(red: 0.86, green: 0.15, blue: 0.5),
        Color(red: 0.25, green: 0.69, blue: 0.65),
        Color(red: 0.93, green: 0.74, blue: 0.13),
        Color(red: 0.71, green: 0.43, blue: 1),
        Color(red: 0.45, green: 0.76, blue: 0.27)
    ]

    /// A line's color: the base's gray, or one from the palettes above.
    private enum Hue: Hashable {
        case base
        case palette(Int)

        var line: Color {
            if case .palette(let index) = self { return RepositoryGraph.lineColors[index] }
            return Color(white: 0.55)
        }

        var label: Color {
            if case .palette(let index) = self { return RepositoryGraph.laneColors[index] }
            return .gray
        }
    }

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
        /// Each commit's row of the graph, by its index in `commits`.
        var graph: [GraphRow<Hue>] = []
        /// The lines running down each row; for a commit's row, the ones going on below it.
        var lines: [[GraphRow<Hue>.Line]] = []
        /// Where each row's text starts: after the rightmost line crossing it.
        var indent: [CGFloat] = []
        /// The unpushed commit each row belongs to, for the band of work only this Mac has.
        var local: [Bool] = []
        /// Each commit's color, by hash: the color of the line of history it is on.
        var colors: [String: Hue] = [:]
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
        layout.graph = graph()
        for (index, row) in layout.graph.enumerated() { layout.colors[commits[index].fullHash] = row.color }

        // Rows between commits, files and extras, carry on the lines the commit above sends down.
        var running: [GraphRow<Hue>.Line] = []
        var reach: [Int] = []
        for item in layout.rows {
            if case .commit(let index) = item.row {
                let row = layout.graph[index]
                running = row.output
                reach.append(max(row.input.count, row.output.count, row.dot + 1) - 1)
            } else {
                reach.append(max(running.count - 1, 0))
            }
            layout.lines.append(running)
        }
        // The extras over one commit stack to the right of every line they cross, the top one furthest out,
        // so each dashed line runs down past the ones below it.
        for (anchor, stack) in extrasByAnchor {
            guard let anchorRow = layout.commitRow[anchor], let index = layout.commitIndex[anchor] else { continue }
            let row = layout.graph[index]
            // Right of the lines a merge starts too, so a dashed line never runs down a merged branch's lane.
            let first = max(row.input.count, row.output.count, row.dot + 1)
            for (position, extra) in stack.enumerated() {
                guard let extraRow = layout.extraRow[extra] else { continue }
                let lane = first + stack.count - 1 - position
                layout.extraLane[extra] = lane
                // The commit's own row too: the dashed line turns into it there, and its labels start past the turn.
                for crossed in extraRow...anchorRow { reach[crossed] = max(reach[crossed], lane) }
            }
        }
        layout.indent = reach.map { laneX($0) + 12 }
        return layout
    }

    /// Lanes and colors as VS Code has them. The current branch is blue down to where it meets the base, and the
    /// base's line and everything down its first parents are gray, so work that is not in the base stands out.
    /// Every other line takes the next color where it starts, at a branch tip or where a branch was merged.
    private func graph() -> [GraphRow<Hue>] {
        let index = Dictionary(commits.enumerated().map { ($0.element.fullHash, $0.offset) }) { first, _ in first }
        var base = Set<String>()
        var tip = commits.firstIndex { commit in
            commit.refs.contains { ref in
                guard let baseRef else { return false }
                return (ref.kind == .remoteBranch && "refs/remotes/\(ref.name)" == baseRef) || (ref.kind == .branch && "refs/heads/\(ref.name)" == baseRef)
            }
        }
        while let current = tip, base.insert(commits[current].fullHash).inserted {
            tip = commits[current].parents.first.flatMap { index[$0] }
        }
        var next = 0
        return CommitGraph.rows(commits, color: { commit in
            if commit.refs.contains(where: { $0.kind == .branch && $0.isHead }) { return .palette(0) }
            return base.contains(commit.fullHash) ? .base : nil
        }, fresh: {
            defer { next += 1 }
            return .palette(1 + next % (Self.laneColors.count - 1))
        })
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
                            row(item.row, indent: layout.indent[index], colors: layout.colors)
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
            .modifier(KeepsHead(head: layout.rows.first?.id, proxy: proxy, focus: focus, waitsForFocus: waitsForFocus))
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

    /// New commits arrive above the rows on screen, and the scroll view keeps those rows where they were.
    /// A graph showing its head scrolls up to the new head, so new work is never hidden above;
    /// one scrolled further down keeps its place.
    private struct KeepsHead: ViewModifier {
        struct Position: Equatable {
            var offset: CGFloat
            var height: CGFloat
            var head: String?
        }

        let head: String?
        let proxy: ScrollViewProxy
        let focus: GraphRowID?
        let waitsForFocus: Bool

        func body(content: Content) -> some View {
            if #available(macOS 15, *) {
                content.onScrollGeometryChange(for: Position.self) { geometry in
                    Position(offset: geometry.contentOffset.y + geometry.contentInsets.top, height: geometry.containerSize.height, head: head)
                } action: { old, new in
                    // A row to scroll to wins, and so does the first read.
                    guard focus == nil, !waitsForFocus, let previous = old.head, let head = new.head, head != previous,
                          old.offset < old.height / 2 else { return }
                    proxy.scrollTo(head, anchor: .top)
                }
            } else {
                content
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
    private func row(_ row: Row, indent: CGFloat, colors: [String: Hue]) -> some View {
        switch row {
        case .commit(let index):
            let commit = commits[index]
            CommitRow(commit: commit, laneColor: (colors[commit.fullHash] ?? .base).label, folders: folders[commit.fullHash] ?? [])
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
                Age(date: extra.date)
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
            // Lines go on a layer of their own, with a ring of space cut around every node, as in VS Code.
            context.drawLayer { context in
                // One path per color, stroked once, so a long history draws in a few calls.
                var paths: [Hue: Path] = [:]
                for (row, lines) in layout.lines.enumerated() {
                    let top = CGFloat(row) * rowHeight
                    guard case .commit(let index) = layout.rows[row].row else {
                        // Lines run straight through rows of files and extras.
                        for (lane, line) in lines.enumerated() {
                            paths[line.color, default: Path()].addPath(vertical(lane, from: top, to: top + rowHeight))
                        }
                        continue
                    }
                    for (path, hue) in Self.lines(layout.graph[index], at: top, rowHeight: rowHeight, laneX: laneX, turn: turn, bend: bend) {
                        paths[hue, default: Path()].addPath(path)
                    }
                }
                for (hue, path) in paths {
                    context.stroke(path, with: .color(hue.line), lineWidth: Self.lineWidth)
                }
                for (index, extra) in extras.enumerated() {
                    guard let row = layout.extraRow[index], let lane = layout.extraLane[index],
                          let anchorRow = layout.commitRow[extra.anchor], let anchor = layout.commitIndex[extra.anchor] else { continue }
                    // One color for everything on a commit, its line's; the node's shape tells files from a stash.
                    let color = layout.graph[anchor].color.line
                    let center = CGPoint(x: laneX(lane), y: y(row))
                    // Drawn out from the commit, so where two lines share the way in, their dashes fall on the same spots.
                    let commit = CGPoint(x: laneX(layout.graph[anchor].dot), y: y(anchorRow))
                    var path = Path()
                    path.move(to: commit)
                    path.addArc(tangent1End: CGPoint(x: center.x, y: commit.y), tangent2End: center, radius: turn)
                    path.addLine(to: center)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: Self.lineWidth, dash: [3, 3]))
                }
                context.blendMode = .destinationOut
                for (index, extra) in extras.enumerated() {
                    guard let row = layout.extraRow[index], let lane = layout.extraLane[index] else { continue }
                    let node = Self.extraNode(extra.kind, at: CGPoint(x: laneX(lane), y: y(row)))
                    context.fill(node, with: .color(.black))
                    context.stroke(node, with: .color(.black), lineWidth: 4)
                }
                for (index, commit) in commits.enumerated() {
                    guard let row = layout.commitRow[commit.fullHash] else { continue }
                    let space: CGFloat = Self.isHead(commit) ? 8 : commit.parents.count > 1 ? 7 : 6
                    context.fill(Self.circle(CGPoint(x: laneX(layout.graph[index].dot), y: y(row)), space), with: .color(.black))
                }
            }
            for (index, extra) in extras.enumerated() {
                guard let row = layout.extraRow[index], let lane = layout.extraLane[index],
                      let anchor = layout.commitIndex[extra.anchor] else { continue }
                let node = Self.extraNode(extra.kind, at: CGPoint(x: laneX(lane), y: y(row)))
                context.stroke(node, with: .color(layout.graph[anchor].color.line), style: StrokeStyle(lineWidth: 1.5, dash: extra.kind == .uncommitted ? [2.5, 2] : []))
            }
            // Nodes sized as VS Code sizes them.
            for (index, commit) in commits.enumerated() {
                guard let row = layout.commitRow[commit.fullHash] else { continue }
                let center = CGPoint(x: laneX(layout.graph[index].dot), y: y(row))
                let color = layout.graph[index].color.line
                if Self.isHead(commit) {
                    // The commit checked out: an open ring.
                    context.stroke(Self.circle(center, 5), with: .color(color), lineWidth: 2)
                } else if commit.parents.count > 1 {
                    // A merge: a thin ring with a dot.
                    context.stroke(Self.circle(center, 4.5), with: .color(color), lineWidth: 1)
                    context.fill(Self.circle(center, 2), with: .color(color))
                } else {
                    context.fill(Self.circle(center, 4), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func vertical(_ lane: Int, from top: CGFloat, to bottom: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: laneX(lane), y: top))
            path.addLine(to: CGPoint(x: laneX(lane), y: bottom))
        }
    }

    /// A commit's row, drawn as VS Code draws it: lines that go on run straight down or bend over into a lane
    /// freed on their left; lines that end turn in to the dot; the first parent's line leaves the dot straight
    /// down, and a merged branch's turns out to its own lane on the right.
    private static func lines(
        _ row: GraphRow<Hue>, at top: CGFloat, rowHeight: CGFloat, laneX: (Int) -> CGFloat, turn: CGFloat, bend: CGFloat
    ) -> [(Path, Hue)] {
        let middle = top + rowHeight / 2
        let bottom = top + rowHeight
        let dot = laneX(row.dot)
        var paths: [(Path, Hue)] = []
        for (lane, line) in row.input.enumerated() {
            let x = laneX(lane)
            var path = Path()
            path.move(to: CGPoint(x: x, y: top))
            if let next = row.next[lane] {
                let to = laneX(next)
                if next != lane {
                    // Under a commit with no parents a line can move into the dot's own lane; it bends in below the dot.
                    let level = next == row.dot ? bottom - bend : middle
                    path.addArc(tangent1End: CGPoint(x: x, y: level), tangent2End: CGPoint(x: to, y: level), radius: bend)
                    path.addArc(tangent1End: CGPoint(x: to, y: level), tangent2End: CGPoint(x: to, y: bottom), radius: bend)
                }
                path.addLine(to: CGPoint(x: to, y: bottom))
            } else {
                if lane != row.dot {
                    path.addArc(tangent1End: CGPoint(x: x, y: middle), tangent2End: CGPoint(x: dot, y: middle), radius: turn)
                }
                path.addLine(to: CGPoint(x: dot, y: middle))
            }
            paths.append((path, line.color))
        }
        for parent in row.parents {
            let x = laneX(parent)
            var path = Path()
            path.move(to: CGPoint(x: dot, y: middle))
            if parent != row.dot {
                path.addArc(tangent1End: CGPoint(x: x, y: middle), tangent2End: CGPoint(x: x, y: bottom), radius: turn)
            }
            path.addLine(to: CGPoint(x: x, y: bottom))
            paths.append((path, row.output[parent].color))
        }
        return paths
    }

    /// The checked-out commit: the current branch's, or a detached HEAD's.
    private static func isHead(_ commit: CommitSnapshot) -> Bool {
        commit.refs.contains { $0.kind == .head || ($0.kind == .branch && $0.isHead) }
    }

    /// Uncommitted files are a dashed circle; a stash is a square.
    private static func extraNode(_ kind: GraphExtra.Kind, at center: CGPoint) -> Path {
        kind == .uncommitted
            ? circle(center, 4.5)
            : Path(roundedRect: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9), cornerRadius: 2)
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    /// The bands keep clear of the pane's edges; the first lane sits inside them, clear of the orange edge.
    private static let bandInset: CGFloat = 8

    private func laneX(_ lane: Int) -> CGFloat {
        Self.bandInset + 12 + CGFloat(max(0, lane)) * laneSpacing
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
            Age(date: commit.date)
                .foregroundStyle(.secondary)
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

/// How long ago a row's commit or change was. A row is drawn once and kept while its commit is,
/// so the age counts on by itself.
private struct Age: View {
    let date: Date

    var body: some View {
        // The schedule only redraws: its dates are the starts of minutes, behind the clock.
        TimelineView(.everyMinute) { _ in
            Text(RepositoryText.age(date))
                .textRole(.secondary)
                .monospacedDigit()
        }
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
