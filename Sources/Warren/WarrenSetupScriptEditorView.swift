import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenSetupScriptEditorView: View {
    let project: Project
    @Binding var value: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenModalSurface {
            VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                Text("Configure setup script")
                    .font(WarrenTypography.dialogTitle)
                    .foregroundStyle(tokens.foreground)
                Text("Configure an executable for \(project.name). Relative paths are resolved from the main repository and run in each new worktree.")
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                WarrenInputField(
                    "Setup script",
                    text: $value,
                    placeholder: "scripts/setup.script",
                    monospaced: true,
                    focusOnAppear: true,
                    labelFont: WarrenTypography.dialogFieldLabel,
                    inputFont: WarrenTypography.dialogInput
                )
                .accessibilityIdentifier("project.setup-script.path")
                HStack(spacing: WarrenSpacing.compact) {
                    Button("Clear", action: clear)
                        .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("project.setup-script.clear")
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                        .keyboardShortcut(.cancelAction)
                    Button("Save", action: onSave)
                        .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(WarrenSpacing.large)
            .frame(width: WarrenLayoutMetrics.standardDialogWidth)
        }
        .onExitCommand(perform: onCancel)
    }

    private func clear() {
        value = ""
        onSave()
    }
}
