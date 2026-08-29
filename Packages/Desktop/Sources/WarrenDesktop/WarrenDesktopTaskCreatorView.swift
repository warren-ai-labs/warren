import Foundation
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

public struct WarrenDesktopTaskCreationRequest: Hashable, Sendable {
    public let requestID: UUID
    public let name: String
    public let source: String?
    public let externalID: String?
    public let url: String?

    public init(
        requestID: UUID = UUID(),
        name: String,
        source: String? = nil,
        externalID: String? = nil,
        url: String? = nil
    ) {
        self.requestID = requestID
        self.name = name
        self.source = source
        self.externalID = externalID
        self.url = url
    }
}

@MainActor
final class WarrenDesktopTaskCreationCoordinator: ObservableObject {
    private(set) var requestID: UUID
    @Published var name: String { didSet { clearServerError() } }
    @Published var source: String { didSet { clearServerError() } }
    @Published var externalID: String { didSet { clearServerError() } }
    @Published var url: String { didSet { clearServerError() } }
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?

    private let onCreate: @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID
    private let onCreated: @MainActor (TaskID) -> Void
    private var lastSubmittedDraft: WarrenDesktopTaskCreationDraft?

    init(
        requestID: UUID = UUID(),
        name: String = "",
        source: String = "",
        externalID: String = "",
        url: String = "",
        onCreate: @escaping @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID,
        onCreated: @escaping @MainActor (TaskID) -> Void
    ) {
        self.requestID = requestID
        self.name = name
        self.source = source
        self.externalID = externalID
        self.url = url
        self.onCreate = onCreate
        self.onCreated = onCreated
    }

    var validationMessage: String? {
        if (normalizedSource == nil) != (normalizedExternalID == nil) {
            return "Source and external ID must be provided together."
        }
        guard let normalizedURL else { return nil }
        guard let components = URLComponents(string: normalizedURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false else {
            return "URL must be an absolute HTTP(S) URL."
        }
        return nil
    }

    var canSubmit: Bool {
        !isSubmitting && !normalizedName.isEmpty && validationMessage == nil
    }

    func submit() async {
        guard canSubmit else { return }
        errorMessage = nil
        isSubmitting = true
        let draft = WarrenDesktopTaskCreationDraft(
            name: normalizedName,
            source: normalizedSource,
            externalID: normalizedExternalID,
            url: normalizedURL
        )
        if let lastSubmittedDraft, lastSubmittedDraft != draft {
            requestID = UUID()
        }
        lastSubmittedDraft = draft
        let request = WarrenDesktopTaskCreationRequest(
            requestID: requestID,
            name: draft.name,
            source: draft.source,
            externalID: draft.externalID,
            url: draft.url
        )

        do {
            let taskID = try await onCreate(request)
            isSubmitting = false
            errorMessage = nil
            onCreated(taskID)
        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
        }
    }

    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<WarrenDesktopTaskCreationCoordinator, Value>) -> Binding<Value> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedSource: String? {
        normalizedOptional(source)?.lowercased()
    }

    private var normalizedExternalID: String? {
        normalizedOptional(externalID)
    }

    private var normalizedURL: String? {
        guard let value = normalizedOptional(url),
              let separator = value.firstIndex(of: ":") else {
            return normalizedOptional(url)
        }
        return value[..<separator].lowercased() + value[separator...]
    }

    private func clearServerError() {
        errorMessage = nil
    }

    private func normalizedOptional(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct WarrenDesktopTaskCreationDraft: Equatable {
    let name: String
    let source: String?
    let externalID: String?
    let url: String?
}

enum WarrenDesktopTaskCreationPresentation {
    static func complete(
        taskID: TaskID,
        tree: inout WarrenDesktopSidebarTreeState,
        onDismiss: () -> Void
    ) {
        tree.tasksCollapsed = false
        tree.expandedTaskIDs.insert(taskID)
        onDismiss()
    }
}

struct WarrenDesktopTaskCreatorView: View {
    let onCancel: () -> Void

    @StateObject private var coordinator: WarrenDesktopTaskCreationCoordinator
    @Environment(\.colorScheme) private var colorScheme

    init(
        onCancel: @escaping () -> Void,
        onCreate: @escaping @MainActor (WarrenDesktopTaskCreationRequest) async throws -> TaskID,
        onCreated: @escaping @MainActor (TaskID) -> Void
    ) {
        self.onCancel = onCancel
        _coordinator = StateObject(wrappedValue: WarrenDesktopTaskCreationCoordinator(
            onCreate: onCreate,
            onCreated: onCreated
        ))
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text("New Task")
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)
            Text("Create a task to organize workspaces across projects.")
                .font(WarrenTypography.dialogBody)
                .foregroundStyle(tokens.mutedForeground)

            WarrenInputField(
                "Name",
                text: coordinator.binding(\.name),
                placeholder: "Delivery",
                monospaced: false,
                focusOnAppear: true,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .disabled(coordinator.isSubmitting)
            WarrenInputField(
                "Source (optional)",
                text: coordinator.binding(\.source),
                placeholder: "tapd",
                monospaced: false,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .disabled(coordinator.isSubmitting)
            WarrenInputField(
                "External ID (optional)",
                text: coordinator.binding(\.externalID),
                placeholder: "123",
                monospaced: false,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .disabled(coordinator.isSubmitting)
            WarrenInputField(
                "URL (optional)",
                text: coordinator.binding(\.url),
                placeholder: "https://tracker.example/tasks/123",
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )
            .disabled(coordinator.isSubmitting)

            if let message = coordinator.validationMessage ?? coordinator.errorMessage {
                Text(message)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.destructive)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Task creation error: \(message)")
            }

            HStack {
                if coordinator.isSubmitting {
                    WarrenBrailleSpinner(size: 16, accessibilityLabel: "Creating task")
                    Text("Creating task…")
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
