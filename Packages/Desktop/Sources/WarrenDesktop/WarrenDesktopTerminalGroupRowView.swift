import SwiftUI
import WarrenDesignSystem
import WarrenDomain

enum WarrenDesktopTerminalGroupEditorMode: Equatable {
    case create
    case edit(TerminalGroupID)

    var title: String {
        switch self {
        case .create: "New Terminal Group"
        case .edit: "Edit Terminal Group"
        }
    }
}

struct WarrenDesktopTerminalGroupRow: View {
    let group: WarrenDesktopTerminalGroup
    let isCollapsed: Bool
    let isSelected: Bool
    var containsSelection: Bool = false
    let isInteractionDisabled: Bool
    var showsSessionChildren: Bool = false
    var rowHeight: CGFloat = WarrenLayoutMetrics.sidebarProjectRowHeight
    let onSelect: () -> Void
    var onDoubleClick: (() -> Void)? = nil
    let onRename: () -> Void
    let onSetHome: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenForceHover) private var forceHover
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        if isCollapsed {
            collapsedRow
        } else {
            expandedRow
        }
    }

    private var collapsedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: onSelect) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "square.3.stack.3d")
                    .font(.system(size: 12, weight: .regular))
                if let mark = group.mark {
                    WarrenDesktopActivityIndicator(mark: mark)
                        .offset(x: 5, y: -3)
                }
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(WarrenInteractiveRowStyle(isSelected: isSelected, isFocused: isFocused))
        .disabled(isInteractionDisabled)
        .focused($isFocused)
        .frame(width: 32, height: 32)
        .foregroundStyle(tokens.mutedForeground)
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityLabel("Terminal group \(group.group.name)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "terminal-group.\(group.id.description)",
            role: .button,
            label: "Terminal group \(group.group.name)",
            value: isSelected ? "Selected" : "Not selected",
            isEnabled: !isInteractionDisabled,
            isSelected: isSelected,
            action: onSelect
        )
        .contextMenu {
            if !isInteractionDisabled { contextMenu }
        }
    }

    private var expandedRow: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        return Button(action: {
            guard !showsSessionChildren else { return }
            onSelect()
        }) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "square.3.stack.3d")
                    .font(.system(size: 12, weight: .regular))
                    .frame(
                        width: WarrenLayoutMetrics.sidebarRowIconSlotSize,
                        height: WarrenLayoutMetrics.sidebarRowIconSlotSize
                    )
                    .foregroundStyle(tokens.mutedForeground)
                    .accessibilityHidden(true)

                Text(group.group.name.isEmpty ? "Terminal Group" : group.group.name)
                    .font(WarrenTypography.sidebarContainerRow)
                    .foregroundStyle(
                        isSelected || containsSelection
                            ? tokens.workspaceSelectedText
                            : tokens.projectText
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text("(\(group.runningSessionCount))")
                    .font(WarrenTypography.navigationMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .opacity(isHovered || isFocused || forceHover ? 1 : 0)
                    .accessibilityHidden(true)

                if let mark = group.mark, !showsSessionChildren {
                    WarrenDesktopActivityIndicator(mark: mark)
                }

                Spacer(minLength: 0)
            }
            .padding(.leading, WarrenDesktopSidebarIndent.terminalGroup)
            .padding(.trailing, WarrenSpacing.compact)
            .frame(minHeight: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenInteractiveRowStyle(
            isSelected: isSelected,
            isFocused: isFocused,
            showsHoverBackground: !showsSessionChildren
        ))
        .disabled(isInteractionDisabled)
        .focused($isFocused)
        .foregroundStyle(tokens.projectText)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !isInteractionDisabled { onDoubleClick?() }
        })
        .accessibilityLabel("Terminal group \(group.group.name)")
        .accessibilityValue(terminalGroupAccessibilityValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .warrenSemanticElement(
            id: "terminal-group.\(group.id.description)",
            role: .button,
            label: "Terminal group \(group.group.name)",
            value: terminalGroupSemanticValue,
            isEnabled: !isInteractionDisabled,
            isSelected: isSelected,
            action: onSelect
        )
        .frame(maxWidth: .infinity, minHeight: rowHeight)
        .background(tokens.interactionBackground(for: .resolve(
            disabled: isInteractionDisabled,
            pressed: false,
            selected: isSelected,
            focused: isFocused,
            hovered: showsSessionChildren ? false : isHovered
        )))
        .clipShape(.rect(cornerRadius: WarrenRadius.row))
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .contextMenu {
            if !isInteractionDisabled { contextMenu }
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    private var terminalGroupSemanticValue: String {
        var values: [String] = []
        if containsSelection {
            values.append("Contains the selected session")
        }
        values.append(isSelected ? "Selected" : "Not selected")
        return values.joined(separator: " · ")
    }

    private var terminalGroupAccessibilityValue: String {
        var values: [String] = []
        if containsSelection {
            values.append("Contains the selected session")
        }
        values.append(
            "\(group.runningSessionCount) running terminal\(group.runningSessionCount == 1 ? "" : "s")"
        )
        values.append(isSelected ? "Selected" : "Not selected")
        return values.joined(separator: " · ")
    }

    @ViewBuilder
    private var contextMenu: some View {
        WarrenDesktopContextMenu([
            .button(title: "Rename Terminal Group", action: onRename),
            .button(title: "Set Default Home…", action: onSetHome),
            .divider,
            .button(title: "Delete Terminal Group…", destructive: true, action: onDelete),
        ])
    }
}

struct WarrenDesktopTerminalGroupEditor: View {
    let title: String
    @Binding var name: String
    @Binding var home: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            Text(title)
                .font(WarrenTypography.dialogTitle)
                .foregroundStyle(tokens.foreground)

            WarrenInputField(
                "Name",
                text: $name,
                placeholder: "Terminal group name",
                monospaced: false,
                focusOnAppear: true,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )

            WarrenInputField(
                "Default home",
                text: $home,
                placeholder: "Use host HOME",
                monospaced: false,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput
            )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onConfirm)
                    .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(WarrenSpacing.large)
        .frame(width: WarrenLayoutMetrics.compactDialogWidth)
        .onExitCommand(perform: onCancel)
    }
}
