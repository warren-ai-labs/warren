import SwiftUI

/// The semantic role for an app-owned presentation surface. A view declares
/// its interaction intent here instead of selecting elevation or z-order by
/// implementation detail.
public enum WarrenPresentationRole: Sendable {
    case inline
    case popover
    case menu
    case modal
    case sheet
    case commandSurface
    case status
}

/// Shared in-window stacking order. Presentation coordinators choose these
/// layers; individual screen components must not invent local z-index values.
public enum WarrenPresentationLayer {
    public static let content: Double = 0
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
        case .popover, .menu, .commandSurface, .modal, .sheet:
            WarrenRadius.base
        }
    }

    public static func elevation(for role: WarrenPresentationRole) -> WarrenPresentationElevation {
        switch role {
        case .inline, .status:
            .init(opacity: 0, radius: 0, y: 0)
        case .popover:
            .init(opacity: 0.45, radius: 20, y: 12)
        case .menu:
            .init(opacity: 0.58, radius: 24, y: 14)
        case .modal, .commandSurface:
            .init(opacity: 0.5, radius: 35, y: 24)
        case .sheet:
            .init(opacity: 0.5, radius: 25, y: 14)
        }
    }
}

/// The dialog family's surface, border and shadow.
///
/// A dialog stands on the same ground as every other floating surface —
/// `popoverSurface`, which is opaque in the opaque material and the raised
/// glass tone in glass, in both appearances — with a `#262626` hairline and a
/// hairline of light along the top edge on Ember. It keeps a heavier single
/// shadow and the window scrim, because a dialog blocks rather than floats.
///
/// The ground used to be a fixed `#141414` on Ember only, so a glass dialog
/// was opaque in dark and translucent on paper.
enum WarrenDialogPalette {
    static func surface(for colorScheme: ColorScheme, tokens: WarrenColorTokens) -> Color {
        tokens.popoverSurface
    }

    static func border(for colorScheme: ColorScheme, tokens: WarrenColorTokens) -> Color {
        colorScheme == .light ? tokens.border : WarrenColorTokens.hex(0x2626_26)
    }

    static let highlight = Color.white.opacity(0.05)

    /// The confirmation red, one step brighter than the status token so a
    /// filled button reads as a button rather than as a dot.
    static func destructive(for colorScheme: ColorScheme, tokens: WarrenColorTokens) -> Color {
        colorScheme == .light ? tokens.destructive : WarrenColorTokens.hex(0xE052_4A)
    }

