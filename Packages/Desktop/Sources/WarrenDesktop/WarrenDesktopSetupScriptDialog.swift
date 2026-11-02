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
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 220)
                .background(
                    tokens.background,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isEditorFocused ? tokens.foreground.opacity(0.54) : tokens.cardBorder,
                            lineWidth: 1
                        )
                }
                .focused($isEditorFocused)
                .accessibilityIdentifier("project.setup-script.path")
                .onAppear { isEditorFocused = true }
        } footer: {
            // A text editor keeps plain Return, so this confirm answers
            // Command-Return and the footer says so.
            WarrenDialogFooter(
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
                Text("Tab switches fields")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.ink4)
            }
        }
        .onExitCommand(perform: onCancel)
    }
}
