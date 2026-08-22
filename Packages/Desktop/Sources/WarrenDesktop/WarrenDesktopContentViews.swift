import AppKit
import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

struct WarrenDesktopWorkspaceContent<TerminalSurface: View>: View {
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let tab: ClientTab?
    let hasProjects: Bool
    let connectionState: WarrenDesktopConnectionState
    let showsPaneHeader: Bool
    let session: WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let terminalFont: TerminalFontPreference
    let wantsTerminalFocus: Bool
    let onAddProject: () -> Void
    let onImportSuperset: () -> Void
    let terminalSurface: @MainActor (WarrenDesktopTerminalContext) -> TerminalSurface

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var primaryButtonFocused: Bool

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let workspace {
            // Keep the terminal surface mounted even while the roster has not
            // yet published a tab for this workspace. Tearing the view down on
            // a transient nil tab recreates Ghostty surfaces in a loop and
            // leaves a blank pane; the injected surface view decides what to
            // show while no session is active.
            let resolvedTab = tab ?? ClientTab(
                id: "workspace-empty-\(workspace.id.rawValue.uuidString)",
                title: "No open sessions",
                sessionID: nil,
                kind: .shell
            )
            WarrenDesktopPaneView(
                workspace: workspace,
                terminalGroup: nil,
                tab: resolvedTab,
                session: session,
                hostName: hostName,
                titleTemplate: titleTemplate,
                showsPaneHeader: showsPaneHeader,
                terminalSurface: terminalSurface(
                    WarrenDesktopTerminalContext(
                        workspace: workspace,
                        tab: resolvedTab,
                        font: terminalFont,
                        wantsTerminalFocus: wantsTerminalFocus
                    )
                )
            )
        } else if let terminalGroup {
            let resolvedTab = tab ?? ClientTab(
                id: "terminal-group-empty-\(terminalGroup.id.rawValue.uuidString)",
                title: "No open sessions",
                sessionID: nil,
                kind: .shell
            )
            WarrenDesktopPaneView(
                workspace: nil,
                terminalGroup: terminalGroup,
                tab: resolvedTab,
                session: session,
                hostName: hostName,
                titleTemplate: titleTemplate,
                showsPaneHeader: showsPaneHeader,
                terminalSurface: terminalSurface(
                    WarrenDesktopTerminalContext(
                        terminalGroup: terminalGroup,
                        tab: resolvedTab,
                        font: terminalFont,
                        wantsTerminalFocus: wantsTerminalFocus
                    )
                )
            )
        } else if workspace == nil, tab == nil,
                  connectionState == .connecting || connectionState == .reconnecting {
            connectionLoadingState(tokens: tokens)
        } else if workspace == nil, tab == nil,
                  connectionState == .disconnected || connectionState == .failed {
            connectionUnavailableState(tokens: tokens)
        } else if workspace == nil, tab == nil, !hasProjects {
            emptyWelcome(tokens: tokens)
        } else {
            VStack(spacing: WarrenSpacing.standard) {
                Text("Select a workspace")
                    .font(WarrenTypography.emptyStateTitle)
                    .foregroundStyle(tokens.mutedForeground)
                Text("Choose a workspace to open its terminals")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .opacity(0.72)
                    .multilineTextAlignment(.center)
                    .lineSpacing(WarrenSpacing.small)
            }
            .padding(.bottom, emptyStatePageOffset * 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("No workspace selected")
        }
    }

