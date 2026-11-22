import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// The Inspector's pages, as the right sidebar's tab row names them.
///
/// The Inspector used to draw its own tab header inside its surface; the right
/// sidebar owns that row now, so the tabs are resolved here and the surface is
/// handed the one it should draw.
public enum WarrenDesktopInspectorTab: String, CaseIterable, Identifiable, Sendable {
    case changes, history, files

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .changes: "Changes"
        case .history: "History"
        case .files: "Files"
        }
    }
}

/// Every page the right sidebar can show for a Workspace: the Inspector's three
/// pages, or the embedded editor.
public enum WarrenDesktopRightSidebarTab: Hashable, Sendable {
    case inspector(WarrenDesktopInspectorTab)
    case editor

    public var inspectorTab: WarrenDesktopInspectorTab? {
        guard case .inspector(let tab) = self else { return nil }
        return tab
    }

    public var isEditor: Bool { self == .editor }

    /// The page a Workspace falls back to when the one it remembered is no
    /// longer available (for example the editor on a remote Host).
    public static func resolve(
        _ remembered: WarrenDesktopRightSidebarTab?,
        inspectorAvailable: Bool,
        editorAvailable: Bool
    ) -> WarrenDesktopRightSidebarTab? {
        if let remembered {
            switch remembered {
            case .editor where editorAvailable:
                return remembered
            case .inspector(let tab) where inspectorAvailable:
                return .inspector(tab)
            default:
                break
            }
        }
        if inspectorAvailable { return .inspector(.changes) }
        if editorAvailable { return .editor }
        return nil
    }
}

/// The value the Inspector publishes to the sidebar's tab row.
///
/// The change count is drawn on the Changes tab, which the Desktop package owns,
/// but the count comes from the app's Inspector model. This small observable
/// bridge carries the one value across that seam without the sidebar having to
/// know about the model or its polling.
@MainActor
public final class WarrenDesktopInspectorActivity: ObservableObject {
    @Published public var changeCount: Int
    @Published public private(set) var hasKeyboardFocus: Bool = false
    private var focusedSources: Set<String> = []

    public init(changeCount: Int = 0) {
        self.changeCount = changeCount
    }

    public func setKeyboardFocus(_ focused: Bool, source: String) {
        if focused {
            focusedSources.insert(source)
        } else {
            focusedSources.remove(source)
        }
        let next = !focusedSources.isEmpty
        if hasKeyboardFocus != next {
            hasKeyboardFocus = next
        }
    }
}

/// The right sidebar: one card beside the terminal that hosts either the
/// Inspector's three tabs (Changes, History, Files) or the Embedded Editor as
/// a separate mode with its own minimal header.
///
/// The top bar keeps a single right-sidebar toggle. Inside the sidebar, the
/// Inspector tabs stay grouped on the leading side and the Embedded Editor
/// launches from a dedicated trailing control beside the external IDE icon.
/// Entering Editor mode replaces the Inspector tab bar with a minimal Editor
/// header whose close button closes the right sidebar and clears the
/// workspace's editor marker.
struct WarrenDesktopRightSidebar: View {
    /// The mode shown for the current Workspace.
    let tab: WarrenDesktopRightSidebarTab
    let inspectorAvailable: Bool
    let editorAvailable: Bool
    /// Whether the embedded editor is running for this Workspace.
    let editorRunning: Bool
    /// The number drawn on the Changes tab, from the Inspector's model.
    let changeCount: Int
    /// The Inspector's page content, resolved for one tab.
    let inspectorContent: (WarrenDesktopInspectorTab) -> AnyView
    /// The embedded editor's content.
    let editorContent: () -> AnyView
    let onSelectTab: (WarrenDesktopRightSidebarTab) -> Void
    /// Switches from Editor mode to the Workspace's last Inspector tab without
    /// closing the right sidebar or clearing the editor marker.
    let onOpenInspector: () -> Void
    /// Closes the embedded editor and the right sidebar.
    let onCloseEditor: () -> Void
    /// The external-editor control, present only where the Host allows one.
    let externalIDE: ExternalIDE?

