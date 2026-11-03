import GitSightCore
import SwiftUI

/// Commits on fixed-height rows, so rails are drawn from row indices and never drift from the text.
struct CommitGraph: View {
    let commits: [CommitSnapshot]
    /// What the commits the range stops at have in common, e.g. "На сервере".
    let boundaryLabel: String
    @Binding var selection: String?

    private static let rowHeight: CGFloat = 36
    private static let laneSpacing: CGFloat = 16
    private static let laneColors: [Color] = [.blue, .orange, .purple, .green, .pink, .teal]

    private var railWidth: CGFloat {
        Self.laneX(commits.map(\.lane).max() ?? 0) + 14
    }

    var body: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                rails
                    .frame(width: railWidth, height: Self.rowHeight * CGFloat(commits.count))
                LazyVStack(spacing: 0) {
                    ForEach(commits, id: \.fullHash) { commit in
                        CommitRow(commit: commit, boundaryLabel: boundaryLabel, isSelected: selection == commit.fullHash)
                            .padding(.leading, railWidth)
                            .frame(height: Self.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard !commit.isBoundary else { return }
                                selection = selection == commit.fullHash ? nil : commit.fullHash
                            }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var rails: some View {
        Canvas { context, size in
            let rows = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($0.element.fullHash, $0.offset) })
            for (row, commit) in commits.enumerated() where !commit.isBoundary {
                let start = point(row: row, lane: commit.lane)
                for (offset, parentHash) in commit.parents.enumerated() {
                    // The core holds this lane for the parent until the parent's row, so nothing else sits on it.
                    let lane = offset < commit.parentLanes.count ? commit.parentLanes[offset] : commit.lane
                    let x = Self.laneX(lane)
                    var path = Path()
                    path.move(to: start)
                    if let parentRow = rows[parentHash] {
                        let end = point(row: parentRow, lane: commits[parentRow].lane)
                        if end.y - start.y <= Self.rowHeight {
                            Self.bend(&path, from: start, to: end)
                        } else {
                            // Into the held lane below the child, down it, into the parent's lane above the parent.
                            var current = start
                            if x != start.x {
                                current = CGPoint(x: x, y: start.y + Self.rowHeight)
                                Self.bend(&path, from: start, to: current)
                            }
                            let join = CGPoint(x: x, y: end.y - Self.rowHeight)
                            if join.y > current.y { path.addLine(to: join) }
                            if x != end.x {
                                Self.bend(&path, from: join, to: end)
                            } else {
                                path.addLine(to: end)
                            }
                        }
                    } else {
                        // The parent is past the history limit: the line runs off the bottom in its lane.
                        var current = start
                        if x != start.x {
                            current = CGPoint(x: x, y: start.y + Self.rowHeight)
                            Self.bend(&path, from: start, to: current)
                        }
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    context.stroke(path, with: .color(color(lane: lane).opacity(0.7)), lineWidth: 1.5)
                }
            }
            for (row, commit) in commits.enumerated() {
                let center = point(row: row, lane: commit.lane)
                let dot = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
                if commit.isBoundary {
                    context.stroke(dot, with: .color(.secondary), lineWidth: 1.5)
                } else {
                    context.fill(dot, with: .color(color(lane: commit.lane)))
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// An S-curve between two lanes that leaves and arrives vertically.
    private static func bend(_ path: inout Path, from start: CGPoint, to end: CGPoint) {
        let height = end.y - start.y
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: start.y + height * 0.6),
            control2: CGPoint(x: end.x, y: end.y - height * 0.6)
        )
    }

    private func point(row: Int, lane: Int) -> CGPoint {
        CGPoint(x: Self.laneX(lane), y: (CGFloat(row) + 0.5) * Self.rowHeight)
    }

    private static func laneX(_ lane: Int) -> CGFloat {
        14 + CGFloat(max(0, lane)) * laneSpacing
    }

    private func color(lane: Int) -> Color {
        Self.laneColors[max(0, lane) % Self.laneColors.count]
    }
}

private struct CommitRow: View {
    let commit: CommitSnapshot
    let boundaryLabel: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(commit.isBoundary ? "\(boundaryLabel): \(commit.subject)" : commit.subject)
                .foregroundStyle(commit.isBoundary ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(commit.shortHash)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
            Text(RepositoryText.age(commit.date, short: true))
                .font(.body)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
                .padding(.vertical, 1)
        )
        .padding(.trailing, 8)
        .help("\(commit.subject)\n\(commit.shortHash) · \(commit.author) · \(RepositoryText.fullDate(commit.date))")
    }
}
