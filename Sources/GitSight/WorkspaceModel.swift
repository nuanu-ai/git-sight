import AppKit
import Foundation
import GitSightCore
import Observation

/// A row of the graph: a commit, uncommitted files on top of a worktree's HEAD, or a stash on its base.
enum GraphRowID: Hashable {
    case commit(String)
    case uncommitted(URL)
    case stash(String)
}

@MainActor
@Observable
final class WorkspaceModel {
    private static let rootKey = "rootPath"
    /// The repository on screen when the app quit, opened again after the first scan.
    private static let openRepositoryKey = "openRepositoryPath"
    /// Coming back to the app rescans only if the last result is older than this.
    private static let refreshInterval: TimeInterval = 60
    /// A window left open rescans this often, for new repositories and work that aged into a new verdict.
    private static let periodicScanInterval: Duration = .seconds(5 * 60)

    private(set) var rootURL: URL?
    private(set) var repositories: [RepositorySnapshot] = []
    private(set) var isScanning = false
    private(set) var scanProgress: RepositoryScanProgress?
    private(set) var scanFailures: [RepositoryScanFailure] = []
    private(set) var errorMessage: String?
    private(set) var lastScanDate: Date?
    /// The user stopped the scan; coming back to the app does not restart it.
    private(set) var scanStopped = false
    var filter = ""
    var showsScanFailures = false
    // View state that outlives a redraw lives here: `@State` is a macro in the macOS 26 SDK,
    // and the Command Line Tools do not ship its plugin.
    var overviewSort = OverviewSort.weight
    var showsWeightInfo = false
    /// The row or line under the pointer, for its hover highlight.
    var hoveredID: String?
    /// What was just copied, for a moment of confirmation: a place's id, or a repository's path.
    private(set) var copiedID: String?

    /// The repository on screen; nil shows the overview.
    private(set) var selectedPath: URL?
    /// The worktree or branch selected in the repository's list.
    private(set) var selectedPlaceID: String?

    /// Every branch of the selected repository, newest first, or the scope's history; nil while it loads.
    private(set) var history: [CommitSnapshot]?
    /// Set when the selected row is older than the newest commits of all branches: the graph then
    /// follows that one line of history, so the row is in it however far back it is.
    private(set) var scope: HistoryScope?
    /// Commits on the scope's line that the base branch doesn't have, the selected branch's own work.
    private(set) var scopeOwnCommits: Set<String> = []
    /// The line of history that holds the selection, checked against each read of all branches.
    private var selectedLine: HistoryScope?
    /// The selection's row, scrolled to again when the graph switches lines: the old graph may have used up `focusRow`.
    private var selectedRow: GraphRowID?
    private(set) var historyError: String?
    /// How many commits the history reads; grows as the user scrolls to its end.
    private var historyLimit = RepositoryInspector.historyPage
    private var isLoadingMore = false

    /// The graph row whose files are listed under it.
    private(set) var openRow: GraphRowID?
    /// Nil while they load.
    private(set) var rowFiles: [CommitFileSnapshot]?
    private(set) var rowFilesError: String?
    /// A row the graph scrolls to once it is drawn. Kept until the history that holds it has loaded.
    var focusRow: GraphRowID?
    /// The place whose tip row is still to be found in history that has not loaded yet.
    private var pendingTip: String?
    /// A repository's first graph stays hidden until it has scrolled to `focusRow`, so its top never flashes first.
    var graphWaitsForFocus = false
    /// The file whose diff is open under the graph.
    private(set) var diffFile: CommitFileSnapshot?
    /// Nil while it loads.
    private(set) var fileDiff: FileDiff?
    private(set) var fileDiffError: String?

