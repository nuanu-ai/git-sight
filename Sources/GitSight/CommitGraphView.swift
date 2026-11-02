import GitSightCore
import SwiftUI

private let commitRowHeight: CGFloat = 32
private let laneSpacing: CGFloat = 18
private let laneColors = [
    Color(.sRGB, red: 10 / 255, green: 132 / 255, blue: 1),
    Color(.sRGB, red: 1, green: 160 / 255, blue: 10 / 255),
    Color(.sRGB, red: 191 / 255, green: 90 / 255, blue: 242 / 255),
    Color(.sRGB, red: 49 / 255, green: 209 / 255, blue: 88 / 255),
    Color(.sRGB, red: 209 / 255, green: 91 / 255, blue: 180 / 255)
]

private struct CommitDetailHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CommitGraphView: View {
    @ObservedObject var model: WorkspaceModel
    let repository: RepositorySnapshot

    private var commits: [CommitSnapshot] { repository.commits }
    private var rowByHash: [String: Int] {
        Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($0.element.fullHash, $0.offset) })
    }
    private var railWidth: CGFloat {
        let maximumLane = commits.map(\.lane).max() ?? 0
        return 32 + CGFloat(max(0, maximumLane)) * laneSpacing
    }
    private var contentHeight: CGFloat {
        CGFloat(commits.count) * commitRowHeight + model.commitDetailHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("Коммиты")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                Label(repository.currentBranch ?? "detached HEAD", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                if repository.ahead > 0 || repository.behind > 0 {
                    Text(divergence)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider().overlay(Theme.border)

            if commits.isEmpty {
                Text("Нет коммитов для отображения.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        rails
                        VStack(spacing: 0) {
                            ForEach(commits, id: \.fullHash) { commit in
                                CommitRow(
                                    model: model,
                                    commit: commit,
                                    leadingPadding: railWidth + 10,
                                    isExpanded: model.expandedCommitHash == commit.fullHash,
                                    action: { model.toggleCommit(commit, in: repository) }
                                )
                                if model.expandedCommitHash == commit.fullHash {
                                    CommitDetails(
                                        model: model,
                                        repository: repository,
                                        commit: commit,
                                        leadingPadding: railWidth + 10
                                    )
                                    .background(
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: CommitDetailHeight.self,
                                                value: geometry.size.height
                                            )
                                        }
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: contentHeight)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 4)
                }
            }
        }
        .background(Theme.background)
        .onPreferenceChange(CommitDetailHeight.self, perform: model.updateCommitDetailHeight)
    }

    private var divergence: String {
        var parts: [String] = []
        if repository.ahead > 0 { parts.append("↑\(repository.ahead)") }
        if repository.behind > 0 { parts.append("↓\(repository.behind)") }
        return parts.joined(separator: " ")
    }

    private var rails: some View {
        Canvas { context, _ in
            for edge in repository.edges {
                guard let fromRow = rowByHash[edge.from],
                      let toRow = rowByHash[edge.to] else { continue }
                let fromCommit = commits[fromRow]
                let toCommit = commits[toRow]
                let start = CGPoint(x: laneX(fromCommit.lane), y: rowY(fromRow))
                let end = CGPoint(x: laneX(toCommit.lane), y: rowY(toRow))
                var path = Path()
                path.move(to: start)
                if start.x == end.x {
                    path.addLine(to: end)
                } else {
                    let distance = end.y - start.y
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: start.x, y: start.y + distance * 0.5),
                        control2: CGPoint(x: end.x, y: end.y - distance * 0.5)
                    )
                }
                context.stroke(
                    path,
                    with: .color(color(for: toCommit.lane).opacity(0.65)),
                    lineWidth: 1.6
                )
            }

            for (row, commit) in commits.enumerated() {
                let center = CGPoint(x: laneX(commit.lane), y: rowY(row))
                let color = color(for: commit.lane)
                if commit.parents.count > 1 || !commit.refs.isEmpty {
                    let outer = Path(ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13))
                    let inner = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
                    context.stroke(outer, with: .color(color), lineWidth: 1.6)
                    context.fill(inner, with: .color(color))
                } else {
                    let dot = Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                    context.fill(dot, with: .color(Theme.background))
                    context.stroke(dot, with: .color(color), lineWidth: 2)
                }
            }
        }
        .frame(width: railWidth, height: contentHeight)
        .allowsHitTesting(false)
    }

    private func laneX(_ lane: Int) -> CGFloat {
        16 + CGFloat(max(0, lane)) * laneSpacing
    }

    private func rowY(_ row: Int) -> CGFloat {
        var y = CGFloat(row) * commitRowHeight + commitRowHeight / 2
        if let expandedHash = model.expandedCommitHash,
           let expandedRow = rowByHash[expandedHash],
           row > expandedRow {
            y += model.commitDetailHeight
        }
        return y
    }

    private func color(for lane: Int) -> Color {
        laneColors[max(0, lane) % laneColors.count]
    }
}

