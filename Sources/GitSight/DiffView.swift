import AppKit
import GitSightCore
import SwiftUI

/// The pane under the graph or the file list: one file's diff, opened by a click on the file.
struct DiffPane: View {
    let file: CommitFileSnapshot
    /// Nil while it loads.
    let diff: FileDiff?
    let error: String?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        let path = file.path as NSString
        return HStack(spacing: 6) {
            Text(path.lastPathComponent)
                .fontWeight(.semibold)
                .lineLimit(1)
                .layoutPriority(1)
            Text(path.deletingLastPathComponent)
                .textRole(.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let diff, !diff.isBinary {
                // What changed at a glance; a side with nothing is left out.
                let added = diff.lines.count { $0.kind == .added }
                let removed = diff.lines.count { $0.kind == .removed }
                if added > 0 { Text("+\(added)").foregroundStyle(.green) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
            }
            Spacer(minLength: 8)
            Button(action: close) {
                Image(systemName: "xmark").accessibilityLabel("Close diff")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .textRole(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .help(file.path)
    }

    @ViewBuilder
    private var content: some View {
        if let error {
            ContentUnavailableView("Couldn't read the diff", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let diff {
            if diff.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc", description: Text("There are no lines to compare."))
            } else if diff.lines.isEmpty {
                ContentUnavailableView("The text is the same", systemImage: "doc", description: Text("Only the file's permissions or mode changed."))
            } else {
                DiffLines(diff: diff)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Unified diff lines with both sides' line numbers, scrolling both ways.
private struct DiffLines: View {
    let diff: FileDiff
    @AppStorage(TextRole.sizeKey) private var textSize = TextRole.standardSize

    var body: some View {
        let digits = String(diff.lines.compactMap { max($0.oldLine ?? 0, $0.newLine ?? 0) }.max() ?? 0).count
        // Monospaced digits are about 0.6 of the font size wide.
        let numberWidth = CGFloat(max(digits, 2)) * TextRole.secondary.size(base: textSize) * 0.62 + 12
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                        row(line, numberWidth: numberWidth)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                            .background(background(line.kind))
                    }
                    if diff.isTruncated {
                        Text("Showing the first \(RepositoryInspector.diffLineLimit) lines")
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .textRole(.secondary)
                .monospaced()
                // A short diff starts at the top left instead of floating in the middle.
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
    }

    private func row(_ line: DiffLine, numberWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            number(line.oldLine, width: numberWidth)
            number(line.newLine, width: numberWidth)
            Text(marker(line.kind))
                .foregroundStyle(.secondary)
                .frame(width: numberWidth / 2)
            // Tabs as four spaces, so indentation lines up however the font measures a tab.
            Text(line.text.replacingOccurrences(of: "\t", with: "    "))
                .foregroundStyle(line.kind == .hunk ? Color.secondary : Color.primary)
                .fixedSize()
                .padding(.trailing, 16)
        }
        .padding(.vertical, 1)
        .textSelection(.enabled)
    }

    private func number(_ value: Int?, width: CGFloat) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
    }

    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "−"
        case .hunk, .context: return ""
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.16)
        case .removed: return Color.red.opacity(0.16)
        case .hunk: return Color.secondary.opacity(0.1)
        case .context: return .clear
        }
    }
}

/// A line between the content and the diff that drags to share the height between them.
struct PaneDivider: View {
    @Binding var fraction: Double
    let height: CGFloat

    var body: some View {
        Divider()
            .overlay {
                // A wider grip than the line itself, as macOS split views have.
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(coordinateSpace: .named(PaneDivider.space)).onChanged { value in
                        guard height > 0 else { return }
                        fraction = min(0.85, max(0.2, 1 - value.location.y / height))
                    })
            }
    }

    static let space = "detail"
}
