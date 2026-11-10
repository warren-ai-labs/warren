import AppKit
import SwiftUI
import WarrenDomain
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
            WarrenLoadingIndicator(size: 13, accessibilityLabel: title)
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

/// The update's loading state, for the app and the Host alike: the window
/// stays as it is behind a slight dim, with one card saying why it is not
/// taking input.
///
/// This is the app replacing itself. It lasts seconds and the person cannot do
/// anything about it, so the card's job is to say three things in order: what is
/// happening, to which version, and what it means for the work they had open.
/// The mark is the app's own icon rather than a spinner: the thing being
/// replaced is the thing on the card.
struct WarrenDesktopUpdateHUD: View {
    /// The line the tree exposes to the UI probes.
    static let elementID = "loading.update-restart"
    static let title = "Updating Warren…"
    static let reassurance = "Sessions keep running. Warren reopens in a moment."
    /// Kept for the Host-restart wording, which has no version to name.
    static let lingeringDetail = "Your Sessions pick up where they were once it is back."

    /// A more specific line from the Host, when it gives one.
    var detail: String? = nil

    @AppStorage(WarrenPreferenceKey.appearanceAppIcon)
    private var appIconRawValue = WarrenAppIconColorway.defaultValue.rawValue

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isLingering = false

    private static let lingerDelay: Duration = .seconds(4)

    private var shownDetail: String? {
        isLingering ? Self.lingeringDetail : detail
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let surface = WarrenColorTokens.resolved(for: colorScheme).popoverSurface
        let elevation = WarrenPresentationMetrics.elevation(for: .popover)
        let shape = RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
        WarrenDesktopDelayedReveal {
            ZStack {
                // A third of the modal scrim: enough to say the window is
                // waiting, well short of the dim that announces a dialog.
                tokens.modalScrim
                    .opacity(0.35)
                    .ignoresSafeArea()
                VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
                    HStack(alignment: .center, spacing: WarrenSpacing.medium) {
                        appMark(tokens: tokens)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title)
                                .font(WarrenTypography.bodyEmphasis)
                                .foregroundStyle(tokens.foreground)
                            if let shownDetail {
                                Text(shownDetail)
                                    .font(WarrenTypography.settingsMeta)
                                    .foregroundStyle(tokens.mutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .transition(.opacity)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    Self.progress(tokens: tokens, reduceMotion: reduceMotion)

                    Text(Self.reassurance)
                        .font(WarrenTypography.footnote)
                        .foregroundStyle(tokens.ink4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(WarrenSpacing.large)
                .frame(width: 340, alignment: .leading)
                .background(shape.fill(surface))
                .overlay(shape.strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
                // The dim behind it is deliberately slight, so the card carries
                // its own lift: the popover rung of the elevation ladder, not a
                // number of its own.
                .shadow(
                    color: .black.opacity(elevation.opacity * (colorScheme == .light ? 0.4 : 1)),
                    radius: elevation.radius,
                    y: elevation.y
                )
                .animation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion), value: isLingering)
                .warrenSemanticElement(
                    id: Self.elementID,
                    role: .text,
                    label: Self.title
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Self.title)
                .accessibilityValue(shownDetail ?? Self.reassurance)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .task {
            try? await Task.sleep(for: Self.lingerDelay)
            guard !Task.isCancelled else { return }
            isLingering = true
        }
    }

    /// The app's own icon, at the size a list marker would be.
    @ViewBuilder
    private func appMark(tokens: WarrenColorTokens) -> some View {
        let colorway = WarrenAppIconColorway(storedValue: appIconRawValue)
        if let image = WarrenDesktopDockIcon.image(for: colorway) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                .fill(tokens.fillHover)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tokens.ink4)
                }
                .accessibilityHidden(true)
        }
    }

    /// A 3pt track with one segment sweeping across it.
    ///
    /// The updater does not report bytes, so the bar cannot claim a percentage;
    /// a sweep says "work is moving" without inventing progress. With reduce
    /// motion it settles into a still third of the track, which still reads as
    /// an unfinished bar.
    private static func progress(tokens: WarrenColorTokens, reduceMotion: Bool) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let segment = max(48, width * 0.3)
            ZStack(alignment: .leading) {
                Capsule().fill(tokens.fillHover)
                if reduceMotion {
                    Capsule()
                        .fill(tokens.foreground.opacity(0.45))
                        .frame(width: segment)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let period = 1.6
                        let phase = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: period) / period
                        Capsule()
                            .fill(tokens.foreground.opacity(0.45))
                            .frame(width: segment)
                            .offset(x: (width - segment) * phase)
                    }
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
