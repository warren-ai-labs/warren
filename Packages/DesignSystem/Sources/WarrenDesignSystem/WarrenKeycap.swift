import SwiftUI

/// A key, drawn as a key.
///
/// The app spelled its shortcuts as text: a dialog's title row ended in a grey
/// "Esc", a menu row trailed "⌘T". At the same size and weight as body text a
/// key reads as another word in the sentence, which is why the escape hatch in
/// a dialog looked like a label nobody could click.
///
/// A keycap is a chip instead: one hairline around a monospaced glyph, sized by
/// its own content, and quiet enough to sit beside a title without competing
/// with it. It is for the places that name one key to explain a surface: a
/// dialog's title row, a hint bar under a palette. A menu row keeps plain
/// right-aligned text, because a column of chips beside a column of labels
/// would read as loudly as the commands themselves.
public struct WarrenKeycap: View {
    private let keys: String
    private let size: Size

    public enum Size: Sendable {
        /// In a title row or beside a menu entry.
        case small
        /// Inside a footer's hint bar.
        case regular

        var height: CGFloat {
            switch self {
            case .small: 16
            case .regular: 18
            }
        }

        var font: CGFloat {
            switch self {
            case .small: 10
            case .regular: 11
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: 5
            case .regular: 6
            }
        }
    }

    public init(_ keys: String, size: Size = .small) {
        self.keys = keys
        self.size = size
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Text(keys)
            .font(.system(size: size.font, weight: .medium, design: .monospaced))
            .foregroundStyle(tokens.ink4)
            .lineLimit(1)
            .padding(.horizontal, size.horizontalPadding)
            .frame(height: size.height)
            .background(tokens.fillHover, in: RoundedRectangle(cornerRadius: WarrenRadius.xs, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.xs, style: .continuous)
                    .strokeBorder(tokens.cardBorder, lineWidth: WarrenSpacing.hairline)
            }
            .accessibilityHidden(true)
    }
}
