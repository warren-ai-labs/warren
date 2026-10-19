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

    public init(changeCount: Int = 0) {
        self.changeCount = changeCount
    }
}

/// The right sidebar: one card holding the Inspector's pages and the embedded
/// editor, with one tab row and the external-editor control.
///
/// The Inspector and the editor used to occupy the same column but never
/// together: the editor took precedence and the Inspector came back when it
/// closed. They are two pages of one container now, so neither has to displace
/// the other and a Tab is how the user moves between them.
struct WarrenDesktopRightSidebar: View {
    /// The page shown for the current Workspace.
    let tab: WarrenDesktopRightSidebarTab
    let inspectorAvailable: Bool
    let editorAvailable: Bool
    /// Whether the embedded editor is running for this Workspace. It is not the
    /// same as "the editor tab is selected": closing the region keeps the tab
    /// and its place.
    let editorRunning: Bool
    /// The number drawn on the Changes tab, from the Inspector's model.
    let changeCount: Int
    /// The Inspector's page content, resolved for one tab.
    let inspectorContent: (WarrenDesktopInspectorTab) -> AnyView
    /// The embedded editor's content.
    let editorContent: () -> AnyView
    let onSelectTab: (WarrenDesktopRightSidebarTab) -> Void
    /// Closes the editor region without hiding the sidebar.
    let onCloseEditor: () -> Void
    /// The external-editor control, present only where the Host allows one.
    let externalIDE: ExternalIDE?

    /// The external-editor control at the end of the tab row.
    struct ExternalIDE {
        /// The editor a plain click opens, and the name the tooltip carries.
        let name: String?
        let canOpen: Bool
        let isMenuPresented: Bool
        let open: () -> Void
        let presentMenu: () -> Void
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredTab: WarrenDesktopRightSidebarTab?
    @State private var isCloseHovered = false
    @State private var isIDEBodyHovered = false
    @State private var isIDEChevronHovered = false

    private var tokens: WarrenColorTokens {
        WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
    }

    var body: some View {
        VStack(spacing: 0) {
            tabRow
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

    // MARK: - Tab row

    private var tabRow: some View {
        HStack(spacing: 2) {
            if inspectorAvailable {
                inspectorTabButton(.changes)
                inspectorTabButton(.history)
                inspectorTabButton(.files)
            }
            if inspectorAvailable, editorAvailable {
                Rectangle()
                    .fill(tokens.foreground.opacity(0.18))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
            if editorAvailable {
                editorTabButton
            }
            Spacer(minLength: 4)
            if let externalIDE {
                externalIDEControl(externalIDE)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
    }

    private func inspectorTabButton(_ inspector: WarrenDesktopInspectorTab) -> some View {
        let page = WarrenDesktopRightSidebarTab.inspector(inspector)
        let isSelected = tab == page
        let isHovered = hoveredTab == page
        return Button {
            onSelectTab(page)
        } label: {
            HStack(spacing: 5) {
                Text(inspector.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                if inspector == .changes, changeCount > 0 {
                    Text("\(changeCount)")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .warrenNumericTransition(value: changeCount)
                        .foregroundStyle(isSelected ? tokens.foreground.opacity(0.8) : tokens.mutedForeground)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(tokens.tertiaryWash, in: Capsule())
                }
            }
            .foregroundStyle(isSelected ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                isSelected
                    ? tokens.tertiaryWash
                    : (isHovered ? tokens.fillHover : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = $0 ? page : (hoveredTab == page ? nil : hoveredTab) }
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

    private var editorTabButton: some View {
        let page = WarrenDesktopRightSidebarTab.editor
        let isSelected = tab == page
        let isHovered = hoveredTab == page
        let showsClose = editorRunning && (isSelected || isHovered)
        // Not running reads quieter, as the spec draws it: it is a page the user
        // can start, not one that is live.
        let titleColor: Color = isSelected
            ? tokens.foreground
            : (editorRunning ? tokens.mutedForeground : tokens.mutedForeground.opacity(0.7))
        return HStack(spacing: 4) {
            Button {
                onSelectTab(page)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 10.5, weight: .medium))
                    Text("Editor")
                        .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                }
                .foregroundStyle(titleColor)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showsClose {
                Button(action: onCloseEditor) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isCloseHovered ? tokens.foreground : tokens.mutedForeground)
                        .frame(width: 16, height: 16)
                        .background(
                            isCloseHovered ? tokens.foreground.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
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
        }
        .padding(.leading, 8)
        .padding(.trailing, showsClose ? 4 : 8)
        // The close key widens the tab; it fades in as the tab grows to it.
        // The tab is the last before the spacer, so nothing else moves.
        .animation(
            WarrenMotion.animation(.feedback, reduceMotion: reduceMotion),
            value: showsClose
        )
        .frame(height: 26)
        .background(
            isSelected
                ? tokens.tertiaryWash
                : (isHovered ? tokens.fillHover : Color.clear),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(.rect)
        .onHover { hoveredTab = $0 ? page : (hoveredTab == page ? nil : hoveredTab) }
        .warrenTooltip("Embedded Editor")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor")
        .accessibilityValue(!editorRunning ? "Not running" : (isSelected ? "Selected" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "right-sidebar.tab.editor",
            role: .button,
            label: "Editor",
            value: editorRunning ? "Running" : "Not running",
            isSelected: isSelected,
            action: { onSelectTab(page) }
        )
    }

    private func externalIDEControl(_ control: ExternalIDE) -> some View {
        let background = control.isMenuPresented
            ? tokens.foreground.opacity(0.10)
            : (isIDEBodyHovered || isIDEChevronHovered ? tokens.fillHover : Color.clear)
        return HStack(spacing: 0) {
            Button(action: control.open) {
                Image(systemName: "macwindow")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 22, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!control.canOpen)
            .onHover { isIDEBodyHovered = $0 }

            Button(action: control.presentMenu) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .frame(width: 16, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isIDEChevronHovered = $0 }
            .accessibilityLabel("Choose editor")
        }
        .foregroundStyle(control.canOpen ? tokens.mutedForeground : tokens.mutedForeground.opacity(0.45))
        .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .warrenTooltip(control.name.map { "Open in \($0)" } ?? "Open in editor")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open in editor")
        .warrenSemanticElement(
            id: "right-sidebar.external-ide",
            role: .button,
            label: "Open in editor",
            value: control.name,
            isSelected: control.isMenuPresented,
            action: control.open
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
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(tokens.mutedForeground.opacity(0.8))
            Text("Embedded editor is not running")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.foreground.opacity(0.85))
            Button(action: open) {
                Text("Open Editor")
                    .font(.system(size: 12, weight: .medium))
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
