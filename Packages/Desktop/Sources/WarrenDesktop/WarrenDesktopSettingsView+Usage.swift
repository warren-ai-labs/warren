import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

extension WarrenDesktopSettingsView {
    // MARK: - Usage

    func usageSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if usageShowsDetail {
                Button {
                    usageShowsDetail = false
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.backward").font(.system(size: 11, weight: .medium))
                        Text("Back to overview")
                    }
                }
                .buttonStyle(WarrenSettingsButtonStyle(kind: .plain))
                .padding(.leading, 6)
            }

            // The panel's cards sit on the page itself. Wrapped in a settings
            // group they were boxes inside a box of the same fill, with two
            // borders and 28pt of the column spent on the wrapper's padding.
            Group {
                if usageShowsDetail {
                    WarrenDesktopUsagePanel(
                        stats: usageStats,
                        state: usageState,
                        tokens: usageTokens,
                        range: $usageRange,
                        selectedDay: $usageSelectedDay,
                        onLoad: { days, day, force in onLoadUsage?(days, day, force) },
                        mode: .detail,
                        showsRangePicker: false
                    )
                } else {
                    WarrenDesktopUsageOverviewPanel(
                        stats: usageStats,
                        state: usageState,
                        tokens: usageTokens,
                        range: $usageRange,
                        selectedDay: $usageSelectedDay,
                        onLoad: { days, day, force in onLoadUsage?(days, day, force) },
                        onOpenDetail: { day in
                            usageSelectedDay = day
                            usageShowsDetail = true
                        },
                        showsRangePicker: false
                    )
                }
            }
            .onAppear { onLoadUsage?(usageRange.days, usageSelectedDay, false) }

            WarrenSettingsGroup("Maintenance") {
                WarrenSettingsRow(
                    "Rebuild Usage Data",
                    description: "Recounts every call from the stored transcripts. Use it after upgrading, or when totals look inflated."
                ) {
                    HStack(spacing: 10) {
                        if let summary = usageRebuildSummary {
                            WarrenSettingsStatusLine(
                                tone: .ok,
                                text: WarrenUsageFormatting.rebuildOutcome(summary)
                            )
                        } else if let usageRebuildError, !usageRebuildError.isEmpty {
                            WarrenSettingsStatusLine(tone: .failed, text: usageRebuildError, isError: true)
                        } else {
                            WarrenSettingsStatusLine(
                                tone: .ok,
                                text: WarrenUsageFormatting.rebuildAge(usageStats.lastRebuild)
                            )
                        }
                        Button(usageRebuildBusy ? "Rebuilding…" : "Rebuild…") {
                            confirmation = .rebuildUsage
                        }
                        .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                        .disabled(usageRebuildBusy || onRebuildUsage == nil)
                        .accessibilityIdentifier("settings.usage.rebuild")
                    }
                }
            }
        }
    }

    /// The page's blocking confirmations. Each is a `WarrenDialog` like every
    /// other blocking flow, so its ground, padding and buttons match the rest
    /// of the app instead of arriving as a system alert.
    /// Opens the rotate confirmation on behalf of the Remote Access block, which
    /// lives in its own file and cannot name the private dialog enum.
    func requestRotateRemoteCode() {
        confirmation = .rotateRemoteCode
    }

    @ViewBuilder
    var confirmationDialogLayer: some View {
        if let confirmation {
            confirmationLayer(for: confirmation)
        }
    }

    @ViewBuilder
    func confirmationLayer(for confirmation: SettingsConfirmation) -> some View {
        switch confirmation {
        case .rebuildUsage:
            settingsConfirmation(
                "Rebuild Usage Data?",
                message: "Warren will re-read the transcripts of every Agent that reports token "
                    + "counts and replace those Agents' Usage aggregates. An Agent whose "
                    + "transcripts cannot be found keeps its current numbers. The Agent "
                    + "journal and all other databases remain unchanged.",
                confirmLabel: "Rebuild",
                onConfirm: rebuildUsage
            )
        case .resetRelay:
            settingsConfirmation(
                "Reset Relay Enrollment?",
                message: "This Mac forgets its Relay URL and enrollment. Phones and browsers "
                    + "paired through the Relay lose access until this Mac is enrolled again.",
                confirmLabel: "Reset",
                onConfirm: resetRelay
            )
        case .rotateRemoteCode:
            settingsConfirmation(
                "Rotate the Remote Access Code?",
                message: "This Mac replaces its connect code. Every device paired through a share "
                    + "link loses access immediately and must scan a new link. LAN pairing and the "
                    + "Relay enrollment are untouched.",
                confirmLabel: "Rotate",
                onConfirm: rotateRemoteCode
            )
        case .revokeDevice(let id, let name):
            settingsConfirmation(
                "Revoke \(name)?",
                message: "This device loses access to this Host through the Relay. It can pair "
                    + "again with a new invite.",
                confirmLabel: "Revoke",
                onConfirm: { revokeRelayDevice(id) }
            )
        }
    }

    func settingsConfirmation(
        _ title: String,
        message: String,
        confirmLabel: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        WarrenDialog(title, message: message) {
            EmptyView()
        } footer: {
            WarrenDesktopDialogFooter(
                confirmLabel: confirmLabel,
                isDestructive: true,
                onCancel: { confirmation = nil },
                onConfirm: {
                    confirmation = nil
                    onConfirm()
                }
            )
        }
        .onExitCommand { confirmation = nil }
    }

    /// The usage panels still read the appearance tokens for their own cards.
    var usageTokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme)
    }

    func rebuildUsage() {
        guard !usageRebuildBusy, let onRebuildUsage else { return }
        usageRebuildBusy = true
        usageRebuildError = nil
        usageRebuildSummary = nil
        onRebuildUsage { result in
            DispatchQueue.main.async {
                usageRebuildBusy = false
                switch result {
                case .success(let summary):
                    usageRebuildSummary = summary
                    onLoadUsage?(usageRange.days, usageSelectedDay, true)
                case .failure(let error):
                    usageRebuildError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Workspaces

    func workspacesSection(palette: WarrenSettingsPalette) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            WarrenSettingsGroup("Empty workspace") {
                WarrenSettingsToggleRow(
                    title: "Start the First Agent",
                    description: "Selecting an empty workspace launches the first Agent in Launch Commands order.",
                    isOn: Binding(get: { autoStartAI }, set: { onSetAutoStartAI($0) }),
                    accessibilityID: "settings.workspaces.auto-start-ai"
                )
                WarrenSettingsRowDivider()
                WarrenSettingsToggleRow(
                    title: "Open a Shell",
                    description: autoStartAI
                        ? "Off while the first Agent starts on its own."
                        : "Double-clicking an empty workspace opens a plain Shell.",
                    isOn: Binding(get: { autoOpenShell }, set: { onSetAutoOpenShell($0) }),
                    isEnabled: !autoStartAI,
                    accessibilityID: "settings.workspaces.auto-open-shell"
                )
            }

            WarrenSettingsGroup("Setup scripts", accessory: "Runs when a worktree is created") {
                if projects.isEmpty {
                    WarrenSettingsEmptyRow(text: "No repositories are configured on this Host yet.")
                } else {
                    ForEach(Array(projects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { WarrenSettingsRowDivider() }
                        setupScriptRow(project, palette: palette)
                    }
                }
            }

            WarrenSettingsGroup("Script environment") {
                environmentRow(code: "$1  $2", description: "Main repository path, then the new worktree path.", palette: palette)
                ForEach(WarrenSetupScriptContract.environmentVariables) { variable in
                    WarrenSettingsRowDivider()
                    environmentRow(code: variable.name, description: variable.description, palette: palette)
                }
            }
        }
        .onAppear { syncSetupScriptValues() }
    }

    func setupScriptRow(_ project: Project, palette: WarrenSettingsPalette) -> some View {
        WarrenSettingsListRow(
            title: project.name,
            subtitle: setupScriptSummary(project),
            leading: { EmptyView() },
            trailing: {
                Button("Edit…") { editingSetupScriptProjectID = project.id }
                    .buttonStyle(WarrenSettingsButtonStyle(kind: .secondary))
                    .accessibilityLabel("Edit setup script for \(project.name)")
            }
        )
    }

    /// The row says only what fits: the script's first line and how many more
    /// there are, or that there is none. The whole script is in the dialog.
    func setupScriptSummary(_ project: Project) -> String {
        let script = setupScriptValues[project.id] ?? project.setupScript ?? ""
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No script"
        }
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        let first = lines.first.map(String.init) ?? ""
        return lines.count > 1 ? "\(first)  +\(lines.count - 1) lines" : first
    }

    @ViewBuilder
    var setupScriptDialogLayer: some View {
        if let id = editingSetupScriptProjectID,
           let project = projects.first(where: { $0.id == id }) {
            WarrenDesktopSetupScriptDialog(
                script: Binding(
                    get: { setupScriptValues[id] ?? project.setupScript ?? "" },
                    set: { setupScriptValues[id] = $0 }
                ),
                onClear: {
                    setupScriptValues[id] = ""
                    onSetProjectSetupScript(id, "")
                    editingSetupScriptProjectID = nil
                },
                onCancel: { editingSetupScriptProjectID = nil },
                onSave: {
                    saveSetupScript(for: project)
                    editingSetupScriptProjectID = nil
                }
            )
        }
    }

    func environmentRow(code: String, description: String, palette: WarrenSettingsPalette) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // Wide enough for the longest name, WARREN_WORKSPACE_BRANCH, so
            // no variable is cut short.
            WarrenDesktopCodeChip(text: code)
                .fixedSize()
                .frame(width: 196, alignment: .leading)
            Text(description)
                .font(WarrenTypography.settingsMeta)
                .foregroundStyle(palette.meta)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // A reference table, not a form: eleven variables at a form row's
        // height made half a page of lookups. Tables take the tighter rhythm.
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
    }

    func saveSetupScript(for project: Project) {
        onSetProjectSetupScript(
            project.id,
            setupScriptValues[project.id] ?? project.setupScript ?? ""
        )
    }

    func syncSetupScriptValues() {
        for project in projects where setupScriptValues[project.id] == nil {
            setupScriptValues[project.id] = project.setupScript ?? ""
        }
    }

}
