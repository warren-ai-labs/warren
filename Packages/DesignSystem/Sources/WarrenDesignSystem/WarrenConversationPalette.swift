import SwiftUI

/// The Conversation pane's color contract (RFC 0023, `chat-view.html`).
///
/// The transcript follows the workbench's neutral dark scale rather than the
/// kit's warm browns: `card #0B0B0B` is the pane, `raise #141414` is the
/// composer and every panel resting on it, `bubble #1C1C1C` marks the person's
/// message, and `code #111111` holds code and command output. The orange accent
/// is spent in exactly three places — a decision's outline, the "needs you"
/// status dot, and context over 85% — so it never reads as decoration.
///
/// Kept apart from `WarrenColorTokens` on purpose: the workbench's global
/// surface palette (popovers, chrome, inputs) has its own values and consumers,
/// and a chat-only restyle must not repaint the sidebar it sits beside.
public struct WarrenConversationPalette: Sendable {
    /// The pane ground the transcript scrolls on.
    public let card: Color
    /// The composer and the panels stacked on it.
    public let raise: Color
    /// The person's message bubble and inline code.
    public let bubble: Color
    /// Fenced code, command output, and a decision's command text.
    public let code: Color
    /// Separators and quiet rules.
    public let line: Color
    /// Control and card outlines.
    public let line2: Color
    /// Answer, person's message, composer text.
    public let ink: Color
    /// Step names, file paths, table cells.
    public let ink2: Color
    /// The work trail, reasoning, and chip labels.
    public let ink3: Color
    /// Placeholders, footer icons, and times.
    public let ink4: Color
    /// The outline a focused control lifts to.
    public let focus: Color
    /// The quote rule inside a message bubble.
    public let quote: Color
    /// Hover fill for quiet rows.
    public let hover: Color
    /// Pressed fill for quiet rows.
    public let press: Color
    /// The one attention hue: decisions, the "needs you" dot, context > 85%.
    public let accent: Color
    public let green: Color
    public let red: Color
    public let blue: Color

    /// The confirmed neutral dark scale from the design.
    public static let dark = WarrenConversationPalette(
        card: WarrenColorTokens.hex(0x0B0B_0B),
        raise: WarrenColorTokens.hex(0x1414_14),
        bubble: WarrenColorTokens.hex(0x1C1C_1C),
        code: WarrenColorTokens.hex(0x1111_11),
        line: WarrenColorTokens.hex(0x1F1F_1F),
        line2: WarrenColorTokens.hex(0x2E2E_2E),
        ink: WarrenColorTokens.hex(0xEDED_ED),
        ink2: WarrenColorTokens.hex(0xD4D4_D4),
        ink3: WarrenColorTokens.hex(0x8A8A_8A),
        ink4: WarrenColorTokens.hex(0x5C5C_5C),
        focus: WarrenColorTokens.hex(0x3A3A_3A),
        quote: WarrenColorTokens.hex(0x3A3A_3A),
        hover: WarrenColorTokens.hex(0x1414_14),
        press: WarrenColorTokens.hex(0x2626_26),
        accent: WarrenColorTokens.hex(0xE574_3A),
        green: WarrenColorTokens.hex(0x5FBF_7A),
        red: WarrenColorTokens.hex(0xE052_4A),
        blue: WarrenColorTokens.hex(0x6F9C_FF)
    )

    /// The paper scale from `lead-agent.html`. The person's bubble is #F2EFEC
    /// rather than the window's #EBE7E3 backdrop color, which made it read as
    /// a hole in the card.
    public static let light = WarrenConversationPalette(
        card: WarrenColorTokens.hex(0xFFFF_FF),
        raise: WarrenColorTokens.hex(0xFCFB_FA),
        bubble: WarrenColorTokens.hex(0xF2EF_EC),
        code: WarrenColorTokens.hex(0xF7F5_F3),
        line: WarrenColorTokens.hex(0xE6E1_DC),
        line2: WarrenColorTokens.hex(0xD9D3_CD),
        ink: WarrenColorTokens.hex(0x1C19_17),
        ink2: WarrenColorTokens.hex(0x3A34_2F),
        ink3: WarrenColorTokens.hex(0x6B65_60),
        ink4: WarrenColorTokens.hex(0x9A93_8C),
        // One step past line2, as Ember's #3A3A3A is past #2E2E2E, so a
        // focused composer still lifts its outline.
        focus: WarrenColorTokens.hex(0xC9C2_BB),
        quote: WarrenColorTokens.hex(0xD9D3_CD),
        hover: WarrenColorTokens.hex(0xF6F3_F0),
        press: WarrenColorTokens.hex(0xE6E1_DC),
        accent: WarrenColorTokens.hex(0xB752_2C),
        green: WarrenColorTokens.hex(0x2F7D_51),
        red: WarrenColorTokens.hex(0xB326_1E),
        blue: WarrenColorTokens.hex(0x1C6F_B8)
    )

    public static func resolved(for colorScheme: ColorScheme) -> Self {
        colorScheme == .light ? light : dark
    }
}
