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
    /// A confirmation carries no body, and the body's top padding on an empty
    /// body is a void between the sentence and its buttons. The initializer
    /// that takes no content closes it.
    private var contentTopPadding: CGFloat

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
        self.contentTopPadding = 16
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
                                .font(WarrenTypography.dialogTitle)
                                .foregroundStyle(tokens.foreground)
                            Spacer(minLength: 0)
                            #if os(macOS)
                            // A key, drawn as a key: at body size and weight
                            // the old "Esc" read as a word in the title line
                            // rather than as the one way out of the dialog.
                            WarrenKeycap("esc")
                            #endif
                        }
                        if let message, !message.isEmpty {
                            // The dialog's one paragraph. Body size with a
                            // little air between the lines: at 12pt on the
                            // default leading a two-line sentence read as one
                            // dense block under the title.
                            Text(message)
                                .font(WarrenTypography.body)
                                .foregroundStyle(tokens.mutedForeground)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        }
                        content
                            .padding(.top, contentTopPadding)
                        footer
                            .padding(.top, 16)
                    }
                    // 20 on the window grid: the dialog's own margin is a
                    // spacing step, not a number of its own.
                    .padding(20)
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

extension WarrenDialog where Content == EmptyView {
    /// A confirmation: a title, a sentence, and the buttons that answer it.
    ///
    /// It exists so the body can be absent rather than empty. Stated the other
    /// way, every confirmation paid the body's top inset for a view that drew
    /// nothing, which left a gap between the sentence and its buttons that read
    /// as a missing paragraph.
    public init(
        _ title: String,
        message: String? = nil,
        width: WarrenDialogWidth = .s,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(title, message: message, width: width, content: {}, footer: footer)
        self.contentTopPadding = 0
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

    /// The same key, spelled for a tooltip. The footer used to draw this string
    /// beside the buttons; a tooltip says it once, on the control that answers
    /// to it, and costs the row no width.
    public var helpText: String {
        switch self {
        case .return: "Return"
        case .commandReturn: "Command-Return"
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
        HStack(spacing: WarrenSpacing.compact) {
            // The confirm key used to be spelled out here, in a second label
            // that repeated the button's own words at the quietest tier. It
            // read as clutter and it squeezed long labels into two lines, so
            // the hint moved to the button's tooltip and the row is the leading
            // control again.
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
            #if os(macOS)
            .warrenTooltip("Esc")
            #else
            .help("Esc")
            #endif
            Button(action: onConfirm) {
                Text(confirmLabel)
            }
            .modifier(WarrenDialogConfirmButtonStyle(
                isDestructive: isDestructive,
                isEnabled: isConfirmEnabled,
                confirmKey: confirmKey
            ))
            #if os(macOS)
            .warrenTooltip(confirmKey.helpText)
            #else
            .help(confirmKey.helpText)
            #endif
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
