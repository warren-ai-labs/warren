import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// Top-right workspace controls share one app-owned popover contract. A
/// control only reports which popover it wants; the window root owns
/// presentation, dismissal and outside clicks.
enum WarrenDesktopChromePopover: Equatable {
    case web
    case endpoint
    case externalIDE
    case overflow
}

/// Shared surface for every top-right chrome popover: same radius, border,
/// elevation, header typography and close affordance.
enum WarrenDesktopChromeTitleMetrics {
    static let iconSize: CGFloat = 12
    static let buttonSize: CGFloat = 22
}

struct WarrenDesktopChromePopoverSurface<Content: View>: View {
    let title: String
    let width: CGFloat
    let onDismiss: () -> Void
    let titleFont: Font
    let role: WarrenPresentationRole
    let titleLeading: AnyView?
    let titleTrailing: AnyView?
    let content: Content

    @Environment(\.colorScheme) private var colorScheme

    init(
        title: String,
        width: CGFloat,
        onDismiss: @escaping () -> Void,
        titleFont: Font = WarrenTypography.popoverTitle,
        role: WarrenPresentationRole = .popover,
        titleLeading: AnyView? = nil,
        titleTrailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.width = width
        self.onDismiss = onDismiss
        self.titleFont = titleFont
        self.role = role
        self.titleLeading = titleLeading
        self.titleTrailing = titleTrailing
        self.content = content()
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.xs) {
                if let titleLeading {
                    titleLeading
                }
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let titleTrailing {
                    titleTrailing
                }
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: WarrenDesktopChromeTitleMetrics.iconSize, weight: .regular))
                        .frame(
                            width: WarrenDesktopChromeTitleMetrics.buttonSize,
                            height: WarrenDesktopChromeTitleMetrics.buttonSize
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityLabel("Close \(title)")
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.vertical, WarrenSpacing.compact)

            Rectangle()
                .fill(tokens.border)
                .frame(height: WarrenSpacing.hairline)

            content
        }
        .frame(width: width, alignment: .leading)
        .warrenPresentationSurface(role: role, cornerRadius: WarrenRadius.base)
        .onExitCommand(perform: onDismiss)
    }
}

struct WarrenDesktopEndpointPopover: View {
    let connectionState: WarrenDesktopConnectionState
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let onSetSidebarVisibility: (String, Bool) -> Void
    let onCustomizeDisplayName: (WarrenDesktopEndpointOption) -> Void
    let onAddSSHHost: () -> Void
    let onRetry: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void

    init(
        connectionState: WarrenDesktopConnectionState,
        endpoints: [WarrenDesktopEndpointOption],
        selectedID: String,
        onSelect: @escaping (String) -> Void,
        onSetSidebarVisibility: @escaping (String, Bool) -> Void,
        onCustomizeDisplayName: @escaping (WarrenDesktopEndpointOption) -> Void = { _ in },
        onAddSSHHost: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.connectionState = connectionState
        self.endpoints = endpoints
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onSetSidebarVisibility = onSetSidebarVisibility
        self.onCustomizeDisplayName = onCustomizeDisplayName
        self.onAddSSHHost = onAddSSHHost
        self.onRetry = onRetry
        self.onStop = onStop
        self.onDismiss = onDismiss
    }

    var body: some View {
        WarrenDesktopChromePopoverSurface(
            title: "Execution Server",
            width: 260,
            onDismiss: onDismiss
        ) {
            WarrenDesktopEndpointPopoverContent(
                connectionState: connectionState,
                endpoints: endpoints,
                selectedID: selectedID,
                onSelect: onSelect,
                onSetSidebarVisibility: onSetSidebarVisibility,
                onCustomizeDisplayName: onCustomizeDisplayName,
                onAddSSHHost: onAddSSHHost,
                onRetry: onRetry,
                onStop: onStop,
                onDismiss: onDismiss
            )
        }
    }
}

/// The list portion is shared by the direct endpoint popover and the inline
/// More detail view. Keeping the list separate avoids stacking a full panel
/// inside another panel when a hidden action is opened from More.
struct WarrenDesktopEndpointPopoverContent: View {
    let connectionState: WarrenDesktopConnectionState
    let endpoints: [WarrenDesktopEndpointOption]
    let selectedID: String
    let onSelect: (String) -> Void
    let onSetSidebarVisibility: (String, Bool) -> Void
    let onCustomizeDisplayName: (WarrenDesktopEndpointOption) -> Void
    let onAddSSHHost: () -> Void
    let onRetry: () -> Void
    let onStop: () -> Void
    let onDismiss: () -> Void

