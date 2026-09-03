import ActivityKit
import SwiftUI
import WidgetKit
import WarrenIOS

@main
struct WarrenLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WarrenLiveActivityAttributes.self) { context in
            SessionLiveActivityLockScreenView(
                attributes: context.attributes,
                state: context.state
            )
            .widgetURL(URL(string: "warren://session/\(context.attributes.sessionID)"))
            .activityBackgroundTint(SessionLiveActivityStyle.background)
            .activitySystemActionForegroundColor(SessionLiveActivityStyle.foreground)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .foregroundStyle(SessionLiveActivityStyle.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.currentSessionTitle ?? context.attributes.sessionTitle)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(context.attributes.hostName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SessionLiveActivityStyle.color(for: context.state.connection))
                            .frame(width: 7, height: 7)
                        Text(context.state.connection.label)
                        Spacer(minLength: 0)
                        Text(SessionLiveActivitySummary(state: context.state).text)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(SessionLiveActivityStyle.accent)
            } compactTrailing: {
                SessionLiveActivityStatusView(state: context.state)
            } minimal: {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundStyle(SessionLiveActivityStyle.color(for: context.state.connection))
            }
            .widgetURL(URL(string: "warren://session/\(context.attributes.sessionID)"))
        }
    }
}

private struct SessionLiveActivityLockScreenView: View {
    let attributes: WarrenLiveActivityAttributes
    let state: WarrenLiveActivityState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(SessionLiveActivityStyle.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.currentSessionTitle ?? attributes.sessionTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    SessionLiveActivityStatusView(state: state)
                    Text(SessionLiveActivitySummary(state: state).text)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.14, green: 0.13, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.currentSessionTitle ?? attributes.sessionTitle)
        .accessibilityValue("\(attributes.hostName), \(state.connection.label), \(SessionLiveActivitySummary(state: state).text)")
    }
}

private struct SessionLiveActivityBreathingDot: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                let phase = animationPhase(at: timeline.date, duration: 1.25)
                ZStack {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                        .scaleEffect(1.0 + pingProgress(for: phase) * 0.8)
                        .opacity(pingOpacity(for: phase))

                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(0.8), radius: 3)
                }
                .frame(width: 14, height: 14)
            }
        }
    }

    private func animationPhase(at date: Date, duration: TimeInterval) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return (elapsed.truncatingRemainder(dividingBy: duration) + duration)
            .truncatingRemainder(dividingBy: duration) / duration
    }

    private func pingProgress(for phase: Double) -> CGFloat {
        let activePortion = 0.75
        guard phase <= activePortion else { return 1.0 }
        return CGFloat(phase / activePortion)
    }

    private func pingOpacity(for phase: Double) -> Double {
        let activePortion = 0.75
        guard phase <= activePortion else { return 0.0 }
        return 1.0 - (phase / activePortion)
    }
}

private struct SessionLiveActivityStatusView: View {
    let state: WarrenLiveActivityState

    var body: some View {
        if state.workingSessionCount > 0 || state.attentionSessionCount > 0 {
            SessionLiveActivityBreathingDot(color: Color(red: 0.96, green: 0.69, blue: 0.24))
        } else {
            Circle()
                .fill(SessionLiveActivityStyle.color(for: state.connection))
                .frame(width: 6, height: 6)
        }
    }
}

private struct SessionLiveActivitySummary {
    let text: String

    init(state: WarrenLiveActivityState) {
        if state.attentionSessionCount > 0 {
            text = "Needs input"
        } else if state.workingSessionCount > 0 {
            text = "\(state.workingSessionCount) working"
        } else {
            let suffix = state.activeSessionCount == 1 ? "" : "s"
            text = "\(state.activeSessionCount) session\(suffix)"
        }
    }
}

private enum SessionLiveActivityStyle {
    static let background = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let foreground = Color.white
    static let accent = Color(red: 0.88, green: 0.47, blue: 0.31)

    static func color(for connection: WarrenLiveActivityConnection) -> Color {
        switch connection {
        case .connected: return Color(red: 0.35, green: 0.78, blue: 0.44)
        case .connecting, .reconnecting: return Color(red: 0.96, green: 0.69, blue: 0.24)
        case .disconnected: return Color(red: 0.95, green: 0.34, blue: 0.34)
        case .stopped: return .secondary
        }
    }

}