    static func shadow(for colorScheme: ColorScheme) -> (opacity: Double, radius: CGFloat, y: CGFloat) {
        colorScheme == .light ? (0.14, 40, 20) : (0.55, 56, 24)
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public init(
        role: WarrenPresentationRole = .popover,
        cornerRadius: CGFloat? = nil,
        showsBorder: Bool = true
    ) {
        self.role = role
        self.cornerRadius = cornerRadius
        self.showsBorder = showsBorder
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let resolvedCornerRadius = cornerRadius ?? WarrenPresentationMetrics.cornerRadius(for: role)
        if role == .modal || role == .sheet {
            dialogSurface(content, tokens: tokens, cornerRadius: resolvedCornerRadius)
        } else {
            let elevation = WarrenPresentationMetrics.elevation(for: role)
            let isElevatedModal = role == .commandSurface
            content
                .background {
                    // On glass every floating surface is one material: the same
                    // Ember tone as a raised surface, over an in-window blur so
                    // the content underneath — usually terminal text — cannot
                    // compete with the surface's own. Inline and status surfaces
                    // sit in the flow and do not float, so they take the tone
                    // without a blur.
                    if windowMaterial == .glass, Self.floats(role) {
                        ZStack {
                            Rectangle().fill(.regularMaterial)
                            tokens.popoverSurface
                        }
                    } else {
                        tokens.popoverSurface
                    }
                }
                .clipShape(.rect(cornerRadius: resolvedCornerRadius))
                .overlay {
                    if showsBorder {
                        RoundedRectangle(cornerRadius: resolvedCornerRadius)
                            .strokeBorder(
                                isElevatedModal ? tokens.border.opacity(0.9) : tokens.border,
                                lineWidth: WarrenSpacing.hairline
                            )
                    }
                }
                .shadow(
                    color: .black.opacity(colorScheme == .light ? min(elevation.opacity * 0.25, 0.14) : elevation.opacity),
                    radius: elevation.radius,
                    y: elevation.y
                )
        }
    }

    /// The blocking card: the dialog ground, a full hairline, a hairline of
    /// light along the top edge, and one heavier shadow.
    @ViewBuilder
    private func dialogSurface(
        _ content: Content,
        tokens: WarrenColorTokens,
        cornerRadius: CGFloat
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shadow = WarrenDialogPalette.shadow(for: colorScheme)
        content
            .background {
                if windowMaterial == .glass {
                    ZStack {
                        Rectangle().fill(.regularMaterial)
                        WarrenDialogPalette.surface(for: colorScheme, tokens: tokens)
                    }
                } else {
                    WarrenDialogPalette.surface(for: colorScheme, tokens: tokens)
                }
            }
            .clipShape(shape)
            .overlay {
                if showsBorder {
                    shape.strokeBorder(
                        WarrenDialogPalette.border(for: colorScheme, tokens: tokens),
                        lineWidth: WarrenSpacing.hairline
                    )
                }
            }
            .overlay(alignment: .top) {
                if colorScheme == .dark {
                    Rectangle()
                        .fill(WarrenDialogPalette.highlight)
                        .frame(height: 1)
                        .padding(.horizontal, cornerRadius)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }
}

extension WarrenPanelSurfaceModifier {
    static func floats(_ role: WarrenPresentationRole) -> Bool {
        switch role {
        case .inline, .status: false
        case .popover, .menu, .modal, .sheet, .commandSurface: true
        }
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

}

/// Full-window modal scrim shared by every custom dialog. The backdrop draws
/// `modalScrim`, the same token the command palette uses, so modal and palette
/// never disagree about how much of the app should recede.
public struct WarrenModalBackdrop<Content: View>: View {
    private let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial).modalScrim
                .ignoresSafeArea()
                .accessibilityHidden(true)
            content
        }
        .transition(.opacity)
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
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @FocusState private var isFocused: Bool

    public init(
        _ label: String,
        text: Binding<String>,
        placeholder: String = "",
        monospaced: Bool = true,
        focusOnAppear: Bool = false,
        labelFont: Font = WarrenTypography.dialogFieldLabel,
        inputFont: Font? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.monospaced = monospaced
        self.focusOnAppear = focusOnAppear
        self.labelFont = labelFont
        self.inputFont = inputFont ?? (monospaced ? WarrenTypography.code : WarrenTypography.dialogInput)
        self.onSubmit = onSubmit
    }

    public var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Text(label)
                .font(labelFont)
                .foregroundStyle(tokens.mutedForeground)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(inputFont)
                .focused($isFocused)
                .padding(.horizontal, WarrenSpacing.compact)
                .frame(minHeight: 32)
                .background(tokens.inputSurface)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .strokeBorder(
                            isFocused ? tokens.focusRing : WarrenDialogPalette.border(for: colorScheme, tokens: tokens),
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
        // The button's own keyboard focus, OR'd with the caller's flag.
        @Environment(\.isFocused) private var environmentFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: isFocused || environmentFocused,
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
                        .strokeBorder(
                            state == .focused
                                ? tokens.focusRing
                                : WarrenDialogPalette.border(for: colorScheme, tokens: tokens),
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: state)
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
        // The button's own keyboard focus, OR'd with the caller's flag.
        @Environment(\.isFocused) private var environmentFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: isFocused || environmentFocused,
                hovered: hovered
            )
            configuration.label
                .font(font)
                .foregroundStyle(.white)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(
                    WarrenDialogPalette.destructive(for: colorScheme, tokens: tokens)
                        .opacity(state == .pressed ? 0.82 : 1)
                )
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .warrenFocusRing(state == .focused)
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: state)
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
        WarrenDialog(title, message: message, width: .s) {
            WarrenInputField(
                fieldLabel,
                text: $text,
                monospaced: false,
                focusOnAppear: true,
                labelFont: WarrenTypography.dialogFieldLabel,
                inputFont: WarrenTypography.dialogInput,
                onSubmit: onConfirm
            )
        } footer: {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    HStack(spacing: 6) {
                        Text("Cancel")
                        WarrenDialogKeycap("esc")
                    }
                }
                .buttonStyle(WarrenSecondaryButtonStyle(font: WarrenTypography.dialogAction))
                .keyboardShortcut(.cancelAction)
                Button(action: onConfirm) {
                    HStack(spacing: 6) {
                        Text(confirmLabel)
                        WarrenDialogKeycap(
                            WarrenDialogConfirmButtonStyle.keycap(isDestructive: isDestructive),
                            isOnPrimary: !isDestructive
                        )
                    }
                }
                .modifier(WarrenDialogConfirmButtonStyle(
                    isDestructive: isDestructive,
                    isEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ))
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
#if os(macOS)
        .onExitCommand(perform: onCancel)
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
