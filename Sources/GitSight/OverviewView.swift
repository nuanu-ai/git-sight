import GitSightCore
import SwiftUI

/// Every repository with work left, one row each: how heavy it is, what kind of work, and how long it has sat.
/// A bubble's size is how much there is, its color the verdict on the oldest piece.
struct OverviewView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        // The order moves on with every rescan; the ages on the rows count on every minute.
        GeometryReader { geometry in
            ScrollView {
                content(now: Date(), columns: OverviewColumns(width: geometry.size.width))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
            }
        }
    }

    @ViewBuilder
    private func content(now: Date, columns: OverviewColumns) -> some View {
        let all = model.filteredRepositories
        let rows = all.filter { $0.weight(now: now) > 0 }.sorted { left, right in
            let a = model.overviewSort.key(left, now: now), b = model.overviewSort.key(right, now: now)
            return a != b ? a > b : left.weight(now: now) > right.weight(now: now)
        }
        let clean = all.filter { $0.weight(now: now) == 0 }
        if rows.isEmpty, model.filter.isEmpty {
            ContentUnavailableView("Nothing left behind", systemImage: "checkmark.circle",
                                   description: Text("Every repository is committed, pushed and merged."))
                .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            let maxWeight = max(1, rows.map { $0.weight(now: now) }.max() ?? 1)
            let maxValue = Dictionary(uniqueKeysWithValues: WorkColumn.allCases.map { column in
                (column, max(1, model.repositories.map { $0.column(column).value }.max() ?? 1))
            })
            VStack(alignment: .leading, spacing: 0) {
                OverviewHeader(model: model, columns: columns)
                OverviewTotals(repositories: all, columns: columns, now: now)
                ForEach(rows, id: \.path) { repository in
                    OverviewRow(model: model, repository: repository, columns: columns, now: now, maxWeight: maxWeight, maxValue: maxValue) { column in
                        model.open(repository, column: column)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VerdictLegend()
                    Spacer(minLength: 0)
                    CleanButton(model: model, repositories: clean)
                }
                .padding(.top, 16)
            }
            .frame(width: columns.total, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum OverviewSort: Hashable {
    case weight, idle
    case column(WorkColumn)

    func key(_ repository: RepositorySnapshot, now: Date) -> Double {
        switch self {
        case .weight:
            return repository.weight(now: now)
        case .idle:
            // Worst verdict first, then the longest idle within it.
            guard let lead = repository.lead(now: now) else { return -1 }
            return Double(lead.verdict(now: now).rawValue) * 1e9 + now.timeIntervalSince(lead.date)
        case .column(let column):
            return Double(repository.column(column).value)
        }
    }
}

/// Column widths as shares of the width, as a table with fixed layout would give them.
/// Under 1180 pt the header icons go, so "Uncommitted" fits; under 860 pt the bars go too.
struct OverviewColumns {
    let name: CGFloat
    let weight: CGFloat
    let kind: CGFloat
    let idle: CGFloat
    let compact: Bool
    let showsIcons: Bool

    init(width: CGFloat) {
        let total = max(0, width - 32)
        compact = width < 860
        showsIcons = width >= 1180
        name = total * (compact ? 0.18 : 0.17)
        kind = total * (compact ? 0.116 : 0.12)
        // "11 months" fits whatever the width; the weight's bar gives up the room.
        idle = max(total * (compact ? 0.12 : 0.08), 96)
        weight = total * (compact ? 0.24 : 0.23) - idle
    }

    var total: CGFloat { name + weight + kind * CGFloat(WorkColumn.allCases.count) + idle }
}

private struct OverviewHeader: View {
    @Bindable var model: WorkspaceModel
    let columns: OverviewColumns

    var body: some View {
        HStack(spacing: 0) {
            Text("Repository")
                .padding(.horizontal, 8)
                .frame(width: columns.name, alignment: .leading)
            HStack(spacing: 2) {
                label(.weight) { Text("Weight") }
                WeightInfoButton(model: model)
            }
            .padding(.horizontal, 8)
            .frame(width: columns.weight, alignment: .leading)
            ForEach(WorkColumn.allCases) { column in
                label(.column(column)) {
                    HStack(spacing: 0) {
                        if columns.showsIcons {
                            Image(systemName: column.systemImage)
                                .imageScale(.small)
                                .frame(width: 24)
                        }
                        Text(column.title)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: columns.kind, alignment: .leading)
            }
            label(.idle) { Text("Idle") }
                .padding(.horizontal, 8)
                .frame(width: columns.idle, alignment: .leading)
        }
        .textRole(.label)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(height: 30, alignment: .bottom)
        .padding(.bottom, 2)
    }

    private func label(_ key: OverviewSort, @ViewBuilder _ title: () -> some View) -> some View {
        let sort = model.overviewSort
        return Button {
            model.overviewSort = key
        } label: {
            HStack(spacing: 4) {
                title()
                // Always there, so the label keeps its width; it shows only on the sorted column.
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .opacity(sort == key ? 1 : 0)
            }
            .foregroundStyle(sort == key ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(sort == key ? .isSelected : [])
    }
}

private struct OverviewTotals: View {
    let repositories: [RepositorySnapshot]
    let columns: OverviewColumns
    let now: Date

    var body: some View {
        let withWork = repositories.count { $0.weight(now: now) > 0 }
        HStack(spacing: 0) {
            Text("\(withWork) of \(RepositoryText.counted(repositories.count, "repository", "repositories"))")
                .textRole(.secondary)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(width: columns.name, alignment: .leading)
            Text(RepositoryText.weight(repositories.reduce(0) { $0 + $1.weight(now: now) }))
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .frame(width: columns.weight, alignment: .leading)
            ForEach(WorkColumn.allCases) { column in
                let value = repositories.reduce(0) { $0 + $1.column(column).value }
                HStack(spacing: 4) {
                    // The total starts where the title does: past the icon when there is one, else at the column edge.
                    if columns.showsIcons { Color.clear.frame(width: 20, height: 1) }
                    if value > 0 {
                        Text(value.formatted()).fontWeight(.semibold)
                        Text(value == 1 ? column.unit.one : column.unit.many)
                            .textRole(.label)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: columns.kind, alignment: .leading)
            }
            Color.clear.frame(width: columns.idle, height: 1)
        }
        .lineLimit(1)
        .monospacedDigit()
        .frame(height: 34)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
    }
}

private struct OverviewRow: View {
    let model: WorkspaceModel
    let repository: RepositorySnapshot
    let columns: OverviewColumns
    let now: Date
    let maxWeight: Double
    let maxValue: [WorkColumn: Int]
    let open: (WorkColumn?) -> Void

    var body: some View {
        let weight = repository.weight(now: now)
        let lead = repository.lead(now: now)
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(repository.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let change = repository.liveChange(now: now) {
                    LiveDot(date: change.date)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: columns.name, alignment: .leading)
            HStack(spacing: 8) {
                if !columns.compact {
                    GeometryReader { track in
                        Capsule(style: .circular)
                            .fill(.quaternary)
                            .overlay(alignment: .leading) {
                                Capsule(style: .circular)
                                    .fill(Color.secondary.opacity(0.55))
                                    .frame(width: track.size.width * weight / maxWeight)
                            }
                    }
                    .frame(height: 6)
                }
                Text(RepositoryText.weight(weight))
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(width: columns.weight, alignment: .leading)
            ForEach(WorkColumn.allCases) { column in
                cell(column)
                    .padding(.horizontal, 8)
                    .frame(width: columns.kind, alignment: .leading)
            }
            // The age counts on between rescans, and its color with it.
            TimelineView(.everyMinute) { _ in
                let now = Date()
                Text(RepositoryText.age(lead?.date, now: now))
                    .monospacedDigit()
                    .fontWeight(lead?.verdict(now: now) == .forgotten ? .semibold : .regular)
                    .foregroundStyle(lead.map { $0.verdict(now: now).textColor } ?? .secondary)
                    .help(lead?.verdict(now: now).title ?? "")
            }
            .padding(.horizontal, 8)
                .frame(width: columns.idle, alignment: .leading)
        }
        .lineLimit(1)
        .frame(height: 44)
        .background(model.hoveredID == hoverID ? Color.primary.opacity(0.05) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator.opacity(0.6)).frame(height: 1) }
        .contentShape(Rectangle())
        .hoverID(hoverID, in: model)
        .onTapGesture { open(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(repository.name)
    }

    private var hoverID: String { "overview:\(repository.path.path)" }

    @ViewBuilder
    private func cell(_ column: WorkColumn) -> some View {
        let (value, lead) = repository.column(column)
        if value > 0, let lead {
            let verdict = lead.verdict(now: now)
            let largest = Double(maxValue[column] ?? 1)
            Button {
                open(column)
            } label: {
                HStack(spacing: 4) {
                    Bubble(verdict: verdict, diameter: 7 + 15 * log1p(Double(value)) / log1p(largest))
                        .frame(width: 24, height: 24)
                    Text(value.formatted())
                        .monospacedDigit()
                        .fontWeight(verdict == .forgotten ? .semibold : .regular)
                        .foregroundStyle(verdict.textColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(column.describe(value, base: repository.base)), idle for \(RepositoryText.age(lead.date, now: now)). \(verdict.title).")
        } else {
            Color.clear.frame(height: 1)
        }
    }
}

private struct Bubble: View {
    let verdict: Verdict
    let diameter: CGFloat

    var body: some View {
        Group {
            if verdict == .clutter {
                Circle().strokeBorder(Color.gray.opacity(0.55), lineWidth: 1.5)
            } else {
                Circle().fill(verdict == .inProgress ? Color.gray.opacity(0.7) : verdict.color)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Clean repositories behind one button, so they don't take a line each or a wall of links under the table.
private struct CleanButton: View {
    @Bindable var model: WorkspaceModel
    let repositories: [RepositorySnapshot]

    var body: some View {
        if !repositories.isEmpty {
            Button {
                model.showsCleanList.toggle()
            } label: {
                Label("\(repositories.count) clean", systemImage: "checkmark")
            }
            .buttonStyle(.borderless)
            .textRole(.secondary)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("Repositories with nothing left behind")
            .popover(isPresented: $model.showsCleanList, arrowEdge: .bottom) {
                if repositories.count > 14 {
                    ScrollView { list }
                        .frame(height: 420)
                } else {
                    list
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(repositories.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.path) { repository in
                Button {
                    model.showsCleanList = false
                    model.open(repository)
                } label: {
                    Text(repository.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(model.hoveredID == "clean:\(repository.path.path)" ? Color.accentColor.opacity(0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverID("clean:\(repository.path.path)", in: model)
                .help(RepositoryText.path(repository.path))
            }
        }
        .padding(8)
        .frame(width: 260, alignment: .leading)
    }
}

private struct VerdictLegend: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach([Verdict.inProgress, .abandoned, .forgotten, .clutter], id: \.self) { verdict in
                HStack(spacing: 4) {
                    VerdictDot(verdict: verdict)
                    Text(verdict.title)
                }
            }
        }
        .textRole(.secondary)
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

/// What the weight is made of, behind the info button.
struct WeightInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How weight works")
                .fontWeight(.semibold)
            Text("How much work could be lost, and how long it has been sitting. The heavier a repository, the higher it sits in the list.")
                .foregroundStyle(.secondary)
            Text("size × age × risk")
                .fontWeight(.semibold)
                .padding(.vertical, 4)
            Text("Size is the number of files for uncommitted work and the number of commits for the rest. A stash or a merged branch counts as one.")
                .foregroundStyle(.secondary)
            scale("Age", WeightScale.ages)
            scale("Risk", WeightScale.risks)
        }
        .textRole(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 340, alignment: .leading)
        .padding(16)
    }

    private func scale(_ title: String, _ steps: [(String, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .textRole(.label)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                ForEach(steps, id: \.0) { step in
                    GridRow {
                        Text(step.0)
                        Text("×\(step.1.formatted(.number.precision(.fractionLength(1))))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }
}

extension Verdict {
    /// Numbers and ages in a verdict's color, readable on the window's background.
    var textColor: Color {
        switch self {
        case .inProgress: return .primary
        case .clutter: return .secondary
        case .abandoned: return .orange
        case .forgotten: return .red
        }
    }
}

/// The weight's recipe in a popover, next to the weight.
struct WeightInfoButton: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Button {
            model.showsWeightInfo.toggle()
        } label: {
            // An image inside Text sits on the text's baseline, next to the words around it.
            Text(Image(systemName: "info.circle"))
        }
        .buttonStyle(.borderless)
        .help("How weight works")
        .accessibilityLabel("How weight works")
        .popover(isPresented: $model.showsWeightInfo, arrowEdge: .bottom) { WeightInfo() }
    }
}

extension View {
    /// Marks this view as the one under the pointer while it is there.
    func hoverID(_ id: String, in model: WorkspaceModel) -> some View {
        onHover { inside in
            if inside {
                model.hoveredID = id
            } else if model.hoveredID == id {
                model.hoveredID = nil
            }
        }
    }
}
