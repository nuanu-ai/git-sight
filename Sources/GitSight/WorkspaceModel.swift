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
    /// How far back a jump to a piece reads history looking for its row.
    private static let historyCeiling = 3000

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

    /// Every branch of the selected repository, newest first; nil while it loads.
    private(set) var history: [CommitSnapshot]?
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
        if selectedPlace == nil { selectedPlaceID = Self.defaultPlace(in: repository)?.id }
        // Edits alone leave the graph as it was; rereading it on every save would keep it loading
        // while an agent works. New commits, branches or stashes change what it shows.
        if previous.map({ Self.graphChanged(from: $0, to: repository) }) ?? true {
            loadHistory(refreshing: true)
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
            historyLimit = RepositoryInspector.historyPage
            loadHistory()
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
        loadMoreUntilFocusShows()
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
        closeRow()
        closeDiff()
    }

    // MARK: Loading

    /// A refresh keeps the graph on screen until the new one arrives.
    private func loadHistory(refreshing: Bool = false) {
        historyTask?.cancel()
        historyError = nil
        guard let path = selectedPath else { return }
        let limit = historyLimit
        let worker = Task.detached(priority: .userInitiated) {
            try RepositoryInspector().repositoryHistory(in: path, limit: limit)
        }
        historyTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.selectedPath == path else { return }
            self.isLoadingMore = false
            switch result {
            case .success(let commits):
                self.history = commits
                if let id = self.pendingTip, id == self.selectedPlaceID, let place = self.selectedPlace,
                   let row = self.tipRow(of: place) {
                    self.pendingTip = nil
                    self.focusRow = row
                }
                if case .commit(let hash) = self.openRow {
                    if !commits.contains(where: { $0.fullHash == hash }) {
                        // A row jumped to further back than this read stays open while the next read looks for it.
                        if self.openRow != self.focusRow || !self.canReadFurther {
                            self.closeRow()
                            self.closeDiff()
                        }
                    } else if self.rowFiles == nil {
                        // A commit's files wait for the history that describes the commit.
                        self.loadRowFiles()
                    }
                }
                self.loadMoreUntilFocusShows()
            case .failure(let error):
                if error is CancellationError { return }
                self.historyError = error.localizedDescription
            }
        }
    }

    /// Whether the last read stopped at its limit, so there may be more history behind it.
    private var canReadFurther: Bool {
        guard let history else { return false }
        return history.count(where: { !$0.isBoundary }) >= historyLimit
    }

    /// Reads the next page of history, if the last read stopped at its limit.
    func loadMoreHistory() {
        guard !isLoadingMore, canReadFurther else { return }
        isLoadingMore = true
        historyLimit += RepositoryInspector.historyPage
        loadHistory(refreshing: true)
    }

    /// A jump to an old stash or branch reads back to the ceiling at once until its row is in the graph,
    /// and gives up on it when even that does not reach it.
    private func loadMoreUntilFocusShows() {
        guard let history, !isLoadingMore else { return }
        let missing: Bool
        if let focus = focusRow {
            let anchor: String?
            switch focus {
            case .commit(let hash): anchor = hash
            case .uncommitted(let worktree): anchor = selectedRepository?.worktrees.first { $0.path == worktree }?.head
            case .stash(let hash): anchor = selectedRepository?.stashes.first { $0.hash == hash }?.base
            }
            missing = anchor.map { anchor in !history.contains { $0.fullHash == anchor } } ?? false
        } else {
            missing = pendingTip != nil && pendingTip == selectedPlaceID
        }
        guard missing else { return }
        guard canReadFurther, historyLimit < Self.historyCeiling else {
            focusRow = nil
            pendingTip = nil
            return
        }
        isLoadingMore = true
        historyLimit = Self.historyCeiling
        loadHistory(refreshing: true)
    }

    private func loadRowFiles(refreshing: Bool = false) {
        filesTask?.cancel()
        if !refreshing { rowFiles = nil }
        rowFilesError = nil
        guard let row = openRow, let repository = selectedRepository else { return }
        let load: @Sendable () throws -> [CommitFileSnapshot]
        switch row {
        case .commit(let hash):
            guard let commit = history?.first(where: { $0.fullHash == hash }) else { return }
            load = { try RepositoryInspector().changedFiles(in: repository.path, commit: commit) }
        case .uncommitted(let worktree):
            load = { try RepositoryInspector().uncommittedFiles(in: worktree) }
        case .stash(let hash):
            let directory = repository.stashDirectory
            load = { try RepositoryInspector().stashFiles(in: directory, stash: hash) }
        }
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

    /// What "Agent task" copies for a place, with the uncommitted files when they are on screen.
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
