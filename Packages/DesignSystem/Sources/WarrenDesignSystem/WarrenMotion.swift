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
    /// The Agent-working cadence. Twice the standard period, because this state
    /// can last for minutes and only has to stay noticeable, not urgent.
    public static let quietActivityPulseDuration: TimeInterval = 2.4
    /// The selection plate as it slides between same-kind options. Slow enough
    /// to read as travel, damped enough not to bounce. Text colour settles
    /// faster so it never lags the plate.
    public static let selectionResponse: TimeInterval = 0.28
    public static let selectionDamping: Double = 0.82
    public static let selectionTextDuration: TimeInterval = 0.12

    public static func selection(reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return .easeInOut(duration: selectionTextDuration) }
        return .spring(
            response: selectionResponse,
            dampingFraction: selectionDamping,
            blendDuration: 0
        )
    }

    public static func animation(
        _ role: WarrenMotionRole,
        reduceMotion: Bool
    ) -> Animation? {
        guard !reduceMotion else { return nil }
        switch role {
        case .feedback:
            return .easeOut(duration: feedbackDuration)
        case .stateChange:
            return .easeOut(duration: stateChangeDuration)
        case .overlay:
            return .spring(response: 0.28, dampingFraction: 0.82, blendDuration: 0)
        }
    }
}

/// How loudly an activity ring reads.
///
/// `standard` is the connection/build cadence: a transport that is retrying or a
/// build that is running is a short-lived condition worth interrupting for.
///
/// `quiet` is for an Agent that is working. That is not short-lived and needs no
/// response, but it was drawn at the same volume — and motion outranks both
/// shape and color in peripheral vision, so "busy, leave it alone" was louder
/// than "halted, waiting on you". Slower, smaller, and fainter keeps "it is
/// alive" readable in the corner of the eye without competing for it.
public enum WarrenStatusPulseIntensity: Hashable, Sendable {
    case standard
    case quiet

    var duration: TimeInterval {
        switch self {
        case .standard: WarrenMotion.activityPulseDuration
        case .quiet: WarrenMotion.quietActivityPulseDuration
        }
    }

    var peakScale: CGFloat {
        switch self {
        case .standard: 1.9
        case .quiet: 1.7
        }
    }

    var peakOpacity: CGFloat {
        switch self {
        case .standard: 0.75
        case .quiet: 0.26
        }
    }
}

