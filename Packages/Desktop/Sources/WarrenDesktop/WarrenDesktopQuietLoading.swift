import SwiftUI
import WarrenDesignSystem
import WarrenObservation

/// The timing the two long waits share: connecting to a Host at launch, and
/// the in-app update that restarts Warren.
///
/// Both are waits the user did not ask to sit through, and both are usually
/// short. So neither says anything until the wait becomes noticeable, and then
/// it says it with one line where the content will be, not with a screen that
/// has to be taken away again.
enum WarrenDesktopLoadingReveal {
    /// A connect or a restart that beats this never shows a loading state.
    static let delay: Duration = .milliseconds(400)

    /// `overlayDuration` is the 0.16s the product already uses for a state
    /// that arrives over content, which keeps these two fades in step with
    /// every other quiet transition.
    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: WarrenMotion.overlayDuration)
    }
}

/// Shows its content only after `delay`, then fades it in.
///
/// The frame is held at full size the whole time, so revealing the mark never
/// moves what is already on screen.
struct WarrenDesktopDelayedReveal<Content: View>: View {
    var delay: Duration = WarrenDesktopLoadingReveal.delay
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        ZStack {
            if isRevealed {
                content()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            withAnimation(WarrenDesktopLoadingReveal.animation(reduceMotion: reduceMotion)) {
                isRevealed = true
            }
        }
    }
}

/// The quiet loading line: a small indeterminate mark and one sentence naming
/// what is happening.
///
/// No illustration and no empty-state wording. A launch is not a state of the
/// workspace, so the content card keeps the shape it will have once the Host
/// answers and only this line appears in it.
struct WarrenDesktopQuietLoadingMark: View {
    let title: String
    let elementID: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: 8) {
            WarrenBrailleSpinner(size: 13, accessibilityLabel: title)
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .warrenSemanticElement(id: elementID, role: .text, label: title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// The content card before the selected Host has answered.
///
/// The launch used to draw a full empty stage here — a 48pt tile, a title and
/// an explanation — and swapped it for real content the moment the roster
/// arrived. On a fast connect that read as a flash of "nothing here". Now the
/// card holds its ground and one line appears only if the wait is worth
/// mentioning.
struct WarrenDesktopConnectingStage: View {
    let title: String
    /// The line the tree exposes to the UI probes.
    static let elementID = "loading.connecting"

    var body: some View {
        WarrenDesktopDelayedReveal {
            WarrenDesktopQuietLoadingMark(title: title, elementID: Self.elementID)
        }
    }
}

/// The in-app update's loading state: the window stays as it is behind a
/// slight dim, with a compact capsule saying why it is not taking input.
///
/// The update replaces the application bundle and restarts Warren, so there is
/// no page to navigate to and nothing to explain at length. Dimming the one
/// window it owns is the whole of the takeover.
struct WarrenDesktopUpdateHUD: View {
    /// The line the tree exposes to the UI probes.
    static let elementID = "loading.update-restart"
    static let title = "Updating Warren…"

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        WarrenDesktopDelayedReveal {
            ZStack {
                // A third of the modal scrim: enough to say the window is
                // waiting, well short of the dim that announces a dialog.
                tokens.modalScrim
                    .opacity(0.35)
                    .ignoresSafeArea()
                HStack(spacing: 9) {
                    WarrenBrailleSpinner(size: 13, accessibilityLabel: Self.title)
                    Text(Self.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(tokens.foreground.opacity(0.92))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(shape.fill(tokens.popoverSurface))
                .overlay(shape.strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
                // The dim is deliberately slight, so the capsule carries the
                // lift itself rather than borrowing it from a dark backdrop.
                .shadow(
                    color: .black.opacity(colorScheme == .light ? 0.18 : 0.45),
                    radius: 18,
                    y: 8
                )
                .warrenSemanticElement(
                    id: Self.elementID,
                    role: .text,
                    label: Self.title
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.title)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}
