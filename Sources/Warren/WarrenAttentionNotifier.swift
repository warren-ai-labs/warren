import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import WarrenDesktop
import WarrenDomain

/// Tells a person away from the window that an Agent is waiting on them: a
/// macOS notification per request and a count on the Dock icon.
///
/// The window already says the same thing with the sidebar dot and the "N
/// waiting" pill, so a notification is posted only while Warren is not the
/// active app. Each request alerts once and its notification is withdrawn as
/// soon as nobody is asking any more, whichever client answered. A request
/// whose decision this client holds can be answered from the notification;
/// the answer goes through the same Host request the approval tray sends.
@MainActor
final class WarrenAttentionNotifier: NSObject {
    static let shared = WarrenAttentionNotifier()

    private nonisolated static let sessionIDKey = "warrenSessionID"
    private nonisolated static let decisionIDKey = "warrenDecisionID"
    private nonisolated static let allowOptionKey = "warrenAllowOptionID"
    private nonisolated static let rejectOptionKey = "warrenRejectOptionID"
    private nonisolated static let allowAction = "warren.attention.allow"
    private nonisolated static let rejectAction = "warren.attention.reject"
    private static let answerableCategory = "warren.attention.answerable"

    /// Called with the Session a clicked notification belongs to.
    var onOpenSession: ((TerminalSessionID) -> Void)?
    /// Answers a decision: Session, decision id, option id.
    var onAnswer: ((TerminalSessionID, String, String) async throws -> Void)?

    private var tracker = WarrenDesktopAttentionAlertTracker()
    private var didRequestAuthorization = false
    private var didInstallCenter = false

    /// `UNUserNotificationCenter.current()` traps in a process without a
    /// bundle identifier, which is how `swift run` and the tests launch.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let center = UNUserNotificationCenter.current()
        if !didInstallCenter {
            didInstallCenter = true
            center.delegate = self
            // The action titles are generic because a category is registered
            // once; the notification's body names the actual request.
            let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
            let reject = UNNotificationAction(identifier: Self.rejectAction, title: "Reject", options: [.destructive])
            center.setNotificationCategories([
                UNNotificationCategory(
                    identifier: Self.answerableCategory,
                    actions: [allow, reject],
                    intentIdentifiers: [],
                    options: []
                ),
            ])
        }
        return center
    }

    /// Brings the badge and Notification Center in line with `alerts`, the
    /// current Host's waiting Sessions.
    func update(_ alerts: [WarrenDesktopAttentionAlert], defaults: UserDefaults = .standard) {
        updateBadge(count: alerts.count, defaults: defaults)
        let change = tracker.update(alerts)
        guard let center else { return }
        if !change.withdraw.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: change.withdraw.map(Self.identifier))
        }
        guard Self.alertsEnabled(defaults), !NSApp.isActive else { return }
        for alert in change.post {
            post(alert, center: center)
        }
    }

    private func updateBadge(count: Int, defaults: UserDefaults) {
        let enabled = Self.isOn(WarrenPreferenceKey.agentAttentionDockBadgeEnabled, defaults: defaults)
        let label = enabled && count > 0 ? String(count) : nil
        if NSApp.dockTile.badgeLabel != label {
            NSApp.dockTile.badgeLabel = label
        }
    }

    private func post(_ alert: WarrenDesktopAttentionAlert, center: UNUserNotificationCenter) {
        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.subtitle = alert.location
        content.body = alert.body
        content.sound = .default
        content.threadIdentifier = alert.sessionID.description
        var userInfo: [String: String] = [Self.sessionIDKey: alert.sessionID.description]
        if let answer = alert.quickAnswer {
            content.categoryIdentifier = Self.answerableCategory
            userInfo[Self.decisionIDKey] = answer.decisionID
            userInfo[Self.allowOptionKey] = answer.allowOptionID
            userInfo[Self.rejectOptionKey] = answer.rejectOptionID
        }
        content.userInfo = userInfo
        // One notification per Session: a newer request replaces the older.
        center.add(UNNotificationRequest(
            identifier: Self.identifier(alert.sessionID),
            content: content,
            trigger: nil
        ))
    }

    private func handle(actionIdentifier: String, userInfo: [String: String]) {
        guard let sessionID = userInfo[Self.sessionIDKey].flatMap(TerminalSessionID.init(uuidString:)) else { return }
        let optionID: String?
        switch actionIdentifier {
        case Self.allowAction: optionID = userInfo[Self.allowOptionKey]
        case Self.rejectAction: optionID = userInfo[Self.rejectOptionKey]
        default: optionID = nil
        }
        guard let optionID, let decisionID = userInfo[Self.decisionIDKey], let onAnswer else {
            NSApp.activate(ignoringOtherApps: true)
            onOpenSession?(sessionID)
            return
        }
        Task { @MainActor in
            do {
                try await onAnswer(sessionID, decisionID, optionID)
            } catch {
                // The request moved on or the Host refused: show the Session
                // so the person can answer it there.
                NSApp.activate(ignoringOtherApps: true)
                self.onOpenSession?(sessionID)
            }
        }
    }

    private static func identifier(_ sessionID: TerminalSessionID) -> String {
        "agent-attention-\(sessionID.description)"
    }

    private static func alertsEnabled(_ defaults: UserDefaults) -> Bool {
        isOn(WarrenPreferenceKey.agentAttentionAlertsEnabled, defaults: defaults)
            && !defaults.bool(forKey: WarrenPreferenceKey.noticeMuted)
    }

    private static func isOn(_ key: String, defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: key) as? Bool) ?? true
    }
}

// The completion-handler forms, as on iOS: the `async` forms call the system's
// completion handler off the main thread after the body returns.
extension WarrenAttentionNotifier: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        // The window already shows the request while Warren is active.
        DispatchQueue.main.async { completionHandler([]) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        var userInfo: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let key = key as? String, let value = value as? String { userInfo[key] = value }
        }
        let info = userInfo
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.handle(actionIdentifier: actionIdentifier, userInfo: info)
            }
            completionHandler()
        }
    }
}

/// Feeds the notifier from the remote model: the current Host's Sessions and
/// the decisions this client holds. It reads the model's publishers rather than
/// observing the model, so the window does not re-render for it.
struct WarrenAttentionAlertsModifier: ViewModifier {
    let model: WarrenRemoteApplicationModel
    let openSession: (TerminalSessionID) -> Void

    func body(content: Content) -> some View {
        let model = self.model
        let openSession = self.openSession
        return content
            .onAppear {
                let notifier = WarrenAttentionNotifier.shared
                notifier.onOpenSession = openSession
                notifier.onAnswer = { [weak model] sessionID, decisionID, optionID in
                    guard let model else { return }
                    try await model.resolvePendingDecision(decisionID, optionID: optionID, in: sessionID)
                }
            }
            .onReceive(model.$projection.combineLatest(model.$pendingDecisions)) { value in
                let (projection, decisions) = value
                WarrenAttentionNotifier.shared.update(
                    WarrenDesktopAttentionAlerts.alerts(projection: projection, decisions: decisions)
                )
            }
    }
}
