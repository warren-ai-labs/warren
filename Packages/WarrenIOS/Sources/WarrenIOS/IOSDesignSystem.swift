import SwiftUI
import WarrenDesignSystem
import WarrenTransport
#if canImport(UIKit)
import UIKit
#endif

/// Functional interface copy is kept as localization keys instead of
/// eagerly-resolved `String` values. SwiftUI can then load a String Catalog
/// without changing the view hierarchy; dynamic Host/Agent payloads remain
/// ordinary strings and are never treated as translation keys.
public enum IOSCopy {
    public static func connectionTitle(for state: WarrenRemoteConnectionState) -> LocalizedStringKey {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .stopped: return "Offline"
        }
    }
}

/// Shared visual language for the native client.
///
/// The mobile surface deliberately uses the same flat Ember primitives as the
/// Web client. Cards are reserved for focused tasks (settings and sheets),
/// while navigation is expressed by rails, whitespace, and quiet separators.
public enum IOSTheme {
    // Keep iOS on the same semantic palette as Web/Desktop. The Dynamic Type
    // hierarchy below remains platform-native, while every color and
    // geometry primitive comes from WarrenDesignSystem.
    private static let tokens = WarrenColorTokens.dark
    public static let background = tokens.background
    public static let chrome = tokens.chromeSurface
    public static let raised = tokens.popoverSurface
    public static let input = tokens.inputSurface
    public static let muted = tokens.muted
    public static let ring = tokens.ring
    public static let focusRing = tokens.focusRing
    public static let strongBorder = tokens.ring
    public static let text = tokens.foreground
    public static let secondaryText = tokens.mutedForeground
    public static let tertiaryText = tokens.mutedForeground.opacity(0.68)
    public static let accent = tokens.highlight
    public static let accentSubtle = tokens.highlight.opacity(0.14)
    public static let amber = tokens.amber
    public static let green = tokens.success
    public static let yellow = tokens.warning
    public static let red = tokens.destructive
    public static let info = tokens.info
    public static let link = tokens.link
    /// Backward-compatible name for the status/info color. New views should
    /// use `info` for status and `link` for interactive text.
    public static let blue = tokens.info
    /// Conversation prose gets a slightly warm, softened white so it reads
    /// as content rather than competing with the surrounding chrome.
    public static let agentText = tokens.foreground.opacity(0.97)
    public static let separator = tokens.chromeDivider

    // Geometry follows the compact Web/Paseo rhythm rather than a stock
    // Form/List rhythm. Touch targets remain at least 44pt where interactive.
    public static let pagePadding = WarrenSpacing.standard
    public static let compactPadding = WarrenSpacing.medium
    public static let headerHeight = WarrenLayoutMetrics.topBarHeight + WarrenSpacing.standard
    public static let toolbarHeight = WarrenLayoutMetrics.mobileActionRowHeight
    public static let rowHeight = WarrenLayoutMetrics.mobileActionRowHeight
    public static let workspaceRowHeight = WarrenLayoutMetrics.mobileActionRowHeight + WarrenSpacing.compact
    public static let controlHeight = WarrenLayoutMetrics.mobileActionRowHeight
    public static let radius = WarrenRadius.base
    public static let smallRadius = WarrenRadius.medium

    public static func statusColor(_ activity: WarrenRemoteAgentActivity) -> Color {
        switch activity {
        case .ready: return green
        case .working: return amber
        case .blocked: return yellow
        case .stalled: return yellow
        case .failed: return red
        case .exited, .unknown: return secondaryText
        }
    }

    /// Attention is an independent Host signal. A ready/working status with
    /// an attention payload still uses the yellow attention color; failures
    /// remain red regardless of stale metadata from an older Host.
    public static func statusColor(_ status: WarrenRemoteAgentStatus) -> Color {
        if status.activity == .failed { return red }
        if status.attention != nil || status.activity == .blocked || status.activity == .stalled {
            return yellow
        }
        return statusColor(status.activity)
    }
}

