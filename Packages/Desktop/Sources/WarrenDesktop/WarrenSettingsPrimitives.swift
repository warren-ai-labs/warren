import SwiftUI
import WarrenDesignSystem

/// A grouped settings card container with smooth continuous corners (12pt), subtle soft
/// surface fill lifted off the page, and delicate hairline border matching Synara & Superset.
public struct WarrenSettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let tokens: WarrenColorTokens
    private let content: Content

    public init(
        tokens: WarrenColorTokens = .dark,
        @ViewBuilder content: () -> Content
    ) {
        self.tokens = tokens
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(colorScheme == .light ? 0.85 : 0.40), lineWidth: WarrenSpacing.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous))
    }
}

/// Thin divider line between stacked rows inside a `WarrenSettingsCard`.
public struct WarrenSettingsCardDivider: View {
    @Environment(\.colorScheme) private var colorScheme
    private let tokens: WarrenColorTokens

    public init(tokens: WarrenColorTokens = .dark) {
        self.tokens = tokens
    }

    public var body: some View {
        Rectangle()
            .fill(tokens.border.opacity(colorScheme == .light ? 0.65 : 0.30))
            .frame(height: WarrenSpacing.hairline)
            .padding(.horizontal, WarrenSpacing.standard)
    }
}

/// A standard settings row inside a card: left-aligned title and description,
/// right-aligned interactive control (Toggle, Picker, Button, etc.).
public struct WarrenSettingsRow<Control: View>: View {
    private let title: String
    private let description: String?
    private let icon: String?
    private let tokens: WarrenColorTokens
    private let control: Control

    public init(
        _ title: String,
        description: String? = nil,
        subtitle: String? = nil,
        icon: String? = nil,
        tokens: WarrenColorTokens = .dark,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = description ?? subtitle
        self.icon = icon
        self.tokens = tokens
        self.control = control()
    }

    public init(
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        icon: String? = nil,
        tokens: WarrenColorTokens = .dark,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.description = subtitle ?? description
        self.icon = icon
        self.tokens = tokens
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: WarrenSpacing.large) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tokens.foreground)

                if let description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, 12)
    }
}

/// Clean section title and optional supporting description above a settings group.
public struct WarrenSettingsSectionHeader: View {
    private let title: String
    private let description: String?
    private let tokens: WarrenColorTokens

    public init(
        _ title: String,
        description: String? = nil,
        tokens: WarrenColorTokens = .dark
    ) {
        self.title = title
        self.description = description
        self.tokens = tokens
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tokens.foreground)

            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }
}

/// A sleek, modern textfield primitive with standard 32pt height, continuous rounded corners,
/// subtle background surface, and refined focus state matching Superset and Synara.
public struct WarrenSettingsInput: View {
    private let placeholder: String
    @Binding private var text: String
    private let isSecure: Bool
    private let monospaced: Bool
    private let tokens: WarrenColorTokens
    private let onSubmit: (() -> Void)?
    @FocusState private var isFocused: Bool

    public init(
        _ placeholder: String = "",
        text: Binding<String>,
        isSecure: Bool = false,
        monospaced: Bool = false,
        tokens: WarrenColorTokens = .dark,
        onSubmit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.monospaced = monospaced
        self.tokens = tokens
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: WarrenSpacing.small) {
            if isSecure {
                SecureField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(monospaced ? WarrenTypography.compactCode : .system(size: 12.5))
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            } else {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(monospaced ? WarrenTypography.compactCode : .system(size: 12.5))
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(tokens.inputSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isFocused ? tokens.highlight.opacity(0.65) : tokens.border.opacity(0.40),
                    lineWidth: WarrenSpacing.hairline
                )
        )
    }
}
