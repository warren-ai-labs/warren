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
    @Environment(\.warrenWindowMaterial) private var windowMaterial

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
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        WarrenDialog(
            "Import Existing Worktrees",
            message: "Choose worktrees to register under \(projectName). This does not create or delete files.",
            width: .m
        ) {
            Group {
            if isLoading {
                HStack(spacing: WarrenSpacing.compact) {
                    WarrenLoadingIndicator(size: 18, accessibilityLabel: "Loading worktrees")
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
            }
            }
        } footer: {
            WarrenDialogFooter(
                confirmLabel: selectedPaths.isEmpty ? "Import" : "Import \(selectedPaths.count)",
                isConfirmEnabled: !isLoading && !selectedPaths.isEmpty,
                onCancel: onCancel,
                onConfirm: { onImport(Array(selectedPaths)) }
            )
        }
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder
    private func candidateRow(
        _ candidate: WarrenDesktopWorktreeCandidate,
        tokens: WarrenColorTokens
    ) -> some View {
        let isDisabled = candidate.imported
        let isSelected = selectedPaths.contains(candidate.path)
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        Button {
            guard !isDisabled else { return }
            if isSelected {
                selectedPaths.remove(candidate.path)
            } else {
                selectedPaths.insert(candidate.path)
            }
        } label: {
            HStack(spacing: WarrenDesktopMenuMetrics.iconSpacing) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? palette.check : palette.icon)
                    .frame(width: WarrenDesktopMenuMetrics.glyphSlot, height: WarrenDesktopMenuMetrics.glyphSlot)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: WarrenSpacing.xs) {
                        Text(candidate.name)
                            .font(WarrenTypography.dialogBody)
                            .foregroundStyle(palette.rowText)
                        if candidate.locked {
                            Label("Locked", systemImage: "lock.fill")
                                .font(WarrenTypography.dialogMeta)
                                .foregroundStyle(palette.meta)
                        }
                        if candidate.imported {
                            Text("Imported")
                                .font(WarrenTypography.dialogMeta)
                                .foregroundStyle(palette.meta)
                        }
                    }
                    Text(candidate.path)
                        .font(WarrenTypography.monoSmall)
                        .foregroundStyle(palette.meta)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenDesktopMenuMetrics.rowHorizontalPadding)
            .frame(
                maxWidth: .infinity,
                minHeight: WarrenDesktopMenuMetrics.twoLineRowHeight,
                alignment: .leading
            )
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
    }
}
