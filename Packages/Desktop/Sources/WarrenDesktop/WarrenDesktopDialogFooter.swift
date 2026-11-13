import SwiftUI
import WarrenDesignSystem

/// A dialog footer that also names its confirm button for the semantic probe.
///
/// The shared footer lives in the design system, which has no dependency on
/// `WarrenObservation`; the desktop is where a dialog is observed, so the node
/// is attached here rather than in every call site.
struct WarrenDesktopDialogFooter<Leading: View>: View {
    let confirmLabel: String
    var cancelLabel = "Cancel"
    var isDestructive = false
    var isConfirmEnabled = true
    var isCancelEnabled = true
    var confirmKey: WarrenDialogConfirmKey?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let leading: Leading

    var body: some View {
        WarrenDialogFooter(
            confirmLabel: confirmLabel,
            cancelLabel: cancelLabel,
            isDestructive: isDestructive,
            isConfirmEnabled: isConfirmEnabled,
            isCancelEnabled: isCancelEnabled,
            confirmKey: confirmKey,
            onCancel: onCancel,
            onConfirm: onConfirm
        ) {
            leading
        }
        .warrenSemanticElement(
            id: "dialog.confirm",
            role: .button,
            label: confirmLabel,
            isEnabled: isConfirmEnabled,
            action: onConfirm
        )
    }
}

extension WarrenDesktopDialogFooter {
    /// A footer with something ahead of its buttons: a progress line, a
    /// key hint, a secondary action.
    init(
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
        self.confirmKey = confirmKey
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self.leading = leading()
    }
}

extension WarrenDesktopDialogFooter where Leading == EmptyView {
    init(
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
            leading: EmptyView()
        )
    }
}