    private var scanTask: Task<Void, Never>?
    /// Follows edits, commits and stashes as they happen; replaced after every scan.
    private var watcher: RepositoryWatcher?
    private var changedPaths: Set<URL> = []
    private var changeTask: Task<Void, Never>?
    /// Tells a scan's late progress and result apart from those of the scan that replaced it.
    private var scanID: UUID?
    private var historyTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.rootKey) {
            rootURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: Self.periodicScanInterval)
                guard let self else { return }
                self.refreshIfStale()
            }
        }
    }

    var selectedRepository: RepositorySnapshot? {
        repositories.first { $0.path == selectedPath }
    }

    var selectedPlace: WorkPlace? {
        selectedRepository?.places.first { $0.id == selectedPlaceID }
    }

    var filteredRepositories: [RepositorySnapshot] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.path.localizedCaseInsensitiveContains(query)
                || $0.branches.contains { $0.name.localizedCaseInsensitiveContains(query) }
        }
    }

    // MARK: Scanning

    func refreshIfStale() {
        guard rootURL != nil, !isScanning, !scanStopped else { return }
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < Self.refreshInterval { return }
        scan()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.message = "Choose the folder that holds your repositories"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        if url != rootURL {
            rootURL = url
            watcher = nil
            repositories = []
            showOverview()
            lastScanDate = nil
        }
        scan()
    }

    func scan() {
        guard let root = rootURL else { return }
        scanTask?.cancel()
        let id = UUID()
        scanID = id
        isScanning = true
        scanStopped = false
        scanProgress = nil
        errorMessage = nil

        let worker = Task.detached(priority: .userInitiated) { [weak self] () throws -> RepositoryScanResult in
            try await RepositoryScanner().scan(under: root) { progress in
                Task { @MainActor in
                    guard let self, self.scanID == id else { return }
                    // Updates hop to the main actor separately and may arrive out of order.
                    if progress.fractionCompleted >= (self.scanProgress?.fractionCompleted ?? 0) {
                        self.scanProgress = progress
                    }
                }
            }
        }
        scanTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.scanID == id else { return }
            self.isScanning = false
            switch result {
            case .success(let scanResult):
                self.apply(scanResult)
            case .failure(let error):
                if error is CancellationError { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanID = nil
        scanStopped = true
        isScanning = false
        scanProgress = nil
    }

    private func apply(_ result: RepositoryScanResult) {
        scanFailures = result.failures
        let firstScan = lastScanDate == nil
        lastScanDate = Date()
        show(result.repositories)
        if firstScan, selectedPath == nil, let path = UserDefaults.standard.string(forKey: Self.openRepositoryKey),
           let repository = repositories.first(where: { $0.path.path == path }) {
            open(repository)
        }
        watch()
        // Changes that came in while scanning may have landed after the scan read that repository.
        if !changedPaths.isEmpty { repositoriesChanged([]) }
    }

    /// Shows new snapshots and keeps the user's place, down to the open row and diff.
    /// `changed` limits which repositories' content reloads; nil means all of them.
    private func show(_ snapshots: [RepositorySnapshot], changed: Set<URL>? = nil) {
        let now = Date()
        let previous = selectedRepository
        repositories = snapshots.sorted {
            let left = $0.weight(now: now), right = $1.weight(now: now)
            if left != right { return left > right }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        guard let path = selectedPath else { return }
        guard let repository = selectedRepository else {
            showOverview()
            return
        }
        guard changed?.contains(path) ?? true else { return }
        if let place = selectedPlace {
            // A detached HEAD moves on and a stash goes; the line follows them.
            selectedLine = line(of: place, row: selectedRow)
        } else {
            selectedPlaceID = Self.defaultPlace(in: repository)?.id
            // The graph followed the place that is gone.
            selectedLine = nil
            selectedRow = nil
        }
        let line = targetLine
        // Edits alone leave the graph as it was; rereading it on every save would keep it loading
        // while an agent works. New commits, branches or stashes change what it shows.
        if line != scope || previous.map({ Self.graphChanged(from: $0, to: repository) }) ?? true {
            loadHistory(line: line, limit: line == scope ? historyLimit : RepositoryInspector.historyPage)
        }
        switch openRow {
        case .stash(let hash) where !repository.stashes.contains(where: { $0.hash == hash }):
            closeRow()
            closeDiff()
        case .uncommitted(let worktree) where !repository.worktrees.contains(where: { $0.path == worktree && $0.dirtyFileCount > 0 }):
            closeRow()
            closeDiff()
        case .stash, .uncommitted:
            // Uncommitted files and stashes change in place; a commit's files never do.
            loadRowFiles(refreshing: true)
        case .commit, nil:
            break
        }
    }

    /// Whether anything the graph draws moved: a branch, a worktree's HEAD, a stash.
    private static func graphChanged(from old: RepositorySnapshot, to new: RepositorySnapshot) -> Bool {
        old.branches != new.branches
            || old.stashes.map(\.hash) != new.stashes.map(\.hash)
            || old.worktrees.map { [$0.path.path, $0.head ?? "", $0.branch ?? ""] } != new.worktrees.map { [$0.path.path, $0.head ?? "", $0.branch ?? ""] }
            || old.worktrees.map { $0.dirtyFileCount > 0 } != new.worktrees.map { $0.dirtyFileCount > 0 }
    }

    private func watch() {
        watcher = RepositoryWatcher(repositories: repositories) { [weak self] paths in
            Task { @MainActor in self?.repositoriesChanged(paths) }
        }
    }

    /// Rereads only the repositories that changed, once a burst of writes has settled.
    private func repositoriesChanged(_ paths: Set<URL>) {
        changedPaths.formUnion(paths)
        guard changeTask == nil else { return }
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            while let self, !self.changedPaths.isEmpty, !self.isScanning {
                let paths = self.changedPaths
                self.changedPaths = []
                let scanned = self.lastScanDate
                let snapshots = await Task.detached(priority: .userInitiated) {
                    paths.compactMap { try? RepositoryInspector().inspect(repositoryAt: $0) }
                }.value
                // A scan that started or finished meanwhile read these repositories later than this did.
                guard !self.isScanning, self.lastScanDate == scanned else { break }
                var updated = self.repositories
                for snapshot in snapshots {
                    if let index = updated.firstIndex(where: { $0.path == snapshot.path }) {
                        updated[index] = snapshot
                    }
                }
                let worktreesBefore = Set(self.repositories.flatMap { $0.worktrees.map(\.path) })
                self.show(updated, changed: paths)
                // A new or removed worktree needs a watcher that covers it.
                if Set(self.repositories.flatMap { $0.worktrees.map(\.path) }) != worktreesBefore {
                    self.watch()
                }
            }
            self?.changeTask = nil
        }
    }

    // MARK: Navigation

    func showOverview() {
        UserDefaults.standard.removeObject(forKey: Self.openRepositoryKey)
        selectedPath = nil
        selectedPlaceID = nil
        clearGraph()
    }

    /// Opens a repository on the place with the most at stake, or on the heaviest piece of one overview column.
    func open(_ repository: RepositorySnapshot, column: WorkColumn? = nil) {
        if selectedPath != repository.path {
            UserDefaults.standard.set(repository.path.path, forKey: Self.openRepositoryKey)
            selectedPath = repository.path
            clearGraph()
            loadHistory(line: nil, limit: RepositoryInspector.historyPage)
        }
        let now = Date()
        if let column {
            let candidates = repository.places.compactMap { place in
                place.pieces.filter { column.contains($0.kind) }.max { $0.weight(now: now) < $1.weight(now: now) }.map { (place, $0) }
            }
            if let (place, piece) = candidates.max(by: { $0.1.weight(now: now) < $1.1.weight(now: now) }) {
                select(place, piece: piece)
                return
            }
        }
        if let place = Self.defaultPlace(in: repository) { select(place) }
    }

    /// The heaviest place, or the main worktree when nothing is at risk.
    private static func defaultPlace(in repository: RepositorySnapshot) -> WorkPlace? {
        let now = Date()
        return repository.places.max { $0.weight(now: now) < $1.weight(now: now) }.flatMap { $0.pieces.isEmpty ? nil : $0 }
            ?? repository.places.first
    }

    /// Selects a place and opens one of its rows: the piece's, or its uncommitted files or stash, whichever comes first.
    func select(_ place: WorkPlace, piece: WorkPiece? = nil) {
        selectedPlaceID = place.id
        let target = piece ?? place.pieces.first { $0.kind == .uncommitted || $0.kind == .stash }
        let row = target.flatMap { row(for: $0, in: place) } ?? tipRow(of: place)
        closeDiff()
        // A place with nothing of its own on the graph is scrolled to, not opened.
        if let row, target != nil {
            if openRow != row {
                openRow = row
                loadRowFiles()
            }
        } else {
            closeRow()
        }
        focusRow = row
        // A branch's tip is known once the history holding it has loaded.
        pendingTip = row == nil ? place.id : nil
        selectedLine = line(of: place, row: row)
        selectedRow = row
        if selectedLine == scope, scope != nil { return }
        if scope != nil {
            // Off the line the graph follows: all branches first, narrowed again if they lack this selection too.
            loadHistory(line: nil, limit: RepositoryInspector.historyPage)
        } else if let history, let line = selectedLine, !line.isShown(in: history) {
            loadHistory(line: line, limit: RepositoryInspector.historyPage)
        }
    }

    /// Shows all branches again after the graph narrowed to one line of history.
    func showAllBranches() {
        guard scope != nil else { return }
        selectedLine = nil
        focusRow = nil
        pendingTip = nil
        loadHistory(line: nil, limit: RepositoryInspector.historyPage)
    }

    /// The line of history that holds a selection: a stash row's base, else the place's branch, detached HEAD or stash base.
    /// A branch is named, not hashed, so the line follows new commits on it.
    private func line(of place: WorkPlace, row: GraphRowID?) -> HistoryScope? {
        let revision: String?
        if case .stash(let hash) = row, let base = selectedRepository?.stashes.first(where: { $0.hash == hash })?.base {
            revision = base
        } else if place.branch != nil, let name = place.branchName {
            revision = "refs/heads/\(name)"
        } else {
            revision = place.worktree?.head ?? place.pieces.compactMap(\.stash?.base).first
        }
        return revision.map { HistoryScope(revision: $0, title: place.branchName ?? place.worktree?.path.lastPathComponent ?? "this stash") }
    }

    /// The line a reread follows: the narrowed one while the selection is still on it, else all branches,
    /// which narrow again by themselves when they lack the selection.
    private var targetLine: HistoryScope? {
        selectedLine == scope ? scope : nil
    }

    /// The row a piece of work lives on.
    func row(for piece: WorkPiece, in place: WorkPlace) -> GraphRowID? {
        switch piece.kind {
        case .uncommitted:
            return place.worktree.map { .uncommitted($0.path) }
        case .stash:
            return piece.stash.map { .stash($0.hash) }
        case .detached, .unpushed, .unmerged, .leftover:
            return tipRow(of: place)
        }
    }

    /// The commit a place's branch or HEAD is at, once the history holding it has loaded.
    private func tipRow(of place: WorkPlace) -> GraphRowID? {
        if let head = place.worktree?.head { return .commit(head) }
        if let name = place.branchName, place.branch != nil,
           let commit = history?.first(where: { $0.refs.contains { $0.kind == .branch && $0.name == name } }) {
            return .commit(commit.fullHash)
        }
        // A live branch's tip is waited for, not swapped for an older stash base on it.
        guard place.branch == nil else { return nil }
        return place.pieces.compactMap(\.stash?.base).first.map { .commit($0) }
    }

    /// Opens a row's files under it, or closes them if that row is already open.
    func toggle(_ row: GraphRowID) {
        closeDiff()
        if openRow == row {
            closeRow()
        } else {
            openRow = row
            loadRowFiles()
        }
    }

    private func closeRow() {
        filesTask?.cancel()
        openRow = nil
        rowFiles = nil
        rowFilesError = nil
    }

    private func clearGraph() {
        historyTask?.cancel()
        history = nil
        historyError = nil
        isLoadingMore = false
        focusRow = nil
        pendingTip = nil
        graphWaitsForFocus = false
        scope = nil
        selectedLine = nil
        selectedRow = nil
        scopeOwnCommits = []
        closeRow()
        closeDiff()
    }

    // MARK: Loading

    /// Reads all branches, or one line of history. The graph on screen stays until the read is in, then switches whole.
    private func loadHistory(line: HistoryScope?, limit: Int) {
        historyTask?.cancel()
        historyError = nil
        guard let path = selectedPath else { return }
        let base = selectedRepository.map { repository in
            // On the server if it is there, as the graph's highlight takes it; the base's own line keeps its unpushed commits.
            ["--not", "--remotes=*/\(repository.base)"]
                + (repository.branches.contains { $0.name == repository.base } && line?.revision != "refs/heads/\(repository.base)"
                    ? ["refs/heads/\(repository.base)"] : [])
        } ?? []
        let worker = Task.detached(priority: .userInitiated) { () throws -> ([CommitSnapshot], Set<String>) in
            let inspector = RepositoryInspector()
            guard let line else { return (try inspector.repositoryHistory(in: path, limit: limit), []) }
            let own = try inspector.history(in: path, revisions: [line.revision] + base, limit: limit)
            return (try inspector.history(of: [line.revision], in: path, limit: limit), Set(own.filter { !$0.isBoundary }.map(\.fullHash)))
        }
        historyTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.selectedPath == path else { return }
            self.isLoadingMore = false
            switch result {
            case .success(let (commits, own)):
                // The selection moved off this line while it was read.
                if let line, line != self.selectedLine {
                    self.loadHistory(line: nil, limit: RepositoryInspector.historyPage)
                    return
                }
                // All branches don't reach the selection: read its own line instead.
                if line == nil, let wanted = self.selectedLine, !wanted.isShown(in: commits) {
                    self.loadHistory(line: wanted, limit: RepositoryInspector.historyPage)
                    return
                }
                // The open row's files come in with the graph, so the graph is never drawn with that row still to open.
                if let row = self.openRow, self.rowFiles == nil, self.rowFilesError == nil,
                   let anchor = self.anchor(of: row), commits.contains(where: { $0.fullHash == anchor }) {
                    if row.isCommit, let load = self.filesLoader(for: row, in: commits) {
                        // A commit's files can only be read once a history describes the commit.
                        let reader = Task.detached(priority: .userInitiated) { try load() }
                        let files = await withTaskCancellationHandler { await reader.result } onCancel: { reader.cancel() }
                        guard !Task.isCancelled, self.selectedPath == path else { return }
                        if self.openRow == row, self.rowFiles == nil, self.rowFilesError == nil {
                            switch files {
                            case .success(let list): self.rowFiles = list
                            case .failure(let error) where !(error is CancellationError): self.rowFilesError = error.localizedDescription
                            default: break
                            }
                        }
                    } else {
                        // A worktree's or stash's files are already being read.
                        await self.filesTask?.value
                        guard !Task.isCancelled, self.selectedPath == path else { return }
                    }
                }
                let switched = self.scope != line
                let first = self.history == nil
                self.scope = line
                self.history = commits
                self.historyLimit = limit
                self.scopeOwnCommits = own
                if switched, let row = self.selectedRow { self.focusRow = row }
                if let id = self.pendingTip, id == self.selectedPlaceID, let place = self.selectedPlace,
                   let row = self.tipRow(of: place) {
                    self.pendingTip = nil
                    self.focusRow = row
                }
                if first, self.focusRow != nil { self.graphWaitsForFocus = true }
                if let row = self.openRow, let anchor = self.anchor(of: row) {
                    if !commits.contains(where: { $0.fullHash == anchor }) {
                        // Not drawn, so not open: its files would also reach the agent task unseen.
                        self.closeRow()
                        self.closeDiff()
                    } else if row.isCommit, self.rowFiles == nil {
                        // A commit's files wait for the history that describes the commit.
                        self.loadRowFiles()
                    }
                }
            case .failure(let error):
                if error is CancellationError { return }
                if line != nil {
                    // The branch is gone since; all branches are still there to show, without the row.
                    self.selectedLine = nil
                    self.focusRow = nil
                    self.pendingTip = nil
                    self.loadHistory(line: nil, limit: RepositoryInspector.historyPage)
                    return
                }
                self.historyError = error.localizedDescription
            }
        }
    }

    /// The commit a graph row is drawn on.
    private func anchor(of row: GraphRowID) -> String? {
        switch row {
        case .commit(let hash): hash
        case .uncommitted(let worktree): selectedRepository?.worktrees.first { $0.path == worktree }?.head
        case .stash(let hash): selectedRepository?.stashes.first { $0.hash == hash }?.base
        }
    }

    /// Whether the last read stopped at its limit, so there may be more history behind it.
    private var canReadFurther: Bool {
        guard let history else { return false }
        return history.count(where: { !$0.isBoundary }) >= historyLimit
    }

    /// Reads the next page of history, if the last read stopped at its limit.
    func loadMoreHistory() {
        // Not while the graph is about to switch lines.
        guard !isLoadingMore, canReadFurther, targetLine == scope else { return }
        isLoadingMore = true
        loadHistory(line: scope, limit: historyLimit + RepositoryInspector.historyPage)
    }

    private func loadRowFiles(refreshing: Bool = false) {
        filesTask?.cancel()
        if !refreshing { rowFiles = nil }
        rowFilesError = nil
        guard let row = openRow, let load = filesLoader(for: row, in: history) else { return }
        let worker = Task.detached(priority: .userInitiated) { try load() }
        filesTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.openRow == row else { return }
            switch result {
            case .success(let files):
                self.rowFiles = files
                // The open diff follows its file as it changes, and closes when the file is gone.
                if let file = self.diffFile {
                    if let current = files.first(where: { $0.path == file.path }) {
                        self.diffFile = current
                        self.loadDiff(refreshing: true)
                    } else {
                        self.closeDiff()
                    }
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.rowFilesError = error.localizedDescription
                self.closeDiff()
            }
        }
    }

    /// What reads a row's files. A commit's need the history that describes the commit.
    private func filesLoader(for row: GraphRowID, in commits: [CommitSnapshot]?) -> (@Sendable () throws -> [CommitFileSnapshot])? {
        guard let repository = selectedRepository else { return nil }
        switch row {
        case .commit(let hash):
            guard let commit = commits?.first(where: { $0.fullHash == hash }) else { return nil }
            return { try RepositoryInspector().changedFiles(in: repository.path, commit: commit) }
        case .uncommitted(let worktree):
            return { try RepositoryInspector().uncommittedFiles(in: worktree) }
        case .stash(let hash):
            let directory = repository.stashDirectory
            return { try RepositoryInspector().stashFiles(in: directory, stash: hash) }
        }
    }

    /// Opens a file's diff, or closes it when that file's diff is already open.
    func toggleDiff(of file: CommitFileSnapshot) {
        if diffFile?.path == file.path {
            closeDiff()
        } else {
            diffFile = file
            loadDiff()
        }
    }

    func closeDiff() {
        diffTask?.cancel()
        diffFile = nil
        fileDiff = nil
        fileDiffError = nil
    }

    /// The diff against the base the file list was read from: the commit's first parent,
    /// HEAD for uncommitted work, the stashed-on commit for a stash.
    private func loadDiff(refreshing: Bool = false) {
        diffTask?.cancel()
        if !refreshing { fileDiff = nil }
        fileDiffError = nil
        guard let file = diffFile, let row = openRow, let repository = selectedRepository else { return }
        let load: @Sendable () throws -> FileDiff
        switch row {
        case .commit(let hash):
            guard let commit = history?.first(where: { $0.fullHash == hash }) else { return closeDiff() }
            load = { try RepositoryInspector().diff(of: file.path, in: commit, repositoryURL: repository.path) }
        case .uncommitted(let worktree):
            load = { try RepositoryInspector().uncommittedDiff(of: file, in: worktree) }
        case .stash(let hash):
            let directory = repository.stashDirectory
            load = { try RepositoryInspector().stashDiff(of: file, stash: hash, in: directory) }
        }
        let worker = Task.detached(priority: .userInitiated) { try load() }
        diffTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.diffFile?.path == file.path else { return }
            switch result {
            case .success(let diff):
                self.fileDiff = diff
            case .failure(let error):
                if error is CancellationError { return }
                self.fileDiffError = error.localizedDescription
            }
        }
    }

    // MARK: Agent tasks

    /// What a place's "Copy task" copies for a place, with the uncommitted files when they are on screen.
    func task(for place: WorkPlace) -> String? {
        guard let repository = selectedRepository else { return nil }
        let files = place.worktree.flatMap { openRow == .uncommitted($0.path) ? rowFiles : nil }
        return WorkText.task(for: place, in: repository, files: files)
    }

    func copy(_ text: String, id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedID = id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.copiedID == id { self?.copiedID = nil }
        }
    }
}

extension GraphRowID {
    var isCommit: Bool {
        if case .commit = self { return true }
        return false
    }
}

extension RepositorySnapshot {
    /// Stashes are shared by all worktrees; a bare repository can only list them from one.
    var stashDirectory: URL { worktrees.first?.path ?? path }
}

/// One line of history the graph follows instead of all branches.
struct HistoryScope: Equatable {
    /// What git log reads: a branch ref or a commit.
    let revision: String
    /// The branch or worktree it belongs to, for the graph's title.
    let title: String
}

extension HistoryScope {
    /// Whether `commits` hold this line's tip.
    func isShown(in commits: [CommitSnapshot]) -> Bool {
        if revision.hasPrefix("refs/heads/") {
            let name = revision.dropFirst("refs/heads/".count)
            return commits.contains { $0.refs.contains { $0.kind == .branch && $0.name == name } }
        }
        return commits.contains { $0.fullHash == revision }
    }
}