/// Deliberate type hierarchy for the compact mobile surface. SF Pro remains
/// the default reading and control face. Mono is reserved for values that
/// are actually machine-shaped (commands, branches, cursors, and connection
/// metadata); a future wordmark may use its own display face without leaking
/// that treatment into ordinary navigation.
public enum IOSTypography {
    // Text styles, rather than fixed point sizes, let Dynamic Type preserve
    // the hierarchy on a small phone and an iPad. The default design is SF
    // Pro on Apple platforms.
    public static let pageTitle = Font.system(.title2, weight: .semibold)
    public static let screenTitle = Font.system(.title3, weight: .semibold)
    public static let navigationTitle = Font.system(.headline, weight: .semibold)
    /// Session chrome is intentionally quieter than a page heading. Keeping
    /// it on one line leaves the second line available for connection and
    /// branch context on a small phone.
    public static let sessionBarTitle = Font.system(.subheadline, weight: .semibold)
    public static let rowTitle = Font.system(.callout, weight: .medium)
    public static let sectionTitle = Font.system(.subheadline, weight: .semibold)
    public static let body = Font.system(.body, weight: .regular)
    public static let bodyEmphasis = Font.system(.callout, weight: .medium)
    public static let secondaryBody = Font.system(.callout, weight: .regular)
    /// Paseo's conversation measure is 16pt with generous line-height for mobile reading.
    /// `callout` maps to that size while retaining Dynamic Type scaling.
    public static let conversation = Font.system(.callout, weight: .regular)
    public static let conversationEmphasis = Font.system(.callout, weight: .medium)
    /// Agent prose stays in the standard SF Pro family so its text shape
    /// matches the surrounding conversation while retaining Dynamic Type.
    public static let agentConversation = Font.system(.callout, weight: .regular)
    public static let userMessage = Font.system(.callout, weight: .regular)
    /// Avenir Next gives the live activity cue a warmer editorial voice while
    /// leaving ordinary navigation and transcript text in SF Pro.
    public static let working = Font.custom("Avenir Next", size: 14, relativeTo: .subheadline).weight(.medium)
    public static let helper = Font.system(.footnote, weight: .regular)
    /// Composer text uses the same compact reading size as conversation
    /// messages so the caret and glyphs share one visual scale.
    public static let input = Font.system(.subheadline, weight: .regular)
    public static let button = Font.system(.subheadline, weight: .semibold)
    /// Provider labels are metadata, not a second heading for every reply.
    public static let messageSender = Font.system(.caption2, weight: .semibold)
    // Caption 2 is useful for purely numeric chrome, but it is too small for
    // translated labels and dense CJK glyphs. Human-readable metadata uses a
    // full caption so localization does not silently lower the legibility
    // floor.
    public static let label = Font.system(.caption, weight: .medium)
    public static let eyebrow = Font.system(.caption, weight: .semibold)
    /// Short state labels are UI chrome, while `metadata` below remains
    /// monospaced for paths, cursors, and provider identifiers.
    public static let status = Font.system(.caption, weight: .medium)
    public static let metadata = Font.system(.caption, design: .monospaced, weight: .regular)
    // Counts and cursor-like metrics are not prose; keeping them compact
    // preserves the dashboard rhythm without shrinking translated labels.
    public static let metric = Font.system(.caption2, design: .monospaced, weight: .medium)
    public static let code = Font.system(.footnote, design: .monospaced, weight: .regular)
    public static let codeBlock = Font.system(.footnote, design: .monospaced, weight: .regular)
}

public struct IOSSurfaceModifier: ViewModifier {
    private let color: Color
    private let radius: CGFloat
    private let border: Color

    public init(
        color: Color = IOSTheme.chrome,
        radius: CGFloat = IOSTheme.radius,
        border: Color = IOSTheme.ring.opacity(0.72)
    ) {
        self.color = color
        self.radius = radius
        self.border = border
    }

    public func body(content: Content) -> some View {
        content
            .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
    }
}

public extension View {
    func iosSurface(
        color: Color = IOSTheme.chrome,
        radius: CGFloat = IOSTheme.radius,
        border: Color = IOSTheme.ring.opacity(0.72)
    ) -> some View {
        modifier(IOSSurfaceModifier(color: color, radius: radius, border: border))
    }

    /// Lets natural-language content grow vertically instead of turning a
    /// translated string into an unexplained ellipsis. Use an explicit
    /// `lineLimit` only when the surrounding component has a deliberate
    /// compact contract (for example, a horizontal session tab rail).
    func iosNaturalWrap() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }

    /// Commands, paths, model identifiers, and code have an intrinsic LTR
    /// reading order even when the surrounding interface is RTL. Keeping
    /// this scope local lets the rest of the app mirror normally.
    func iosMachineText() -> some View {
        environment(\.layoutDirection, .leftToRight)
            .multilineTextAlignment(.leading)
    }

    /// Native sheets keep their system gesture and dismissal behavior, while
    /// sharing one detent/indicator/safe-area contract across dashboard,
    /// session, and Agent surfaces.
    func iosSheetPresentation(_ detents: PresentationDetent...) -> some View {
        presentationDetents(Set(detents))
            .presentationDragIndicator(.visible)
            .safeAreaPadding(.bottom, WarrenSpacing.small)
    }
}

