import SwiftUI

/// The single state precedence used by every interactive Warren surface.
public enum WarrenInteractionState: Equatable, Sendable {
    case `default`
    case hovered
    case focused
    case selected
    case pressed
    case disabled

    public static func resolve(
        disabled: Bool,
        pressed: Bool,
        selected: Bool,
        focused: Bool,
        hovered: Bool
    ) -> Self {
        if disabled { return .disabled }
        if pressed { return .pressed }
        if selected { return .selected }
        if focused { return .focused }
        if hovered { return .hovered }
        return .default
    }
}

/// The one keyboard focus ring every Warren control draws: a hairline in
/// `focusRing` around the control's own shape.
///
/// Controls used to stroke their own rings, and one surface drew it from
/// `ring` — a grey that sits at 1.6:1 on paper, no louder than an unfocused
/// border. Drawing it here keeps the color, weight and shape in one place.
public struct WarrenFocusRingModifier: ViewModifier {
    public let isFocused: Bool
    public let cornerRadius: CGFloat
    public let lineWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    public init(
        isFocused: Bool,
        cornerRadius: CGFloat = WarrenRadius.small,
        lineWidth: CGFloat = 1
    ) {
        self.isFocused = isFocused
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
    }

    public func body(content: Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(isFocused ? tokens.focusRing : .clear, lineWidth: isFocused ? lineWidth : 0)
                    .allowsHitTesting(false)
            }
    }
}

public extension View {
    /// Strokes the shared keyboard focus ring around this view while
    /// `isFocused` is true. Pass the control's own corner radius so the ring
    /// follows its shape.
    func warrenFocusRing(
        _ isFocused: Bool,
        cornerRadius: CGFloat = WarrenRadius.small,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(WarrenFocusRingModifier(
            isFocused: isFocused,
            cornerRadius: cornerRadius,
            lineWidth: lineWidth
        ))
    }
}

private struct WarrenInteractiveBody: View {
    let configuration: ButtonStyle.Configuration
    let selected: Bool
    let focused: Bool
    let cornerRadius: CGFloat
    let pressedOpacity: Double
    /// Whether the pointer alone paints the row's background.
    ///
    /// The hover wash is what says a row navigates. A row that turns a click
    /// into nothing must not borrow it; the row is responsible for giving the
    /// pointer its feedback somewhere else.
    let showsHoverBackground: Bool
    /// Whether the button's own keyboard focus also draws the ring, on top of
    /// the caller's `focused`. `isFocused` here is the focus of the nearest
    /// focusable ancestor, which inside a button style is the button itself.
    let readsEnvironmentFocus: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var environmentFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var hovered = false

    var body: some View {
        // Resolved here rather than passed in: these styles draw in both
        // appearances, and a fixed palette lost the hover and selection washes
        // on paper.
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let state = WarrenInteractionState.resolve(
            disabled: !isEnabled,
            pressed: configuration.isPressed,
            selected: selected,
            focused: focused || (readsEnvironmentFocus && environmentFocused),
            hovered: hovered
        )
        configuration.label
            .background(background(for: state, tokens: tokens))
            .opacity(state == .disabled ? 0.42 : (state == .pressed ? pressedOpacity : 1))
            .clipShape(.rect(cornerRadius: cornerRadius))
            .warrenFocusRing(state == .focused, cornerRadius: cornerRadius)
            .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: state)
            .onHover { hovered = $0 }
    }

    private func background(for state: WarrenInteractionState, tokens: WarrenColorTokens) -> Color {
        if state == .hovered, !showsHoverBackground { return .clear }
        return tokens.interactionBackground(for: state)
    }
}

/// Shared row language for navigation, palette results, and other dense lists.
///
/// Selection is the neutral `fillSelected` wash and nothing else, like every
/// other navigation list. The accent is reserved for Agent activity and the
/// primary action, so a selected row carries no accent bar — one would also
/// read as the "needs you" color. Pressing a selected row keeps the same wash
/// and only dims, so the selection does not flicker under the pointer.
///
/// Row focus is caller-driven only: a list usually sits inside a focusable
/// container, whose focus would otherwise ring every row at once.
public struct WarrenInteractiveRowStyle: ButtonStyle {
    public var isSelected: Bool
    public var isFocused: Bool
    public var cornerRadius: CGFloat
    /// Set false for a row the pointer cannot activate; see
    /// `WarrenInteractiveBody.showsHoverBackground`.
    public var showsHoverBackground: Bool

    public init(
        isSelected: Bool = false,
        isFocused: Bool = false,
        cornerRadius: CGFloat = WarrenRadius.row,
        showsHoverBackground: Bool = true
    ) {
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.cornerRadius = cornerRadius
        self.showsHoverBackground = showsHoverBackground
    }

    public func makeBody(configuration: Configuration) -> some View {
        WarrenInteractiveBody(
            configuration: configuration,
            selected: isSelected,
            focused: isFocused,
            cornerRadius: cornerRadius,
            pressedOpacity: 0.82,
            showsHoverBackground: showsHoverBackground,
            readsEnvironmentFocus: false
        )
    }
}

/// Compact icon/text controls used in the window chrome.
///
/// The focus ring follows the button's own keyboard focus, so a caller does
/// not have to thread a `FocusState` through. `isFocused` is kept for callers
/// that already track focus elsewhere and is OR'd with it.
public struct WarrenChromeButtonStyle: ButtonStyle {
    public var isFocused: Bool

    public init(isFocused: Bool = false) {
        self.isFocused = isFocused
    }

    public func makeBody(configuration: Configuration) -> some View {
        WarrenInteractiveBody(
            configuration: configuration,
            selected: false,
            focused: isFocused,
            cornerRadius: WarrenRadius.small,
            pressedOpacity: 0.82,
            showsHoverBackground: true,
            readsEnvironmentFocus: true
        )
    }
}

/// Warren's neutral primary action, replacing the system blue prominent style.
public struct WarrenPrimaryButtonStyle: ButtonStyle {
    public var isFocused: Bool
    public var font: Font

    public init(isFocused: Bool = false, font: Font = WarrenTypography.body) {
        self.isFocused = isFocused
        self.font = font
    }

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration, isFocused: isFocused, font: font)
    }

    private struct PrimaryBody: View {
        let configuration: ButtonStyle.Configuration
        let isFocused: Bool
        let font: Font
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var environmentFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovered = false

        var body: some View {
            let tokens = WarrenColorTokens.resolved(for: colorScheme)
            let focused = isFocused || environmentFocused
            let state = WarrenInteractionState.resolve(
                disabled: !isEnabled,
                pressed: configuration.isPressed,
                selected: false,
                focused: focused,
                hovered: hovered
            )
            configuration.label
                .font(font)
                .foregroundStyle(tokens.background)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(fill(for: state, tokens: tokens))
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .warrenFocusRing(state == .focused)
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: state)
                .onHover { hovered = $0 }
        }

        /// Hover lifts the fill slightly even while the button holds focus,
        /// because focus outranks hover in the state order but the pointer
        /// still deserves an answer. Press and disabled own the look outright.
        private func fill(for state: WarrenInteractionState, tokens: WarrenColorTokens) -> Color {
            switch state {
            case .pressed:
                tokens.foreground.opacity(0.82)
            case .disabled:
                tokens.primary
            case .default, .hovered, .focused, .selected:
                hovered ? tokens.primary.opacity(0.88) : tokens.primary
            }
        }
    }
}
