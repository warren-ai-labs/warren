import SwiftUI
import WarrenDomain
import WarrenDesignSystem

struct WarrenWorkspaceCreatorView: View {
    let project: Project
    let isCreating: Bool
    let errorMessage: String?
    let onCancel: () -> Void
    let onCreate: (WorkspaceCreationRequest) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var requestID = UUID()
    @State private var displayName = ""
    @State private var branch = ""

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            Text("New workspace")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)
            Text("Create a Git worktree for \(project.name).")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)

            WarrenInputField(
                "Workspace name",
                text: $displayName,
                placeholder: "feature/my-change",
                monospaced: false,
                focusOnAppear: true,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )

            WarrenInputField(
                "Branch",
                text: $branch,
                placeholder: "main",
                monospaced: false,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .onChange(of: branch) { value in
                if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    displayName = value
                }
            }

            Text("Worktree files are stored under ~/.warren/worktrees.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Creation failed: \(errorMessage)")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCreating)
                Button {
                    onCreate(WorkspaceCreationRequest(
                        requestID: requestID,
                        displayName: displayName,
                        branch: branch,
                        path: ""
                    ))
                } label: {
                    if isCreating {
                        HStack(spacing: WarrenSpacing.xs) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Creating…")
                        }
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isCreating ||
                    branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: WarrenLayoutMetrics.standardDialogWidth)
        .background(tokens.popoverSurface)
        .onExitCommand(perform: onCancel)
    }
}
