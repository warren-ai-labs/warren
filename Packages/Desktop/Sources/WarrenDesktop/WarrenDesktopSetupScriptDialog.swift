import SwiftUI
import WarrenDesignSystem

/// The one editor for a project's setup script. A single-line field could not
/// hold a script, so the row shows the first line and this L dialog holds the
/// whole thing; the sidebar and Settings open the same one.
public struct WarrenDesktopSetupScriptDialog: View {
    @Binding var script: String
    /// The row that opened this dialog also offers to clear it; nil hides the
    /// button on the surfaces that do not.
    var onClear: (() -> Void)? = nil
    let onCancel: () -> Void
    let onSave: () -> Void

    public init(
        script: Binding<String>,
        onClear: (() -> Void)? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) {
        self._script = script
        self.onClear = onClear
        self.onCancel = onCancel
        self.onSave = onSave
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @FocusState private var isEditorFocused: Bool

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(
            "Edit Setup Script",
            message: "Runs on this Mac after a Workspace's worktree is created.",
            width: .l
        ) {
            TextEditor(text: $script)
                .font(WarrenTypography.mono)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(
                    tokens.inputSurface,
                    in: RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                        .strokeBorder(
                            isEditorFocused ? tokens.focusRing : tokens.cardBorder,
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .shadow(color: isEditorFocused ? tokens.focusRing.opacity(0.55) : .clear, radius: 3)
                .focused($isEditorFocused)
                .accessibilityIdentifier("project.setup-script.path")
                .onAppear { isEditorFocused = true }
        } footer: {
            // A text editor keeps plain Return, so this confirm answers
            // Command-Return and the footer says so.
            WarrenDesktopDialogFooter(
                confirmLabel: "Save",
                confirmKey: .commandReturn,
                onCancel: onCancel,
                onConfirm: onSave
            ) {
                if let onClear {
                    Button("Clear", action: onClear)
                        .buttonStyle(WarrenSecondaryButtonStyle(
                            font: WarrenTypography.dialogAction,
                            height: WarrenLayoutMetrics.dialogControlHeight
                        ))
                        .disabled(script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("project.setup-script.clear")
                }
            }
        }
        .onExitCommand(perform: onCancel)
    }
}
