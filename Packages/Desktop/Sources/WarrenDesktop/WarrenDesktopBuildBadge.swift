import AppKit
import SwiftUI
import WarrenDesignSystem

/// Build provenance read from the app bundle. `scripts/build-app.sh` stamps
/// `build-variant.txt` (`build` for debug previews, `release` for release
/// builds); `WARREN_BUILD_VARIANT` covers `swift run` sessions.
enum WarrenBuildVariant {
    static let isBuild: Bool = {
        if let url = Bundle.main.url(forResource: "build-variant", withExtension: "txt"),
           let value = try? String(contentsOf: url, encoding: .utf8) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines) == "build"
        }
        return ProcessInfo.processInfo.environment["WARREN_BUILD_VARIANT"] == "build"
    }()
}

/// Compact update state shown beside the build provenance marker.
public enum WarrenDesktopUpdateStatus: Equatable, Sendable {
    case none
    case available(version: String)
    case updating
    case failed

    var label: String? {
        switch self {
        case .none:
            nil
        case .available:
            "Update"
        case .updating:
            "Updating…"
        case .failed:
            "Failed"
        }
    }

    var isActionable: Bool {
        switch self {
        case .available, .failed:
            true
        case .none, .updating:
            false
        }
    }

    var accessibilityLabel: String? {
        switch self {
        case .none:
            nil
        case .available(let version):
            "New Warren version available: \(version)"
        case .updating:
            "Updating Warren"
        case .failed:
            "Warren update failed"
        }
    }

    var helpText: String? {
        switch self {
        case .none:
            nil
        case .available(let version):
            "Warren \(version) is ready to install. Click to install it."
        case .updating:
            "Warren is installing an update."
        case .failed:
            "The Warren update failed. Click to retry."
        }
    }
}

/// Small top-of-window marker that tells preview builds apart from release
/// installs when several Warren windows are open side by side.
struct WarrenDesktopBuildBadge: View {
    let updateStatus: WarrenDesktopUpdateStatus
    let showsBuildMarker: Bool
    /// Drops the reserved slot so the marker shrinks with its rail.
    ///
    /// The sidebar header is the first surface to run out of width when the
    /// rail is dragged narrow. A marker that refuses to compress does not
    /// truncate — it widens the sidebar's whole content column, and SwiftUI
    /// then centres that column inside the rail, so every row loses its
    /// leading edge. The footer keeps the reserved slot because its status chip
    /// must not wander as the label changes length.
    var isCompact: Bool
    let onUpdateAction: () -> Void

    init(
        updateStatus: WarrenDesktopUpdateStatus = .none,
        showsBuildMarker: Bool = true,
        isCompact: Bool = false,
        onUpdateAction: @escaping () -> Void = {}
    ) {
        self.updateStatus = updateStatus
        self.showsBuildMarker = showsBuildMarker
        self.isCompact = isCompact
        self.onUpdateAction = onUpdateAction
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @State private var isStatusHovered = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        HStack(spacing: WarrenSpacing.small) {
            if showsBuildMarker {
                Text("BUILD")
                    .fontWeight(.medium)
                    .foregroundStyle(tokens.amber)
                    .lineLimit(1)
            }

            // The compact form answers "is this a local build?" inside a narrow
            // rail, so it does not pad the marker out to the status slot.
            if showsBuildMarker, !isCompact {
                Spacer(minLength: WarrenSpacing.medium)
            }
            statusControl(tokens: tokens)
        }
        .font(WarrenTypography.sectionLabel)
        .tracking(1.0)
        .frame(minWidth: showsBuildMarker && !isCompact ? 132 : 0, alignment: .trailing)
        .frame(height: 28, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .help(helpText)
    }

    @ViewBuilder
    private func statusControl(tokens: WarrenColorTokens) -> some View {
        if let label = updateStatus.label {
            if updateStatus.isActionable {
                Button(action: onUpdateAction) {
                    statusLabel(label: label, tokens: tokens)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, WarrenSpacing.xs)
                .padding(.vertical, WarrenSpacing.xxs)
                .background(
                    color(for: updateStatus, tokens: tokens)
                        .opacity(isStatusHovered ? 0.10 : 0.04)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.xs)
                        .stroke(
                            color(for: updateStatus, tokens: tokens)
                                .opacity(isStatusHovered ? 0.45 : 0.20),
                            lineWidth: WarrenSpacing.hairline
                        )
                }
                .clipShape(.rect(cornerRadius: WarrenRadius.xs))
                .contentShape(.rect(cornerRadius: WarrenRadius.xs))
                .scaleEffect(isStatusHovered ? 1.01 : 1)
                .onHover { isStatusHovered = $0 }
                .animation(.easeOut(duration: WarrenMotion.feedbackDuration), value: isStatusHovered)
                .accessibilityLabel(updateStatus.accessibilityLabel ?? label)
                .accessibilityHint("Install or retry the Warren update")
            } else {
                statusLabel(label: label, tokens: tokens)
            }
        }
    }

