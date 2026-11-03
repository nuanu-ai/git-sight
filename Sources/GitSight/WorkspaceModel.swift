import AppKit
import Foundation
import GitSightCore
import Observation

/// What the detail column shows for the selected finding.
enum FindingContent {
    case history([CommitSnapshot])
    case files([CommitFileSnapshot])
}

@MainActor
@Observable
final class WorkspaceModel {
    private static let rootKey = "rootPath"
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
    /// The finding whose agent task was just copied, for a moment of confirmation.
    private(set) var copiedFindingID: String?

    var selectedPath: URL? {
        didSet {
            guard selectedPath != oldValue else { return }
            selectedFindingID = selectedRepository.map { $0.findings.first?.id ?? Self.graphID(of: $0) }
        }
    }
    var selectedFindingID: String? {
        didSet {
            guard selectedFindingID != oldValue else { return }
            loadContent()
        }
    }
    var selectedCommitHash: String? {
        didSet {
            guard selectedCommitHash != oldValue else { return }
            loadCommitFiles()
        }
    }

    private(set) var findingContent: FindingContent?
    private(set) var findingError: String?
    private(set) var commitFiles: [CommitFileSnapshot]?
    private(set) var commitFilesError: String?

    private var scanTask: Task<Void, Never>?
    /// Follows edits, commits and stashes as they happen; replaced after every scan.
    private var watcher: RepositoryWatcher?
    private var changedPaths: Set<URL> = []
    private var changeTask: Task<Void, Never>?
    /// Tells a scan's late progress and result apart from those of the scan that replaced it.
    private var scanID: UUID?
    private var contentTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?

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

    var selectedFinding: Finding? {
        selectedRepository?.findings.first { $0.id == selectedFindingID }
    }

    /// The middle column's first item: the graph of the whole repository, selected like a finding.
    static func graphID(of repository: RepositorySnapshot) -> String {
        "\(repository.path.path)|graph"
    }

    var showsGraph: Bool {
        selectedRepository.map { selectedFindingID == Self.graphID(of: $0) } ?? false
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

    func refreshIfStale() {
        guard rootURL != nil, !isScanning, !scanStopped else { return }
        if let lastScanDate, Date().timeIntervalSince(lastScanDate) < Self.refreshInterval { return }
        scan()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.message = "Выберите папку, в которой лежат ваши репозитории"
        panel.prompt = "Выбрать"
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
            selectedPath = nil
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
        lastScanDate = Date()
        show(result.repositories)
        watch()
        // Changes that came in while scanning may have landed after the scan read that repository.
        if !changedPaths.isEmpty { repositoriesChanged([]) }
    }

    /// Shows new snapshots and keeps the user's place, down to the selected commit.
    /// `changed` limits which repositories' content reloads; nil means all of them.
    private func show(_ snapshots: [RepositorySnapshot], changed: Set<URL>? = nil) {
        let previousFinding = selectedFindingID
        repositories = snapshots.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.oldestUnsavedWork != $1.oldestUnsavedWork {
                return ($0.oldestUnsavedWork ?? .distantFuture) < ($1.oldestUnsavedWork ?? .distantFuture)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        if selectedRepository == nil {
            selectedPath = repositories.first?.path
        } else if let repository = selectedRepository, changed?.contains(repository.path) ?? true {
            if previousFinding == Self.graphID(of: repository) || repository.findings.contains(where: { $0.id == previousFinding }) {
                loadContent(refreshing: true)
            } else {
                selectedFindingID = repository.findings.first?.id ?? Self.graphID(of: repository)
            }
        }
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

    /// A refresh keeps the current content and commit on screen until the new content arrives.
    private func loadContent(refreshing: Bool = false) {
        contentTask?.cancel()
        findingError = nil
        if !refreshing {
            commitTask?.cancel()
            findingContent = nil
            commitFiles = nil
            selectedCommitHash = nil
        }
        guard let id = selectedFindingID else { return }
        let finding = selectedFinding
        let graphOf = showsGraph ? selectedRepository?.path : nil
        let worker = Task.detached(priority: .userInitiated) { () throws -> FindingContent in
            let inspector = RepositoryInspector()
            guard let finding else {
                guard let graphOf else { throw CancellationError() }
                return .history(try inspector.repositoryHistory(in: graphOf))
            }
            switch finding.source {
            case .history(let directory, let revisions):
                return .history(try inspector.history(in: directory, revisions: revisions))
            case .uncommitted(let worktree):
                return .files(try inspector.uncommittedFiles(in: worktree))
            case .stash(let directory, _, let hash):
                return .files(try inspector.stashFiles(in: directory, stash: hash))
            }
        }
        contentTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.selectedFindingID == id else { return }
            switch result {
            case .success(let content):
                self.findingContent = content
                if case .history(let commits) = content, let hash = self.selectedCommitHash,
                   !commits.contains(where: { $0.fullHash == hash }) {
                    self.selectedCommitHash = nil
                }
            case .failure(let error):
                if error is CancellationError { return }
                self.findingError = error.localizedDescription
            }
        }
    }

    /// The request "Скопировать задачу для агента" puts on the clipboard, with the files on screen.
    func agentTask(for finding: Finding) -> String? {
        guard let repository = selectedRepository else { return nil }
        var files: [CommitFileSnapshot]?
        if case .files(let loaded) = findingContent { files = loaded }
        return repository.agentTask(for: finding, files: files)
    }

    func copyAgentTask(for finding: Finding) {
        guard let task = agentTask(for: finding) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task, forType: .string)
        copiedFindingID = finding.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.copiedFindingID == finding.id { self?.copiedFindingID = nil }
        }
    }

    private func loadCommitFiles() {
        commitTask?.cancel()
        commitFiles = nil
        commitFilesError = nil
        guard case .history(let commits) = findingContent,
              let commit = commits.first(where: { $0.fullHash == selectedCommitHash }),
              case .history(let directory, _) = selectedFinding?.source else { return }
        let hash = commit.fullHash
        let worker = Task.detached(priority: .userInitiated) {
            try RepositoryInspector().changedFiles(in: directory, commit: commit)
        }
        commitTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.selectedCommitHash == hash else { return }
            switch result {
            case .success(let files):
                self.commitFiles = files
            case .failure(let error):
                if error is CancellationError { return }
                self.commitFilesError = error.localizedDescription
            }
        }
    }
}
