import Foundation
import WarrenTransport

#if os(iOS) && canImport(ActivityKit)
@preconcurrency import ActivityKit
#endif

#if os(iOS) && canImport(UIKit)
import UIKit
#endif

/// The small state projection rendered by Warren's Session Live Activity.
///
/// This is deliberately a client-side snapshot. Live Activities can keep the
/// last useful Session state visible while iOS suspends the app, but they do not
/// keep a WebSocket or the app process running indefinitely.
public enum WarrenLiveActivityConnection: String, Codable, Hashable, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
    case stopped

    public init(_ state: WarrenRemoteConnectionState) {
        switch state {
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reconnecting: self = .reconnecting
        case .disconnected: self = .disconnected
        case .stopped: self = .stopped
        }
    }

    public var label: String {
        switch self {
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting"
        case .disconnected: return "Disconnected"
        case .stopped: return "Offline"
        }
    }
}

public struct WarrenLiveActivityState: Codable, Equatable, Hashable, Sendable {
    public let connection: WarrenLiveActivityConnection
    public let activeSessionCount: Int
    public let workingSessionCount: Int
    public let attentionSessionCount: Int
    public let currentSessionTitle: String?
    public let updatedAt: Date

    public init(
        connection: WarrenLiveActivityConnection,
        activeSessionCount: Int = 0,
        workingSessionCount: Int = 0,
        attentionSessionCount: Int = 0,
        currentSessionTitle: String? = nil,
        updatedAt: Date = .now
    ) {
        self.connection = connection
        self.activeSessionCount = max(0, activeSessionCount)
        self.workingSessionCount = max(0, workingSessionCount)
        self.attentionSessionCount = max(0, attentionSessionCount)
        let title = currentSessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentSessionTitle = title?.isEmpty == false ? title : nil
        self.updatedAt = updatedAt
    }
}

#if os(iOS) && canImport(ActivityKit)

/// Activity attributes shared by the iOS app and its WidgetKit extension.
public struct WarrenLiveActivityAttributes: ActivityAttributes, Codable, Hashable, Sendable {
    public typealias ContentState = WarrenLiveActivityState

    /// Session and Host names are local display metadata. Relay URLs and
    /// capabilities never enter the activity payload or the Dynamic Island UI.
    public let sessionID: String
    public let sessionTitle: String
    public let hostName: String

    public init(sessionID: String, sessionTitle: String, hostName: String) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.hostName = hostName
    }
}

#else

/// macOS and non-ActivityKit package builds retain the same Codable shape so
/// model tests and previews can exercise the projection without UIKit.
public struct WarrenLiveActivityAttributes: Codable, Hashable, Sendable {
    public typealias ContentState = WarrenLiveActivityState

    public let sessionID: String
    public let sessionTitle: String
    public let hostName: String

    public init(sessionID: String, sessionTitle: String, hostName: String) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.hostName = hostName
    }
}

#endif

/// Owns one Session Live Activity for the currently selected Session.
///
/// The coordinator is intentionally a no-op on platforms without ActivityKit;
/// this keeps the WarrenIOS package testable on macOS while the app target
/// gets the native Dynamic Island implementation on iOS 17.
@MainActor
public final class IOSLiveActivityCoordinator {
    /// Receives `(sessionID, hex push token)` whenever ActivityKit rotates the
    /// token. The app registers it with Relay over HTTPS; the callback is
    /// intentionally absent from the Widget extension and never enters the
    /// Dynamic Island payload.
    public var pushTokenHandler: (@MainActor (String, String) -> Void)?
    /// Called when the local Activity is ended (for example after changing
    /// the selected Session) so the Relay can drop its token registration.
    public var activityEndedHandler: (@MainActor (String) -> Void)?

#if os(iOS) && canImport(ActivityKit)
    private var activity: Activity<WarrenLiveActivityAttributes>?
    private var updateTask: Task<Void, Never>?
    private var pushTokenTask: Task<Void, Never>?
    private var lastSessionIdentity: String?
    private var lastState: WarrenLiveActivityState?
#endif

    public init() {}

