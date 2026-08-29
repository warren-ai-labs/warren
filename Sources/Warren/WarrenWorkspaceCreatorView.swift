import SwiftUI
import WarrenDomain
import WarrenDesignSystem

struct WarrenWorkspaceCreatorView: View {
    let project: Project
    let onCancel: @MainActor () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var coordinator: WarrenWorkspaceCreationCoordinator

    init(
        project: Project,
        onCancel: @escaping @MainActor () -> Void,
        onCreate: @escaping @MainActor (WorkspaceCreationRequest) async throws -> Void
    ) {
        self.project = project
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: WarrenWorkspaceCreationCoordinator(
            onCreate: onCreate,
            onDismiss: onCancel
        ))
    }

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
                text: coordinator.binding(\.displayName),
                placeholder: "feature/my-change",
                monospaced: false,
                focusOnAppear: true,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .disabled(coordinator.isSubmitting)

            WarrenInputField(
                "Branch",
                text: coordinator.binding(\.branch),
                placeholder: "main",
                monospaced: false,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .disabled(coordinator.isSubmitting)
            .onChange(of: coordinator.branch) { value in
                if coordinator.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    coordinator.displayName = value
                }
            }

            Text("Worktree files are stored under ~/.warren/worktrees.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)

            if let errorMessage = coordinator.errorMessage {
                Text(errorMessage)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Workspace creation error: \(errorMessage)")
            }

            HStack {
                if coordinator.isSubmitting {
                    WarrenBrailleSpinner(size: 16, accessibilityLabel: "Creating workspace")
                    Text("Creating workspace…")
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.mutedForeground)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                    .disabled(coordinator.isSubmitting)
                Button("Create", action: submit)
                .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.canSubmit)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: WarrenLayoutMetrics.standardDialogWidth)
        .background(tokens.popoverSurface)
        .onExitCommand {
            guard !coordinator.isSubmitting else { return }
            onCancel()
        }
    }

    private func submit() {
        Task { @MainActor in
            await coordinator.submit()
        }
    }
}

@MainActor
final class WarrenWorkspaceCreationCoordinator: ObservableObject {
    private(set) var requestID: UUID
    @Published var displayName: String { didSet { clearServerError() } }
    @Published var branch: String { didSet { clearServerError() } }
    @Published var path: String { didSet { clearServerError() } }
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?

    private let onCreate: @MainActor (WorkspaceCreationRequest) async throws -> Void
    private let onDismiss: @MainActor () -> Void
    private var lastSubmittedDraft: WarrenWorkspaceCreationDraft?

    init(
        requestID: UUID = UUID(),
        displayName: String = "",
        branch: String = "",
        path: String = "",
        onCreate: @escaping @MainActor (WorkspaceCreationRequest) async throws -> Void,
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.requestID = requestID
        self.displayName = displayName
        self.branch = branch
        self.path = path
        self.onCreate = onCreate
        self.onDismiss = onDismiss
    }

    var canSubmit: Bool {
        !isSubmitting
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() async {
        guard canSubmit else { return }
        errorMessage = nil
        isSubmitting = true
        let draft = WarrenWorkspaceCreationDraft(
            displayName: displayName,
            branch: branch,
            path: path
        )
        if let lastSubmittedDraft, lastSubmittedDraft != draft {
            requestID = UUID()
        }
        lastSubmittedDraft = draft
        let request = WorkspaceCreationRequest(
            requestID: requestID,
            displayName: draft.displayName,
            branch: draft.branch,
            path: draft.path
        )

        do {
            try await onCreate(request)
            isSubmitting = false
            errorMessage = nil
            onDismiss()
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
        }
    }

    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<WarrenWorkspaceCreationCoordinator, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    private func clearServerError() {
        errorMessage = nil
    }
}

private struct WarrenWorkspaceCreationDraft: Equatable {
    let displayName: String
    let branch: String
    let path: String
}