public struct IOSStatusDot: View {
    public let color: Color
    public let size: CGFloat

    public init(color: Color, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The four built-in Session marks reuse the same SVG artwork as Desktop's
/// preset command bar. They live in the iOS package's asset catalog so the
/// native tab rail does not approximate provider branding with SF Symbols.
public struct IOSPresetIcon: View {
    private let presetID: String
    private let size: CGFloat

    public init(presetID: String, size: CGFloat = 18) {
        self.presetID = presetID
        self.size = size
    }

    public var body: some View {
        Image(assetName, bundle: .module)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .opacity(0.92)
            .scaleEffect(presetID == "codex" ? 1.35 : 1)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var assetName: String {
        switch presetID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "claude-code": return "preset-claude"
        case "codex": return "preset-codex-white"
        case "opencode", "open-code": return "preset-opencode"
        case "pi": return "preset-pi"
        case "qoder": return "preset-qoder"
        default: return "preset-shell"
        }
    }
}

/// A compact marker for Sessions that have an Agent activity state. Shell-only
/// Sessions keep using `IOSStatusDot`; this symbol makes Agent activity
/// distinguishable in scope lists without adding another status label.
public struct IOSAgentActivityMark: View {
    private let activity: WarrenRemoteAgentActivity
    private let attention: WarrenRemoteAgentAttention?
    private let slotSize: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        activity: WarrenRemoteAgentActivity,
        attention: WarrenRemoteAgentAttention? = nil,
        slotSize: CGFloat = 27
    ) {
        self.activity = activity
        self.attention = attention
        self.slotSize = slotSize
    }

    public var body: some View {
        let color = IOSTheme.statusColor(
            WarrenRemoteAgentStatus(activity: activity, attention: attention)
        )
        // A 20 Hz cadence keeps the working cue visible while avoiding a
        // 30 Hz invalidation for every Agent row during list scrolling.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !shouldPulse)) { timeline in
            let pulsePhase = animationPhase(at: timeline.date, duration: 1.25)
            ZStack {
                if shouldPulse && !reduceMotion {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .scaleEffect(webPingScale(for: pulsePhase))
                        .opacity(webPingOpacity(for: pulsePhase))
                }
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            .frame(width: slotSize, height: slotSize)
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var shouldPulse: Bool {
        iosAgentActivityShouldPulse(activity)
    }

    private func animationPhase(at date: Date, duration: TimeInterval) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return (elapsed.truncatingRemainder(dividingBy: duration) + duration)
            .truncatingRemainder(dividingBy: duration) / duration
    }

    /// Mirrors Web's `.activity.pulse::before` and `ping` keyframes:
    /// scale from 1 to 2 during the first 75% of a 1.25s cycle, then remain
    /// invisible until the next cycle.
    private func webPingScale(for phase: Double) -> CGFloat {
        1 + webPingProgress(for: phase)
    }

    private func webPingOpacity(for phase: Double) -> Double {
        1 - webPingProgress(for: phase)
    }

    private func webPingProgress(for phase: Double) -> Double {
        let progress = min(max(phase / 0.75, 0), 1)
        let inverse = 1 - progress
        // Cubic ease-out is the SwiftUI equivalent of Web's
        // cubic-bezier(0, 0, 0.2, 1) for this small indicator.
        return 1 - inverse * inverse * inverse
    }

    private var accessibilityLabel: String {
        if attention != nil { return "Agent needs attention" }
        switch activity {
        case .ready: return "Agent ready"
        case .working: return "Agent working"
        case .blocked: return "Agent waiting for input"
        case .stalled: return "Agent stalled"
        case .failed: return "Agent failed"
        case .exited: return "Agent exited"
        case .unknown: return "Agent status unknown"
        }
    }
}

/// Working is the sole animated Agent state. Blocked, attention, and failed
/// states stay static so the accompanying explanation remains easy to scan.
@inline(__always)
func iosAgentActivityShouldPulse(_ activity: WarrenRemoteAgentActivity) -> Bool {
    activity == .working
}

/// A compact status label with a moving highlight for active work. It is used
/// in the Agent composer so the activity cue stays at the bottom of the
/// session while Workspace and Session rails remain stable.
struct IOSShimmerText: View {
    private let title: String
    private let color: Color
    private let highlightColor: Color
    private let font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, color: Color, highlightColor: Color = Color.white.opacity(0.92), font: Font) {
        self.title = title
        self.color = color
        self.highlightColor = highlightColor
        self.font = font
    }

    var body: some View {
        if reduceMotion {
            Text(title)
                .font(font)
                .foregroundStyle(color)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let phase = shimmerPhase(at: timeline.date)
                // Match the Web shimmer's 220% background travelling from
                // left to right. A wide gradient keeps the warm base visible
                // on both sides of the highlight instead of producing a
                // narrow, doubled-looking yellow/white glyph.
                let start = -1.20 + phase * 2.40
                let end = start + 2.20
                Text(title)
                    .font(font)
                    // Keep the glyph in one render pass. Overlaying a second
                    // Text for the highlight made the warm base and white
                    // shimmer visibly double when SwiftUI rounded their
                    // fractional positions differently.
                    .foregroundStyle(LinearGradient(
                        stops: [
                            .init(color: color, location: 0),
                            .init(color: color, location: 0.38),
                            .init(color: highlightColor, location: 0.50),
                            .init(color: color, location: 0.62),
                            .init(color: color, location: 1),
                        ],
                        startPoint: UnitPoint(x: start, y: 0.5),
                        endPoint: UnitPoint(x: end, y: 0.5)
                    ))
            }
        }
    }

