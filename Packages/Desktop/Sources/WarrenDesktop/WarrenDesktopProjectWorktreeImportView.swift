import SwiftUI
import WarrenDesignSystem

/// One-time selector for existing Git worktrees belonging to a Project.
/// Imported rows stay visible and disabled so the operation is explainable
/// instead of silently disappearing after the first import.
public struct WarrenDesktopProjectWorktreeImportView: View {
    public let projectName: String
    public let candidates: [WarrenDesktopWorktreeCandidate]
    public let isLoading: Bool
    public let onCancel: () -> Void
    public let onImport: ([String]) -> Void

    @State private var selectedPaths: Set<String> = []
    @Environment(\.colorScheme) private var colorScheme

    public init(
        projectName: String,
        candidates: [WarrenDesktopWorktreeCandidate],
        isLoading: Bool = false,
        onCancel: @escaping () -> Void,
        onImport: @escaping ([String]) -> Void
    ) {
        self.projectName = projectName
        self.candidates = candidates
        self.isLoading = isLoading
        self.onCancel = onCancel
        self.onImport = onImport
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Text("Import Existing Worktrees")
                    .font(WarrenTypography.dialogTitle)
                    .foregroundStyle(tokens.foreground)
                Text("Choose worktrees to register under \(projectName). This does not create or delete files.")
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLoading {
                HStack(spacing: WarrenSpacing.compact) {
                    WarrenBrailleSpinner(size: 18, accessibilityLabel: "Loading worktrees")
                    Text("Reading Git worktrees…")
                        .font(WarrenTypography.dialogBody)
                        .foregroundStyle(tokens.mutedForeground)
                }
                .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else if candidates.isEmpty {
                Text("No external Git worktrees are available to import.")
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate, tokens: tokens)
                        }
                    }
                }
                .frame(minHeight: 140, maxHeight: 320)
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.medium)
                        .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                Button("Import Selected", action: { onImport(Array(selectedPaths)) })
                    .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                    .disabled(isLoading || selectedPaths.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: 560)
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder
    private func candidateRow(
        _ candidate: WarrenDesktopWorktreeCandidate,
        tokens: WarrenColorTokens
    ) -> some View {
        let isDisabled = candidate.imported
        Button {
            guard !isDisabled else { return }
            if selectedPaths.contains(candidate.path) {
                selectedPaths.remove(candidate.path)
            } else {
                selectedPaths.insert(candidate.path)
            }
        } label: {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: selectedPaths.contains(candidate.path) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isDisabled ? tokens.mutedForeground : tokens.highlight)
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    HStack(spacing: WarrenSpacing.xs) {
                        Text(candidate.name)
                            .font(WarrenTypography.dialogBody)
                        if candidate.locked {
                            Label("Locked", systemImage: "lock.fill")
                                .font(WarrenTypography.dialogMeta)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        if candidate.imported {
                            Text("Imported")
                                .font(WarrenTypography.dialogMeta)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                    }
                    Text(candidate.path)
                        .font(WarrenTypography.dialogMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .padding(.vertical, WarrenSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? tokens.mutedForeground : tokens.foreground)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.58 : 1)
    }
}
