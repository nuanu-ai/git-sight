import AppKit
import GitSightCore
import SwiftUI
import UniformTypeIdentifiers

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

struct RepositorySidebar: View {
    @Bindable var model: WorkspaceModel
    /// Sections the user folded, by key. All start open: clean repositories are still worth watching.
    @AppStorage("collapsedSidebarSections") private var collapsed = ""

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

    private func isExpanded(_ key: String) -> Bool {
        !collapsed.split(separator: ",").contains(Substring(key))
    }

    private func expansion(_ key: String) -> Binding<Bool> {
        Binding {
            isExpanded(key)
        } set: { expanded in
            var keys = Set(collapsed.split(separator: ",").map(String.init))
            if expanded { keys.remove(key) } else { keys.insert(key) }
            collapsed = keys.sorted().joined(separator: ",")
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
            // Headers are plain rows rather than section headers: the list insets section headers
            // differently from rows, and one inset keeps chevrons, dots, names and numbers on shared lines.
            if !active.isEmpty {
                SidebarHeader(title: "Сейчас", color: .accentColor, count: active.count, isExpanded: expansion("now"))
                if isExpanded("now") {
                    ForEach(active, id: \.0.path) { repository, change in
                        RepositoryRow(repository: repository, activity: change)
                    }
                }
            }
            ForEach([Severity.critical, .warning, .attention, .clean], id: \.self) { severity in
                let group = repositories.filter { $0.severity == severity }
                let key = "\(severity)"
                if !group.isEmpty {
                    SidebarHeader(title: severity.title, color: severity.color, count: group.count, isExpanded: expansion(key))
                    if isExpanded(key) {
                        ForEach(group, id: \.path) { repository in
                            RepositoryRow(repository: repository)
                        }
                    }
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
        HStack(spacing: SidebarGrid.gap) {
            Circle()
                .fill(repository.severity.color)
                .frame(width: 7, height: 7)
                .frame(width: SidebarGrid.marker)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.name)
                    .lineLimit(1)
                // The age on the right already says when; the line says what.
                Text(activity?.text ?? repository.summary)
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



/// The columns every sidebar row shares, headers included, so nothing drifts between them.
enum SidebarGrid {
    /// The leading column: a repository's dot, a group's chevron.
    static let marker: CGFloat = 10
    static let gap: CGFloat = 8
}

/// A group of repositories that folds on click. It sits on the same columns as the rows below it.
private struct SidebarHeader: View {
    let title: String
    let color: Color
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: SidebarGrid.gap) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SidebarGrid.marker)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(color == Severity.attention.color ? Color.black.opacity(0.8) : .white)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(color))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // More room above a group than inside it.
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded ? "развёрнуто" : "свёрнуто")
    }
}

// MARK: - Findings of one repository

private struct FindingList: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        if let repository = model.selectedRepository {
            let findings = repository.findings
            List(selection: $model.selectedFindingID) {
                // Every section has a title: a section without one turns the list into an outline,
                // which insets its rows differently.
                Section("Репозиторий") {
                    GraphRow(repository: repository)
                        .tag(WorkspaceModel.graphID(of: repository))
                    if findings.isEmpty {
                        // Nothing to fix; the graph above is still there to watch. Kept on the rows' text column.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Color.clear.frame(width: 16, height: 1)
                            Text(repository.hasRemote
                                 ? "Всё на сервере: здесь нет работы, которой не было бы на сервере."
                                 : "Нет remote: вся история есть только на этом компьютере.")
                                .foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    }
                }
                section("Не закоммичено", findings.filter { $0.kind == .uncommitted })
                section("Нет на сервере", findings.filter { $0.kind == .branch || $0.kind == .detached })
                section("Стэши", findings.filter { $0.kind == .stash })
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

/// The whole repository's graph, on the same columns as the findings below it.
private struct GraphRow: View {
    let repository: RepositorySnapshot

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Все ветки")
                Text(repository.branchesSummary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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
        } else if model.showsGraph, let repository = model.selectedRepository {
            VStack(spacing: 0) {
                GraphHeader(repository: repository)
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
                CommitGraph(
                    commits: commits,
                    // A detached HEAD's range also stops at local branches and tags.
                    boundaryLabel: model.selectedFinding?.kind == .detached ? "Уже в ветке или на сервере" : "На сервере",
                    selection: $model.selectedCommitHash,
                    files: model.commitFiles,
                    filesError: model.commitFilesError
                )
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

private struct GraphHeader: View {
    let repository: RepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Все ветки")
                .font(.title2.weight(.semibold))
            Text(repository.branchesSummary)
                .foregroundStyle(.secondary)
            Text(RepositoryText.path(repository.path))
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            // Labels turn into icons as the column narrows, as in the finding header.
            ViewThatFits(in: .horizontal) {
                actions(iconsOnly: false)
                actions(iconsOnly: true)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension GraphHeader {
    fileprivate func actions(iconsOnly: Bool) -> some View {
        HStack(spacing: 8) {
            Button { Workspace.reveal(repository.path) } label: {
                if iconsOnly { Image(systemName: "folder") } else { Text("Показать в Finder") }
            }
            .help("Показать в Finder")
            Button { Workspace.openTerminal(at: repository.path) } label: {
                if iconsOnly { Image(systemName: "terminal") } else { Text("Открыть в Терминале") }
            }
            .help("Открыть в Терминале")
        }
        .controlSize(.large)
        .fixedSize()
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
            // Fresh work is still being done, by you or an agent; a task for it would only get in the way.
            if finding.severity >= .warning || finding.work == .commits(upstreamGone: true) {
                let copied = model.copiedFindingID == finding.id
                Button {
                    model.copyAgentTask(for: finding)
                } label: {
                    // The label keeps its width when it confirms, so nothing moves under the pointer.
                    HStack(spacing: 6) {
                        Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                            .frame(width: 18)
                        Text(shortPrimary ? "Задача для агента" : "Скопировать задачу для агента")
                    }
                }
                .buttonStyle(.borderedProminent)
                // Hovering shows exactly what goes on the clipboard.
                .help(model.agentTask(for: finding) ?? "")
                .accessibilityValue(copied ? "Скопировано" : "")
            }
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

/// A changed file as VS Code lists it: icon, name, folder, and the status letter on the right.
struct FileRow: View {
    let file: CommitFileSnapshot

    var body: some View {
        let path = file.path as NSString
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: path.pathExtension) ?? .data))
                .resizable()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(path.lastPathComponent)
                .strikethrough(letter == "D")
                .lineLimit(1)
                .layoutPriority(1)
            Text(path.deletingLastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(letter)
                .font(.body.monospaced().weight(.semibold))
                .foregroundStyle(statusColor)
                .help(statusName)
        }
        .help(file.path)
    }

    /// git's status letter, with untracked shown as U like VS Code.
    private var letter: String {
        let letter = String(file.status.prefix(1))
        return letter == "?" ? "U" : letter
    }

    private var statusColor: Color {
        switch letter {
        case "A", "U": return .green
        case "D": return .red
        case "R", "C": return .blue
        default: return .orange
        }
    }

    private var statusName: String {
        switch letter {
        case "A": return "Добавлен"
        case "U": return "Новый, не добавлен в git"
        case "D": return "Удалён"
        case "R": return "Переименован"
        case "C": return "Скопирован"
        default: return "Изменён"
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
