import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Builds the environment used when the desktop launches Warren-owned
/// background processes. The launching terminal may contain mise, direnv,
/// agent and terminal-integration state; none of that is a daemon contract.
enum WarrenProcessEnvironment {
    static let defaultTerm = "xterm-ghostty"

    private static let controlledKeys: Set<String> = [
        "DISPLAY",
        "WAYLAND_DISPLAY",
        "DBUS_SESSION_BUS_ADDRESS",
        "XAUTHORITY",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "WARREN_CONFIG",
        "WARREN_INSTANCE_LOCK",
        "WARREN_CODE_SERVER_PATH",
        "WARREN_SSH_TUNNEL_PATH",
        "WARREN_CLI_PATH",
        "WARREN_CLI_INSTALL_DIRECTORY",
        "WARREN_BUILD_VARIANT",
        "WARREN_TERMINAL_DIAGNOSTICS",
        "WARREN_TERMINAL_DIAGNOSTICS_DIR",
        "CODEX_HOME",
        "CLAUDE_CONFIG_DIR",
        "WARREN_DATA_DIR",
        "WARREN_OPENCODE_DATA_DIR",
        "WARREN_OPENCODE_PLUGIN_PATH",
        "WARREN_WEB_ROOT",
        "WARREN_GHOSTLINE_V0_COMPAT",
        "WARREN_GHOSTLINE_FORCE_HANDOFF",
        "WARREN_FORCE_HANDOFF",
        "WARREN_LISTEN",
        "WARREN_LAN_HTTPS",
        "WARREN_TLS_DIR",
        "WARREN_STATE",
        "WARREN_TOKEN_FILE",
        "WARREN_HOST_NAME",
        "WARREN_RUNTIME",
        "WARREN_GHOSTLINE_SOCKET",
        "WARREN_GHOSTLINE_PROBE_FOREGROUND",
        "WARREN_SETTINGS_FILE",
        "WARREN_LOG_FILE",
        "WARREN_WORKTREE_ROOT",
        "WARREN_OUTPUT_DIR",
        "WARREN_RELAY_URL",
        "WARREN_RELAY_HOST_ID",
        "WARREN_RELAY_KEY_ID",
        "WARREN_RELAY_KEY",
        // These are launch-path overrides used only to find bundled binaries.
        "WARREN_APP_PATH",
        "WARREN_HEADLESS_PATH",
        "WARREN_DAEMON_MENUBAR_PATH",
        "WARREN_MENUBAR_ICON_PATH",
    ]

    /// Returns a clean environment for a Warren-owned child process.
    static func clean(
        source: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        let home = nonEmpty(source["HOME"]) ?? homeDirectory.path
        var result: [String: String] = [:]
        if !home.isEmpty { result["HOME"] = home }

        copyNonEmpty("USER", from: source, into: &result)
        copyNonEmpty("LOGNAME", from: source, into: &result)
        if result["LOGNAME"] == nil, let user = result["USER"] { result["LOGNAME"] = user }
        if let value = nonEmpty(source["TMPDIR"]) { result["TMPDIR"] = value }
        copyNonEmpty("LANG", from: source, into: &result)
        copyNonEmpty("TZ", from: source, into: &result)
        for (key, value) in source where key.hasPrefix("LC_") {
            if isValidEnvironmentKey(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result[key] = value
            }
        }

        result["SHELL"] = canonicalShell(source["SHELL"])
        result["PATH"] = stablePath(homeDirectory: URL(fileURLWithPath: home))
        result["TERM"] = defaultTerm
        result["COLORTERM"] = "truecolor"

        for key in controlledKeys {
            copyNonEmpty(key, from: source, into: &result)
        }
        if let socket = nonEmpty(source["SSH_AUTH_SOCK"]), isSocket(atPath: socket) {
            result["SSH_AUTH_SOCK"] = socket
        }
        return result
    }

    /// Returns the environment passed to the headless daemon. It is the clean
    /// host environment plus the explicit Warren configuration/path keys that
    /// are needed to locate its files and sibling executables.
    static func daemonEnvironment(
        from source: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: String] {
        clean(source: source, homeDirectory: homeDirectory)
    }

    static func stablePath(homeDirectory: URL) -> String {
        var entries = [
            homeDirectory.appendingPathComponent(".local/bin").path,
            homeDirectory.appendingPathComponent("go/bin").path,
            homeDirectory.appendingPathComponent(".cargo/bin").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        var seen = Set<String>()
        entries.removeAll { !seen.insert($0).inserted }
        return entries.joined(separator: ":")
    }

    private static func canonicalShell(_ value: String?) -> String {
        let candidates = [
            value?.trimmingCharacters(in: .whitespacesAndNewlines),
            "/bin/zsh",
            "/usr/bin/zsh",
            "/bin/bash",
            "/usr/bin/bash",
            "/bin/sh",
            "/usr/bin/sh",
        ].compactMap { $0 }.filter { !$0.isEmpty }
        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate).inserted {
            let name = URL(fileURLWithPath: candidate).lastPathComponent
            guard ["bash", "fish", "sh", "zsh"].contains(name),
                  candidate.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            return candidate
        }
        return "/bin/sh"
    }

    private static func copyNonEmpty(
        _ key: String,
        from source: [String: String],
        into result: inout [String: String]
    ) {
        if let value = nonEmpty(source[key]) { result[key] = value }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func isValidEnvironmentKey(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        for (index, scalar) in key.unicodeScalars.enumerated() {
            let isLetter = (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            guard isLetter || scalar.value == 95 || (index > 0 && isDigit) else { return false }
        }
        return true
    }

    private static func isSocket(atPath path: String) -> Bool {
        #if canImport(Darwin)
        var info = stat()
        return path.withCString { pointer in
            Darwin.lstat(pointer, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
        }
        #else
        return FileManager.default.fileExists(atPath: path)
        #endif
    }
}
