import AppKit
import GitSightCore
import SwiftUI

struct MainWindowView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Group {
            if model.repositories.isEmpty {
                WorkspaceStateView(model: model)
                    .frame(minWidth: 640, minHeight: 420)
            } else {
                NavigationSplitView {
                    RepositorySidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 440)
                } content: {
                    FindingList(model: model)
                        .navigationSplitViewColumnWidth(min: 300, ideal: 400, max: 600)
                } detail: {
                    FindingDetail(model: model)
                }
                .searchable(text: $model.filter, placement: .sidebar, prompt: "Репозиторий или ветка")
                // The window shows the split view's title, not the content column's.
                .navigationTitle(model.selectedRepository?.name ?? "git-sight")
                .navigationSubtitle(model.selectedRepository.map { RepositoryText.path($0.path) } ?? "")
                // macOS's 13 pt default reads too small for a window you scan at a glance.
                .font(.title3)
                .frame(minWidth: 960, minHeight: 560)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: model.chooseRoot) {
                    Label(model.rootURL.map { RepositoryText.path($0) } ?? "Выбрать папку", systemImage: "folder")
                        .labelStyle(.titleAndIcon)
                }
                .help("Папка, в которой искать репозитории (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning, !model.repositories.isEmpty {
                    ProgressView(value: model.scanProgress?.fractionCompleted ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .help("Сканирование…")
                } else {
                    Button(action: model.scan) {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.rootURL == nil || model.isScanning)
                    .help("Просканировать заново (⌘R)")
                }
            }
        }
    }
}

// MARK: - Empty, first scan and error states

private struct WorkspaceStateView: View {
    let model: WorkspaceModel

    var body: some View {
        if model.isScanning {
            VStack(spacing: 12) {
                ProgressView(value: model.scanProgress?.fractionCompleted ?? 0)
                    .frame(width: 280)
                Text(status)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Остановить", action: model.cancelScan)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rootURL == nil {
            ContentUnavailableView {
                Label("Где искать репозитории?", systemImage: "folder.badge.questionmark")
            } description: {
                Text("git-sight найдёт все git-репозитории в папке и покажет работу, которой нет на сервере. Он только читает и ничего не меняет.")
            } actions: {
                Button("Выбрать папку…", action: model.chooseRoot)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("Не удалось просканировать папку", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Повторить", action: model.scan)
                Button("Выбрать другую папку…", action: model.chooseRoot)
            }
        } else if model.scanStopped {
            ContentUnavailableView {
                Label("Сканирование остановлено", systemImage: "stop.circle")
            } description: {
                Text("Результатов пока нет.")
            } actions: {
                Button("Сканировать", action: model.scan)
                Button("Выбрать другую папку…", action: model.chooseRoot)
            }
        } else if model.lastScanDate != nil {
            ContentUnavailableView {
                Label("Репозиториев не найдено", systemImage: "folder")
            } description: {
                Text("В \(model.rootURL.map { RepositoryText.path($0) } ?? "папке") нет git-репозиториев. Скрытые папки, Library и node_modules пропускаются.")
            } actions: {
                Button("Выбрать другую папку…", action: model.chooseRoot)
            }
        } else {
            Color.clear
        }
    }

    private var status: String {
        guard let progress = model.scanProgress else { return "Ищем репозитории…" }
        switch progress.phase {
        case .discovery:
            return "Ищем репозитории: просмотрено папок \(progress.scannedDirectories)"
        case .inspection:
            return "Проверяем репозитории: \(progress.processedRepositories) из \(progress.totalRepositories)"
        }
    }
}

// MARK: - Sidebar

private struct RepositorySidebar: View {
    @Bindable var model: WorkspaceModel
    @AppStorage("showsCleanRepositories") private var showsClean = false

    /// Changes newer than this put a repository under "Сейчас".
    private static let activeWindow: TimeInterval = 15 * 60

    var body: some View {
        // Re-evaluated every half minute so repositories leave "Сейчас" once they go quiet.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            list(now: timeline.date)
        }
        .listStyle(.sidebar)
        .overlay {
            if model.filteredRepositories.isEmpty {
                ContentUnavailableView.search(text: model.filter)
            }
        }
        .safeAreaInset(edge: .bottom) {
            SidebarFooter(model: model)
        }
    }

    private func list(now: Date) -> some View {
        let all = model.filteredRepositories
        let active = all
            .compactMap { repository in repository.latestChangeText.map { (repository, $0) } }
            .filter { abs(now.timeIntervalSince($0.1.date)) < Self.activeWindow }
            .sorted { $0.1.date > $1.1.date }
        let activePaths = Set(active.map(\.0.path))
        let repositories = all.filter { !activePaths.contains($0.path) }
        return List(selection: $model.selectedPath) {
            if !active.isEmpty {
                Section {
                    ForEach(active, id: \.0.path) { repository, change in
                        RepositoryRow(repository: repository, activity: change)
                    }
                } header: {
                    ActivityHeader(count: active.count)
                }
            }
            ForEach([Severity.critical, .warning, .attention], id: \.self) { severity in
                let group = repositories.filter { $0.severity == severity }
                if !group.isEmpty {
                    Section {
                        ForEach(group, id: \.path) { repository in
                            RepositoryRow(repository: repository)
                        }
                    } header: {
                        SeverityHeader(severity: severity, count: group.count)
                    }
                }
            }
            let clean = repositories.filter { $0.severity == .clean }
            if !clean.isEmpty {
                Section(isExpanded: $showsClean) {
                    ForEach(clean, id: \.path) { repository in
                        RepositoryRow(repository: repository)
                    }
                } header: {
                    SeverityHeader(severity: .clean, count: clean.count)
                }
            }
        }
    }
}

private struct RepositoryRow: View {
    let repository: RepositorySnapshot
    /// Under "Сейчас" the row tells what just happened; the age on the right still says what is at stake.
    var activity: (date: Date, text: String)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(repository.severity.color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.name)
                    .lineLimit(1)
                Text(activity.map { "\($0.text) · \(RepositoryText.age($0.date, short: true))" } ?? repository.summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let oldest = repository.oldestUnsavedWork {
                Text(RepositoryText.age(oldest, short: true))
                    .font(.body)
                    .fontWeight(repository.severity >= .warning ? .semibold : .regular)
                    .monospacedDigit()
                    .foregroundStyle(repository.severity.tint)
            }
        }
        .padding(.vertical, 2)
        .tag(repository.path)
        .help(RepositoryText.path(repository.path))
        .contextMenu { RepositoryActions(repository: repository) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(repository.name), \(repository.severity.title), \(activity?.text ?? repository.summary)")
    }
}

private struct RepositoryActions: View {
    let repository: RepositorySnapshot