    @ViewBuilder
    private func statusLabel(label: String, tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            switch updateStatus {
            case .available:
                WarrenStatusIndicator(
                    color: color(for: updateStatus, tokens: tokens),
                    isActive: true,
                    size: 4,
                    accessibilityLabel: "Update ready"
                )
            case .updating:
                WarrenLoadingIndicator(size: 10, accessibilityLabel: "Updating Warren")
            case .failed:
                EmptyView()
            case .none:
                EmptyView()
            }
            Text(label)
                .font(updateStatus == .failed
                    ? .system(size: 12, weight: .light)
                    : WarrenTypography.sectionLabel)
                .foregroundStyle(color(for: updateStatus, tokens: tokens))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func color(
        for status: WarrenDesktopUpdateStatus,
        tokens: WarrenColorTokens
    ) -> Color {
        switch status {
        case .none:
            tokens.mutedForeground
        case .available:
            tokens.info
        case .updating:
            tokens.amber
        case .failed:
            tokens.destructive
        }
    }

    private var helpText: String {
        ["This window is a locally built preview", updateStatus.helpText]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// The update state as one glyph at the sidebar's foot, beside the notice
/// bell. It is absent while there is nothing to say; otherwise its colour
/// and motion carry the state without a word:
///
/// - ready to install: an accent arrow with a slow halo, and a click
///   installs;
/// - installing: an amber arrow inside a ring that turns;
/// - failed: a red retry arrow, and a click retries.
struct WarrenDesktopUpdateIcon: View {
    let status: WarrenDesktopUpdateStatus
    let onAction: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    static let size: CGFloat = 28

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let tint = color(tokens: tokens)
        // Installing is not a button state, but it keeps the button so the
        // glyph is not dimmed the way a disabled control would be.
        Button(action: { if status.isActionable { onAction() } }) {
            glyph(tint: tint)
                .frame(width: Self.size, height: WarrenLayoutMetrics.tabPillHeight)
                .contentShape(.rect)
                .accessibilityHidden(true)
        }
        .buttonStyle(WarrenChromeButtonStyle())
        .frame(width: Self.size, height: WarrenLayoutMetrics.tabPillHeight)
        .warrenTooltip(status.helpText ?? "")
        .accessibilityLabel(status.accessibilityLabel ?? "")
        .accessibilityHint(status.isActionable ? "Install or retry the Warren update" : "")
        .warrenSemanticElement(
            id: "sidebar.update",
            role: .button,
            label: status.accessibilityLabel ?? "",
            isEnabled: status.isActionable,
            action: onAction
        )
        // Restart the motion whenever the state changes, so the installing
        // ring always starts from its own phase, and follow Reduce Motion as
        // it is switched rather than only as it stood when this appeared.
        .onAppear { isAnimating = !reduceMotion }
        .onChange(of: status) { _ in
            isAnimating = false
            DispatchQueue.main.async { isAnimating = !reduceMotion }
        }
        .onChange(of: reduceMotion) { isAnimating = !$0 }
    }

    @ViewBuilder
    private func glyph(tint: Color) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .available:
            // An update can wait for days, so the arrow itself holds still:
            // a SwiftUI `repeatForever` redraws the whole hosting view every
            // frame, which starves the terminal renderer. The motion is the
            // Core Animation pulse every activity dot uses, which also stops
            // the moment Reduce Motion is turned on.
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(tint)
                .background {
                    // A halo that swells out from behind the arrow.
                    WarrenStatusIndicator(
                        color: tint,
                        isActive: true,
                        size: 12,
                        intensity: .quiet,
                        accessibilityLabel: "Update ready"
                    )
                    .accessibilityHidden(true)
                }
        case .updating:
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.22), lineWidth: 1.5)
                // Turned by Core Animation, like the halo above: a SwiftUI
                // `repeatForever` would redraw the hosting view every frame.
                WarrenDesktopUpdateRing(color: tint, isAnimating: isAnimating)
                Image(systemName: "arrow.down")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(tint)
        }
    }

    private func color(tokens: WarrenColorTokens) -> Color {
        switch status {
        case .none: tokens.mutedForeground
        case .available: tokens.info
        case .updating: tokens.amber
        case .failed: tokens.destructive
        }
    }
}

/// The installing ring's arc. It turns on the compositor, below SwiftUI's
/// invalidation boundary, the way `WarrenStatusPulseView` pulses.
private struct WarrenDesktopUpdateRing: NSViewRepresentable {
    let color: Color
    let isAnimating: Bool

    func makeNSView(context: Context) -> WarrenDesktopUpdateRingView {
        let view = WarrenDesktopUpdateRingView(frame: .zero)
        view.update(color: NSColor(color), isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ nsView: WarrenDesktopUpdateRingView, context: Context) {
        nsView.update(color: NSColor(color), isAnimating: isAnimating)
    }
}

@MainActor
private final class WarrenDesktopUpdateRingView: NSView {
    private static let animationKey = "warren.update-ring"
    private static let lineWidth: CGFloat = 1.5
    /// The share of the circle the arc covers.
    private static let arcLength: CGFloat = 0.28
    private static let turnDuration: CFTimeInterval = 0.9

    private let arcLayer = CAShapeLayer()
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        arcLayer.fillColor = nil
        arcLayer.lineWidth = Self.lineWidth
        arcLayer.lineCap = .round
        arcLayer.strokeEnd = Self.arcLength
        layer?.addSublayer(arcLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks belong to the update button the ring sits in.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.frame = bounds
        // Centred on the frame's edge, like the SwiftUI track it turns on.
        arcLayer.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
        installAnimationIfNeeded()
    }

    func update(color: NSColor, isAnimating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.strokeColor = color.cgColor
        CATransaction.commit()
        self.isAnimating = isAnimating
        if isAnimating {
            installAnimationIfNeeded()
        } else {
            arcLayer.removeAnimation(forKey: Self.animationKey)
        }
    }

    private func installAnimationIfNeeded() {
        guard isAnimating, arcLayer.animation(forKey: Self.animationKey) == nil else { return }
        // A layer's y axis points up, so a clockwise turn is a negative angle.
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = Self.turnDuration
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arcLayer.add(turn, forKey: Self.animationKey)
    }
}
