import SwiftUI
import WarrenClientCore
import WarrenDesignSystem
import WarrenDomain
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
        /// The empty content card a worktree with no Session shows.
        case empty
        case palette
        /// The split group's stacked icons at rest, which cannot be
        /// photographed without a group in the user's own tabs.
        case fan
        /// The Settings window, which otherwise needs live Host state to open.
        case settings
        /// The update/restart card, which only appears for a few seconds.
        case hud
        /// The approval tray's "N waiting" pill and its panel.
        case tray
        /// The launch-command bar that hangs off the "+" menu.
        case presets
        /// A notice toast stack over the window it lands on.
        case toasts
        /// The sidebar header's update marker, in each of its states.
        case badge
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
        case .empty: emptyStage
        case .palette: palette
        case .fan: FanGallery()
        case .settings: settings
        case .hud: hud
        case .tray: tray
        case .presets: presets
        case .toasts: toasts
        case .badge: badge
        }
    }

    /// The update marker as the sidebar header draws it, state by state.
    private var badge: some View {
        VStack(alignment: .leading, spacing: 20) {
            // The footer glyph the release builds use, beside the marker the
            // preview builds use, so the two can be compared in one shot.
            HStack(spacing: 24) {
                ForEach(Array([
                    ("ready", WarrenDesktopUpdateStatus.available(version: "0.35.0")),
                    ("installing", .updating),
                    ("failed", .failed),
                ].enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 8) {
                        Text(item.0)
                            .font(WarrenTypography.caption)
                            .foregroundStyle(WarrenColorTokens.dark.ink4)
                        WarrenDesktopUpdateIcon(status: item.1, onAction: {})
                    }
                }
            }
            .padding(.bottom, 8)

            ForEach(Array([
                ("Local build, no update", WarrenDesktopUpdateStatus.none),
                ("Update ready", .available(version: "0.35.0")),
                ("Installing", .updating),
                ("Update failed", .failed),
            ].enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.0)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(WarrenColorTokens.dark.ink4)
                    WarrenDesktopBuildBadge(updateStatus: item.1, isCompact: false)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WarrenColorTokens.dark.workbenchCardFill)
    }

    /// A worktree with no Session, the way the app's content card draws it.
    private var emptyStage: some View {
        ZStack {
            galleryBackdrop
            WarrenDesktopEmptyStage(
                mark: .symbol("apple.terminal"),
                title: "No sessions here yet",
                message: "Start a shell or an Agent from + in the tab bar.",
                hints: [.init(keys: "⌘T", label: "New shell")]
            )
            .padding(.leading, 316)
        }
    }

    /// The update/restart card over a dimmed window.
    private var hud: some View {
        ZStack {
            galleryBackdrop
            WarrenDesktopUpdateHUD(detail: "Installing 0.35.0")
        }
    }

    /// A stand-in for the window behind a floating surface: the ground, a few
    /// blocks where the sidebar and a pane would be, and nothing else.
    private var galleryBackdrop: some View {
        ZStack(alignment: .topLeading) {
            WarrenColorTokens.dark.windowBackdrop
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(WarrenColorTokens.dark.workbenchCardFill)
                    .frame(width: 300)
                RoundedRectangle(cornerRadius: 12)
                    .fill(WarrenColorTokens.dark.workbenchCardFill)
            }
            .padding(8)
        }
    }

    /// The approval tray pill, with two Agents waiting.
    private var tray: some View {
        let store = WarrenDesktopApprovalTrayStore()
        store.update([
            WarrenDesktopApprovalTrayEntry(
                id: TerminalSessionID(UUID(uuidString: "af02b8a4-6e7e-418a-a245-759c8170e3bf")!),
                kind: .claude,
                title: "检查 herdr app UI",
                location: "warren · feat/workbench-cards",
                mark: .approvalNeeded,
                ask: "Claude wants to run a command",
                detail: "git push origin main",
                decision: nil
            ),
            WarrenDesktopApprovalTrayEntry(
                id: TerminalSessionID(UUID(uuidString: "43517822-7987-4519-8d7c-efaa0b170a7d")!),
                kind: .codex,
                title: "sumi redundancy cleanup",
                location: "sumi · refactor/sumi/redundancy",
                mark: .inputNeeded,
                ask: "Codex is asking a question",
                detail: nil,
                decision: nil
            ),
        ])
        return VStack(alignment: .leading, spacing: 24) {
            WarrenDesktopApprovalTrayPill(
                store: store,
                onOpen: { _ in },
                onResolve: { _, _, _ in }
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("The panel it opens")
                    .font(WarrenTypography.caption)
                    .foregroundStyle(WarrenColorTokens.dark.ink4)
                // The panel as the menu layer presents it: the shared menu
                // surface at the tray's own width, not a bare stack.
                WarrenDesktopApprovalTrayPanel(
                    store: store,
                    onOpen: { _ in },
                    onResolve: { _, _, _ in },
                    onDismiss: {}
                )
                .frame(width: WarrenDesktopApprovalTray.width)
                // The menu layer's own surface, which is what caps the panel's
                // height; a bare card stretched it to the shots's full canvas.
                .modifier(WarrenDesktopMenuSurfaceModifier(width: WarrenDesktopApprovalTray.width))
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WarrenColorTokens.dark.windowBackdrop)
    }

    /// The launch-command bar with the fixture's first workspace.
    private var presets: some View {
        let workspace = projection.groups.first?.workspaces.first
        return VStack(alignment: .leading, spacing: 16) {
            WarrenDesktopPresetBar(
                workspace: workspace,
                isBusy: false,
                canUseEmbeddedBrowser: true,
                onLaunch: { _ in }
            )
            Text("The bar as it drops from the pane's + control.")
                .font(WarrenTypography.caption)
                .foregroundStyle(WarrenColorTokens.dark.ink4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WarrenColorTokens.dark.windowBackdrop)
    }

    /// Two notices stacked as they arrive.
    ///
    /// The stack only takes notices that arrive *after* it appears, so the
    /// gallery primes it empty and fills it a beat later — otherwise the shot
    /// photographs an empty corner.
    private var toasts: some View {
        ToastGallery()
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
                        WarrenInputField("Name", text: $taskName)
                        WarrenInputField("External ID", text: $externalID, monospaced: true)
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

/// The notice toast stack, primed the way the app primes it: empty on appear,
/// then filled by an arrival.
private struct ToastGallery: View {
    @State private var notices: [WarrenDesktopNotice] = []

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WarrenGalleryBackdrop()
            WarrenDesktopNoticeToastStack(
                notices: notices,
                isMuted: false,
                onOpen: {}
            )
            // The app pins the stack to the sidebar's width in the window's
            // bottom-left corner; a shot at full width is not the same surface.
            .frame(width: 288)
            .padding(16)
        }
        .task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            notices = [
                WarrenDesktopNotice(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    kind: .error,
                    title: "Update failed",
                    message: "Warren could not prepare the update. Click to retry."
                ),
                WarrenDesktopNotice(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    kind: .success,
                    title: "Workspace created",
                    message: "feat/overlay-polish is ready."
                ),
            ]
        }
    }
}

/// The window behind a floating surface, for shots that need one.
struct WarrenGalleryBackdrop: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            WarrenColorTokens.dark.windowBackdrop
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(WarrenColorTokens.dark.workbenchCardFill)
                    .frame(width: 300)
                RoundedRectangle(cornerRadius: 12)
                    .fill(WarrenColorTokens.dark.workbenchCardFill)
            }
            .padding(8)
        }
    }
}
