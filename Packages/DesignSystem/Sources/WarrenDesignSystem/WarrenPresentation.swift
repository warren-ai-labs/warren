import SwiftUI

/// The semantic role for an app-owned presentation surface. A view declares
/// its interaction intent here instead of selecting elevation or z-order by
/// implementation detail.
public enum WarrenPresentationRole: Sendable {
    case inline
    case popover
    case modal
    case sheet
    case commandSurface
    case status
}

/// Shared in-window stacking order. Presentation coordinators choose these
/// layers; individual screen components must not invent local z-index values.
public enum WarrenPresentationLayer {
    public static let content: Double = 0
    public static let inlineOverlay: Double = 10
    public static let drawer: Double = 20
    public static let popover: Double = 30
    public static let commandSurface: Double = 40
    public static let modal: Double = 50
    public static let menu: Double = 60
}

public struct WarrenPresentationElevation: Sendable {
    public let opacity: Double
    public let radius: CGFloat
    public let y: CGFloat

    public init(opacity: Double, radius: CGFloat, y: CGFloat) {
        self.opacity = opacity
        self.radius = radius
        self.y = y
    }
}

/// Role-specific geometry and elevation values shared by the DesignSystem.
public enum WarrenPresentationMetrics {
    public static func cornerRadius(for role: WarrenPresentationRole) -> CGFloat {
        switch role {
        case .inline, .status:
            WarrenRadius.medium
        case .popover, .commandSurface:
            WarrenRadius.base
        case .modal, .sheet:
            WarrenRadius.large
        }
    }

    public static func elevation(for role: WarrenPresentationRole) -> WarrenPresentationElevation {
        switch role {
        case .inline, .status:
            .init(opacity: 0, radius: 0, y: 0)
        case .popover:
            .init(opacity: 0.45, radius: 20, y: 12)
        case .modal, .commandSurface:
            .init(opacity: 0.5, radius: 35, y: 24)
        case .sheet:
            .init(opacity: 0.5, radius: 25, y: 14)
        }
    }
}

/// Role-specific elevation for a floating Warren surface. The previous
/// panel-only primitive mapped every use to one shadow, which made a local
/// popover read as heavily as a blocking dialog.
public struct WarrenPanelSurfaceModifier: ViewModifier {
    public let role: WarrenPresentationRole
    public let cornerRadius: CGFloat?
    public let showsBorder: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(
        role: WarrenPresentationRole = .popover,
        cornerRadius: CGFloat? = nil,
        showsBorder: Bool = true
    ) {
        self.role = role
        self.cornerRadius = cornerRadius
        self.showsBorder = showsBorder
    }

    public func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let resolvedCornerRadius = cornerRadius ?? WarrenPresentationMetrics.cornerRadius(for: role)
        let elevation = WarrenPresentationMetrics.elevation(for: role)
        content
            .background(tokens.popoverSurface)
            .clipShape(.rect(cornerRadius: resolvedCornerRadius))
            .overlay {
                if showsBorder {
                    RoundedRectangle(cornerRadius: resolvedCornerRadius)
                        .stroke(tokens.border, lineWidth: WarrenSpacing.hairline)
                }
            }
            .shadow(
                color: .black.opacity(elevation.opacity),
                radius: elevation.radius,
                y: elevation.y
            )
    }
}

public extension View {
    /// Applies a semantic app-owned surface with its prescribed background,
    /// radius, border and elevation.
    func warrenPresentationSurface(
        role: WarrenPresentationRole,
        cornerRadius: CGFloat? = nil,
        showsBorder: Bool = true
    ) -> some View {
        modifier(WarrenPanelSurfaceModifier(
            role: role,
            cornerRadius: cornerRadius,
            showsBorder: showsBorder
        ))
    }

    /// Backward-compatible shorthand for local popovers and compact panels.
    func warrenPanelSurface(
        cornerRadius: CGFloat = WarrenRadius.base,
        showsBorder: Bool = true
    ) -> some View {
        warrenPresentationSurface(
            role: .popover,
            cornerRadius: cornerRadius,
            showsBorder: showsBorder
        )
    }
}

/// Full-window modal scrim shared by every custom dialog. The backdrop uses
/// the same 50% black scrim as the command palette so modal and palette
/// never disagree about how much of the app should recede.
public struct WarrenModalBackdrop<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            content
        }
        .transition(.opacity)
    }
}

/// Blocking compact surface for editable, destructive and decision-oriented
/// flows. Backdrop clicks deliberately do nothing: a modal must never discard
/// a user's input by accident.
public struct WarrenModalSurface<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat

    public init(
        cornerRadius: CGFloat = WarrenRadius.large,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        WarrenModalBackdrop {
            content
                .warrenPresentationSurface(role: .modal, cornerRadius: cornerRadius)
        }
    }
}

/// Blocking wide surface for multi-row selection and short review flows.
/// The parent owns dismissal, so sheets keep the same explicit cancellation
/// contract as modals unless a caller intentionally supplies another action.
public struct WarrenSheetSurface<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat

    public init(
        cornerRadius: CGFloat = WarrenRadius.large,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        WarrenModalBackdrop {
            content
                .warrenPresentationSurface(role: .sheet, cornerRadius: cornerRadius)
        }
    }
}

/// Labeled input field with the Warren surface language: sunken input
/// background, subtle border, small radius and an accent focus ring.
public struct WarrenInputField: View {
    private let label: String
    private let placeholder: String
    private let monospaced: Bool
    private let focusOnAppear: Bool
    private let onSubmit: (() -> Void)?
    private let labelFont: Font
    private let inputFont: Font

