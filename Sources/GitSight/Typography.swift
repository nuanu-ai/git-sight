import SwiftUI

/// The window's type sizes, all from one base size the user sets with ⌘+ and ⌘−, as in VS Code.
/// Nothing is smaller than 12 pt at the standard size.
enum TextRole {
    /// Names, commit subjects, file names.
    case primary
    /// The line under a name, folders, the facts under a title.
    case secondary
    /// Branch labels, counts, status letters.
    case label
    /// The title over the detail.
    case title

    static let sizeKey = "textSize"
    static let standardSize: Double = 15
    static let sizes: ClosedRange<Double> = 12...24

    func size(base: Double) -> CGFloat {
        switch self {
        case .primary: return base
        case .secondary: return base - 1
        case .label: return base - 3
        case .title: return base + 5
        }
    }
}

private struct RoleFont: ViewModifier {
    @AppStorage(TextRole.sizeKey) private var base = TextRole.standardSize
    let role: TextRole

    func body(content: Content) -> some View {
        content.font(.system(size: role.size(base: base)))
    }
}

extension View {
    func textRole(_ role: TextRole) -> some View {
        modifier(RoleFont(role: role))
    }
}

/// View ▸ Крупнее / Мельче / Обычный размер.
struct TextSizeCommands: Commands {
    @AppStorage(TextRole.sizeKey) private var base = TextRole.standardSize

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Крупнее") { base = min(base + 1, TextRole.sizes.upperBound) }
                .keyboardShortcut("+")
                .disabled(base >= TextRole.sizes.upperBound)
            Button("Мельче") { base = max(base - 1, TextRole.sizes.lowerBound) }
                .keyboardShortcut("-")
                .disabled(base <= TextRole.sizes.lowerBound)
            Button("Обычный размер") { base = TextRole.standardSize }
                .keyboardShortcut("0")
                .disabled(base == TextRole.standardSize)
            Divider()
        }
    }
}
