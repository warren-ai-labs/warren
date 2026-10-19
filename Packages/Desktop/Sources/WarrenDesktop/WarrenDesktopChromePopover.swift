import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// Top-right workspace controls share one app-owned popover contract. A
/// control only reports which popover it wants; the window root owns
/// presentation, dismissal and outside clicks.
enum WarrenDesktopChromePopover: Hashable {
    /// The Host list, hanging from the sidebar's Host row.
    case hostPicker
    case externalIDE
    /// The "+" menu: the command presets.
    case newSession
}

/// Shared surface for a top-right chrome popover: the menu surface's radius,
/// border and elevation, a group header, and Escape to dismiss.
struct WarrenDesktopChromePopoverSurface<Content: View>: View {
    let title: String
    let width: CGFloat
    let onDismiss: () -> Void
    let content: Content

    init(
        title: String,
        width: CGFloat,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.width = width
        self.onDismiss = onDismiss
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenDesktopMenuGroupHeader(title: title)
            content
        }
        .warrenMenuSurface(width: width)
        .onExitCommand(perform: onDismiss)
    }
}

/// The external-editor menu, hanging from the right sidebar's tab row.
///
/// The embedded editor is a page of the sidebar now, so this menu is only the
/// outside editors: one row per installed application, the current one checked,
/// and a way through to Settings › Editors.
struct WarrenDesktopExternalIDEMenu: View {
    let options: [WarrenDesktopExternalIDEOption]
    let currentID: String?
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void
    let onManageEditors: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        WarrenDesktopChromePopoverSurface(
            title: "OPEN WORKSPACE IN",
            width: 220,
            onDismiss: onDismiss
        ) {
            WarrenDesktopExternalIDEPopoverContent(
                options: options,
                currentID: currentID,
                onOpen: onOpen,
                onManageEditors: onManageEditors,
                onDismiss: onDismiss
            )
        }
    }
}

struct WarrenDesktopExternalIDEPopoverContent: View {
    let options: [WarrenDesktopExternalIDEOption]
    /// The editor a plain click opens, checked in the list.
    let currentID: String?
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void
    let onManageEditors: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var hoveredID: String?

    private typealias Metrics = WarrenDesktopMenuMetrics

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(WarrenDesktopExternalIDEMenuPresentation.items(from: options)) { item in
                row(
                    id: item.id,
                    title: item.title,
                    isChecked: item.id == currentID,
                    palette: palette,
                    action: {
                        onOpen(item.option)
                        onDismiss()
                    }
                )
            }

            WarrenDesktopMenuDivider()

            Button(action: onManageEditors) {
                HStack(spacing: Metrics.iconSpacing) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(palette.icon)
                        .frame(width: Metrics.glyphSlot, height: Metrics.glyphSlot)
                        .accessibilityHidden(true)
                    Text("Manage Editors…")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.rowText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.rowHorizontalPadding)
                .frame(minHeight: Metrics.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenDesktopMenuRowStyle())
            .accessibilityLabel("Manage Editors")
            .warrenSemanticElement(
                id: "external-ide.manage",
                role: .button,
                label: "Manage Editors",
                action: onManageEditors
            )
        }
    }

    private func row(
        id: String,
        title: String,
        isChecked: Bool,
        palette: WarrenDesktopMenuPalette,
        action: @escaping () -> Void
    ) -> some View {
        let isHot = hoveredID == id
        return Button(action: action) {
            HStack(spacing: Metrics.checkSpacing) {
                WarrenDesktopMenuCheckColumn(isChecked: isChecked)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.rowHorizontalPadding)
            .frame(minHeight: Metrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .onHover { hoveredID = $0 ? id : (hoveredID == id ? nil : hoveredID) }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .warrenSemanticElement(
            id: "external-ide.\(id)",
            role: .button,
            label: title,
            isSelected: isChecked,
            action: action
        )
    }
}
