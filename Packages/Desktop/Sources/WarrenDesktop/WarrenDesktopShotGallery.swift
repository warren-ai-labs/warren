import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain

/// The floating surfaces, drawn on their own for design review.
///
/// `UIShot` renders these offscreen: a dialog, a command palette and the rest
/// of the overlay family are hard to look at in the running app, because
/// looking at one normally means opening it over whatever the person was doing.
/// This gallery exists only to be photographed; nothing in the app mounts it.
///
/// It is inside `WarrenDesktop` rather than in the shot tool because the
/// components it composes are internal, and making them public to photograph
/// them would widen the module's contract for a review convenience.
public struct WarrenDesktopShotGallery: View {
    public enum Surface: String, CaseIterable, Sendable {
        case dialog
        case palette
        /// The split group's stacked icons at rest, which cannot be
        /// photographed without a group in the user's own tabs.
        case fan
        /// The Settings window, which otherwise needs live Host state to open.
        case settings
    }

    public let surface: Surface
    public let projection: WarrenDesktopProjection
    /// Which Settings page to draw when `surface` is `.settings`.
    public let settingsSection: WarrenDesktopSettingsSection

    public init(
        surface: Surface,
        projection: WarrenDesktopProjection,
        settingsSection: WarrenDesktopSettingsSection = .appearance
    ) {
        self.surface = surface
        self.projection = projection
        self.settingsSection = settingsSection
    }

    public var body: some View {
        switch surface {
        case .dialog: DialogGallery()
        case .palette: palette
        case .fan: FanGallery()
        case .settings: settings
        }
    }

    /// The Settings window with a Host's shape but no live Host behind it.
    ///
    /// The page takes thirty-five parameters of Host state; everything it needs
    /// to *look* right is a value, so the gallery supplies values rather than
    /// opening the real page over the user's work.
    private var settings: some View {
        WarrenDesktopSettingsView(
            onBack: {},
            hostName: "mbp14-m3",
            webStatus: WarrenDesktopWebStatus(
                isRunning: true,
                localURL: URL(string: "http://127.0.0.1:8789")
            ),
            onWebTest: nil,
            onWebStop: nil,
            onWebReset: nil,
            onRelayEnroll: nil,
            onRelayPairing: nil,
            lanPairing: WarrenDesktopLANPairing(),
            onLANPairing: nil,
            relaySettings: WarrenDesktopRelaySettings(),
            onSetRelayEnabled: nil,
            onResetRelay: nil,
            relayDevices: [],
            onLoadRelayDevices: nil,
            onRevokeRelayDevice: nil,
            defaultRuntime: "ghostline",
            onSetRuntime: { _ in },
            autoOpenShell: true,
            onSetAutoOpenShell: { _ in },
            autoStartAI: false,
            onSetAutoStartAI: { _ in },
            openAIBaseURL: "",
            openAIModel: "",
            openAITitleEnabled: false,
            onSetOpenAISetting: { _, _ in },
            onTestOpenAI: { _, _, _ in },
            projects: projection.groups.map(\.project),
            projectGroups: projection.groups,
            onSetProjectSetupScript: { _, _ in },
            usageStats: WarrenUsageStats(),
            usageState: .idle,
            onLoadUsage: nil,
            onRebuildUsage: nil,
            initialSettingsSection: settingsSection
        )
    }

    /// The palette over the window it would open on, at its real width.
    private var palette: some View {
        ZStack(alignment: .top) {
            WarrenColorTokens.dark.windowBackdrop
            // A suggestion of the window behind it: the palette is judged
            // against content, not against an empty ground.
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<14, id: \.self) { line in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: [520.0, 380, 610, 300, 460][line % 5], height: 10)
                        .padding(.leading, line % 3 == 0 ? 0 : 24)
                }
                Spacer(minLength: 0)
            }
            .padding(56)

            WarrenDesktopCommandPalette(
                projection: projection,
                onAction: { _ in },
                onDismiss: {},
                width: WarrenLayoutMetrics.commandPaletteWidth,
                resultsMaxHeight: WarrenLayoutMetrics.commandPaletteResultsMaxHeight
            )
            .padding(.top, 96)
        }
    }
}