    var body: some View {
        Button("Показать в Finder") { Workspace.reveal(repository.path) }
        Button("Открыть в Терминале") { Workspace.openTerminal(at: repository.path) }
        if let remote = repository.remoteWebURL {
            Button("Открыть \(remote.host ?? "remote")") { NSWorkspace.shared.open(remote) }
        }
        Divider()
        Button("Скопировать путь") { Workspace.copy(repository.path.path) }
    }
}

private struct SidebarFooter: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            if let lastScanDate = model.lastScanDate {
                Text("Обновлено \(lastScanDate.formatted(date: .omitted, time: .shortened))")
            }
            if let errorMessage = model.errorMessage {
                // The list above is from the last scan that worked.
                Label("Не удалось обновить", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errorMessage)
            }
            Spacer()
            if !model.scanFailures.isEmpty {
                Button {
                    model.showsScanFailures.toggle()
                } label: {
                    Label("Не прочитано: \(model.scanFailures.count)", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $model.showsScanFailures) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.scanFailures, id: \.path) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(RepositoryText.path(failure.path)).font(.body.weight(.medium))
                                    Text(failure.message).font(.callout).foregroundStyle(.secondary)
                                }
                                .textSelection(.enabled)
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 420, height: 260)
                }
            }
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Verdicts

/// The verdict as a filled label, the strongest mark in the window.
private struct SeverityBadge: View {
    let severity: Severity

    var body: some View {
        Text(severity.title)
            .font(.body.weight(.semibold))
            .foregroundStyle(severity == .attention ? Color.black.opacity(0.8) : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(severity.color))
    }
}

private struct ActivityHeader: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.accentColor)
            Text("Сейчас")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SeverityHeader: View {
    let severity: Severity
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(severity.color)
                .frame(width: 9, height: 9)
            Text(severity.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text("\(count)")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Findings of one repository

private struct FindingList: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        if let repository = model.selectedRepository {
            let findings = repository.findings
            Group {
                if findings.isEmpty {
                    ContentUnavailableView {
                        Label(
                            repository.hasRemote ? "Всё на сервере" : "Нет remote",
                            systemImage: repository.hasRemote ? "checkmark.circle" : "externaldrive"
                        )
                    } description: {
                        Text(repository.hasRemote
                             ? "Здесь нет работы, которой не было бы на сервере."
                             : "У репозитория нет remote, вся история есть только на этом компьютере.")
                    }
                } else {
                    List(selection: $model.selectedFindingID) {
                        section("Не закоммичено", findings.filter { $0.kind == .uncommitted })
                        section("Нет на сервере", findings.filter { $0.kind == .branch || $0.kind == .detached })
                        section("Стэши", findings.filter { $0.kind == .stash })
                    }
                }
            }
        } else {
            ContentUnavailableView("Выберите репозиторий", systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ findings: [Finding]) -> some View {
        if !findings.isEmpty {
            Section(title) {
                ForEach(findings) { finding in
                    FindingRow(finding: finding)
                        .tag(finding.id)
                }
            }
        }
    }
}

private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: finding.systemImage)
                .foregroundStyle(finding.severity.tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                // Stash messages are prose; two lines keep them readable at the default width.
                Text(finding.title)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text([finding.detail, finding.note].compactMap { $0 }.joined(separator: " · "))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Text(RepositoryText.age(finding.date, short: true))
                .font(.body)
                .fontWeight(finding.severity >= .warning ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(finding.severity.tint)
        }
        .padding(.vertical, 2)
        .help([finding.title, finding.detail, finding.note].compactMap { $0 }.joined(separator: "\n"))
    }
}

