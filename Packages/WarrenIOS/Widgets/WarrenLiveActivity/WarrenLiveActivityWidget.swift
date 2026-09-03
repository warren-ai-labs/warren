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
                DynamicIslandExpandedRegion(.trailing) {
                    SessionLiveActivityStatusView(state: context.state, compact: false)
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
                SessionLiveActivityStatusView(state: context.state, compact: true)
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
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SessionLiveActivityStyle.accent)
                Text(attributes.hostName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·")
                    .foregroundStyle(.secondary.opacity(0.6))
                Circle()
                    .fill(SessionLiveActivityStyle.color(for: state.connection))
                    .frame(width: 6, height: 6)
                Text(state.connection.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                SessionLiveActivityBadge(state: state)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(state.currentSessionTitle ?? attributes.sessionTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(SessionLiveActivitySummary(state: state).text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.14, green: 0.13, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }
}

private struct SessionLiveActivityBadge: View {
    let state: WarrenLiveActivityState

    var body: some View {
        HStack(spacing: 4) {
            if state.attentionSessionCount > 0 {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.96, green: 0.69, blue: 0.24))
                Text("Needs input")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(red: 0.96, green: 0.69, blue: 0.24))
            } else if state.workingSessionCount > 0 {
                Circle()
                    .fill(Color(red: 0.96, green: 0.69, blue: 0.24))
                    .frame(width: 5, height: 5)
                Text("Working")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color(red: 0.96, green: 0.69, blue: 0.24))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.44))
                Text("Ready")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

private struct SessionLiveActivityStatusView: View {
    let state: WarrenLiveActivityState
    let compact: Bool

    var body: some View {
        if compact {
            Text(compactText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(SessionLiveActivityStyle.color(for: state.connection))
                .lineLimit(1)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: SessionLiveActivityStyle.symbol(for: state.connection))
                    .foregroundStyle(SessionLiveActivityStyle.color(for: state.connection))
                Text(compactText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var compactText: String {
        if state.attentionSessionCount > 0 { return "!" }
        if state.workingSessionCount > 0 { return "\(state.workingSessionCount)" }
        return state.connection == .connected ? "✓" : "…"
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

    static func symbol(for connection: WarrenLiveActivityConnection) -> String {
        switch connection {
        case .connected: return "checkmark.circle.fill"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .disconnected: return "exclamationmark.triangle.fill"
        case .stopped: return "pause.circle.fill"
        }
    }
}
