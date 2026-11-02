import GitSightCore
import SwiftUI

enum Theme {
    static let background = Color(.sRGB, red: 23 / 255, green: 24 / 255, blue: 28 / 255)
    static let raised = Color(.sRGB, red: 30 / 255, green: 31 / 255, blue: 37 / 255)
    static let hover = Color.white.opacity(0.045)
    static let selected = Color.white.opacity(0.07)
    static let border = Color.white.opacity(0.07)
    static let text = Color(.sRGB, red: 236 / 255, green: 236 / 255, blue: 239 / 255)
    static let secondary = Color(.sRGB, red: 162 / 255, green: 164 / 255, blue: 172 / 255)
    static let tertiary = Color(.sRGB, red: 147 / 255, green: 149 / 255, blue: 159 / 255)
    static let accent = Color(.sRGB, red: 10 / 255, green: 132 / 255, blue: 255 / 255)
}

extension Severity {
    var color: Color {
        switch self {
        case .clean: return Color(.sRGB, red: 49 / 255, green: 209 / 255, blue: 88 / 255)
        case .attention: return Color(.sRGB, red: 255 / 255, green: 214 / 255, blue: 10 / 255)
        case .warning: return Color(.sRGB, red: 255 / 255, green: 160 / 255, blue: 10 / 255)
        case .critical: return Color(.sRGB, red: 255 / 255, green: 69 / 255, blue: 58 / 255)
        }
    }

