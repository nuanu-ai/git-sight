import GitSightCore
import SwiftUI

/// One repository: its worktrees and branches with work on the left, the selected one's facts
/// and the graph of every branch on the right, and a file's diff under the graph once clicked.
struct RepositoryView: View {
    @Bindable var model: WorkspaceModel
    let repository: RepositorySnapshot

    /// The list's width, kept across launches; HSplitView forgets where its divider was.
    @AppStorage("placeListWidth") private var listWidth = 360.0

    var body: some View {
        HStack(spacing: 0) {
            PlaceList(model: model, repository: repository)
                .frame(width: listWidth)
            ColumnDivider(width: $listWidth)
            GraphPane(model: model, repository: repository)
                .frame(minWidth: 420, maxWidth: .infinity)
        }
        .coordinateSpace(name: ColumnDivider.space)
    }
}

/// The line between the list and the graph; dragging it sets the list's width.
private struct ColumnDivider: View {
    @Binding var width: Double

    var body: some View {
        Divider()
            .overlay {
                // A wider grip than the line itself, as macOS split views have.
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(coordinateSpace: .named(Self.space)).onChanged { value in
                        width = min(520, max(260, value.location.x.rounded()))
                    })
            }
    }

    static let space = "repository"
}

// MARK: - The list of worktrees and branches

private struct PlaceList: View {
    @Bindable var model: WorkspaceModel
    let repository: RepositorySnapshot
    @AppStorage("showsLeftovers") private var showsLeftovers = false
    @FocusState private var isFocused: Bool

    /// Branches not checked out, by what is wrong with them.
    private enum Group: CaseIterable {
        case local, unmerged, leftover
    }

    var body: some View {
        // The order moves on with every rescan; the ages on the rows count on every minute.
        let now = Date()
    let sections = sections(now: now)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    head(now: now)
                    section("Worktrees", systemImage: "folder", count: sections.worktrees.count) {
                        ForEach(sections.worktrees, id: \.id) { place in
                            PlaceRow(model: model, repository: repository, place: place, now: now)
                        }
                    }
                    if !sections.branches.isEmpty {
                        section("Branches not checked out", systemImage: "arrow.triangle.branch", count: sections.branches.count) {
                            ForEach(Group.allCases, id: \.self) { group in
                                subgroup(group, places: sections.branches.filter { self.group(of: $0) == group }, now: now)
                            }
                        }
                    }
                    if !sections.deleted.isEmpty {
                        section("Stashes from deleted branches", systemImage: "tray", count: sections.deleted.count) {
                            ForEach(sections.deleted, id: \.id) { place in
                                PlaceRow(model: model, repository: repository, place: place, now: now)
                            }
                        }
                    }
                    let quiet = quietBranches
                    if quiet > 0 {
                        Text(repository.weight(now: now) > 0
                             ? "\(quiet) more \(quiet == 1 ? "branch" : "branches") merged and on the server, nothing to do."
                             : "\(RepositoryText.counted(quiet, "branch", "branches")) merged and on the server, nothing to do.")
                            .textRole(.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 16)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedPlaceID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(by: -1, in: sections.order) }
        .onKeyPress(.downArrow) { move(by: 1, in: sections.order) }
        .background(.background)
    }

    private struct Sections {
        var worktrees: [WorkPlace] = []
        var branches: [WorkPlace] = []
        var deleted: [WorkPlace] = []
        /// Rows in the order they are on screen, for the arrow keys.
        var order: [WorkPlace] = []
    }

    private func sections(now: Date) -> Sections {
        let heaviest: (WorkPlace, WorkPlace) -> Bool = { left, right in
            let a = left.weight(now: now), b = right.weight(now: now)
            if a != b { return a > b }
            return left.isMainWorktree && !right.isMainWorktree
        }
        var sections = Sections()
        let places = repository.places.filter { place in
            model.filter.isEmpty || repository.name.localizedCaseInsensitiveContains(model.filter)
                || (place.branchName ?? "").localizedCaseInsensitiveContains(model.filter)
                || (place.worktree?.name ?? "").localizedCaseInsensitiveContains(model.filter)
        }
        sections.worktrees = places.filter { $0.worktree != nil }.sorted(by: heaviest)
        sections.branches = places.filter { $0.worktree == nil && $0.branch != nil }.sorted(by: heaviest)
        sections.deleted = places.filter(\.isDeletedBranch).sorted(by: heaviest)
        sections.order = sections.worktrees
            + Group.allCases.flatMap { group in
                group == .leftover && !showsLeftovers ? [] : sections.branches.filter { self.group(of: $0) == group }
            }
            + sections.deleted
        return sections
    }