    private func shimmerPhase(at date: Date) -> Double {
        // Keep the highlight calm enough to read as a status cue rather than
        // a progress spinner. The Web Agent footer uses the same cadence.
        let duration = 3.2
        let elapsed = date.timeIntervalSinceReferenceDate
        return (elapsed.truncatingRemainder(dividingBy: duration) + duration)
            .truncatingRemainder(dividingBy: duration) / duration
    }
}

/// A quiet 44pt chrome control. It intentionally has no filled capsule: the
/// surrounding rail already provides the affordance in the Web surface.
public struct IOSIconButton: View {
    private let systemName: String
    private let label: String
    private let action: () -> Void

    public init(_ systemName: String, label: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.label = label
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(IOSTypography.button)
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A light-weight keyboard dismissal affordance. The surface intentionally
/// has no capsule or filled background: it sits beside the native safe-area
/// inset and should read as a quiet action rather than another toolbar.
public struct IOSKeyboardDismissButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(IOSTypography.button)
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Hide keyboard")
    }
}

public struct IOSSectionLabel: View {
    private let title: String
    private let count: Int?

    public init(_ title: String, count: Int? = nil) {
        self.title = title
        self.count = count
    }

    public var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(IOSTypography.eyebrow)
                .foregroundStyle(IOSTheme.secondaryText.opacity(0.74))
                .iosNaturalWrap()
                .layoutPriority(1)
            if let count {
                Text("\(count)")
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(IOSTheme.muted.opacity(0.4), in: Capsule())
            }
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.72))
                .frame(height: 1)
                .frame(minWidth: 8)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small project visual. Roster DTOs intentionally do not carry image
/// assets, so the deterministic letter tile remains stable across launches.
public struct IOSProjectIcon: View {
    private let name: String
    private let size: CGFloat

    public init(name: String, size: CGFloat = 22) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(IOSTheme.muted)
            Text(initial)
                .font(.system(size: max(10, size * 0.48), weight: .medium, design: .rounded))
                .foregroundStyle(IOSTheme.text)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(IOSTheme.ring.opacity(0.72), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init)?.uppercased() ?? "W"
    }
}

/// Shared heading for scope/settings pages. The root index uses its own
/// larger rail to match the Web mobile sidebar.
public struct IOSScreenHeading: View {
    public let title: String
    public let symbol: String
    public let subtitle: String?