/// The split group's fan at rest, three members wide, on the bar it sits on.
private struct FanGallery: View {
    @StateObject private var hover = WarrenDesktopPaneGroupHover()

    private func member(_ index: Int, kind: TerminalSessionKind, title: String) -> WarrenDesktopPaneGroupPresentation.Member {
        WarrenDesktopPaneGroupPresentation.Member(
            tab: ClientTab(id: "tab-\(index)", title: title, kind: kind),
            title: title,
            mark: nil,
            activity: "Running",
            icon: WarrenDesktopAppIcon(kind: kind),
            unitFrame: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )
    }

    private var group: WarrenDesktopPaneGroupPresentation {
        WarrenDesktopPaneGroupPresentation(
            scopeKey: "gallery",
            title: "warren",
            context: "warren · feat/workbench-cards",
            members: [
                member(0, kind: .claude, title: "Claude Code"),
                member(1, kind: .codex, title: "Codex"),
                member(2, kind: .pi, title: "Pi"),
            ],
            currentTabID: "tab-0",
            containsSelection: true,
            canSplit: true
        )
    }

    private static let noop = WarrenDesktopPaneGroupActions(
        selectMember: { _ in },
        selectGroup: {},
        toggleZoom: { _ in },
        isZoomed: { _ in false },
        closeMember: { _ in },
        split: {},
        ungroup: {},
        merge: { _ in },
        splitDrop: { _, _, _ in },
        contextMenu: { _ in [] }
    )

    var body: some View {
        ZStack {
            WarrenColorTokens.dark.windowBackdrop
            VStack(alignment: .leading, spacing: 20) {
                WarrenDesktopPaneGroupPill(group: group, actions: Self.noop, hover: hover)
                Text("At rest, three members")
                    .font(WarrenTypography.caption)
                    .foregroundStyle(WarrenColorTokens.dark.ink4)
            }
            .padding(40)
        }
    }
}

/// The dialog family side by side: a rename, a destructive confirmation, and a
/// form. Each dialog paints its own scrim and centres itself, so each one gets
/// its own band of the board.
private struct DialogGallery: View {
    @State private var workspaceName = "warren"
    @State private var taskName = "Ship the new chrome"
    @State private var externalID = "tapd-8842"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: 0) {
            band {
                WarrenDialog("Rename Workspace", width: .s) {
                    WarrenInputField("Name", text: $workspaceName)
                } footer: {
                    WarrenDialogFooter(
                        confirmLabel: "Rename",
                        onCancel: {},
                        onConfirm: {}
                    )
                }
            }
            band {
                WarrenDialog(
                    "Delete Workspace?",
                    message: "The Git worktree stays on disk. Its Sessions end, and Warren stops tracking this checkout.",
                    width: .s
                ) {
                    EmptyView()
                } footer: {
                    WarrenDialogFooter(
                        // The title already names the object; the button's job
                        // is the verb. "Delete Workspace" is what wrapped this
                        // footer into two lines.
                        confirmLabel: "Delete",
                        isDestructive: true,
                        onCancel: {},
                        onConfirm: {}
                    )
                }
            }
            band {
                WarrenDialog(
                    "New Task",
                    message: "A Task groups Workspaces from more than one project.",
                    width: .m
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        WarrenInputField("Name", text: $taskName, monospaced: false)
                        WarrenInputField("External ID", text: $externalID)
                    }
                } footer: {
                    WarrenDialogFooter(
                        confirmLabel: "Create Task",
                        onCancel: {},
                        onConfirm: {}
                    )
                }
            }
        }
        .background(tokens.windowBackdrop)
    }

    private func band<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
