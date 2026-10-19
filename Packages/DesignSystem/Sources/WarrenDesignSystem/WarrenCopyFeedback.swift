import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What one copy put on the pasteboard.
public struct WarrenCopyReceipt: Equatable, Identifiable, Sendable {
    /// Where the confirmation is drawn.
    public enum Confirmation: Equatable, Sendable {
        /// The window's HUD chip. For copies whose control is gone by the time
        /// the text lands: a menu item, or a button the pointer revealed.
        case announced(label: String)
        /// The control that copied swaps its own glyph for a check, because it
        /// is still under the pointer. Nothing else is drawn.
        case inline(source: String)
    }

    public let id: UUID
    public let value: String
    public let confirmation: Confirmation
}

/// The single place a copy is written and confirmed.
///
/// Before this, every copy site wrote the pasteboard itself and most of them
/// confirmed nothing; the few that did each kept their own `copied` flag and
/// their own `asyncAfter` reset. One owner keeps one timer, so a second copy
/// replaces the first confirmation instead of racing it.
@MainActor
public final class WarrenCopyFeedback: ObservableObject {
    public static let shared = WarrenCopyFeedback()

    /// How long a confirmation stays up.
    public static let visibleDuration: TimeInterval = 1.5

    @Published public private(set) var receipt: WarrenCopyReceipt?

    private var retireTask: Task<Void, Never>?

    public init() {}

    /// Copies `text` and confirms it in the window's HUD, as `label`.
    public func copy(_ text: String, announcing label: String) {
        write(text, confirmation: .announced(label: label))
    }

    /// Copies `text` and confirms it on the control named `source`, which
    /// reads `confirms(_:)` to draw its check.
    public func copy(_ text: String, confirmingIn source: String) {
        write(text, confirmation: .inline(source: source))
    }

    /// Whether the control named `source` should show its check right now.
    public func confirms(_ source: String) -> Bool {
        receipt?.confirmation == .inline(source: source)
    }

    private func write(_ text: String, confirmation: WarrenCopyReceipt.Confirmation) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        let receipt = WarrenCopyReceipt(id: UUID(), value: text, confirmation: confirmation)
        self.receipt = receipt
        retireTask?.cancel()
        retireTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.receipt?.id == receipt.id else { return }
            self.receipt = nil
        }
    }
}

/// The window's copy confirmation: a dark chip near the bottom edge with a
/// check that draws itself, the label, and the copied value.
///
/// It stays dark in both appearances for the reason `hudSurface` gives. It
/// never takes a click, so it cannot sit in the way of what is under it.
public struct WarrenCopyFeedbackHUD: View {
    @ObservedObject private var feedback = WarrenCopyFeedback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        ZStack {
            if let receipt = feedback.receipt,
               case let .announced(label) = receipt.confirmation {
                WarrenCopyReceiptChip(label: label, value: receipt.value)
                    // A new copy is a new chip, so its check draws again.
                    .id(receipt.id)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: 6))
                    )
            }
        }
        .animation(
            WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)
                ?? .easeOut(duration: WarrenMotion.stateChangeDuration),
            value: feedback.receipt?.id
        )
        .allowsHitTesting(false)
    }
}

private struct WarrenCopyReceiptChip: View {
    let label: String
    let value: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: 8) {
            WarrenCheckGlyph()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(tokens.success, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tokens.hudForeground)
            Text(Self.preview(of: value))
                .font(WarrenTypography.monoSmall)
                .foregroundStyle(tokens.hudForeground.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 7)
        .background(tokens.hudSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .fixedSize()
        .onAppear {
            guard !reduceMotion else {
                drawn = true
                return
            }
            withAnimation(.easeOut(duration: 0.32).delay(0.06)) { drawn = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// The first line of what was copied; a multi-line copy would otherwise
    /// widen the chip to its longest line.
    static func preview(of value: String) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return firstLine.trimmingCharacters(in: .whitespaces)
    }
}

/// A check mark drawn as one stroke, so `trim` can draw it from its foot.
struct WarrenCheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.82))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.94, y: rect.minY + rect.height * 0.20))
        return path
    }
}