    public init(title: String, symbol: String, subtitle: String? = nil) {
        self.title = title
        self.symbol = symbol
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IOSTypography.screenTitle)
                    .foregroundStyle(IOSTheme.text)
                    .lineLimit(2)
                    .iosNaturalWrap()
                    .layoutPriority(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(2)
                        .iosNaturalWrap()
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

public struct IOSBrandMark: View {
    private let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(IOSTheme.input)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .stroke(IOSTheme.ring, lineWidth: max(1, size / 34))
                }
            WarrenMarkStroke(points: [
                CGPoint(x: 673.2, y: 815.2), CGPoint(x: 883.8, y: 232.5),
                CGPoint(x: 788.2, y: 203.5), CGPoint(x: 638.8, y: 804.8),
            ])
            .fill(IOSTheme.text.opacity(0.72))
            WarrenMarkStroke(points: [
                CGPoint(x: 700.8, y: 799.5), CGPoint(x: 548.4, y: 278.1),
                CGPoint(x: 515.3, y: 285.9), CGPoint(x: 611.2, y: 820.5),
            ])
            .fill(IOSTheme.text)
            WarrenMarkStroke(points: [
                CGPoint(x: 517.4, y: 273.1), CGPoint(x: 168.8, y: 785.9),
                CGPoint(x: 247.2, y: 834.1), CGPoint(x: 546.4, y: 290.9),
            ])
            .fill(IOSTheme.text)
            WarrenMarkStroke(points: [
                CGPoint(x: 257.9, y: 813.7), CGPoint(x: 270.0, y: 219.3),
                CGPoint(x: 234.0, y: 216.7), CGPoint(x: 158.1, y: 806.3),
            ])
            .fill(IOSTheme.text.opacity(0.72))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Warren")
    }
}

private struct WarrenMarkStroke: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 1024
        let origin = CGPoint(x: rect.midX - 512 * scale, y: rect.midY - 512 * scale)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: origin.x + first.x * scale, y: origin.y + first.y * scale))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale))
        }
        path.closeSubpath()
        return path
    }
}

public struct IOSModeToggle: View {
    @Binding private var selection: IOSSessionDisplayMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedMode: String?
    private let isAgentSession: Bool
    private let hasAttention: Bool

    public init(
        selection: Binding<IOSSessionDisplayMode>,
        isAgentSession: Bool = true,
        hasAttention: Bool = false
    ) {
        _selection = selection
        self.isAgentSession = isAgentSession
        self.hasAttention = hasAttention
    }

    public var body: some View {
        if isAgentSession {
            HStack(spacing: 0) {
                modeButton(.terminal, symbol: "terminal", accessibilityLabel: "Terminal")
                    .padding(.trailing, 1)
                modeButton(.agent, symbol: "bubble.left.and.bubble.right", accessibilityLabel: hasAttention ? "Agent chat (needs attention)" : "Agent chat")
                    .overlay(alignment: .topTrailing) {
                        if hasAttention && selection == .terminal {
                            Circle()
                                .fill(IOSTheme.amber)
                                .frame(width: 7, height: 7)
                                .offset(x: -4, y: 4)
                        }
                    }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
            .background(IOSTheme.input, in: RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                    .stroke(IOSTheme.ring.opacity(0.72), lineWidth: 0.5)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func modeButton(
        _ mode: IOSSessionDisplayMode,
        symbol: String,
        accessibilityLabel: String
    ) -> some View {
        Button {
            selection = mode
        } label: {
            Image(systemName: symbol)
                .font(IOSTypography.button)
                .foregroundStyle(selection == mode ? IOSTheme.text : IOSTheme.secondaryText)
                .frame(width: 40, height: 40)
                .background(selection == mode ? IOSTheme.muted : .clear, in: RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                        .stroke(
                            focusedMode == mode.rawValue ? IOSTheme.focusRing : .clear,
                            lineWidth: focusedMode == mode.rawValue ? 1 : 0
                        )
                }
        }
        .buttonStyle(.plain)
        .focused($focusedMode, equals: mode.rawValue)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selection == mode ? .isSelected : [])
    }
}

public struct IOSKeyCap: View {
    private let title: String
    private let symbol: String?
    private let action: () -> Void
    private let isEnabled: Bool
    private let isSelected: Bool

    public init(
        title: String,
        symbol: String? = nil,
        isEnabled: Bool = true,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                } else {
                    Text(title)
                }
            }
            .font(IOSTypography.label)
            .foregroundStyle(isEnabled ? IOSTheme.text : IOSTheme.secondaryText.opacity(0.42))
            .frame(minWidth: 44, minHeight: 44)
            .background(
                isSelected ? IOSTheme.accentSubtle : IOSTheme.input,
                in: RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous)
                    .stroke(isSelected ? IOSTheme.accent.opacity(0.72) : IOSTheme.ring.opacity(isEnabled ? 0.72 : 0.32), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }
}

/// Lightweight tactile feedback for discrete user interactions.
@MainActor
public enum IOSHaptics {
    public static func selection() {
        #if os(iOS) && canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    public static func light() {
        #if os(iOS) && canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
}
