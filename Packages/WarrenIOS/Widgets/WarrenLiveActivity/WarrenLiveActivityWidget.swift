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
        }
    }
}

private struct SessionLiveActivityLockScreenView: View {
    let attributes: WarrenLiveActivityAttributes
    let state: WarrenLiveActivityState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title2)
                .foregroundStyle(SessionLiveActivityStyle.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.currentSessionTitle ?? attributes.sessionTitle)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(SessionLiveActivityStyle.color(for: state.connection))
                        .frame(width: 7, height: 7)
                    Text(state.connection.label)
                    Text("·")
                    Text(SessionLiveActivitySummary(state: state).text)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(attributes.hostName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
