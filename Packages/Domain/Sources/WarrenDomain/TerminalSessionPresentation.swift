import Foundation

/// Presentation rules shared by every Warren client that labels a Session.
///
/// The rules live here rather than in a view layer so the Desktop, iOS, and
/// Web clients resolve the same label for the same Session. They depend only
/// on the fields the Host projects, never on a client's own state.
public enum TerminalSessionPresentation {
    /// Process names that mean "the shell is at its prompt" rather than "a
    /// command is running". A foreground shell must not be shown as a command.
    public static let shellProcessNames: Set<String> = [
        "zsh", "bash", "sh", "dash", "fish", "ksh", "csh", "tcsh",
        "pwsh", "powershell", "cmd", "nu", "elvish", "xonsh", "oil", "osh",
    ]

    /// Agent kinds that keep a stable purpose label regardless of the
    /// foreground process.
    private static let managedPurposes: [TerminalSessionKind: String] = [
        .claude: "claude",
        .codex: "codex",
        .opencode: "opencode",
        .pi: "pi",
        .qoder: "qoder",
        .antigravity: "antigravity",
        .trae: "trae",
    ]

    /// Resolves the command label shown in a title, tab, or row.
    ///
    /// The full command line wins over the bare process name so a running
    /// `npm run dev` reads better than `npm`. A foreground shell resolves
    /// empty, so callers fall back to the directory instead of showing `zsh`.
    public static func commandLabel(
        kind: TerminalSessionKind,
        process: String,
        commandLine: String
    ) -> String {
        if let purpose = managedPurposes[kind] {
            return purpose
        }
        let commandLine = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !commandLine.isEmpty,
           !shellProcessNames.contains(executableName(commandLine).lowercased()) {
            return commandLine
        }
        let process = process.trimmingCharacters(in: .whitespacesAndNewlines)
        if !process.isEmpty,
           !shellProcessNames.contains(executableName(process).lowercased()) {
            return process
        }
        if process.isEmpty, commandLine.isEmpty {
            return kind == .shell ? "" : kind.displayName
        }
        return ""
    }

    /// Tab and row title: a user-set name or a meaningful generated title
    /// wins, otherwise `command · directory` or just the directory. Returns an
    /// empty string when nothing is known so the caller can apply its own
    /// empty label.
    public static func tabTitle(
        customTitle: String?,
        title: String = "",
        kind: TerminalSessionKind,
        process: String,
        commandLine: String,
        directory: String,
        fallbackTitle: String = ""
    ) -> String {
        let name = sessionName(customTitle: customTitle, title: title, kind: kind)
        if !name.isEmpty {
            return name
        }
        let directoryName = directoryName(directory)
        let command = commandLabel(kind: kind, process: process, commandLine: commandLine)
        if directoryName.isEmpty {
            if !command.isEmpty {
                return command
            }
            return fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return command.isEmpty ? directoryName : "\(command) · \(directoryName)"
    }

    /// The Session's own name: the user-set title, or the generated title when
    /// it carries more than the kind already shows.
    public static func sessionName(
        customTitle: String?,
        title: String,
        kind: TerminalSessionKind
    ) -> String {
        let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty {
            return custom
        }
        let generated = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !generated.isEmpty, !isGeneratedDefaultTitle(generated, kind: kind) {
            return generated
        }
        return ""
    }

    /// The last path component, which is the readable label for a directory.
    public static func directoryName(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    /// The name of the shell a foreground process names, or nil when the
    /// process is not a shell.
    public static func shellName(process: String) -> String? {
        let name = executableName(process)
        guard !name.isEmpty, shellProcessNames.contains(name.lowercased()) else { return nil }
        return name
    }

    /// A shell row's title: where the shell is, not what it is running.
    ///
    /// A user-set or meaningful generated name wins. Otherwise the title says
    /// where the shell is: the shell's own name at the worktree root, the path
    /// relative to the worktree inside it, and a `~`-shortened path outside.
    /// The command never appears here, so it is not written twice beside the
    /// row's second line.
    public static func shellLocationTitle(
        customTitle: String?,
        title: String,
        kind: TerminalSessionKind,
        shellName: String,
        directory: String,
        worktreeRoot: String
    ) -> String {
        let name = sessionName(customTitle: customTitle, title: title, kind: kind)
        if !name.isEmpty { return name }
        let shell = shellName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = shell.isEmpty ? kind.displayName : shell
        let path = normalizedPath(directory)
        guard !path.isEmpty else { return fallback }
        let root = normalizedPath(worktreeRoot)
        if !root.isEmpty, path == root { return fallback }
        if !root.isEmpty, path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return abbreviatedPath(path)
    }

    /// A directory shortened for display: `~` stands in for the home directory,
    /// and everything else is left as the shell reported it.
    public static func abbreviatedPath(_ path: String) -> String {
        let normalized = normalizedPath(path)
        guard !normalized.isEmpty else { return "" }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #else
        // iOS has no shell home; tilde abbreviation is desktop chrome only.
        let home = ""
        #endif
        guard !home.isEmpty else { return normalized }
        if normalized == home { return "~" }
        if normalized.hasPrefix(home + "/") {
            return "~" + normalized.dropFirst(home.count)
        }
        return normalized
    }

    /// A path with redundant separators and `.`/`..` segments removed, without
    /// resolving symlinks: the displayed path should be the one the shell
    /// reported, not the one the filesystem points at.
    public static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    /// The executable a process name or command line refers to, without a
    /// leading login-shell dash.
    public static func executableName(_ value: String) -> String {
        let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
        let base = (token as NSString).lastPathComponent
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }

    /// Whether a placeholder value is just the generated default name and
    /// therefore redundant next to the directory and command.
    ///
    /// The Host fixes a Session's `title` at creation from its kind. A Session
    /// that the user has not named carries no information the kind and command
    /// do not already convey, so the template suppresses it.
    public static func isGeneratedDefaultTitle(
        _ title: String,
        kind: TerminalSessionKind
    ) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        return value.caseInsensitiveCompare(kind.displayName) == .orderedSame
    }
}
