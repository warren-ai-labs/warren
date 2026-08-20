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

private struct WarrenInteractiveBody: View {
    let configuration: ButtonStyle.Configuration
    let tokens: WarrenColorTokens
    let selected: Bool
    let focused: Bool
    let cornerRadius: CGFloat
    let pressedOpacity: Double

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let state = WarrenInteractionState.resolve(
            disabled: !isEnabled,
            pressed: configuration.isPressed,
            selected: selected,
            focused: focused,
            hovered: hovered
        )
        configuration.label
            .background(background(for: state))
            .opacity(state == .disabled ? 0.42 : (state == .pressed ? pressedOpacity : 1))
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(state == .focused ? tokens.focusRing : .clear, lineWidth: state == .focused ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state)
            .onHover { hovered = $0 }
    }

    private func background(for state: WarrenInteractionState) -> Color {
        tokens.interactionBackground(for: state)
    }
}

/// Shared row language for navigation, palette results, and other dense lists.
public struct WarrenInteractiveRowStyle: ButtonStyle {
    public var isSelected: Bool
    public var isFocused: Bool
    public var cornerRadius: CGFloat

    public init(isSelected: Bool = false, isFocused: Bool = false, cornerRadius: CGFloat = WarrenRadius.row) {
        self.isSelected = isSelected
        self.isFocused = isFocused
        self.cornerRadius = cornerRadius
    }

    public func makeBody(configuration: Configuration) -> some View {
        WarrenInteractiveBody(
            configuration: configuration,
            tokens: .dark,
            selected: isSelected,
            focused: isFocused,
            cornerRadius: cornerRadius,
            pressedOpacity: 0.82
        )
    }
}

/// Compact icon/text controls used in the window chrome.
public struct WarrenChromeButtonStyle: ButtonStyle {
    public var isFocused: Bool

    public init(isFocused: Bool = false) {
        self.isFocused = isFocused
    }

    public func makeBody(configuration: Configuration) -> some View {
        WarrenInteractiveBody(
            configuration: configuration,
            tokens: .dark,
            selected: false,
            focused: isFocused,
            cornerRadius: WarrenRadius.small,
            pressedOpacity: 0.82
        )
    }
}

/// Presets retain their selected/pressed wash without any scale animation.
public struct WarrenPresetButtonStyle: ButtonStyle {
    public var isFocused: Bool

    public init(isFocused: Bool = false) {
        self.isFocused = isFocused
    }

    public func makeBody(configuration: Configuration) -> some View {
        WarrenInteractiveBody(
            configuration: configuration,
            tokens: .dark,
            selected: false,
            focused: isFocused,
            cornerRadius: WarrenRadius.small,
            pressedOpacity: 0.82
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
                .foregroundStyle(tokens.background)
                .padding(.horizontal, WarrenSpacing.medium)
                .frame(minHeight: WarrenLayoutMetrics.compactControlHeight)
                .background(state == .pressed ? tokens.foreground.opacity(0.82) : tokens.primary)
                .clipShape(.rect(cornerRadius: WarrenRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small)
                        .stroke(state == .focused ? tokens.focusRing : .clear, lineWidth: state == .focused ? 1 : 0)
                }
                .opacity(state == .disabled ? 0.42 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: state)
                .onHover { hovered = $0 }
        }
    }
}