    @Binding private var text: String
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        monospaced: Bool = true,
        focusOnAppear: Bool = false,
        labelFont: Font = WarrenTypography.bodyEmphasis,
        inputFont: Font? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.monospaced = monospaced
        self.focusOnAppear = focusOnAppear
        self.labelFont = labelFont
        self.inputFont = inputFont ?? (monospaced ? WarrenTypography.code : WarrenTypography.body)
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text(label)
                .font(labelFont)
                .foregroundStyle(tokens.mutedForeground)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(inputFont)
                .focused($isFocused)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(minHeight: 30)
                .background(tokens.inputSurface)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(
                            isFocused ? tokens.highlight : tokens.border,
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .onSubmit {
                    onSubmit?()
                }
                .accessibilityLabel(label)
        }
        .onAppear {
            if focusOnAppear {
                isFocused = true
            }
        }
    }
}

/// Quiet bordered action used for Cancel and non-emphasized dialog actions.
public struct WarrenSecondaryButtonStyle: ButtonStyle {
    public var isFocused: Bool
    public var font: Font

    public init(isFocused: Bool = false, font: Font = WarrenTypography.body) {
        self.isFocused = isFocused
        self.font = font
    }

    public func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, isFocused: isFocused, font: font)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let isFocused: Bool
        let font: Font
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.dark
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: isFocused,
                hovered: hovered
            )
            configuration.label
                .font(font)
                .foregroundStyle(tokens.foreground)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(
                    state == .pressed
                        ? tokens.fillSelected
                        : (state == .hovered ? tokens.fillHover : Color.clear)
                )
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(
                            state == .focused ? tokens.focusRing : tokens.border,
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state)
                .onHover { hovered = $0 }
        }
    }
}

/// Filled destructive action used by deletion confirmations.
public struct WarrenDestructiveButtonStyle: ButtonStyle {
    public var isFocused: Bool
    public var font: Font

    public init(isFocused: Bool = false, font: Font = WarrenTypography.bodyEmphasis) {
        self.isFocused = isFocused
        self.font = font
    }

    public func makeBody(configuration: Configuration) -> some View {
        DestructiveBody(configuration: configuration, isFocused: isFocused, font: font)
    }

    private struct DestructiveBody: View {
        let configuration: Configuration
        let isFocused: Bool
        let font: Font
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.dark
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: isFocused,
                hovered: hovered
            )
            configuration.label
                .font(font)
                .foregroundStyle(.white)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(
                    state == .pressed
                        ? tokens.destructive.opacity(0.82)
                        : tokens.destructive
                )
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(
                            state == .focused ? tokens.focusRing : Color.clear,
                            lineWidth: state == .focused ? 1 : 0
                        )
                }
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state)
                .onHover { hovered = $0 }
        }
    }
}

/// Reusable text-input dialog with the shared modal surface: scrim, panel,
/// visible label, focus on open, Return to confirm and Escape to cancel.
public struct WarrenTextInputDialog: View {
    public let title: String
    public let message: String
    public let fieldLabel: String
    public let confirmLabel: String
    public let isDestructive: Bool
    public let onCancel: () -> Void
    public let onConfirm: () -> Void

    @Binding public var text: String
    @Environment(\.colorScheme) private var colorScheme

    public init(
        title: String,
        message: String,
        fieldLabel: String,
        text: Binding<String>,
        confirmLabel: String = "Rename",
        isDestructive: Bool = false,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.fieldLabel = fieldLabel
        self._text = text
        self.confirmLabel = confirmLabel
        self.isDestructive = isDestructive
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenModalBackdrop {
            VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                Text(title)
                    .font(WarrenTypography.dialogTitle)
                    .foregroundStyle(tokens.foreground)

                Text(message)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                WarrenInputField(
                    fieldLabel,
                    text: $text,
                    monospaced: false,
                    focusOnAppear: true,
                    labelFont: WarrenTypography.dialogFieldLabel,
                    inputFont: WarrenTypography.dialogInput,
                    onSubmit: onConfirm
                )

                HStack(spacing: WarrenSpacing.compact) {
                    Spacer(minLength: 0)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                        .keyboardShortcut(.cancelAction)
                    if isDestructive {
                        Button(confirmLabel, action: onConfirm)
                            .buttonStyle(WarrenDestructiveButtonStyle(font: WarrenTypography.dialogCriticalAction))
                            .keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button(confirmLabel, action: onConfirm)
                            .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                            .keyboardShortcut(.defaultAction)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(WarrenSpacing.large)
            .frame(width: WarrenLayoutMetrics.compactDialogWidth)
        }
        .onExitCommand(perform: onCancel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// One-action modal for messages that used to escape into a platform-native
/// alert. Keeping it app-owned preserves the same typography, focus behavior
/// and in-window context as the action that triggered it.
public struct WarrenMessageDialog: View {
    public let title: String
    public let message: String
    public let actionLabel: String
    public let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    public init(
        title: String,
        message: String,
        actionLabel: String = "OK",
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.onDismiss = onDismiss
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenModalSurface {
            VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
                Text(title)
                    .font(WarrenTypography.dialogTitle)
                    .foregroundStyle(tokens.foreground)

                Text(message)
                    .font(WarrenTypography.dialogBody)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer(minLength: 0)
                    Button(actionLabel, action: onDismiss)
                        .buttonStyle(WarrenPrimaryButtonStyle(font: WarrenTypography.dialogAction))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(WarrenSpacing.large)
            .frame(width: WarrenLayoutMetrics.compactDialogWidth)
        }
        .onExitCommand(perform: onDismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