    /// The external-editor control at the end of the header row.
    struct ExternalIDE {
        /// The editor a plain click opens, and the name the tooltip carries.
        let name: String?
        /// That editor's own app icon, drawn as the button.
        let icon: NSImage?
        let canOpen: Bool
        let isMenuPresented: Bool
        let open: () -> Void
        let presentMenu: () -> Void
        /// The right-click menu: every editor, then Manage Editors….
        let chooseActions: [WarrenDesktopContextMenuAction]
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var hoveredTab: WarrenDesktopInspectorTab?
    @State private var isOpenEditorHovered = false
    @State private var isOpenInspectorHovered = false
    @State private var isCloseHovered = false
    @State private var isIDEBodyHovered = false

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            Rectangle()
                .fill(tokens.chromeDivider)
                .frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.workbenchCardFill)
        .warrenCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Right sidebar")
    }

    // MARK: - Header

    @ViewBuilder
    private var headerRow: some View {
        switch tab {
        case .inspector:
            inspectorHeader
        case .editor:
            editorHeader
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 2) {
            if inspectorAvailable {
                inspectorTabButton(.changes)
                inspectorTabButton(.history)
                inspectorTabButton(.files)
            }
            Spacer(minLength: 4)
            if editorAvailable {
                openEditorButton
            }
            if let externalIDE {
                externalIDEControl(externalIDE)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
    }

    private var editorHeader: some View {
        HStack(spacing: 2) {
            Text("Editor")
                .font(WarrenTypography.panelTabSelected)
                .foregroundStyle(tokens.foreground)
                .padding(.leading, 8)
                .accessibilityLabel("Editor")

            Spacer(minLength: 4)
            if inspectorAvailable {
                openInspectorButton
            }
            if let externalIDE {
                externalIDEControl(externalIDE)
            }
            closeEditorButton
        }
        .padding(.horizontal, 6)
        .frame(height: WarrenLayoutMetrics.tabBarHeight)
    }

    private func inspectorTabButton(_ inspector: WarrenDesktopInspectorTab) -> some View {
        let page = WarrenDesktopRightSidebarTab.inspector(inspector)
        let isSelected = tab == page
        let isHovered = hoveredTab == inspector
        return Button {
            onSelectTab(page)
        } label: {
            HStack(spacing: 4) {
                WarrenDesktopPanelTabTitle(inspector.title, isSelected: isSelected)
                if inspector == .changes, changeCount > 0 {
                    Text("\(changeCount)")
                        .font(WarrenTypography.count)
                        .warrenNumericTransition(value: changeCount)
                        .foregroundStyle(isSelected ? tokens.foreground.opacity(0.8) : tokens.mutedForeground)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(tokens.tertiaryWash, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 8)
            .frame(height: WarrenLayoutMetrics.tabPillHeight)
            .background(
                isSelected
                    ? tokens.tertiaryWash
                    : (isHovered ? tokens.fillHover : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? inspector : (hoveredTab == inspector ? nil : hoveredTab) }
        .accessibilityLabel(inspector.title)
        .accessibilityValue(accessibilityValue(for: inspector))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "right-sidebar.tab.\(inspector.rawValue)",
            role: .button,
            label: inspector.title,
            value: accessibilityValue(for: inspector),
            isSelected: isSelected,
            action: { onSelectTab(page) }
        )
    }

    private func accessibilityValue(for inspector: WarrenDesktopInspectorTab) -> String {
        guard inspector == .changes, changeCount > 0 else { return "" }
        return "\(changeCount) changes"
    }

    /// Launches the Embedded Editor mode from the Inspector header, kept on the
    /// trailing side beside the external IDE action so it never reads as a
    /// fourth Inspector tab.
    private var openEditorButton: some View {
        let open = { onSelectTab(.editor) }
        return Button(action: open) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(editorRunning || isOpenEditorHovered ? tokens.foreground : tokens.mutedForeground)
                .frame(width: 28, height: 26)
                .background(
                    isOpenEditorHovered ? tokens.fillHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isOpenEditorHovered = $0 }
        .warrenTooltip("Open Embedded Editor")
        .accessibilityLabel("Open Embedded Editor")
        .accessibilityValue(editorRunning ? "Running" : "")
        .warrenSemanticElement(
            id: "right-sidebar.editor.open",
            role: .button,
            label: "Open Embedded Editor",
            value: editorRunning ? "Running" : "Not running",
            action: open
        )
    }

    /// Switches from Editor mode back to the Inspector without closing the
    /// right sidebar or clearing the Workspace's editor marker.
    private var openInspectorButton: some View {
        Button(action: onOpenInspector) {
            HStack(spacing: 4) {
                Text("Inspector")
                    .font(WarrenTypography.panelTab)
                if changeCount > 0 {
                    Text("\(changeCount)")
                        .font(WarrenTypography.count)
                        .warrenNumericTransition(value: changeCount)
                        .foregroundStyle(isOpenInspectorHovered ? tokens.foreground.opacity(0.8) : tokens.mutedForeground)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(tokens.tertiaryWash, in: Capsule())
                }
            }
            .foregroundStyle(isOpenInspectorHovered ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isOpenInspectorHovered ? tokens.fillHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isOpenInspectorHovered = $0 }
        .warrenTooltip("Switch to Inspector")
        .accessibilityLabel("Inspector")
        .accessibilityValue(changeCount > 0 ? "\(changeCount) changes" : "")
        .warrenSemanticElement(
            id: "right-sidebar.inspector.open",
            role: .button,
            label: "Inspector",
            value: changeCount > 0 ? "\(changeCount) changes" : "",
            action: onOpenInspector
        )
    }

    private var closeEditorButton: some View {
        Button(action: onCloseEditor) {
            Image(systemName: "xmark")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isCloseHovered ? tokens.foreground : tokens.mutedForeground)
                .frame(width: 28, height: 26)
                .background(
                    isCloseHovered ? tokens.fillHover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .warrenTooltip("Close Editor")
        .accessibilityLabel("Close Editor")
        .warrenSemanticElement(
            id: "right-sidebar.editor.close",
            role: .button,
            label: "Close Editor",
            action: onCloseEditor
        )
    }

    /// One button: the current editor's own app icon, which opens the
    /// Workspace there. The choice of editor moved to a right-click, so the
    /// row ends in a single control instead of a split button. With no
    /// editor available a click shows the list instead.
    private func externalIDEControl(_ control: ExternalIDE) -> some View {
        let background = control.isMenuPresented
            ? tokens.foreground.opacity(0.10)
            : (isIDEBodyHovered ? tokens.fillHover : Color.clear)
        return Button(action: control.canOpen ? control.open : control.presentMenu) {
            Group {
                if let icon = control.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 16, height: 16)
                        .opacity(control.canOpen ? 1 : 0.45)
                } else {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(control.canOpen ? tokens.mutedForeground : tokens.mutedForeground.opacity(0.45))
                }
            }
            .frame(width: 28, height: 26)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isIDEBodyHovered = $0 }
        .warrenContextMenu(control.chooseActions)
        .warrenTooltip(control.name.map { "Open in \($0)" } ?? "Open in editor")
        .accessibilityLabel(control.name.map { "Open in \($0)" } ?? "Open in editor")
        .accessibilityActions {
            Button("Choose editor", action: control.presentMenu)
        }
        .warrenSemanticElement(
            id: "right-sidebar.external-ide",
            role: .button,
            label: "Open in editor",
            value: control.name,
            isSelected: control.isMenuPresented,
            action: control.canOpen ? control.open : control.presentMenu
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .inspector(let inspector):
            inspectorContent(inspector)
        case .editor:
            if editorRunning {
                editorContent()
            } else {
                editorIdle
            }
        }
    }

    /// The Editor page while the region is not running: a quiet prompt, not an
    /// empty code-server surface. The tab starts the region, so the prompt is
    /// the same action in words.
    private var editorIdle: some View {
        let open = { onSelectTab(.editor) }
        return VStack(spacing: 10) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tokens.mutedForeground.opacity(0.8))
            Text("Embedded editor is not running")
                .font(WarrenTypography.emptyStateTitle)
                .foregroundStyle(tokens.foreground.opacity(0.85))
            Button(action: open) {
                Text("Open Editor")
                    .font(WarrenTypography.captionEmphasis)
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(tokens.tertiaryWash, in: Capsule())
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .warrenSemanticElement(
                id: "right-sidebar.editor.open",
                role: .button,
                label: "Open Editor",
                action: open
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A panel tab's title. Each tab reserves its selected width, so the bolder
/// cut never nudges the tabs after it when the selection moves.
struct WarrenDesktopPanelTabTitle: View {
    let title: String
    let isSelected: Bool

    init(_ title: String, isSelected: Bool) {
        self.title = title
        self.isSelected = isSelected
    }

    var body: some View {
        Text(title)
            .font(WarrenTypography.panelTabSelected)
            .hidden()
            .overlay(alignment: .leading) {
                Text(title)
                    .font(isSelected ? WarrenTypography.panelTabSelected : WarrenTypography.panelTab)
            }
    }
}
