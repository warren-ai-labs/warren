import AppKit
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
    private static let pingSeconds: TimeInterval = 0.2
    /// A ping this late means one main-thread turn held the window for
    /// several frames: a visible hitch, though far from a hang.
    private static let hitchThreshold: TimeInterval = 0.1
    /// Hitches are summarised at most this often, so a janky stretch costs
    /// one line rather than one per frame.
    private static let hitchReportInterval: TimeInterval = 10
    @MainActor private static var previousPing: Date?
    @MainActor private static var hitchCount = 0
    @MainActor private static var worstHitch: TimeInterval = 0
    @MainActor private static var lastHitchReport = Date.distantPast

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
            let now = Date()
            lock.withLock { lastPingDate = now }
            noteMainThreadTurn(at: now)
            if watchdogTask != nil {
                try? await Task.sleep(for: pingInterval)
                schedulePing()
            }
        }
    }

    /// Counts pings that ran late by a hitch or more and reports the count
    /// and the worst one at most every `hitchReportInterval`. Only while the
    /// app is active: App Nap delays a background app's timers on purpose.
    @MainActor
    private static func noteMainThreadTurn(at now: Date) {
        defer { previousPing = now }
        guard let previous = previousPing, NSApplication.shared.isActive else { return }
        let late = now.timeIntervalSince(previous) - pingSeconds
        if late >= hitchThreshold {
            hitchCount += 1
            worstHitch = max(worstHitch, late)
        }
        guard hitchCount > 0, now.timeIntervalSince(lastHitchReport) >= hitchReportInterval else { return }
        TerminalDiagnostics.log("main_thread_hitch", [
            "count": String(hitchCount),
            "worst_ms": String(Int(worstHitch * 1000)),
            "threshold_ms": String(Int(hitchThreshold * 1000)),
        ])
        hitchCount = 0
        worstHitch = 0
        lastHitchReport = now
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
