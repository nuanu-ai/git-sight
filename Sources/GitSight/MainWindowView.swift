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
                // Two columns: a repository's findings fold out under it in the sidebar,
                // so the graph and the diff get the rest of the window.
                NavigationSplitView {
                    RepositorySidebar(model: model)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 480)
                } detail: {
                    FindingDetail(model: model)
                }
                .searchable(text: $model.filter, placement: .sidebar, prompt: "Репозиторий или ветка")
                // The window shows the split view's title, not the content column's.
                .navigationTitle(model.selectedRepository?.name ?? "git-sight")
                .navigationSubtitle(model.selectedRepository.map { RepositoryText.path($0.path) } ?? "")
                // macOS's 13 pt default reads too small for a window you scan at a glance.
                .textRole(.primary)
                .frame(minWidth: 820, minHeight: 560)
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
                    .textRole(.secondary)
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

    /// A repository's row selects its graph; a finding's row selects that finding.
    private var selection: Binding<String?> {
        Binding {
            model.selectedFindingID
        } set: { id in
            guard let id else { return }
            if let repository = model.repositories.first(where: { WorkspaceModel.graphID(of: $0) == id }) {
                model.selectedPath = repository.path
            }
            model.selectedFindingID = id
        }
    }

    /// The selected repository's work, folded out under its row: uncommitted, then local commits, then stashes.
    @ViewBuilder
    private func findings(of repository: RepositorySnapshot) -> some View {
        if repository.path == model.selectedPath {
            let order: [Finding.Kind] = [.uncommitted, .branch, .detached, .stash]
            ForEach(repository.findings.sorted { order.firstIndex(of: $0.kind) ?? 0 < order.firstIndex(of: $1.kind) ?? 0 }) { finding in
                FindingRow(finding: finding)
                    .tag(finding.id)
            }
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
        return List(selection: selection) {
            // Headers are plain rows rather than section headers: the list insets section headers
            // differently from rows, and one inset keeps chevrons, dots, names and numbers on shared lines.
            if !active.isEmpty {
                SidebarHeader(title: "Сейчас", color: .accentColor, count: active.count, isExpanded: expansion("now"))
                if isExpanded("now") {
                    ForEach(active, id: \.0.path) { repository, change in
                        RepositoryRow(repository: repository, activity: change)
                        findings(of: repository)
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
                            findings(of: repository)
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
                .selectableTint(repository.severity.color)
                .frame(width: 7, height: 7)
                .frame(width: SidebarGrid.marker)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(repository.name)
                    .lineLimit(1)
                // The age on the right already says when; the line says what.
                Text(activity?.text ?? repository.summary)
                    .textRole(.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let oldest = repository.oldestUnsavedWork {
                Text(RepositoryText.age(oldest, short: true))
                    .textRole(.secondary)
                    .fontWeight(repository.severity >= .warning ? .semibold : .regular)
                    .monospacedDigit()
                    .selectableTint(repository.severity.tint)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, SidebarGrid.step)
        .tag(WorkspaceModel.graphID(of: repository))
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
                                    Text(RepositoryText.path(failure.path)).fontWeight(.medium)
                                    Text(failure.message).textRole(.secondary).foregroundStyle(.secondary)
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
        .textRole(.secondary)
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
            .textRole(.secondary)
            .fontWeight(.semibold)
            .foregroundStyle(severity == .attention ? Color.black.opacity(0.8) : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(severity.color))
    }
}



/// A severity color that turns white on a selected row, as macOS does in Mail and Finder:
/// red or orange on the selection's blue is hard to read and rough on the eye at the edges.
private struct SelectableTint: ViewModifier {
    @Environment(\.backgroundProminence) private var prominence
    let color: Color

    func body(content: Content) -> some View {
        content.foregroundStyle(prominence == .increased ? Color.white : color)
    }
}

extension View {
    fileprivate func selectableTint(_ color: Color) -> some View {
        modifier(SelectableTint(color: color))
    }
}

/// The columns every sidebar row shares. Each level of nesting moves in by one step, and a row's
/// marker (a group's chevron, a repository's dot, a finding's icon) sits in the text column of the level above,
/// as in Mail: group title at 18, repository name at 36, finding at 54.
enum SidebarGrid {
    static let marker: CGFloat = 14
    static let gap: CGFloat = 4
    static let step: CGFloat = marker + gap
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
                    .textRole(.label)
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: SidebarGrid.marker)
                Text(title)
                    .fontWeight(.semibold)
                Spacer(minLength: 4)
                Text("\(count)")
                    .textRole(.label)
                    .fontWeight(.semibold)
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

/// A finding under its repository's row, one level further in.
private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(spacing: SidebarGrid.gap) {
            Image(systemName: finding.systemImage)
                .imageScale(.small)
                .selectableTint(finding.severity.tint)
                .frame(width: SidebarGrid.marker)
                .accessibilityHidden(true)
            // The name alone repeats: a worktree on main and the branch main are both "main".
            // What kind of work it is follows the name.
            (Text(finding.title) + Text("  \(finding.detail)").foregroundStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Text(RepositoryText.age(finding.date, short: true))
                .textRole(.secondary)
                .fontWeight(finding.severity >= .warning ? .semibold : .regular)
                .monospacedDigit()
                .selectableTint(finding.severity.tint)
        }
        .padding(.leading, SidebarGrid.step * 2)
        .help([finding.title, finding.detail, finding.note].compactMap { $0 }.joined(separator: "\n"))
    }
}

// MARK: - Detail of one finding

private struct FindingDetail: View {
    @Bindable var model: WorkspaceModel
    /// The diff's share of the height under the header; the user drags the line between them.
    @AppStorage("diffFraction") private var diffFraction = 0.65

    var body: some View {
        if let finding = model.selectedFinding {
            VStack(spacing: 0) {
                FindingHeader(model: model, finding: finding)
                Divider()
                withDiff
            }
        } else if model.showsGraph, let repository = model.selectedRepository {
            VStack(spacing: 0) {
                GraphHeader(repository: repository)
                Divider()
                withDiff
            }
        } else {
            ContentUnavailableView("Выберите репозиторий", systemImage: "sidebar.left")
        }
    }

    /// The graph or file list on top, and under it, once a file is clicked, most of the height for its diff.
    @ViewBuilder
    private var withDiff: some View {
        if let file = model.diffFile {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    content
                        .frame(height: geometry.size.height * (1 - diffFraction))
                    PaneDivider(fraction: $diffFraction, height: geometry.size.height)
                    DiffPane(file: file, diff: model.fileDiff, error: model.fileDiffError, close: model.closeDiff)
                }
            }
            .coordinateSpace(name: PaneDivider.space)
        } else {
            content
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
                    selection: $model.selectedCommitHash,
                    files: model.commitFiles,
                    filesError: model.commitFilesError,
                    openFile: model.diffFile,
                    onOpenFile: model.toggleDiff,
                    onReachEnd: model.loadMoreHistory
                )
            case .files(let files):
                FileList(files: files, openFile: model.diffFile, onOpenFile: model.toggleDiff)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                Text("Все ветки")
                    .textRole(.title)
                    .fontWeight(.semibold)
                Spacer(minLength: 12)
                DetailActions(location: repository.path)
            }
            Text(repository.branchesSummary)
                .textRole(.secondary)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Finder and Terminal as icons: the path they open is in the window's title.
private struct DetailActions: View {
    let location: URL

    var body: some View {
        HStack(spacing: 4) {
            Button { Workspace.reveal(location) } label: {
                Image(systemName: "folder").accessibilityLabel("Показать в Finder")
            }
            .help("Показать в Finder")
            Button { Workspace.openTerminal(at: location) } label: {
                Image(systemName: "terminal").accessibilityLabel("Открыть в Терминале")
            }
            .help("Открыть в Терминале")
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .fixedSize()
    }
}

private struct FindingHeader: View {
    let model: WorkspaceModel
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // One accent line: the badge names the verdict, the colored reason in the facts explains it.
            HStack(spacing: 10) {
                SeverityBadge(severity: finding.severity)
                Text(finding.title)
                    .textRole(.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                // As the header narrows, the agent button's label shortens instead of truncating.
                ViewThatFits(in: .horizontal) {
                    actions(shortPrimary: false)
                    actions(shortPrimary: true)
                }
            }
            facts
                .textRole(.secondary)
                .lineLimit(2)
            // The repository's path is in the window's title; a worktree elsewhere is worth naming.
            if finding.location != model.selectedRepository?.path {
                Text(RepositoryText.path(finding.location))
                    .textRole(.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actions(shortPrimary: Bool) -> some View {
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
                .controlSize(.large)
                // Hovering shows exactly what goes on the clipboard.
                .help(model.agentTask(for: finding) ?? "")
                .accessibilityValue(copied ? "Скопировано" : "")
            }
            DetailActions(location: finding.location)
        }
        .fixedSize()
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
    let openFile: CommitFileSnapshot?
    let onOpenFile: (CommitFileSnapshot) -> Void

    var body: some View {
        if files.isEmpty {
            ContentUnavailableView("Файлов нет", systemImage: "doc")
        } else {
            // A click opens a file's diff below and the same click closes it. A List selection
            // would not report a click on the row it has already selected.
            ScrollViewReader { proxy in
                List(files, id: \.path) { file in
                    FileRow(file: file)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenFile(file) }
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(file.path == openFile?.path ? Color.accentColor.opacity(0.22) : .clear)
                                .padding(.horizontal, 8)
                        )
                        .listRowSeparator(.hidden)
                }
                // The diff pane takes the lower part; the open file scrolls back into view.
                .onChange(of: openFile?.path) { _, path in
                    guard let path else { return }
                    DispatchQueue.main.async {
                        withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(path) }
                    }
                }
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
                .textRole(.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(letter)
                .textRole(.secondary)
                .fontWeight(.semibold)
                .monospaced()
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
