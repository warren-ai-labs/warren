import SwiftUI
import WarrenDesignSystem

/// The one shape every empty content card takes: a mark in a tile, a title,
/// a line of explanation, then the way forward — buttons, or the shortcuts
/// that do the same.
///
/// The content card used to say "nothing here" five different ways: a light
/// 20pt title with no mark when no Workspace was selected, a bare spinner
/// while connecting, a floating server glyph when the Host was gone, and a
/// column of plain-text shortcuts when a Workspace had no Session. One stage
/// keeps the mark, the type and the spacing the same, so each state differs
/// only in what it says.
public struct WarrenDesktopEmptyStage<Actions: View>: View {
    public enum Mark {
        case symbol(String)
        /// A Host on its way: the tile holds the spinner instead of a glyph.
        case progress
        /// A problem: the glyph takes the warning tone.
        case warning(String)
    }

    public struct Hint: Identifiable {
        public let keys: String
        public let label: String
        public var id: String { keys }

        public init(keys: String, label: String) {
            self.keys = keys
            self.label = label
        }
    }

    let mark: Mark
    let title: String
    let message: String?
    let hints: [Hint]
    @ViewBuilder let actions: () -> Actions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public init(
        mark: Mark,
        title: String,
        message: String? = nil,
        hints: [Hint] = [],
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.mark = mark
        self.title = title
        self.message = message
        self.hints = hints
        self.actions = actions
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(spacing: 0) {
            tile(tokens: tokens)
                .padding(.bottom, 16)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tokens.foreground.opacity(0.9))
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                actions()
            }
            .padding(.top, 18)

            if !hints.isEmpty {
                hintGrid(tokens: tokens)
                    .padding(.top, 22)
            }
        }
        .padding(.horizontal, WarrenSpacing.large)
        // The card sits below the tab bar; lift the stage so its optical
        // centre lands on the window's rather than the card's.
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func tile(tokens: WarrenColorTokens) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Group {
            switch mark {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(tokens.treeSecondaryText)
            case .progress:
                WarrenBrailleSpinner(size: 18, accessibilityLabel: title)
            case .warning(let name):
                Image(systemName: name)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(tokens.warning)
            }
        }
        .frame(width: 48, height: 48)
        .background(shape.fill(tokens.treeRowHover))
        .overlay(shape.strokeBorder(tokens.cardBorder, lineWidth: 1))
        .accessibilityHidden(true)
    }

    /// Shortcuts as the menus draw them: a key cap per key, then what it does,
    /// in two aligned columns.
    private func hintGrid(tokens: WarrenColorTokens) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(hints) { hint in
                HStack(spacing: 12) {
                    WarrenDesktopMenuKeycaps(keys: hint.keys)
                        .frame(width: 64, alignment: .trailing)
                    Text(hint.label)
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(hint.keys): \(hint.label)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tokens.cardBorder, lineWidth: 1)
        )
    }
}

public extension WarrenDesktopEmptyStage where Actions == EmptyView {
    init(mark: Mark, title: String, message: String? = nil, hints: [Hint] = []) {
        self.init(mark: mark, title: title, message: message, hints: hints) { EmptyView() }
    }
}
