import SwiftUI
import WarrenDesignSystem

/// A read-only detail card on the shared floating surface.
///
/// The Session title's hover card is one; a Host's detail card is meant to be
/// the same shape, so the label column and the monospaced values live here
/// rather than in either caller.
struct WarrenDesktopDetailCard: View {
    struct Row: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    /// The design's card width, inside the floating surface's own inset.
    static let width: CGFloat = 300

    let rows: [Row]

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.label)
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 62, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.foreground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
