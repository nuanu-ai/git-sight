import AppKit
import Combine
import Foundation
import GitSightCore

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var rootURL = FileManager.default.homeDirectoryForCurrentUser
    @Published private(set) var repositories: [RepositorySnapshot] = []
    @Published private(set) var selectedPath: URL?
    @Published private(set) var isScanning = false
    @Published private(set) var hasStartedScan = false
    @Published private(set) var scanProgress: RepositoryScanProgress?
    @Published private(set) var scanFailures: [RepositoryScanFailure] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastScanDate: Date?
    @Published var filter = ""

    @Published private(set) var expandedCommitHash: String?
    @Published private(set) var loadingCommitHash: String?
    @Published private(set) var commitFiles: [String: [CommitFileSnapshot]] = [:]
    @Published private(set) var commitErrorMessage: String?
    @Published private(set) var commitDetailHeight: CGFloat = 0
    @Published var hoveredRepositoryPath: URL?
    @Published var hoveredCommitHash: String?
    @Published var hoveredIssueID: String?

    private var scanTask: Task<Void, Never>?
    private var commitTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var commitGeneration = 0
    private var accessedRootURL: URL?

    var selectedRepository: RepositorySnapshot? {
        repositories.first { $0.path == selectedPath }
    }

    var filteredRepositories: [RepositorySnapshot] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.path.path.localizedCaseInsensitiveContains(query)
                || $0.currentBranch?.localizedCaseInsensitiveContains(query) == true
        }
    }

    func start() {
        scan()
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "Папка с репозиториями"
        panel.prompt = "Выбрать"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let shouldRestart = isScanning || lastScanDate != nil
        accessedRootURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        accessedRootURL = url
        rootURL = url
        if shouldRestart { scan() }
    }

    func cancelScan() {
        scanGeneration += 1
        scanTask?.cancel()
        isScanning = false
        hasStartedScan = false
        scanProgress = nil
        errorMessage = nil
    }

    func scan() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let root = rootURL

        clearCommitExpansion()
        repositories = []
        selectedPath = nil
        scanFailures = []
        scanProgress = nil
        errorMessage = nil
        lastScanDate = nil
        hasStartedScan = true
        isScanning = true

        let worker = Task.detached(priority: .userInitiated) { [weak self] () throws -> RepositoryScanResult in
            guard let self else { throw CancellationError() }
            return try RepositoryScanner().scan(under: root) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.scanGeneration == generation, self.isScanning else { return }
                    self.scanProgress = progress
                }
            }
        }

        scanTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.scanGeneration == generation else { return }
            self.isScanning = false
            switch result {
            case .success(let scanResult):
                self.repositories = scanResult.repositories.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.scanFailures = scanResult.failures
                self.selectedPath = self.repositories.first?.path
                self.lastScanDate = Date()
            case .failure(let error):
                if error is CancellationError { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func select(_ repository: RepositorySnapshot) {
        guard selectedPath != repository.path else { return }
        selectedPath = repository.path
        clearCommitExpansion()
    }

    func toggleCommit(_ commit: CommitSnapshot, in repository: RepositorySnapshot) {
        commitDetailHeight = 0
        if expandedCommitHash == commit.fullHash {
            commitTask?.cancel()
            commitGeneration += 1
            expandedCommitHash = nil
            loadingCommitHash = nil
            commitErrorMessage = nil
            return
        }

        commitTask?.cancel()
        commitGeneration += 1
        let generation = commitGeneration
        expandedCommitHash = commit.fullHash
        commitErrorMessage = nil
        guard commitFiles[commit.fullHash] == nil else {
            loadingCommitHash = nil
            return
        }
        loadFiles(for: commit, in: repository, generation: generation)
    }

    func retryCommitFiles(for commit: CommitSnapshot, in repository: RepositorySnapshot) {
        commitFiles.removeValue(forKey: commit.fullHash)
        commitTask?.cancel()
        commitGeneration += 1
        let generation = commitGeneration
        expandedCommitHash = commit.fullHash
        commitErrorMessage = nil
        loadFiles(for: commit, in: repository, generation: generation)
    }

    private func loadFiles(
        for commit: CommitSnapshot,
        in repository: RepositorySnapshot,
        generation: Int
    ) {
        loadingCommitHash = commit.fullHash
        let repositoryURL = repository.path
        let hash = commit.fullHash
        let worker = Task.detached(priority: .userInitiated) {
            try RepositoryInspector().changedFiles(in: repositoryURL, commit: commit)
        }
        commitTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.commitGeneration == generation,
                  self.selectedPath == repositoryURL,
                  self.expandedCommitHash == hash else { return }
            self.loadingCommitHash = nil
            switch result {
            case .success(let files):
                self.commitFiles[hash] = files
            case .failure(let error):
                if error is CancellationError { return }
                self.commitErrorMessage = error.localizedDescription
            }
        }
    }

    func updateCommitDetailHeight(_ height: CGFloat) {
        guard commitDetailHeight != height else { return }
        commitDetailHeight = height
    }

    private func clearCommitExpansion() {
        commitTask?.cancel()
        commitGeneration += 1
        expandedCommitHash = nil
        loadingCommitHash = nil
        commitFiles = [:]
        commitErrorMessage = nil
        commitDetailHeight = 0
    }
}
