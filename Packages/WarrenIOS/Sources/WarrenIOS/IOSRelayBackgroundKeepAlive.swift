import Foundation

#if os(iOS) && canImport(UIKit)
import UIKit
#endif

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
