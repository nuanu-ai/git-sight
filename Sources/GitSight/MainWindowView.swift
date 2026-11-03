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
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 360)
                        // In the sidebar's own toolbar, so the sidebar button keeps to the sidebar's edge
                        // instead of sitting between the sidebar and the detail.
                        .toolbar {
                            ToolbarItem {
                                Button(action: model.chooseRoot) {
                                    Label(model.rootURL.map { RepositoryText.path($0) } ?? "Choose Folder", systemImage: "folder")
                                        .labelStyle(.titleAndIcon)
                                }
                                .help("The folder to look for repositories in (⌘O)")
                            }
                        }
                } detail: {
                    if let repository = model.selectedRepository {
                        RepositoryView(model: model, repository: repository)
                    } else {
                        OverviewView(model: model)
                    }
                }
                .searchable(text: $model.filter, placement: .sidebar, prompt: "Repository or branch")
                .navigationTitle(model.selectedRepository?.name ?? "Overview")
                // macOS's 13 pt default reads too small for a window you scan at a glance.
                .textRole(.primary)
                .frame(minWidth: 980, minHeight: 600)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning, !model.repositories.isEmpty {
                    ProgressView(value: model.scanProgress?.fractionCompleted ?? 0)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .help("Scanning…")
                } else {
                    Button(action: model.scan) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.rootURL == nil || model.isScanning)
                    .help("Scan again (⌘R)")
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
                Button("Stop", action: model.cancelScan)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.rootURL == nil {
            ContentUnavailableView {
                Label("Where are your repositories?", systemImage: "folder.badge.questionmark")
            } description: {
                Text("git-sight finds every git repository in a folder and shows work that isn't on the server yet. It only reads and never changes anything.")
            } actions: {
                Button("Choose Folder…", action: model.chooseRoot)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        } else if let errorMessage = model.errorMessage {
            ContentUnavailableView {
                Label("Couldn't scan the folder", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Try Again", action: model.scan)
                Button("Choose Another Folder…", action: model.chooseRoot)
            }
        } else if model.scanStopped {
            ContentUnavailableView {
                Label("Scan stopped", systemImage: "stop.circle")
            } description: {
                Text("Nothing to show yet.")
            } actions: {
                Button("Scan", action: model.scan)
                Button("Choose Another Folder…", action: model.chooseRoot)
            }
        } else if model.lastScanDate != nil {
            ContentUnavailableView {
                Label("No repositories found", systemImage: "folder")
            } description: {
                Text("There are no git repositories in \(model.rootURL.map { RepositoryText.path($0) } ?? "this folder"). Hidden folders, Library and node_modules are skipped.")
            } actions: {
                Button("Choose Another Folder…", action: model.chooseRoot)
            }
        } else {
            Color.clear
        }
    }

    private var status: String {
        guard let progress = model.scanProgress else { return "Looking for repositories…" }
        switch progress.phase {
        case .discovery:
            return "Looking for repositories: \(RepositoryText.counted(progress.scannedDirectories, "folder", "folders")) so far"
        case .inspection:
            return "Reading repositories: \(progress.processedRepositories) of \(progress.totalRepositories)"
        }
    }
}

// MARK: - Sidebar

/// The columns every sidebar row shares: a group's title sits in the marker column,
/// a row's dot or icon there too, and names one step in, as in Mail.
enum SidebarGrid {
    static let marker: CGFloat = 14
    static let gap: CGFloat = 4
    static let step: CGFloat = marker + gap
}

struct RepositorySidebar: View {
    @Bindable var model: WorkspaceModel

    private static let overviewTag = "overview"