private struct CommitRow: View {
    @ObservedObject var model: WorkspaceModel
    let commit: CommitSnapshot
    let leadingPadding: CGFloat
    let isExpanded: Bool
    let action: () -> Void

    private var isHovering: Bool { model.hoveredCommitHash == commit.fullHash }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(commit.subject)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let ref = commit.refs.first {
                    Text(ref)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(laneColors[max(0, commit.lane) % laneColors.count])
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(laneColors[max(0, commit.lane) % laneColors.count].opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(commit.author)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                Text(RepositoryText.relative(commit.date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: commitRowHeight)
            .background(isExpanded ? Theme.selected : (isHovering ? Theme.hover : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isExpanded ? Color.white.opacity(0.14) : .clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { model.hoveredCommitHash = $0 ? commit.fullHash : nil }
        .help("\(commit.shortHash) · \(commit.subject)")
        .accessibilityHint(isExpanded ? "Скрыть файлы коммита" : "Показать файлы коммита")
    }
}

private struct CommitDetails: View {
    @ObservedObject var model: WorkspaceModel
    let repository: RepositorySnapshot
    let commit: CommitSnapshot
    let leadingPadding: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(commit.shortHash)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .textSelection(.enabled)
                Text("\(commit.author) · \(RepositoryText.fullDate(commit.date))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                if let files = model.commitFiles[commit.fullHash] {
                    Text(RepositoryText.files(files.count))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            if commit.refs.count > 1 {
                Text(commit.refs.joined(separator: " · "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, leadingPadding)
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
            }

            if model.loadingCommitHash == commit.fullHash {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Загружаем файлы…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                }
                .padding(.leading, leadingPadding)
                .padding(.bottom, 12)
            } else if let error = model.commitErrorMessage {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Не удалось загрузить файлы. \(error)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Повторить") {
                        model.retryCommitFiles(for: commit, in: repository)
                    }
                    .controlSize(.small)
                }
                .padding(.leading, leadingPadding)
                .padding(.trailing, 12)
                .padding(.bottom, 12)
            } else if let files = model.commitFiles[commit.fullHash] {
                if files.isEmpty {
                    Text("Список изменений пуст.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiary)
                        .padding(.leading, leadingPadding)
                        .padding(.bottom, 12)
                } else {
                    ForEach(files, id: \.path) { file in
                        CommitFileRow(file: file)
                            .padding(.leading, max(12, leadingPadding - 16))
                    }
                    Spacer().frame(height: 10)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}

private struct CommitFileRow: View {
    let file: CommitFileSnapshot

    private var path: NSString { file.path as NSString }
    private var status: String { String(describing: file.status).uppercased() }
    private var statusLetter: String { String(status.prefix(1)) }
    private var statusColor: Color {
        switch statusLetter {
        case "A": return Color(.sRGB, red: 49 / 255, green: 209 / 255, blue: 88 / 255)
        case "D": return Color(.sRGB, red: 1, green: 69 / 255, blue: 58 / 255)
        default: return Color(.sRGB, red: 1, green: 160 / 255, blue: 10 / 255)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(fileType)
                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .frame(width: 24, height: 16)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(path.lastPathComponent)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Text(path.deletingLastPathComponent)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(statusLetter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .help(file.path)
    }

    private var fileType: String {
        let ext = path.pathExtension.uppercased()
        return ext.isEmpty ? "FILE" : String(ext.prefix(4))
    }
}
