import SwiftUI
import WarrenDesignSystem

/// The quiet outlined `LEAD` word beside a Session's title (RFC 0024 §7).
///
/// It uses the sidebar's meta grey and a hairline outline, never a status hue:
/// the colour channels already mean "working" and "needs you", so ownership is
/// carried by the word alone. A Crew Session gets no mark.
struct WarrenDesktopLeadMark: View {
    var tokens: WarrenColorTokens
    var height: CGFloat = 15

    var body: some View {
        Text("LEAD")
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(tokens.sessionMetaIdleText)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tokens.ring, lineWidth: 1)
            )
            .accessibilityLabel("Lead Session")
            .accessibilityHidden(false)
    }
}