    var body: some View {
        // Re-evaluated every half minute so repositories leave "Live now" once they go quiet.
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

    private var selection: Binding<String?> {
        Binding {
            model.selectedPath?.path ?? Self.overviewTag
        } set: { tag in
            guard let tag, tag != (model.selectedPath?.path ?? Self.overviewTag) else { return }
            if tag == Self.overviewTag {
                model.showOverview()
            } else if let repository = model.repositories.first(where: { $0.path.path == tag }) {
                model.open(repository)
            }
        }
    }

    private func list(now: Date) -> some View {
        let all = model.filteredRepositories
        let live = all.filter { $0.liveChange(now: now) != nil }
        let quiet = all.filter { $0.liveChange(now: now) == nil }
        let total = model.repositories.reduce(0) { $0 + $1.weight(now: now) }
        return List(selection: selection) {
            HStack(spacing: SidebarGrid.gap) {
                Image(systemName: "square.grid.2x2")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarGrid.marker)
                Text("Overview")
                Spacer(minLength: 4)
                Weight(value: total)
            }
            .tag(Self.overviewTag)
            group("Live now", live, now: now)
            group("Work left", quiet.filter { $0.weight(now: now) > 0 }, now: now)
            group("Clean", quiet.filter { $0.weight(now: now) == 0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, now: now)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ repositories: [RepositorySnapshot], now: Date) -> some View {
        if !repositories.isEmpty {
            // A plain row, not a section header: SwiftUI insets those differently from rows.
            Text(title)
                .textRole(.label)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                // Enough to set the group off, no more than the gap over Overview.
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(repositories, id: \.path) { repository in
                RepositoryRow(repository: repository, now: now)
                    .tag(repository.path.path)
            }
        }
    }
}

/// A repository's weight, right-aligned in the sidebar; nothing when there is nothing to weigh.
private struct Weight: View {
    let value: Double

    var body: some View {
        if value > 0 {
            Text(RepositoryText.weight(value))
                .textRole(.secondary)
                .monospacedDigit()
                .selectableTint(.secondary)
        }
    }
}

private struct RepositoryRow: View {
    let repository: RepositorySnapshot
    let now: Date

    var body: some View {
        let weight = repository.weight(now: now)
        let lead = repository.lead(now: now)
        HStack(spacing: SidebarGrid.gap) {
            VerdictDot(verdict: lead?.verdict(now: now))
                .frame(width: SidebarGrid.marker)
            Text(repository.name)
                .lineLimit(1)
                .selectableTint(weight > 0 ? .primary : .secondary)
            if let change = repository.liveChange(now: now) {
                LiveDot(date: change.date)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 4)
            Weight(value: weight)
        }
        .help(RepositoryText.path(repository.path))
        .contextMenu { RepositoryActions(repository: repository) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(repository.name), \(lead?.verdict(now: now).title ?? "clean")")
    }
}

private struct RepositoryActions: View {
    let repository: RepositorySnapshot

    var body: some View {
        Button("Show in Finder") { Workspace.reveal(repository.path) }
        Button("Open in Terminal") { Workspace.openTerminal(at: repository.path) }
        if let remote = repository.remoteWebURL {
            Button("Open \(remote.host ?? "Remote")") { NSWorkspace.shared.open(remote) }
        }
        Divider()
        Button("Copy Path") { Workspace.copy(repository.path.path) }
    }
}

private struct SidebarFooter: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
            if let lastScanDate = model.lastScanDate {
                Text("Updated \(lastScanDate.formatted(date: .omitted, time: .shortened))")
            }
            if let errorMessage = model.errorMessage {
                // The list above is from the last scan that worked.
                Label("Couldn't refresh", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errorMessage)
            }
            Spacer()
            if !model.scanFailures.isEmpty {
                Button {
                    model.showsScanFailures.toggle()
                } label: {
                    Label("Couldn't read \(model.scanFailures.count)", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $model.showsScanFailures) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.scanFailures, id: \.path) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(RepositoryText.path(failure.path)).fontWeight(.medium)
                                    Text(failure.message).textRole(.secondary).foregroundStyle(.secondary)
                                }
                                .textSelection(.enabled)
                            }
                        }
                        .padding(16)
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

// MARK: - Files

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
        case "A": return "Added"
        case "U": return "New, not added to git yet"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        default: return "Modified"
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