    public func sync(
        sessionID: String,
        sessionTitle: String,
        hostName: String,
        state: WarrenLiveActivityState
    ) {
#if os(iOS) && canImport(ActivityKit)
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSessionID.isEmpty else {
            end()
            return
        }
        let normalizedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = normalizedTitle.isEmpty ? "Warren Session" : normalizedTitle
        let normalizedHostName = hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHostName.isEmpty else {
            end()
            return
        }

        let sessionIdentity = "\(normalizedHostName)\u{1F}\(normalizedSessionID)"
        if lastSessionIdentity != sessionIdentity {
            end()
            lastSessionIdentity = sessionIdentity
        }

        // `updatedAt` is useful to the extension but should not turn every
        // repeated projection into an ActivityKit update.
        if let lastState,
           lastState.connection == state.connection,
           lastState.activeSessionCount == state.activeSessionCount,
           lastState.workingSessionCount == state.workingSessionCount,
           lastState.attentionSessionCount == state.attentionSessionCount,
           lastState.currentSessionTitle == state.currentSessionTitle {
            return
        }
        lastState = state

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(
            state: state,
            staleDate: Date.now.addingTimeInterval(60 * 60),
            relevanceScore: state.connection == .connected ? 1 : 0.5
        )

        if let activity {
            updateTask?.cancel()
            updateTask = Task { [weak self, activity] in
                guard !Task.isCancelled else { return }
                await activity.update(content)
                await MainActor.run {
                    guard let self, self.updateTask != nil else { return }
                    self.updateTask = nil
                }
            }
            return
        }

        do {
            let requestedActivity = try Activity.request(
                attributes: WarrenLiveActivityAttributes(
                    sessionID: normalizedSessionID,
                    sessionTitle: resolvedTitle,
                    hostName: normalizedHostName,
                ),
                content: content,
                pushType: .token
            )
            activity = requestedActivity
            observePushTokenUpdates(for: requestedActivity, sessionID: normalizedSessionID)
        } catch {
            // Live Activities are optional UI. A denied authorization or a
            // system quota must never affect Relay connection handling.
            activity = nil
        }
#else
        _ = sessionID
        _ = sessionTitle
        _ = hostName
        _ = state
#endif
    }

    public func end() {
#if os(iOS) && canImport(ActivityKit)
        let endedSessionID = activity?.attributes.sessionID
        updateTask?.cancel()
        updateTask = nil
        pushTokenTask?.cancel()
        pushTokenTask = nil
        let activity = activity
        self.activity = nil
        lastSessionIdentity = nil
        lastState = nil
        if let endedSessionID {
            activityEndedHandler?(endedSessionID)
        }
        guard let activity else { return }
        Task { await activity.end(nil, dismissalPolicy: .default) }
#endif
    }

#if os(iOS) && canImport(ActivityKit)
    private func observePushTokenUpdates(
        for activity: Activity<WarrenLiveActivityAttributes>,
        sessionID: String
    ) {
        pushTokenTask?.cancel()
        pushTokenTask = Task { [weak self, activity] in
            for await data in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                let token = data.map { String(format: "%02x", $0) }.joined()
                guard !token.isEmpty else { continue }
                await MainActor.run {
                    guard let self, self.activity?.id == activity.id else { return }
                    self.pushTokenHandler?(sessionID, token)
                }
            }
        }
    }
#endif
}

/// Extends a Relay connection for the finite background execution window that
/// iOS grants to ordinary apps. It is deliberately not a fake indefinite
/// keepalive: when the system expires this task, the foreground transition
/// will reconnect the WebSocket.
@MainActor
public final class IOSRelayBackgroundKeepAlive {
#if os(iOS) && canImport(UIKit)
    private var taskIdentifier: UIBackgroundTaskIdentifier = .invalid
#endif

    public init() {}

    public var isActive: Bool {
#if os(iOS) && canImport(UIKit)
        return taskIdentifier != .invalid
#else
        return false
#endif
    }

    public func begin() {
#if os(iOS) && canImport(UIKit)
        guard taskIdentifier == .invalid else { return }
        taskIdentifier = UIApplication.shared.beginBackgroundTask(
            withName: "Warren Relay keep-alive"
        ) { [weak self] in
            self?.end()
        }
#endif
    }

    public func end() {
#if os(iOS) && canImport(UIKit)
        guard taskIdentifier != .invalid else { return }
        let identifier = taskIdentifier
        taskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
#endif
    }
}
