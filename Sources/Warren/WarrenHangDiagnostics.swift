import Foundation
import GhosttyAdapter

/// Watches the main thread for stalls and captures diagnostics.
/// Logs ping/pong and endpoint switch milestones to terminal-diagnostics.log.
enum WarrenHangDiagnostics {
    nonisolated(unsafe) private static var watchdogTask: Task<Void, Never>?
    nonisolated(unsafe) private static var lastPingDate = Date()
    private static let lock = NSLock()
    private static let stallThreshold: Duration = .seconds(2)
    private static let pingInterval: Duration = .milliseconds(200)

    static func start() {
        guard watchdogTask == nil else { return }
        TerminalDiagnostics.log("hang_watchdog_start", ["threshold_ms": "2000"])
        watchdogTask = Task.detached(priority: .utility) { await run() }
        schedulePing()
    }

    static func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    static func logEndpointSwitch(from: String, to: String) {
        TerminalDiagnostics.log("endpoint_switch", ["from": from, "to": to])
    }

    static func logWebLinkSwitch(kind: String) {
        TerminalDiagnostics.log("weblink_switch", ["kind": kind])
    }

    static func logDisconnectBegin(endpoint: String) {
        TerminalDiagnostics.log("disconnect_begin", ["endpoint": endpoint])
    }

    static func logDisconnectEnd(endpoint: String, durationMs: Int) {
        TerminalDiagnostics.log("disconnect_end", ["endpoint": endpoint, "duration_ms": String(durationMs)])
    }

    static func logConnectBegin(endpoint: String) {
        TerminalDiagnostics.log("connect_begin", ["endpoint": endpoint])
    }

    static func logSurfaceShutdownBegin(count: Int) {
        TerminalDiagnostics.log("surface_shutdown_begin", ["surfaces": String(count)])
    }

    static func logSurfaceShutdownEnd(durationMs: Int) {
        TerminalDiagnostics.log("surface_shutdown_end", ["duration_ms": String(durationMs)])
    }

    private static func schedulePing() {
        Task { @MainActor in
            lock.withLock { lastPingDate = Date() }
            if watchdogTask != nil {
                try? await Task.sleep(for: pingInterval)
                schedulePing()
            }
        }
    }

    private static func run() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            let interval: TimeInterval = lock.withLock { Date().timeIntervalSince(lastPingDate) }
            if interval > 2.0 {
                let ms = Int(interval * 1000)
                TerminalDiagnostics.log("main_thread_stall", [
                    "duration_ms": String(ms),
                    "hint": "main thread blocked >2s; switching endpoint or weblink may be deadlocked",
                ])
                // Also write a freeze marker to help capture sample externally
                let markerURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Warren/freeze-\(Int(Date().timeIntervalSince1970)).log")
                try? "stall \(ms)ms at \(Date())\n".write(to: markerURL, atomically: true, encoding: .utf8)
            }
        }
    }
}

private extension Duration {
    init(_ interval: TimeInterval) {
        self = .seconds(interval)
    }
}
