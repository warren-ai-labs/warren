import SwiftUI

/// The three widths every dialog is cut to. Nothing else sets its own width.
public enum WarrenDialogWidth: Sendable {
    /// A confirmation or a rename: one field or one sentence.
    case s
    /// A single-page form.
    case m
    /// A dialog with an editor or a list.
    case l

    public var points: CGFloat {
        switch self {
        case .s: 400
        case .m: 480
        case .l: 720
        }
    }
}

/// The one dialog container.
///
/// Every blocking flow draws inside it, so the ground, padding, title block and
/// footer stay identical between the rename prompt, a delete confirmation and a
/// form. It sits in the middle of the window, keeping at least `windowMargin`
/// from every edge, so a short confirmation does not read as pinned high.
public struct WarrenDialog<Content: View, Footer: View>: View {
    private let width: WarrenDialogWidth
    private let title: String
    private let message: String?
    private let content: Content
    private let footer: Footer

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public init(
        _ title: String,
        message: String? = nil,
        width: WarrenDialogWidth = .s,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.message = message
        self.width = width
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenModalBackdrop {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                        if let message, !message.isEmpty {
                            Text(message)
                                .font(.system(size: 12))
                                .foregroundStyle(tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                        content
                            .padding(.top, 16)
                        footer
                            .padding(.top, 20)
                    }
                    .padding(20)
                    // A window narrower than the dialog's width gets a narrower
                    // dialog, never one cut off at both sides.
                    .frame(maxWidth: width.points)
                    .warrenPresentationSurface(role: .modal, cornerRadius: 12)
                    .padding(.horizontal, Self.windowMargin)
                    .padding(.vertical, Self.windowMargin)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

extension WarrenDialog {
    /// The least room a dialog leaves between itself and the window's edges.
    static var windowMargin: CGFloat { 16 }
}

/// The primary/destructive confirm button, so a caller does not have to branch
/// on the style itself. A primary confirm is the default action, so Return
/// takes it; a destructive confirm takes Command-Return, so a stray Return
/// cannot delete anything. The destructive variant keeps its inverted label
/// and its danger fill.
///
/// The footer's keycap reads `keycap(isDestructive:)`, which is derived from
/// the same choice as the shortcut, so the cap a dialog shows is the key it
/// actually answers to.
public struct WarrenDialogConfirmButtonStyle: ViewModifier {
    private let isDestructive: Bool
    private let isEnabled: Bool

    public init(isDestructive: Bool, isEnabled: Bool = true) {
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
    }

    /// The key a confirm button answers to.
    public static func shortcut(isDestructive: Bool) -> KeyboardShortcut {
        isDestructive ? KeyboardShortcut(.return, modifiers: .command) : .defaultAction
    }

    /// The keycap text for `shortcut(isDestructive:)`.
    public static func keycap(isDestructive: Bool) -> String {
        isDestructive ? "\u{2318}\u{23CE}" : "\u{23CE}"
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if isDestructive {
            content
                .buttonStyle(WarrenDestructiveButtonStyle(font: WarrenTypography.dialogCriticalAction))
                .keyboardShortcut(Self.shortcut(isDestructive: true))
                .disabled(!isEnabled)
        } else {
            content
                .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                .keyboardShortcut(Self.shortcut(isDestructive: false))
                .disabled(!isEnabled)
        }
    }
}

/// A keycap inside a dialog button. The primary button's cap is a black wash so
/// it reads as disabled against the inverted fill.
public struct WarrenDialogKeycap: View {
    private let text: String
    private let isOnPrimary: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public init(_ text: String, isOnPrimary: Bool = false) {
        self.text = text
        self.isOnPrimary = isOnPrimary
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(
                isOnPrimary ? tokens.background.opacity(0.72) : tokens.mutedForeground
            )
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOnPrimary ? Color.black.opacity(0.10) : tokens.foreground.opacity(0.07))
            )
    }
}
