import SwiftUI
import WarrenDesignSystem

/// The one confirmation dialog: a question for a title, what will happen as
/// its message, optional content between them and the buttons, and a red
/// validation line when the Host refused.
///
/// Deleting a Task, a Workspace, a project or a Host and resetting usage all
/// ask through this, so every confirmation has one shape, one set of keys and
/// one place to change it. A text field asks through `WarrenTextInputDialog`.
struct WarrenDesktopConfirmationDialog<Content: View>: View {
    let title: String
    let message: String
    var confirmLabel = "Delete"
    var isDestructive = true
    var isConfirmEnabled = true
    var validationMessage: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(title, message: message) {
            VStack(alignment: .leading, spacing: 14) {
                content()
                if let validationMessage {
                    Text(validationMessage)
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } footer: {
            WarrenDesktopDialogFooter(
                confirmLabel: confirmLabel,
                isDestructive: isDestructive,
                isConfirmEnabled: isConfirmEnabled,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        }
        .onExitCommand(perform: onCancel)
    }
}

extension WarrenDesktopConfirmationDialog where Content == EmptyView {
    init(
        title: String,
        message: String,
        confirmLabel: String = "Delete",
        isDestructive: Bool = true,
        isConfirmEnabled: Bool = true,
        validationMessage: String? = nil,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.init(
            title: title,
            message: message,
            confirmLabel: confirmLabel,
            isDestructive: isDestructive,
            isConfirmEnabled: isConfirmEnabled,
            validationMessage: validationMessage,
            onCancel: onCancel,
            onConfirm: onConfirm,
            content: { EmptyView() }
        )
    }
}
