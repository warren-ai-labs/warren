import SwiftUI
#if os(macOS)
import AppKit
#endif

public enum WarrenMotionRole: Sendable {
    case feedback
    case stateChange
    case overlay
}

/// Motion policy shared by every Warren surface.
///
/// Geometry around native renderer hosts must switch without animation.
/// These roles are reserved for local feedback, content state, and overlays.
public enum WarrenMotion {
    public static let feedbackDuration: TimeInterval = 0.08
    public static let stateChangeDuration: TimeInterval = 0.14
    public static let overlayDuration: TimeInterval = 0.16
    public static let activityPulseDuration: TimeInterval = 1.2
    public static let spinnerFrameDuration: TimeInterval = 0.09

    public static func animation(
        _ role: WarrenMotionRole,
        reduceMotion: Bool
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        let duration = switch role {
        case .feedback: feedbackDuration
        case .stateChange: stateChangeDuration
        case .overlay: overlayDuration
        }
        return .easeOut(duration: duration)
    }
}

/// A stable status dot with an optional compositor-driven activity ring.
/// The ring is inserted only while work is active, so static warning and
/// failure states do not keep an infinite animation alive.
public struct WarrenStatusIndicator: View {
    private let color: Color
    private let isActive: Bool
    private let size: CGFloat
    private let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        color: Color,
        isActive: Bool = false,
        size: CGFloat = 7,
        accessibilityLabel: String
    ) {
        self.color = color
        self.isActive = isActive
        self.size = size
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ZStack {
            if isActive, !reduceMotion {
                WarrenStatusPulseRing(color: color, size: size)
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

#if os(macOS)
private struct WarrenStatusPulseRing: NSViewRepresentable {
    let color: Color
    let size: CGFloat

    func makeNSView(context: Context) -> WarrenStatusPulseView {
        WarrenStatusPulseView(color: NSColor(color), size: size)
    }

    func updateNSView(_ nsView: WarrenStatusPulseView, context: Context) {
        nsView.update(color: NSColor(color), size: size)
    }
}

/// Keeps the infinite activity pulse below SwiftUI's invalidation boundary.
/// A SwiftUI `repeatForever` animation makes the complete `NSHostingView`
/// participate in every display cycle; with activity markers in the sidebar
/// and tab bar that can starve the native terminal renderer. Core Animation
/// updates this layer on the compositor without re-evaluating the view graph.
@MainActor
final class WarrenStatusPulseView: NSView {
    static let animationKey = "warren.activity-pulse"

    private let pulseLayer = CALayer()
    private var pulseSize: CGFloat

    init(color: NSColor, size: CGFloat) {
        pulseSize = size
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: size, height: size)))
        wantsLayer = true
        layer?.masksToBounds = false
        pulseLayer.backgroundColor = color.withAlphaComponent(0.65).cgColor
        layer?.addSublayer(pulseLayer)
        updateGeometry()
        installAnimationIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: pulseSize, height: pulseSize)
    }

    override func layout() {
        super.layout()
        updateGeometry()
        installAnimationIfNeeded()
    }

    func update(color: NSColor, size: CGFloat) {
        let sizeChanged = pulseSize != size
        pulseSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.backgroundColor = color.withAlphaComponent(0.65).cgColor
        updateGeometry()
        CATransaction.commit()
        if sizeChanged {
            invalidateIntrinsicContentSize()
        }
        installAnimationIfNeeded()
    }

    private func updateGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.bounds = CGRect(x: 0, y: 0, width: pulseSize, height: pulseSize)
        pulseLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        pulseLayer.cornerRadius = pulseSize / 2
        CATransaction.commit()
    }

    private func installAnimationIfNeeded() {
        guard pulseLayer.animation(forKey: Self.animationKey) == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 1.9

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.75
        opacity.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = WarrenMotion.activityPulseDuration
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        pulseLayer.add(group, forKey: Self.animationKey)
    }
}
#else
private struct WarrenStatusPulseRing: View {
    let color: Color
    let size: CGFloat

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.65))
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 1.9 : 1)
            .opacity(expanded ? 0 : 0.75)
            .onAppear {
                withAnimation(
                    .easeOut(duration: WarrenMotion.activityPulseDuration)
                        .repeatForever(autoreverses: false)
                ) {
                    expanded = true
                }
            }
    }
}
#endif

/// Warren's single indeterminate loading mark: a 2x4 braille-style dot grid
/// with one dot lighting up and travelling clockwise around the ring.
/// Use it only where the user is actively waiting.
public struct WarrenBrailleSpinner: View {
    private let size: CGFloat
    private let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 18, accessibilityLabel: String = "Loading") {
        self.size = size
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let color = WarrenColorTokens.resolved(for: colorScheme).highlight
        Group {
            if reduceMotion {
                WarrenBrailleField(size: size, color: color, activeDot: nil)
            } else {
                WarrenSpinningBrailleField(size: size, color: color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct WarrenSpinningBrailleField: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: WarrenMotion.spinnerFrameDuration)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let step = Int(elapsed / WarrenMotion.spinnerFrameDuration) % WarrenBrailleField.dots.count
            WarrenBrailleField(size: size, color: color, activeDot: step)
        }
    }
}

private struct WarrenBrailleField: View {
    let size: CGFloat
    let color: Color
    let activeDot: Int?

    /// 2x4 grid in clockwise order, starting at the top-left.
    fileprivate static let dots: [CGPoint] = [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1),
        CGPoint(x: 1, y: 2),
        CGPoint(x: 1, y: 3),
        CGPoint(x: 0, y: 3),
        CGPoint(x: 0, y: 2),
        CGPoint(x: 0, y: 1),
    ]

    var body: some View {
        let dotSize = max(2, size * 0.15)
        let gap = dotSize * 0.65
        let restingOpacity = activeDot == nil ? 0.35 : 0.18
        ZStack {
            ForEach(Array(Self.dots.enumerated()), id: \.offset) { index, point in
                Circle()
                    .fill(color.opacity(activeDot == index ? 1 : restingOpacity))
                    .frame(width: dotSize, height: dotSize)
                    .offset(
                        x: (point.x - 0.5) * (dotSize + gap),
                        y: (point.y - 1.5) * (dotSize + gap)
                    )
            }
        }
        .frame(
            width: dotSize * 2 + gap,
            height: dotSize * 4 + gap * 3
        )
        .accessibilityHidden(true)
    }
}
