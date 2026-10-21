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
/// `.cycle` is the mark for every wait the user is sitting through. It moves
/// through three states and back: the balls in a row with a pulse running
/// through them, the same row rising and falling as a wave, then the three
/// gathering into a triangle and gliding round it once before they line up
/// again. `.triangle` keeps them on the triangle the whole time; it is
/// reserved for an update, the one wait that takes over the window.
/// Neither takes the accent or any hue, so a spinner never reads as a status or
/// a call to action.
public struct WarrenLoadingIndicator: View {
    public enum Style: Sendable {
        case cycle
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
        _ style: Style = .cycle,
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
                    let period = style == .cycle ? WarrenMotion.loadingCyclePeriod : WarrenMotion.loadingTrianglePeriod
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
    /// One pass through the cycle's three states: pulse, wave, triangle.
    public static let loadingCyclePeriod: TimeInterval = WarrenLoadingCycle.period
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
        case .cycle:
            return WarrenLoadingCycle.ball(index: index, size: size, phase: phase)
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

/// The timeline of `WarrenLoadingIndicator.Style.cycle`.
///
/// Every state starts and ends with the balls at rest in the row (or, inside
/// the triangle, on their corners), so one state hands over to the next with no
/// jump. Each move eases with smootherstep and each pulse is a raised cosine,
/// so nothing starts or stops with a jolt.
enum WarrenLoadingCycle {
    static let pulse: TimeInterval = 1.75
    static let wave: TimeInterval = 1.75
    static let gather: TimeInterval = 0.65
    /// Three legs, so each ball comes back to the corner it gathered on.
    static let lap: TimeInterval = 2.25
    static let spread: TimeInterval = 0.65
    static let period = pulse + wave + gather + lap + spread

    /// Larger than the triangle's balls: in a row the cycle's mark sits inline
    /// beside text, and three dots at a fifth of a small frame read as noise.
    static let diameterRatio: CGFloat = 0.25
    /// How large a ball grows at the top of its pulse.
    static let pulseScale: CGFloat = 1.25
    static let restOpacity = 0.5
    static let triangleOpacity = 0.85

    /// Which corner each ball of the row gathers on: the outer two take the
    /// bottom corners on their own side and the middle one rises to the top,
    /// so no two paths cross.
    static let gatherCorner = [2, 0, 1]

    static func ball(index: Int, size: CGFloat, phase: Double?) -> WarrenLoadingBalls.Ball {
        let diameter = max(2.5, size * diameterRatio)
        // The row leaves room for a ball at the top of its pulse.
        let pitch = (size - diameter * pulseScale) / 2
        let row = CGPoint(x: CGFloat(index - 1) * pitch, y: 0)
        let corners = WarrenLoadingBalls.triangleCorners(size: size, diameter: diameter)
        let home = corners[gatherCorner[index]]
        guard let phase else {
            return .init(center: row, diameter: diameter, scale: 1, opacity: 0.7)
        }
        var t = phase.truncatingRemainder(dividingBy: 1) * period
        if t < 0 { t += period }

        if t < pulse {
            let lift = stagger(t / pulse, index: index)
            return .init(
                center: row,
                diameter: diameter,
                scale: 1 + (pulseScale - 1) * lift,
                opacity: restOpacity + (1 - restOpacity) * lift
            )
        }
        t -= pulse
        if t < wave {
            let lift = stagger(t / wave, index: index)
            // Rises about a third of the frame, well inside it.
            return .init(
                center: CGPoint(x: row.x, y: -pitch * 0.7 * lift),
                diameter: diameter,
                scale: 1,
                opacity: restOpacity + (1 - restOpacity) * lift
            )
        }
        t -= wave
        if t < gather {
            let eased = smootherstep(t / gather)
            return .init(
                center: mix(row, home, eased),
                diameter: diameter,
                scale: 1,
                opacity: restOpacity + (triangleOpacity - restOpacity) * eased
            )
        }
        t -= gather
        if t < lap {
            let progress = t / lap * 3
            let leg = min(2, Int(progress))
            let eased = smootherstep(progress - Double(leg))
            let start = (gatherCorner[index] + leg) % 3
            return .init(
                center: mix(corners[start], corners[(start + 1) % 3], eased),
                diameter: diameter,
                scale: 1,
                opacity: triangleOpacity
            )
        }
        t -= lap
        let eased = smootherstep(min(1, t / spread))
        return .init(
            center: mix(home, row, eased),
            diameter: diameter,
            scale: 1,
            opacity: triangleOpacity + (restOpacity - triangleOpacity) * eased
        )
    }

    /// A raised-cosine bump for ball `index`: each ball's bump takes 60% of
    /// the state and starts a fifth after the one before it, so all three are
    /// at rest when the state begins and ends.
    static func stagger(_ progress: Double, index: Int) -> Double {
        let local = (progress - Double(index) * 0.2) / 0.6
        guard local > 0, local < 1 else { return 0 }
        return 0.5 - 0.5 * cos(2 * .pi * local)
    }

    static func smootherstep(_ t: Double) -> Double {
        let t = max(0, min(1, t))
        return t * t * t * (t * (6 * t - 15) + 10)
    }

    static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