/// A stable status dot with an optional compositor-driven activity ring.
/// The ring is inserted only while work is active, so static warning and
/// failure states do not keep an infinite animation alive.
public struct WarrenStatusIndicator: View {
    private let color: Color
    private let isActive: Bool
    private let size: CGFloat
    private let intensity: WarrenStatusPulseIntensity
    private let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        color: Color,
        isActive: Bool = false,
        size: CGFloat = 7,
        intensity: WarrenStatusPulseIntensity = .standard,
        accessibilityLabel: String
    ) {
        self.color = color
        self.isActive = isActive
        self.size = size
        self.intensity = intensity
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        ZStack {
            if isActive, !reduceMotion {
                WarrenStatusPulseRing(color: color, size: size, intensity: intensity)
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
    let intensity: WarrenStatusPulseIntensity

    func makeNSView(context: Context) -> WarrenStatusPulseView {
        WarrenStatusPulseView(color: NSColor(color), size: size, intensity: intensity)
    }

    func updateNSView(_ nsView: WarrenStatusPulseView, context: Context) {
        nsView.update(color: NSColor(color), size: size, intensity: intensity)
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
    private var intensity: WarrenStatusPulseIntensity

    init(color: NSColor, size: CGFloat, intensity: WarrenStatusPulseIntensity = .standard) {
        pulseSize = size
        self.intensity = intensity
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

    func update(color: NSColor, size: CGFloat, intensity: WarrenStatusPulseIntensity = .standard) {
        let sizeChanged = pulseSize != size
        pulseSize = size
        // A cadence change has to replace the running animation, not wait for
        // the next one: `installAnimationIfNeeded` is a no-op while a key is
        // already attached.
        if self.intensity != intensity {
            self.intensity = intensity
            pulseLayer.removeAnimation(forKey: Self.animationKey)
        }
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
        scale.toValue = intensity.peakScale

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = intensity.peakOpacity
        opacity.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = intensity.duration
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
    let intensity: WarrenStatusPulseIntensity

    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color.opacity(0.65))
            .frame(width: size, height: size)
            .scaleEffect(expanded ? intensity.peakScale : 1)
            .opacity(expanded ? 0 : intensity.peakOpacity)
            .onAppear {
                withAnimation(
                    .easeOut(duration: intensity.duration)
                        .repeatForever(autoreverses: false)
                ) {
                    expanded = true
                }
            }
    }
}
#endif

/// Warren's single indeterminate loading mark: three small balls in one
/// neutral colour.
///
/// `.dots` lines them up and lets a soft pulse run through them left to right;
/// it is the mark for every wait the user is sitting through. `.triangle` sets
/// them on the corners of a triangle and glides each one to the next corner in
/// turn; it is reserved for an update, the one wait that takes over the window.
/// Neither takes the accent or any hue, so a spinner never reads as a status or
/// a call to action.
public struct WarrenLoadingIndicator: View {
    public enum Style: Sendable {
        case dots
        case triangle
    }

    private let style: Style
    private let size: CGFloat
    private let accessibilityLabel: String
    private let colorOverride: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// `color` is only for a mark on a filled control, where it takes the
    /// control's foreground; everywhere else the neutral loading colour applies.
    public init(
        _ style: Style = .dots,
        size: CGFloat = 18,
        color: Color? = nil,
        accessibilityLabel: String = "Loading"
    ) {
        self.style = style
        self.size = size
        self.colorOverride = color
        self.accessibilityLabel = accessibilityLabel
    }

    public var body: some View {
        let color = colorOverride ?? WarrenLoadingPalette.color(for: colorScheme)
        Group {
            if reduceMotion {
                WarrenLoadingBalls(style: style, size: size, color: color, phase: nil)
            } else {
                TimelineView(.animation) { context in
                    let period = style == .dots ? WarrenMotion.loadingDotsPeriod : WarrenMotion.loadingTrianglePeriod
                    let elapsed = context.date.timeIntervalSinceReferenceDate
                    WarrenLoadingBalls(
                        style: style,
                        size: size,
                        color: color,
                        phase: elapsed.truncatingRemainder(dividingBy: period) / period
                    )
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The loading colour: a soft graphite on light grounds and a soft silver on
/// dark ones, so the mark sits a step below the text it accompanies.
public enum WarrenLoadingPalette {
    public static func color(for colorScheme: ColorScheme) -> Color {
        colorScheme == .light ? Color(white: 0.36) : Color(white: 0.78)
    }
}

extension WarrenMotion {
    /// One pulse running through the three dots.
    public static let loadingDotsPeriod: TimeInterval = 1.4
    /// One full lap of the triangle: each ball reaches the next corner in a third of it.
    public static let loadingTrianglePeriod: TimeInterval = 3.6
}

/// One frame of the three balls. `phase` runs 0..<1 over a period; nil draws
/// the still mark reduced motion asks for.
struct WarrenLoadingBalls: View {
    let style: WarrenLoadingIndicator.Style
    let size: CGFloat
    let color: Color
    let phase: Double?

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let ball = Self.ball(style: style, index: index, size: size, phase: phase)
                Circle()
                    .fill(color)
                    .frame(width: ball.diameter, height: ball.diameter)
                    .scaleEffect(ball.scale)
                    .opacity(ball.opacity)
                    .offset(x: ball.center.x, y: ball.center.y)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    struct Ball: Equatable {
        var center: CGPoint
        var diameter: CGFloat
        var scale: CGFloat
        var opacity: Double
    }

    /// Where ball `index` sits at `phase`, as an offset from the frame's centre.
    static func ball(style: WarrenLoadingIndicator.Style, index: Int, size: CGFloat, phase: Double?) -> Ball {
        switch style {
        case .dots:
            let diameter = max(2, size * 0.2)
            let pitch = (size - diameter) / 2
            let center = CGPoint(x: CGFloat(index - 1) * pitch, y: 0)
            guard let phase else {
                return Ball(center: center, diameter: diameter, scale: 1, opacity: 0.7)
            }
            // A raised-cosine pulse, each dot a sixth of a period behind the
            // last. It breathes in size and strength rather than blinking.
            let local = (phase - Double(index) / 6).truncatingRemainder(dividingBy: 1)
            let wave = 0.5 - 0.5 * cos(2 * .pi * (local < 0 ? local + 1 : local))
            return Ball(center: center, diameter: diameter, scale: 0.8 + 0.2 * wave, opacity: 0.3 + 0.6 * wave)
        case .triangle:
            let diameter = max(2, size * 0.2)
            let corners = triangleCorners(size: size, diameter: diameter)
            guard let phase else {
                return Ball(center: corners[index], diameter: diameter, scale: 1, opacity: 0.9)
            }
            // Each ball starts on its own corner and glides to the next one.
            // The ease is smootherstep, so a move starts and settles with no
            // jolt and the three rest together at the corners.
            let progress = phase * 3
            let leg = Int(progress) % 3
            let t = progress - floor(progress)
            let eased = t * t * t * (t * (6 * t - 15) + 10)
            let from = corners[(index + leg) % 3]
            let to = corners[(index + leg + 1) % 3]
            let center = CGPoint(
                x: from.x + (to.x - from.x) * eased,
                y: from.y + (to.y - from.y) * eased
            )
            return Ball(center: center, diameter: diameter, scale: 1, opacity: 0.9)
        }
    }

    /// Top, bottom-right and bottom-left corners of an equilateral triangle
    /// that keeps every ball inside the frame.
    static func triangleCorners(size: CGFloat, diameter: CGFloat) -> [CGPoint] {
        let side = size - diameter
        let height = side * sqrt(3) / 2
        let top = -height / 2
        return [
            CGPoint(x: 0, y: top),
            CGPoint(x: side / 2, y: top + height),
            CGPoint(x: -side / 2, y: top + height),
        ]
    }
}