    init(
        connectionState: WarrenDesktopConnectionState,
        endpoints: [WarrenDesktopEndpointOption],
        selectedID: String,
        onSelect: @escaping (String) -> Void,
        onSetSidebarVisibility: @escaping (String, Bool) -> Void,
        onCustomizeDisplayName: @escaping (WarrenDesktopEndpointOption) -> Void = { _ in },
        onAddSSHHost: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.connectionState = connectionState
        self.endpoints = endpoints
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onSetSidebarVisibility = onSetSidebarVisibility
        self.onCustomizeDisplayName = onCustomizeDisplayName
        self.onAddSSHHost = onAddSSHHost
        self.onRetry = onRetry
        self.onStop = onStop
        self.onDismiss = onDismiss
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let presentation = WarrenDesktopConnectionPresentation(connectionState)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                WarrenStatusIndicator(
                    color: statusColor(presentation.tone, tokens: tokens),
                    isActive: presentation.isActive,
                    size: 8,
                    accessibilityLabel: presentation.label
                )
                Text(presentation.label)
                    .font(WarrenTypography.popoverMeta)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.standard)
            .padding(.vertical, WarrenSpacing.compact)

            if connectionState == .failed || connectionState == .disconnected {
                Button {
                    onRetry()
                } label: {
                    Label("Retry connection", systemImage: "arrow.clockwise")
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.compact)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Try the selected execution server again")
            } else if connectionState == .connecting || connectionState == .reconnecting {
                Button {
                    onStop()
                } label: {
                    Label("Stop connection", systemImage: "stop.circle")
                        .font(WarrenTypography.popoverItem)
                        .foregroundStyle(tokens.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WarrenSpacing.standard)
                        .padding(.vertical, WarrenSpacing.compact)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Stop connecting to the selected execution server")
            }

            ForEach(endpoints) { endpoint in
                endpointRow(endpoint, tokens: tokens)
            }

            Divider()
                .padding(.vertical, WarrenSpacing.xs)

            Button {
                NotificationCenter.default.post(name: WarrenDesktopEndpointOption.probeRequested, object: nil)
            } label: {
                Label("Check hosts", systemImage: "arrow.clockwise")
                    .font(WarrenTypography.popoverItem)
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
            }
            .buttonStyle(.plain)

            Button {
                onAddSSHHost()
                onDismiss()
            } label: {
                Label("Add SSH Host…", systemImage: "plus.circle")
                    .font(WarrenTypography.popoverItem)
                    .foregroundStyle(tokens.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            NotificationCenter.default.post(name: WarrenDesktopEndpointOption.probeRequested, object: nil)
        }
    }

    private func statusColor(
        _ tone: WarrenDesktopConnectionTone,
        tokens: WarrenColorTokens
    ) -> Color {
        switch tone {
        case .success: tokens.success
        case .info: tokens.info
        case .warning: tokens.warning
        case .destructive: tokens.destructive
        }
    }

    private func endpointRow(
        _ endpoint: WarrenDesktopEndpointOption,
        tokens: WarrenColorTokens
    ) -> some View {
        let isSelected = endpoint.id == selectedID

        return HStack(alignment: .center, spacing: WarrenSpacing.xs) {
            Button {
                onSelect(endpoint.id)
                onDismiss()
            } label: {
                HStack(spacing: WarrenSpacing.compact) {
                    Image(systemName: endpoint.id == selectedID ? "checkmark.circle.fill" : "circle")
                        .font(WarrenTypography.popoverMeta)
                        .foregroundStyle(
                            endpoint.id == selectedID
                                ? tokens.highlight
                                : tokens.mutedForeground
                        )
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(endpoint.label)
                            .font(WarrenTypography.popoverItem)
                            .foregroundStyle(tokens.foreground)
                        if let detail = endpoint.detail {
                            Text(detail)
                                .font(WarrenTypography.popoverMeta)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        if let status = endpoint.probeStatus {
                            Text(status)
                                .font(WarrenTypography.popoverMeta)
                                .foregroundStyle(endpoint.probeFailed ? tokens.destructive : tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let error = endpoint.connectionError {
                            Text(error)
                                .font(WarrenTypography.popoverMeta)
                                .foregroundStyle(tokens.destructive)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(endpoint.label)
            .accessibilityValue([endpoint.id == selectedID ? "Selected" : nil, endpoint.probeStatus, endpoint.connectionError].compactMap { $0 }.joined(separator: ". "))
            .warrenSemanticElement(
                id: "endpoint.\(endpoint.id)",
                role: .button,
                label: endpoint.label,
                value: [endpoint.probeStatus, endpoint.connectionError].compactMap { $0 }.joined(separator: "\n"),
                isSelected: endpoint.id == selectedID,
                action: {
                    onSelect(endpoint.id)
                    onDismiss()
                }
            )
            .contextMenu {
                Button("Customize Display Name…") {
                    onCustomizeDisplayName(endpoint)
                }
            }

            if isSelected && !endpoint.isDisplayedInSidebar {
                sidebarMembershipLabel(isDisplayed: true, tokens: tokens)
                    .accessibilityHidden(true)
            } else {
                Button {
                    onSetSidebarVisibility(endpoint.id, !endpoint.isDisplayedInSidebar)
                } label: {
                    sidebarMembershipLabel(
                        isDisplayed: endpoint.isDisplayedInSidebar,
                        tokens: tokens
                    )
                }
                .buttonStyle(.plain)
                .help(
                    endpoint.isDisplayedInSidebar
                        ? "Remove \(endpoint.label) from Sidebar"
                        : "Add \(endpoint.label) to Sidebar"
                )
                .accessibilityLabel(
                    endpoint.isDisplayedInSidebar
                        ? "Remove \(endpoint.label) from Sidebar"
                        : "Add \(endpoint.label) to Sidebar"
                )
                .accessibilityHint("This does not change the active execution server")
                .warrenSemanticElement(
                    id: "endpoint.\(endpoint.id).sidebar",
                    role: .button,
                    label: endpoint.isDisplayedInSidebar
                        ? "Remove \(endpoint.label) from Sidebar"
                        : "Add \(endpoint.label) to Sidebar",
                    action: {
                        onSetSidebarVisibility(endpoint.id, !endpoint.isDisplayedInSidebar)
                    }
                )
            }
        }
        .padding(.leading, WarrenSpacing.standard)
        .padding(.trailing, WarrenSpacing.compact)
        .padding(.vertical, WarrenSpacing.compact)
    }

    private func sidebarMembershipLabel(
        isDisplayed: Bool,
        tokens: WarrenColorTokens
    ) -> some View {
        Label(
            isDisplayed ? "Sidebar" : "Add",
            systemImage: isDisplayed ? "checkmark" : "plus"
        )
        .font(WarrenTypography.popoverMeta.weight(.semibold))
        .foregroundStyle(isDisplayed ? tokens.highlight : tokens.mutedForeground)
        .padding(.horizontal, WarrenSpacing.xs)
        .padding(.vertical, WarrenSpacing.xxs)
        .background(
            isDisplayed
                ? tokens.highlight.opacity(0.14)
                : tokens.border.opacity(0.6),
            in: Capsule()
        )
    }
}

struct WarrenDesktopExternalIDEPopover: View {
    let options: [WarrenDesktopExternalIDEOption]
    let embeddedEditorAvailable: Bool
    let embeddedEditorDefault: Bool
    let onOpenEmbeddedEditor: () -> Void
    let onSetEmbeddedEditorDefault: (Bool) -> Void
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void
    let onDismiss: () -> Void

    var body: some View {
        WarrenDesktopChromePopoverSurface(
            title: "Open in IDE",
            width: 260,
            onDismiss: onDismiss
        ) {
            WarrenDesktopExternalIDEPopoverContent(
                options: options,
                embeddedEditorAvailable: embeddedEditorAvailable,
                embeddedEditorDefault: embeddedEditorDefault,
                onOpenEmbeddedEditor: onOpenEmbeddedEditor,
                onSetEmbeddedEditorDefault: onSetEmbeddedEditorDefault,
                onOpen: onOpen,
                onDismiss: onDismiss
            )
        }
    }
}

struct WarrenDesktopExternalIDEPopoverContent: View {
    static let codeServerInstallationGuideURL = URL(
        string: "https://coder.com/docs/code-server/install"
    )!

    let options: [WarrenDesktopExternalIDEOption]
    let embeddedEditorAvailable: Bool
    let embeddedEditorDefault: Bool
    let onOpenEmbeddedEditor: () -> Void
    let onSetEmbeddedEditorDefault: (Bool) -> Void
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @AppStorage(WarrenPreferenceKey.embeddedEditorOpenLinks)
    private var embeddedEditorOpenLinks = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            if embeddedEditorAvailable {
                Button(action: openEmbeddedEditor) {
                    HStack(spacing: WarrenSpacing.compact) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(
                                width: WarrenLayoutMetrics.externalIDEIconSize,
                                height: WarrenLayoutMetrics.externalIDEIconSize
                            )
                            .accessibilityHidden(true)
                        Text("Embedded Editor")
                            .font(WarrenTypography.popoverItem)
                            .foregroundStyle(tokens.foreground)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Embedded Editor")
                .warrenSemanticElement(
                    id: "workspace-editor.open",
                    role: .button,
                    label: "Open Embedded Editor",
                    action: openEmbeddedEditor
                )

                Toggle(
                    "Open embedded editor by default",
                    isOn: Binding(
                        get: { embeddedEditorDefault },
                        set: { onSetEmbeddedEditorDefault($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.vertical, WarrenSpacing.compact)
                .accessibilityValue(embeddedEditorDefault ? "Checked" : "Unchecked")

                Toggle(
                    "Open terminal links in embedded editor",
                    isOn: $embeddedEditorOpenLinks
                )
                .toggleStyle(.checkbox)
                .font(WarrenTypography.popoverMeta)
                .foregroundStyle(tokens.mutedForeground)
                .padding(.horizontal, WarrenSpacing.standard)
                .padding(.vertical, WarrenSpacing.compact)
                .accessibilityValue(embeddedEditorOpenLinks ? "Checked" : "Unchecked")

                Button(action: openCodeServerInstallationGuide) {
                    HStack(spacing: WarrenSpacing.compact) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14, weight: .light))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(
                                width: WarrenLayoutMetrics.externalIDEIconSize,
                                height: WarrenLayoutMetrics.externalIDEIconSize
                            )
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Install code-server")
                                .font(WarrenTypography.popoverItem)
                                .foregroundStyle(tokens.foreground)
                            Text("View installation guide")
                                .font(WarrenTypography.popoverMeta)
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(tokens.mutedForeground)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Install code-server")
                .accessibilityHint("Open the official installation guide")
                .warrenSemanticElement(
                    id: "workspace-editor.install",
                    role: .button,
                    label: "Install code-server",
                    action: openCodeServerInstallationGuide
                )

                if !options.isEmpty {
                    Rectangle()
                        .fill(tokens.border)
                        .frame(height: WarrenSpacing.hairline)
                }
            }

            ForEach(WarrenDesktopExternalIDEMenuPresentation.items(from: options)) { item in
                Button {
                    onOpen(item.option)
                    onDismiss()
                } label: {
                    HStack(spacing: WarrenSpacing.compact) {
                        iconView(item.icon, tokens: tokens)
                        Text(item.title)
                            .font(WarrenTypography.popoverItem)
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, WarrenSpacing.standard)
                    .padding(.vertical, WarrenSpacing.compact)
                    .contentShape(.rect)
                    .opacity(item.isEnabled ? 1 : 0.42)
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
                .accessibilityHint(item.isEnabled ? "" : "Unavailable")
            }
        }
    }

    @ViewBuilder
    private func iconView(_ icon: NSImage?, tokens: WarrenColorTokens) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
        } else {
            Image(systemName: "app")
                .font(.system(size: WarrenLayoutMetrics.externalIDEIconSize, weight: .light))
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
                .foregroundStyle(tokens.mutedForeground)
        }
    }

    private func openEmbeddedEditor() {
        onOpenEmbeddedEditor()
        onDismiss()
    }

    private func openCodeServerInstallationGuide() {
        openURL(Self.codeServerInstallationGuideURL)
        onDismiss()
    }
}