// MARK: - Detail of one finding

private struct FindingDetail: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        if let finding = model.selectedFinding {
            VStack(spacing: 0) {
                FindingHeader(model: model, finding: finding)
                Divider()
                content
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.findingError {
            ContentUnavailableView("Не удалось прочитать", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            switch model.findingContent {
            case .history(let commits):
                VSplitView {
                    CommitGraph(
                        commits: commits,
                        // A detached HEAD's range also stops at local branches and tags.
                        boundaryLabel: model.selectedFinding?.kind == .detached ? "Уже в ветке или на сервере" : "На сервере",
                        selection: $model.selectedCommitHash
                    )
                        .frame(minHeight: 160)
                    if let commit = commits.first(where: { $0.fullHash == model.selectedCommitHash }) {
                        CommitFilesPane(commit: commit, files: model.commitFiles, error: model.commitFilesError)
                            .frame(minHeight: 120, idealHeight: 220)
                    }
                }
            case .files(let files):
                FileList(files: files)
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct FindingHeader: View {
    let model: WorkspaceModel
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One accent line: the badge names the verdict, the colored reason in the facts explains it.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SeverityBadge(severity: finding.severity)
                Text(finding.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            facts
            Text(RepositoryText.path(finding.location))
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            // As the column narrows, labels shorten step by step instead of truncating.
            ViewThatFits(in: .horizontal) {
                actions(shortPrimary: false, iconsOnly: false)
                actions(shortPrimary: false, iconsOnly: true)
                actions(shortPrimary: true, iconsOnly: true)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(shortPrimary: Bool, iconsOnly: Bool) -> some View {
        HStack(spacing: 8) {
            let copied = model.copiedFindingID == finding.id
            Button {
                model.copyAgentTask(for: finding)
            } label: {
                Label(copied ? "Скопировано" : (shortPrimary ? "Задача для агента" : "Скопировать задачу для агента"),
                      systemImage: copied ? "checkmark" : "doc.on.clipboard")
            }
            .buttonStyle(.borderedProminent)
            .help("Текст, который можно вставить агенту: что найдено, где и что с этим сделать")
            secondary("Показать в Finder", systemImage: "folder", iconOnly: iconsOnly) {
                Workspace.reveal(finding.location)
            }
            secondary("Открыть в Терминале", systemImage: "terminal", iconOnly: iconsOnly) {
                Workspace.openTerminal(at: finding.location)
            }
        }
        .controlSize(.large)
        .fixedSize()
    }

    private func secondary(_ title: String, systemImage: String, iconOnly: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if iconOnly {
                Image(systemName: systemImage).accessibilityLabel(title)
            } else {
                Text(title)
            }
        }
        .help(title)
    }

    private var facts: Text {
        let reason = Text(finding.reason)
            .fontWeight(finding.severity >= .warning ? .medium : .regular)
            .foregroundStyle(finding.severity.tint)
        let rest = [finding.detail, finding.note].compactMap { $0 }.joined(separator: " · ")
        return Text("\(rest) · ").foregroundStyle(.secondary) + reason
    }
}

// MARK: - Files

private struct FileList: View {
    let files: [CommitFileSnapshot]

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView("Файлов нет", systemImage: "doc")
        } else {
            List(files, id: \.path) { file in
                FileRow(file: file)
            }
        }
    }
}

private struct FileRow: View {
    let file: CommitFileSnapshot

    var body: some View {
        let path = file.path as NSString
        HStack(spacing: 8) {
            Text(file.status)
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 14)
                .help(statusName)
            Text(path.lastPathComponent)
                .lineLimit(1)
            Text(path.deletingLastPathComponent)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .help(file.path)
    }

    private var statusColor: Color {
        switch file.status.prefix(1) {
        case "A", "?": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }

    private var statusName: String {
        switch file.status.prefix(1) {
        case "A": return "Добавлен"
        case "?": return "Новый, не добавлен в git"
        case "D": return "Удалён"
        case "R": return "Переименован"
        default: return "Изменён"
        }
    }
}

private struct CommitFilesPane: View {
    let commit: CommitSnapshot
    let files: [CommitFileSnapshot]?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(commit.shortHash)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text("\(commit.author) · \(RepositoryText.fullDate(commit.date))")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if let files {
                    Text(RepositoryText.files(files.count))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let error {
                ContentUnavailableView("Не удалось прочитать файлы", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let files {
                FileList(files: files)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Read-only actions outside the app

enum Workspace {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openTerminal(at url: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
