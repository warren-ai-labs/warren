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
                        // The title row carries the one key that leaves the
                        // dialog. It used to ride inside the Cancel button as a
                        // cap, which put a second label in a button that already
                        // says what it does; herdr keeps the hint in the title
                        // row, out of every button, and so does this.
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                            Spacer(minLength: 0)
                            #if os(macOS)
                            Text("Esc")
                                .font(.system(size: 11))
                                .foregroundStyle(tokens.ink4)
                                .accessibilityHidden(true)
                            #endif
                        }
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
                            .padding(.top, 18)
                    }
                    .padding(18)
                    // A window narrower than the dialog's width gets a narrower
                    // dialog, never one cut off at both sides.
                    .frame(maxWidth: width.points)
                    .warrenPresentationSurface(role: .modal)
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

/// The key a dialog's primary action answers to.
///
/// A primary confirm takes Return; a destructive one takes Command-Return, so a
/// stray Return cannot delete anything. The footer's hint and the button's
/// binding are both read from here, so the key a dialog shows is the key it
/// listens for.
public enum WarrenDialogConfirmKey: Sendable {
    case `return`
    case commandReturn

    public var shortcut: KeyboardShortcut {
        switch self {
        case .return: .defaultAction
        case .commandReturn: KeyboardShortcut(.return, modifiers: .command)
        }
    }

    /// The glyph the footer shows, without a box around it.
    public var hint: String {
        switch self {
        case .return: "\u{23CE}"
        case .commandReturn: "\u{2318}\u{23CE}"
        }
    }
}

/// The one dialog footer: a dim key hint on the left, an optional status beside
/// it, and Cancel / confirm on the right.
///
/// Every blocking flow ends here, so a rename, an import and a delete all put
/// their buttons in the same place at the same height. The key hint is plain
/// text rather than a cap inside the button: a button already carries its own
/// label, and a boxed key beside it made the primary read as two controls.
public struct WarrenDialogFooter<Leading: View>: View {
    private let confirmLabel: String
    private let cancelLabel: String
    private let isDestructive: Bool
    private let isConfirmEnabled: Bool
    private let isCancelEnabled: Bool
    private let confirmKey: WarrenDialogConfirmKey
    private let leading: Leading
    private let onCancel: () -> Void
    private let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public init(
        confirmLabel: String,
        cancelLabel: String = "Cancel",
        isDestructive: Bool = false,
        isConfirmEnabled: Bool = true,
        isCancelEnabled: Bool = true,
        confirmKey: WarrenDialogConfirmKey? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.isDestructive = isDestructive
        self.isConfirmEnabled = isConfirmEnabled
        self.isCancelEnabled = isCancelEnabled
        self.confirmKey = confirmKey ?? (isDestructive ? .commandReturn : .return)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.leading = leading()
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 8) {
            Text("\(confirmKey.hint) \(confirmLabel)")
                .font(WarrenTypography.dialogMeta)
                .foregroundStyle(tokens.ink4)
                .accessibilityHidden(true)
            leading
            Spacer(minLength: 12)
            Button(action: onCancel) {
                Text(cancelLabel)
            }
            .buttonStyle(WarrenSecondaryButtonStyle(
                font: WarrenTypography.dialogAction,
                height: WarrenLayoutMetrics.dialogControlHeight
            ))
            .keyboardShortcut(.cancelAction)
            .disabled(!isCancelEnabled)
            Button(action: onConfirm) {
                Text(confirmLabel)
            }
            .modifier(WarrenDialogConfirmButtonStyle(
                isDestructive: isDestructive,
                isEnabled: isConfirmEnabled,
                confirmKey: confirmKey
            ))
        }
    }
}

extension WarrenDialogFooter where Leading == EmptyView {
    public init(
        confirmLabel: String,
        cancelLabel: String = "Cancel",
        isDestructive: Bool = false,
        isConfirmEnabled: Bool = true,
        isCancelEnabled: Bool = true,
        confirmKey: WarrenDialogConfirmKey? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.init(
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel,
            isDestructive: isDestructive,
            isConfirmEnabled: isConfirmEnabled,
            isCancelEnabled: isCancelEnabled,
            confirmKey: confirmKey,
            onCancel: onCancel,
            onConfirm: onConfirm,
            leading: { EmptyView() }
        )
    }
}

/// The primary/destructive confirm button, so a caller does not have to branch
/// on the style itself. A primary confirm is the default action, so Return
/// takes it; a destructive confirm takes Command-Return, so a stray Return
/// cannot delete anything. The destructive variant keeps its inverted label
/// and its danger fill.
///
/// The footer's hint reads `WarrenDialogConfirmKey.hint`, which is derived from
/// the same choice as the shortcut, so the key a dialog shows is the key it
/// actually answers to.
public struct WarrenDialogConfirmButtonStyle: ViewModifier {
    private let isDestructive: Bool
    private let isEnabled: Bool
    private let confirmKey: WarrenDialogConfirmKey

    public init(
        isDestructive: Bool,
        isEnabled: Bool = true,
        confirmKey: WarrenDialogConfirmKey? = nil
    ) {
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.confirmKey = confirmKey ?? Self.defaultKey(isDestructive: isDestructive)
    }

    /// The key a confirm button answers to.
    public static func shortcut(isDestructive: Bool) -> KeyboardShortcut {
        defaultKey(isDestructive: isDestructive).shortcut
    }

    /// The glyph for `shortcut(isDestructive:)`.
    public static func keycap(isDestructive: Bool) -> String {
        defaultKey(isDestructive: isDestructive).hint
    }

    static func defaultKey(isDestructive: Bool) -> WarrenDialogConfirmKey {
        isDestructive ? .commandReturn : .return
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if isDestructive {
            content
                .buttonStyle(WarrenDestructiveButtonStyle(
                    font: WarrenTypography.dialogCriticalAction,
                    height: WarrenLayoutMetrics.dialogControlHeight
                ))
                .keyboardShortcut(confirmKey.shortcut)
                .disabled(!isEnabled)
        } else {
            content
                .buttonStyle(WarrenPrimaryButtonStyle(
                    font: WarrenTypography.dialogAction,
                    height: WarrenLayoutMetrics.dialogControlHeight
                ))
                .keyboardShortcut(confirmKey.shortcut)
                .disabled(!isEnabled)
        }
    }
}