    private func emptyWelcome(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            Text("Open a project to begin")
                .font(WarrenTypography.emptyStateTitle)
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
            Button(action: onAddProject) {
                Text("Add Project…")
                    .font(WarrenTypography.body)
            }
            .buttonStyle(WarrenPrimaryButtonStyle(isFocused: primaryButtonFocused))
            .focused($primaryButtonFocused)
            .warrenSemanticElement(
                id: "onboarding.add-project",
                role: .button,
                label: "Add Project",
                action: onAddProject
            )
            Button(action: onImportSuperset) {
                Text("Import from Superset")
                    .font(WarrenTypography.body)
            }
            .buttonStyle(WarrenSecondaryButtonStyle())
            .warrenSemanticElement(
                id: "onboarding.import-superset",
                role: .button,
                label: "Import from Superset",
                action: onImportSuperset
            )
        }
        .padding(.bottom, emptyStatePageOffset * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func connectionLoadingState(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        return VStack(spacing: WarrenSpacing.standard) {
            WarrenBrailleSpinner(
                size: 22,
                accessibilityLabel: presentation.label
            )
            Text(presentation.label)
                .font(WarrenTypography.emptyStateTitle)
                .foregroundStyle(tokens.mutedForeground)
            Text("Waiting for projects and sessions from \(hostName)")
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
                .opacity(0.72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.label) Waiting for projects and sessions")
    }

    private func connectionUnavailableState(tokens: WarrenColorTokens) -> some View {
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        return VStack(spacing: WarrenSpacing.standard) {
            Image(systemName: "server.rack")
                .font(.system(size: 22, weight: .light))
            Text(presentation.label)
                .font(WarrenTypography.emptyStateTitle)
            Text("Choose another execution server or wait for this server to return")
                .font(WarrenTypography.body)
                .opacity(0.72)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(tokens.mutedForeground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presentation.label)
    }

    /// The empty state sits inside the content area below the tab and preset
    /// bars; nudge it up by half that chrome so its visual center lands on the
    /// whole page's center instead of the terminal pane's center.
    private var emptyStatePageOffset: CGFloat {
        (WarrenLayoutMetrics.tabBarHeight + WarrenLayoutMetrics.presetBarHeight) / 2
    }

}

private struct WarrenDesktopPaneView<TerminalSurface: View>: View {
    let workspace: Workspace?
    let terminalGroup: TerminalGroup?
    let tab: ClientTab
    let session: WarrenDesktopSession?
    let hostName: String
    let titleTemplate: TerminalDisplayTitleTemplate
    let showsPaneHeader: Bool
    let terminalSurface: TerminalSurface

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            if showsPaneHeader {
                HStack(spacing: WarrenSpacing.compact) {
                    Text(displayTitle)
                        .font(WarrenTypography.paneShellTitle)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .help(fullDisplayTitle)
                        .contextMenu {
                            Button("Copy Full Title") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(fullDisplayTitle, forType: .string)
                            }
                        }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(height: WarrenLayoutMetrics.paneHeaderHeight)
                .background(tokens.tertiaryWash)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(tokens.chromeDivider)
                        .frame(height: WarrenSpacing.hairline)
                }
            }

            ZStack {
                terminalSurface
                    // AppKit-backed terminal views have a useful intrinsic grid
                    // size. Without an explicit flexible frame SwiftUI preserves
                    // that size and centers a 50-column surface inside a much
                    // larger pane. The pane owns geometry, so the renderer must
                    // accept the entire proposed content size.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(WarrenSpacing.compact)
                    .background(tokens.background)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal panel \(tab.title)")
    }

    private var displayTitle: String {
        if let customTitle = normalizedCustomTitle {
            return customTitle
        }
        return titleTemplate.renderCompact(titleContext)
    }

    private var fullDisplayTitle: String {
        if let customTitle = normalizedCustomTitle {
            return customTitle
        }
        return titleTemplate.render(titleContext)
    }

    private var normalizedCustomTitle: String? {
        guard let customTitle = session?.customTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !customTitle.isEmpty else {
            return nil
        }
        return customTitle
    }

    private var titleContext: TerminalDisplayTitleContext {
        TerminalDisplayTitleContext(
            session: session?.title ?? tab.title,
            command: session?.runtimeProcess ?? tab.kind.displayName,
            directory: session?.workingDirectory.isEmpty == false
                ? session!.workingDirectory
                : (workspace?.path ?? terminalGroup?.home ?? ""),
            workspace: workspace?.name ?? terminalGroup?.name ?? "",
            branch: workspace?.branch ?? "",
            host: hostName,
            user: NSUserName(),
            os: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}