    var label: String {
        switch self {
        case .clean: return "чисто"
        case .attention: return "в работе"
        case .warning: return "заброшено"
        case .critical: return "забыто"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.border)
            HStack(spacing: 0) {
                RepositorySidebar(model: model)
                    .frame(width: 264)
                Divider().overlay(Theme.border)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, idealWidth: 1180, minHeight: 600, idealHeight: 760)
        .background(Theme.raised)
        .preferredColorScheme(.dark)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("git-sight")
                .font(.system(size: 13.5, weight: .semibold))
            Text("·")
                .foregroundStyle(Theme.tertiary)
            Button(action: model.chooseRoot) {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                    Text(rootTitle)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Выбрать папку для поиска репозиториев")

            Spacer(minLength: 12)

            if model.isScanning {
                ProgressView(value: model.scanProgress?.fractionCompleted ?? 0)
                    .frame(width: 110)
                Text("Сканируем…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
            } else if let lastScanDate = model.lastScanDate {
                Text("Обновлено \(lastScanDate.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiary)
                if !model.scanFailures.isEmpty {
                    Label("Пропущено: \(model.scanFailures.count)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Severity.warning.color)
                        .help(model.scanFailures.map { "\($0.path.path): \($0.message)" }.joined(separator: "\n\n"))
                }
            }
            Button(action: model.isScanning ? model.cancelScan : model.scan) {
                Image(systemName: model.isScanning ? "xmark" : "arrow.clockwise")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: .command)
            .help(model.isScanning ? "Остановить сканирование" : "Сканировать локальные репозитории заново")

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiary)
                TextField("Фильтр", text: $model.filter)
                    .textFieldStyle(.plain)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(width: 170)
            .background(Theme.raised)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 50)
        .background(Theme.raised)
    }

    private var rootTitle: String {
        if model.rootURL == FileManager.default.homeDirectoryForCurrentUser {
            return "~ (домашний каталог)"
        }
        return RepositoryText.path(model.rootURL)
    }

    @ViewBuilder
    private var detail: some View {
        if model.isScanning {
            ScanInProgressView(model: model)
        } else if let errorMessage = model.errorMessage {
            WorkspaceStateView(
                systemImage: "exclamationmark.triangle",
                title: "Сканирование не началось",
                message: errorMessage,
                actionTitle: "Повторить",
                action: model.scan
            )
        } else if let repository = model.selectedRepository {
            RepositoryDetailView(model: model, repository: repository)
        } else if !model.hasStartedScan {
            FirstScanView(model: model)
        } else {
            WorkspaceStateView(
                systemImage: "folder",
                title: "Сканирование завершено",
                message: model.scanFailures.first?.message ?? "В выбранной папке репозитории не найдены.",
                actionTitle: "Начать заново",
                action: model.scan
            )
        }
    }
}

private struct FirstScanView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text("Где искать репозитории?")
                .font(.system(size: 17, weight: .semibold))
            Button(action: model.chooseRoot) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(RepositoryText.path(model.rootURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                }
                .frame(maxWidth: 460)
            }
            .buttonStyle(.link)
            Button("Начать сканирование", action: model.scan)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)
            Text("Сканирование только читает Git-метаданные.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanInProgressView: View {
    @ObservedObject var model: WorkspaceModel

    private var status: String {
        guard let progress = model.scanProgress else { return "Подготавливаем сканирование" }
        switch progress.phase {
        case .discovery:
            return "Каталогов: \(progress.scannedDirectories) · репозиториев найдено: \(progress.totalRepositories)"
        case .inspection:
            return "Проверка репозитория \(progress.processedRepositories) из \(progress.totalRepositories)"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Сканируем репозитории")
                .font(.system(size: 16, weight: .semibold))
            ProgressView(value: model.scanProgress?.fractionCompleted ?? 0) {
                Text(status)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: 440)
            Text(RepositoryText.path(model.rootURL))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 440)
            Button("Остановить", role: .cancel, action: model.cancelScan)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RepositorySidebar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(RepositoryText.repositories(model.repositories.count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                if !model.repositories.isEmpty {
                    let abandonedCount = model.repositories.filter { $0.severity >= .warning }.count
                    Text("· заброшено в \(abandonedCount)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.filteredRepositories, id: \.path) { repository in
                        RepositoryRow(model: model, repository: repository)
                    }
                    if model.filteredRepositories.isEmpty && !model.isScanning {
                        Text(model.repositories.isEmpty ? "Нет репозиториев" : "Ничего не найдено")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 28)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Theme.raised)
    }
}

private struct RepositoryRow: View {
    @ObservedObject var model: WorkspaceModel
    let repository: RepositorySnapshot

    private var isSelected: Bool { model.selectedPath == repository.path }

    var body: some View {
        Button(action: { model.select(repository) }) {
            HStack(spacing: 9) {
                Circle()
                    .fill(repository.severity.color)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(repository.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.text : Theme.secondary)
                        .lineLimit(1)
                    Text(repository.shortSignal)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(repository.statusLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(repository.severity.color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HoverBackground(isSelected: isSelected))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(repository.name), \(repository.statusLabel), \(repository.shortSignal)")
    }
}

struct RepositoryDetailView: View {
    @ObservedObject var model: WorkspaceModel
    let repository: RepositorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(repository.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(RepositoryText.path(repository.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(repository.statusLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(repository.severity.color)
                }
                Text(repository.fullReason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 13)
            .padding(.bottom, 11)
            Divider().overlay(Theme.border)
            IssuePanel(model: model, repository: repository)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct IssuePanel: View {
    @ObservedObject var model: WorkspaceModel
    let repository: RepositorySnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                let dirtyWorktrees = repository.dirtyWorktrees
                    .sorted { ($0.dirtyModifiedAt ?? .distantFuture) < ($1.dirtyModifiedAt ?? .distantFuture) }
                if !dirtyWorktrees.isEmpty {
                    IssueSection(title: "Не закоммичено") {
                        ForEach(dirtyWorktrees, id: \.path) { worktree in
                            IssueRow(
                                identifier: "dirty-\(worktree.path.path)",
                                systemImage: "pencil",
                                title: worktree.isMain ? "основной чекаут" : worktree.name,
                                branch: worktree.branch,
                                detail: RepositoryText.files(worktree.dirtyFileCount),
                                date: worktree.dirtyModifiedAt ?? worktree.lastActivity
                            )
                        }
                    }
                }

                let unpushedBranches = repository.unpushedBranches
                    .sorted { ($0.lastCommitDate ?? .distantFuture) < ($1.lastCommitDate ?? .distantFuture) }
                if !unpushedBranches.isEmpty || !repository.detachedWorktrees.isEmpty {
                    IssueSection(title: "Нет на сервере") {
                        ForEach(unpushedBranches, id: \.name) { branch in
                            IssueRow(
                                identifier: "branch-\(branch.name)",
                                systemImage: "arrow.triangle.branch",
                                title: branch.name,
                                branch: nil,
                                detail: RepositoryText.commits(branch.unpushedCommits),
                                date: branch.lastCommitDate,
                                monospacedTitle: true
                            )
                        }
                        ForEach(repository.detachedWorktrees, id: \.path) { worktree in
                            IssueRow(
                                identifier: "detached-\(worktree.path.path)",
                                systemImage: "folder",
                                title: worktree.name,
                                branch: "detached HEAD",
                                detail: RepositoryText.commits(worktree.unpushedCommits),
                                date: worktree.lastActivity
                            )
                        }
                    }
                }

                if !repository.stashes.isEmpty {
                    IssueSection(title: "Стэши · \(repository.stashes.count)") {
                        ForEach(repository.stashes.sorted(by: { $0.date < $1.date }), id: \.name) { stash in
                            IssueRow(
                                identifier: "stash-\(stash.name)",
                                systemImage: "tray.full",
                                title: stash.name,
                                branch: nil,
                                detail: stash.message,
                                date: stash.date,
                                monospacedTitle: true
                            )
                        }
                    }
                }

                if !repository.hasRemote {
                    Label("Нет remote: вся история есть только на этом компьютере.", systemImage: "externaldrive")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 16)
                } else if repository.severity == .clean {
                    Label("Всё, что есть локально, есть и на сервере.", systemImage: "checkmark.circle")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct IssueSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 12)
            .padding(.bottom, 4)
        content
    }
}

private struct IssueRow: View {
    let identifier: String
    let systemImage: String
    let title: String
    let branch: String?
    let detail: String
    let date: Date?
    var monospacedTitle = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(monospacedTitle ? .system(size: 11, design: .monospaced) : .system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let branch {
                        Text(branch)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                    }
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Text(RepositoryText.relative(date))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(HoverBackground())
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .help([title, branch, detail].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct WorkspaceStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var showsProgress = false
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
