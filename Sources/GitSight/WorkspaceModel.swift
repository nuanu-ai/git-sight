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
            selectedFindingID = selectedRepository?.findings.first?.id
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
    /// Tells a scan's late progress and result apart from those of the scan that replaced it.
    private var scanID: UUID?
    private var contentTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.rootKey) {
            rootURL = URL(fileURLWithPath: path, isDirectory: true)
        }
    }

    var selectedRepository: RepositorySnapshot? {
        repositories.first { $0.path == selectedPath }
    }

    var selectedFinding: Finding? {
        selectedRepository?.findings.first { $0.id == selectedFindingID }
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
        let previousFinding = selectedFindingID
        repositories = result.repositories.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.oldestUnsavedWork != $1.oldestUnsavedWork {
                return ($0.oldestUnsavedWork ?? .distantFuture) < ($1.oldestUnsavedWork ?? .distantFuture)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        scanFailures = result.failures
        lastScanDate = Date()
        if selectedRepository == nil {
            selectedPath = repositories.first?.path
        } else if let repository = selectedRepository {
            // A rescan keeps the user's place, down to the selected commit.
            if repository.findings.contains(where: { $0.id == previousFinding }) {
                loadContent(refreshing: true)
            } else {
                selectedFindingID = repository.findings.first?.id
            }
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
        guard let finding = selectedFinding else { return }
        let id = finding.id
        let worker = Task.detached(priority: .userInitiated) { () throws -> FindingContent in
            let inspector = RepositoryInspector()
            switch finding.source {
            case .history(let directory, let revisions):
                return .history(try inspector.history(in: directory, revisions: revisions))
            case .uncommitted(let worktree):
                return .files(try inspector.uncommittedFiles(in: worktree))
            case .stash(let directory, let name):
                return .files(try inspector.stashFiles(in: directory, stash: name))
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

    func copyAgentTask(for finding: Finding) {
        guard let repository = selectedRepository else { return }
        var files: [CommitFileSnapshot]?
        if case .files(let loaded) = findingContent { files = loaded }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(repository.agentTask(for: finding, files: files), forType: .string)
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