    private func group(of place: WorkPlace) -> Group {
        let kinds = Set(place.pieces.map(\.kind))
        if !kinds.isDisjoint(with: [.unpushed, .detached, .stash, .uncommitted]) { return .local }
        if kinds.contains(.unmerged) { return .unmerged }
        return .leftover
    }

    /// Branches with nothing to do that the list leaves out.
    private var quietBranches: Int {
        let shown = Set(repository.places.compactMap(\.branchName))
        return repository.branches.count { !$0.hasWorktree && !shown.contains($0.name) }
    }

    private func move(by step: Int, in order: [WorkPlace]) -> KeyPress.Result {
        guard !order.isEmpty else { return .ignored }
        let index = order.firstIndex { $0.id == model.selectedPlaceID }.map { $0 + step } ?? 0
        guard order.indices.contains(index) else { return .handled }
        model.select(order[index])
        return .handled
    }

    private func head(now: Date) -> some View {
        let weight = repository.weight(now: now)
        return VStack(alignment: .leading, spacing: 4) {
            // The button is centered on the title's line, the same way the selection's sits over the graph.
            HStack(alignment: .center, spacing: 8) {
                Text(repository.name)
                    .textRole(.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if weight > 0 {
                    CopyButton(model: model, id: repository.path.path,
                               help: "Copy a task for an agent to sort out everything in this repository") {
                        WorkText.task(for: repository, now: now)
                    }
                }
            }
            // The path keeps its line to itself when the column is too narrow to share it.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    path.fixedSize()
                    facts(weight: weight, afterPath: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    path
                    HStack(alignment: .firstTextBaseline, spacing: 4) { facts(weight: weight, afterPath: false) }
                }
            }
            .textRole(.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var path: some View {
        Text(RepositoryText.path(repository.path))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    @ViewBuilder
    private func facts(weight: Double, afterPath: Bool) -> some View {
        Text("\(afterPath ? "· " : "")base branch \(repository.base)")
            .lineLimit(1)
        if weight > 0 {
            Text("· weight \(RepositoryText.weight(weight))")
                .monospacedDigit()
                .lineLimit(1)
            WeightInfoButton(model: model)
        }
    }

    private func section(_ title: String, systemImage: String, count: Int, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The icon in the rows' dot column, the title over their names.
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Text(title)
                    .fontWeight(.semibold)
                Text("\(count)")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .textRole(.secondary)
            .foregroundStyle(.secondary)
            .frame(minHeight: 24)
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isHeader)
            rows()
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func subgroup(_ group: Group, places: [WorkPlace], now: Date) -> some View {
        if !places.isEmpty {
            switch group {
            case .local:
                subtitle("only on this Mac")
            case .unmerged:
                subtitle("not merged into \(repository.base)")
            case .leftover:
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsLeftovers.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .imageScale(.small)
                            .rotationEffect(.degrees(showsLeftovers ? 90 : 0))
                        Text("merged, safe to remove · \(places.count)")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .textRole(.secondary)
                .foregroundStyle(.secondary)
                .frame(minHeight: 24)
                .padding(.leading, 40)
                .accessibilityValue(showsLeftovers ? "shown" : "hidden")
            }
            if group != .leftover || showsLeftovers {
                ForEach(places, id: \.id) { place in
                    PlaceRow(model: model, repository: repository, place: place, now: now)
                }
            }
        }
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .textRole(.secondary)
            .foregroundStyle(.secondary)
            .frame(minHeight: 24)
            .padding(.leading, 40)
    }
}

/// A worktree on two lines, its folder and then its branch; a branch or a deleted branch's stash on one.
private struct PlaceRow: View {
    let model: WorkspaceModel
    let repository: RepositorySnapshot
    let place: WorkPlace
    let now: Date

    var body: some View {
        let selected = model.selectedPlaceID == place.id
        let lead = place.lead(now: now)
        HStack(alignment: .top, spacing: 8) {
            VerdictDot(verdict: lead?.verdict(now: now))
                .frame(width: 16, height: lineHeight)
            VStack(alignment: .leading, spacing: 2) {
                firstLine
                    .frame(height: lineHeight)
                if let worktree = place.worktree {
                    secondLine(worktree)
                        .frame(height: lineHeight)
                }
            }
            Spacer(minLength: 8)
            // The age counts on between rescans, and its color with it.
            TimelineView(.everyMinute) { _ in
                let now = Date()
                Text(RepositoryText.age(lead?.date, now: now))
                    .textRole(.secondary)
                    .monospacedDigit()
                    .fontWeight(lead?.verdict(now: now) == .forgotten ? .semibold : .regular)
                    .selectableTint(lead.map { $0.verdict(now: now).textColor } ?? .secondary)
            }
            .frame(height: lineHeight)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
        .environment(\.backgroundProminence, selected ? .increased : .standard)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { model.select(place) }
        .id(place.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @AppStorage(TextRole.sizeKey) private var textSize = TextRole.standardSize
    private var lineHeight: CGFloat { (textSize * 1.4).rounded() }

    @ViewBuilder
    private var firstLine: some View {
        HStack(spacing: 6) {
            if let worktree = place.worktree {
                Image(systemName: "folder")
                    .imageScale(.small)
                    .selectableTint(.secondary)
                Text(worktree.path.lastPathComponent)
                    .fontWeight(.medium)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if place.isMainWorktree {
                    // Goes first when the row narrows: the name matters more.
                    ViewThatFits { Text("main worktree").textRole(.secondary).selectableTint(.secondary); EmptyView() }
                }
                if let piece = place.pieces.first(where: { $0.kind == .uncommitted }) {
                    if now.timeIntervalSince(piece.date) < RepositorySnapshot.liveWindow { LiveDot(date: piece.date) }
                    WorkChip(model: model, place: place, pieces: [piece], repository: repository, now: now)
                }
            } else if place.isDeletedBranch, let stash = place.pieces.first?.stash {
                Image(systemName: "tray")
                    .imageScale(.small)
                    .selectableTint(.secondary)
                Text("\"\(stash.text)\"")
                    .fontWeight(.medium)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if let branch = stash.branch {
                    Text("from \(branch)").textRole(.secondary).selectableTint(.secondary)
                }
                branchChips
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                    .selectableTint(.secondary)
                Text(place.branchLabel)
                    .fontWeight(.medium)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                branchChips
            }
        }
    }

    private func secondLine(_ worktree: WorktreeSnapshot) -> some View {
        HStack(spacing: 6) {
            if let branch = place.branchName {
                Image(systemName: "arrow.triangle.branch")
                    .imageScale(.small)
                    .selectableTint(.secondary)
                Text(branch)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            } else {
                Image(systemName: "smallcircle.filled.circle")
                    .imageScale(.small)
                    .selectableTint(.secondary)
                Text("detached at").selectableTint(.secondary)
                Text(String((worktree.head ?? "").prefix(7)))
                    .monospaced()
            }
            branchChips
        }
    }

    /// The branch's own work; uncommitted files belong to the worktree's line, stashes share one chip.
    @ViewBuilder
    private var branchChips: some View {
        let own = place.pieces.filter { $0.kind != .uncommitted && $0.kind != .stash }
        let stashes = place.pieces.filter { $0.kind == .stash }
        ForEach(Array(own.enumerated()), id: \.offset) { _, piece in
            WorkChip(model: model, place: place, pieces: [piece], repository: repository, now: now)
        }
        if !stashes.isEmpty {
            WorkChip(model: model, place: place, pieces: stashes, repository: repository, now: now)
        }
    }
}

/// An icon and a number for one kind of work. A click selects the row and opens that work in the graph.
private struct WorkChip: View {
    let model: WorkspaceModel
    let place: WorkPlace
    /// One piece, or every stash of the place.
    let pieces: [WorkPiece]
    let repository: RepositorySnapshot
    let now: Date

    var body: some View {
        let piece = pieces[0]
        let verdict = pieces.map { $0.verdict(now: now) }.max() ?? .inProgress
        Button {
            model.select(place, piece: piece)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: piece.kind.systemImage)
                    .imageScale(.small)
                if piece.kind == .leftover {
                    Text("merged")
                } else if piece.kind != .stash || pieces.count > 1 {
                    Text((piece.kind == .stash ? pieces.count : piece.amount).formatted())
                        .fontWeight(verdict == .forgotten ? .semibold : .medium)
                        .monospacedDigit()
                }
            }
            .selectableTint(verdict == .inProgress ? .secondary : verdict == .clutter ? Color.secondary.opacity(0.7) : verdict.textColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(pieces.map { WorkText.fact($0, in: place, repository: repository, now: now) }.joined(separator: "\n"))
    }
}

/// Copies a task to the clipboard; the icon turns into a checkmark for a moment, the label stays.
/// The repository's button and the selection's look the same: they differ only in what they cover,
/// which their place says, next to the repository's name or the branch's.
private struct CopyButton: View {
    let model: WorkspaceModel
    let id: String
    let help: String
    let text: () -> String

    var body: some View {
        let copied = model.copiedID == id
        Button {
            model.copy(text(), id: id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                    .frame(width: 16)
                Text("Copy task")
            }
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityValue(copied ? "Copied" : "")
    }
}

// MARK: - The selection, the graph and the diff

private struct GraphPane: View {
    @Bindable var model: WorkspaceModel
    let repository: RepositorySnapshot
    /// The diff's share of the height under the selection; the user drags the line between them.
    @AppStorage("diffFraction") private var diffFraction = 0.6

    var body: some View {
        VStack(spacing: 0) {
            if let place = model.selectedPlace {
                SelectionHeader(model: model, repository: repository, place: place)
                Divider()
            }
            // One graph whether the diff is open or not: moving it into another container would rebuild
            // its scroll view, which then jumped back to the top on the first file opened.
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    graph
                        .frame(height: model.diffFile == nil ? geometry.size.height : geometry.size.height * (1 - diffFraction))
                    if let file = model.diffFile {
                        PaneDivider(fraction: $diffFraction, height: geometry.size.height)
                        DiffPane(file: file, diff: model.fileDiff, error: model.fileDiffError, close: model.closeDiff)
                    }
                }
            }
            .coordinateSpace(name: PaneDivider.space)
        }
        .background(.background)
        .onExitCommand { model.closeDiff() }
    }

    @ViewBuilder
    private var graph: some View {
        VStack(spacing: 0) {
            // With the graph, not before it: the title is only known once the read says which line it shows.
            if model.history != nil {
                GraphLegend(scope: model.scope, showAllBranches: model.showAllBranches)
                Divider()
            }
            if let error = model.historyError {
                ContentUnavailableView("Couldn't read the history", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let commits = model.history {
                RepositoryGraph(
                    commits: commits,
                    extras: extras,
                    folders: folders,
                    baseRef: repository.baseRef,
                    highlighted: highlighted(in: commits),
                    openRow: model.openRow,
                    files: model.rowFiles,
                    filesError: model.rowFilesError,
                    openFile: model.diffFile,
                    focus: $model.focusRow,
                    waitsForFocus: $model.graphWaitsForFocus,
                    onToggle: model.toggle,
                    onOpenFile: model.toggleDiff,
                    onReachEnd: model.loadMoreHistory
                )
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Uncommitted files on each worktree's HEAD and every stash on the commit it was made on.
    private var extras: [GraphExtra] {
        let worktrees = repository.worktrees.compactMap { worktree -> GraphExtra? in
            guard worktree.dirtyFileCount > 0, let head = worktree.head else { return nil }
            return GraphExtra(id: .uncommitted(worktree.path), kind: .uncommitted, anchor: head,
                              text: "\(RepositoryText.files(worktree.dirtyFileCount)) uncommitted in \(worktree.path.lastPathComponent)",
                              date: worktree.dirtyModifiedAt ?? worktree.lastActivity ?? Date())
        }
        let stashes = repository.stashes.compactMap { stash -> GraphExtra? in
            guard let base = stash.base else { return nil }
            return GraphExtra(id: .stash(stash.hash), kind: .stash, anchor: base, text: "Stash \"\(stash.text)\"", date: stash.date)
        }
        return worktrees + stashes
    }

    /// Worktree folders by the commit their branch is at. A worktree on no branch is already labeled by the history.
    private var folders: [String: [String]] {
        Dictionary(grouping: repository.worktrees.filter { $0.branch != nil && $0.head != nil }, by: { $0.head ?? "" })
            .mapValues { $0.map { $0.path.lastPathComponent } }
    }

    /// The selected place's own rows: its commits down to where they join the base, its uncommitted files and stashes.
    private func highlighted(in commits: [CommitSnapshot]) -> Set<GraphRowID> {
        guard let place = model.selectedPlace else { return [] }
        var rows = Set<GraphRowID>()
        if let worktree = place.worktree, worktree.dirtyFileCount > 0 { rows.insert(.uncommitted(worktree.path)) }
        for piece in place.pieces { if let stash = piece.stash { rows.insert(.stash(stash.hash)) } }

        let byHash = Dictionary(commits.map { ($0.fullHash, $0) }, uniquingKeysWith: { first, _ in first })
        let tip: String? = place.worktree?.head ?? place.branchName.flatMap { name in
            commits.first { $0.refs.contains { $0.kind == .branch && $0.name == name } }?.fullHash
        }
        guard let tip else { return rows }
        if model.scope != nil {
            // The base's commits aren't in a single line's history, so the read said which ones are the branch's own.
            rows.formUnion(model.scopeOwnCommits.map { .commit($0) })
            if !rows.contains(where: \.isCommit) { rows.insert(.commit(tip)) }
            return rows
        }
        // What the base already has, on the server if it is there, so the base's own unpushed commits still count.
        let baseRefs = commits.filter { commit in
            commit.refs.contains { $0.kind == .remoteBranch && "refs/remotes/\($0.name)" == repository.baseRef }
        }
        let baseTips = baseRefs.isEmpty
            ? commits.filter { $0.refs.contains { $0.kind == .branch && $0.name == repository.base } }
            : baseRefs
        var inBase = Set<String>()
        var queue = baseTips.map(\.fullHash)
        while let hash = queue.popLast() {
            guard inBase.insert(hash).inserted, let commit = byHash[hash] else { continue }
            queue += commit.parents
        }
        var hash: String? = tip
        while let current = hash, !inBase.contains(current), let commit = byHash[current] {
            rows.insert(.commit(current))
            hash = commit.parents.first
        }
        if rows.isEmpty || !rows.contains(where: \.isCommit) { rows.insert(.commit(tip)) }
        return rows
    }
}

/// The selected worktree or branch: what it is, one line per piece of work, and where it lives.
private struct SelectionHeader: View {
    let model: WorkspaceModel
    let repository: RepositorySnapshot
    let place: WorkPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                what
                Spacer(minLength: 8)
                if !place.pieces.isEmpty {
                    CopyButton(model: model, id: place.id, help: "Copy a task for an agent to sort out only this") {
                        model.task(for: place) ?? ""
                    }
                }
            }
            if place.pieces.isEmpty {
                Text(WorkText.clean(place))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(place.pieces.enumerated()), id: \.offset) { _, piece in
                        FactButton(model: model, repository: repository, place: place, piece: piece)
                    }
                }
                .padding(.leading, -6)
            }
            if let worktree = place.worktree {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .imageScale(.small)
                    Text(RepositoryText.path(worktree.path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button { Workspace.reveal(worktree.path) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                    Button { Workspace.openTerminal(at: worktree.path) } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Open in Terminal")
                    .accessibilityLabel("Open in Terminal")
                }
                .buttonStyle(.borderless)
                .textRole(.secondary)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var what: some View {
        let color = RepositoryGraph.laneColors[0]
        if place.isDeletedBranch, let stash = place.pieces.first?.stash {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .foregroundStyle(.secondary)
                let count = place.pieces.count { $0.kind == .stash }
                Text(count > 1 ? "\(count) stashes from \(place.branchLabel)" : "Stash \"\(stash.text)\"")
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .textRole(.title)
        } else {
            HStack(spacing: 6) {
                if let worktree = place.worktree {
                    LabelPill(label: .folder(worktree.path.lastPathComponent), color: color, role: .primary)
                }
                if let name = place.branchName {
                    let local = place.pieces.contains { $0.kind == .unpushed }
                    let branch = place.branch
                    let synced = branch.map { $0.upstream != nil && !$0.upstreamGone && $0.ahead == 0 && $0.behind == 0 } ?? false
                    LabelPill(label: .branch(name, onServer: synced && !local, current: false), color: color, role: .primary)
                } else if let head = place.worktree?.head {
                    LabelPill(label: .head(String(head.prefix(7))), color: color, role: .primary)
                }
            }
        }
    }
}

/// One piece of work as a sentence. A click scrolls the graph to its row and opens its files.
private struct FactButton: View {
    let model: WorkspaceModel
    let repository: RepositorySnapshot
    let place: WorkPlace
    let piece: WorkPiece

    var body: some View {
        let verdict = piece.verdict(now: Date())
        let hoverID = "fact:\(place.id):\(piece.kind):\(piece.stash?.hash ?? "")"
        let isHovered = model.hoveredID == hoverID
        Button {
            model.select(place, piece: piece)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: piece.kind.systemImage)
                    .imageScale(.small)
                    .foregroundStyle(verdict == .abandoned || verdict == .forgotten ? verdict.color : Color.secondary)
                    .frame(width: 16)
                // The hint is laid out even while hidden, so the line keeps its width when it shows;
                // where the pane is too narrow for it, it goes and the sentence keeps the room.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(WorkText.fact(piece, in: place, repository: repository))
                        Text("show in graph")
                            .textRole(.label)
                            .foregroundStyle(.tertiary)
                            .opacity(isHovered ? 1 : 0)
                    }
                    .fixedSize()
                    Text(WorkText.fact(piece, in: place, repository: repository))
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverID(hoverID, in: model)
    }
}

/// What the marks in the graph mean, over it. When the pane narrows the marks wrap, and "All branches" goes first;
/// a single branch's title stays, since it says why the graph shows less.
private struct GraphLegend: View {
    let scope: HistoryScope?
    let showAllBranches: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 8)
                marks
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                if scope != nil { title }
                marks
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textRole(.label)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var title: some View {
        if let scope {
            HStack(spacing: 12) {
                Text("History of \(scope.title)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("This is older than the newest commits of all branches, so the graph shows its history alone.")
                Button("All branches", action: showAllBranches)
                    .buttonStyle(.link)
                    .foregroundStyle(.tint)
                    .fixedSize()
            }
        } else {
            Text("All branches")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        }
    }

    private var marks: some View {
        FlowLayout(spacing: 12, lineSpacing: 4) {
            LabelPill(label: .branch("branch", onServer: false, current: false), color: RepositoryGraph.laneColors[0])
                .help("")
            Label("on the server", systemImage: "cloud")
            LabelPill(label: .folder("worktree"), color: .secondary)
                .help("")
            HStack(spacing: 4) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
                    .frame(width: 9, height: 9)
                Text("uncommitted")
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(lineWidth: 1.5)
                    .frame(width: 9, height: 9)
                Text("stash")
            }
            HStack(spacing: 4) {
                Rectangle()
                    .fill(.orange)
                    .frame(width: 3, height: 12)
                    .background(alignment: .leading) { Rectangle().fill(.orange.opacity(0.1)).frame(width: 14, height: 12) }
                    .frame(width: 14, alignment: .leading)
                Text("only on this Mac")
            }
        }
    }
}

/// Lays its views out in a row and wraps them onto the next line when the row is full, like words.
private struct FlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (frame, subview) in zip(frames(width: bounds.width, subviews: subviews), subviews) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Items on one line are centered on it, so pills and plain labels line up.
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var lines: [[CGRect]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append(CGRect(origin: CGPoint(x: x, y: 0), size: size))
            x += size.width + spacing
        }
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for line in lines where !line.isEmpty {
            let height = line.map(\.height).max() ?? 0
            frames += line.map { $0.offsetBy(dx: 0, dy: y + (height - $0.height) / 2) }
            y += height + lineSpacing
        }
        return frames
    }
}
