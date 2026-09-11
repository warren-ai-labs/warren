import Foundation
import CoreGraphics

enum GhosttyDiagnosticsFormat {
    static func finiteSize(_ size: CGSize) -> String {
        "\(finitePart(size.width))x\(finitePart(size.height))"
    }

    private static func finitePart(_ value: CGFloat) -> String {
        guard value.isFinite else { return "inf" }
        if value > 1_000_000 { return ">1M" }
        if value < -1_000_000 { return "<-1M" }
        return String(Int(value))
    }
}
import GhosttyTerminal

/// Terminal presentation diagnostics for the workspace/tab-switch black pane.
///
/// Milestone events (switches, attach, first snapshot, present failures, view
/// mount/teardown, resize) are written by default to
/// `~/Library/Logs/Warren/terminal-diagnostics.log`, rotated to a `.log.1`
/// backup once the file exceeds 2 MB. `WARREN_TERMINAL_DIAGNOSTICS=1` (or the
/// `--terminal-diagnostics` launch argument) additionally enables the
/// vendored GhosttyTerminal debug stream and verbose per-draw events.
public enum TerminalDiagnostics {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var enabled = false
        var verbose = false
        var handle: FileHandle?
        var fileURL: URL?
        var bytesWritten = 0
    }

    private static let store = Store()
    private static let maxFileBytes = 2 * 1024 * 1024
    /// Serial writer for events recorded on latency-sensitive paths.
    ///
    /// `log` performs the file write while holding `store.lock`, which is
    /// acceptable for the low-rate milestone events but not for anything on the
    /// focus/reconcile path: those run on the main actor and would put a disk
    /// write between an AppKit responder change and the next frame. Hopping to
    /// this queue keeps the ordering guarantee (it is serial, and the event
    /// timestamp is captured at the call site) without blocking the caller.
    private static let asyncQueue = DispatchQueue(
        label: "com.abcdlsj.warren.terminal-diagnostics",
        qos: .utility
    )

    public static var isEnabled: Bool {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.enabled
    }

    public static var isVerbose: Bool {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.verbose
    }

    public static func configure(
        environment: [String: String],
        arguments: [String]
    ) {
        let verboseRequested =
            environment["WARREN_TERMINAL_DIAGNOSTICS"] == "1"
            || arguments.contains("--terminal-diagnostics")
        store.lock.lock()
        guard !store.enabled else {
            store.lock.unlock()
            return
        }

        let defaultDirectory = NSHomeDirectory() + "/Library/Logs/Warren"
        let directory = URL(
            fileURLWithPath: environment["WARREN_TERMINAL_DIAGNOSTICS_DIR"]
                ?? defaultDirectory,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appendingPathComponent("terminal-diagnostics.log")
        store.fileURL = fileURL
        store.handle = openForAppend(fileURL)
        store.bytesWritten = (
            try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        ) ?? 0
        store.enabled = true
        store.verbose = verboseRequested
        store.lock.unlock()

        if verboseRequested {
            TerminalDebugLog.enable(.all)
            TerminalDebugLog.sink = { message in
                Self.writeRaw(message)
            }
        }
        log("diagnostics_start", [
            "verbose": verboseRequested ? "true" : "false",
            "file": fileURL.path,
        ])
    }

    /// Milestone event: always recorded once diagnostics are configured.
    public static func log(
        _ event: String,
        _ fields: [String: String] = [:]
    ) {
        store.lock.lock()
        defer { store.lock.unlock() }
        guard store.enabled else { return }
        writeLocked(event, fields)
    }

    /// Milestone event recorded without blocking the calling thread.
    ///
    /// Use this instead of `log` on the main actor's hot paths. The timestamp is
    /// read here so the recorded time is the moment the event happened rather
    /// than the moment the writer drained.
    public static func logAsync(
        _ event: String,
        _ fields: [String: String] = [:]
    ) {
        guard isEnabled else { return }
        let timestamp = Date().timeIntervalSince1970
        asyncQueue.async {
            store.lock.lock()
            defer { store.lock.unlock() }
            guard store.enabled else { return }
            writeLocked(event, fields, timestamp: timestamp)
        }
    }

    /// Verbose event: recorded only with `WARREN_TERMINAL_DIAGNOSTICS=1`.
    public static func logVerbose(
        _ event: String,
        _ fields: [String: String] = [:]
    ) {
        store.lock.lock()
        defer { store.lock.unlock() }
        guard store.enabled, store.verbose else { return }
        writeLocked(event, fields)
    }

    private static func writeLocked(
        _ event: String,
        _ fields: [String: String],
        timestamp: TimeInterval? = nil
    ) {
        var payload: [String: String] = [
            "time": String(format: "%.3f", timestamp ?? Date().timeIntervalSince1970),
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "event": event,
        ]
        for (key, value) in fields {
            payload[key] = value
        }
        let line: String
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ), let text = String(data: data, encoding: .utf8) {
            line = text
        } else {
            line = payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        }
        appendLocked(line + "\n")
    }

    private static func writeRaw(_ message: String) {
        store.lock.lock()
        defer { store.lock.unlock() }
        guard store.enabled, store.verbose else { return }
        appendLocked(message + "\n")
    }

    private static func appendLocked(_ line: String) {
        guard store.handle != nil,
              let data = line.data(using: .utf8) else { return }
        if store.bytesWritten + data.count > maxFileBytes {
            rotateLocked()
        }
        guard let handle = store.handle else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        store.bytesWritten += data.count
    }

    private static func rotateLocked() {
        guard let fileURL = store.fileURL else { return }
        store.handle?.closeFile()
        store.handle = nil
        let backup = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        store.handle = openForAppend(fileURL)
        store.bytesWritten = 0
    }

    private static func openForAppend(_ url: URL) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }
}
