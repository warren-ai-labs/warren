import Foundation
import WarrenClientCore
import WarrenDomain

/// Tab title derivation matching Superset's GroupStrip: an interactive shell
/// reads as its directory so multiple workspaces are recognizable at a glance.
/// When a stable purpose is available, it is shown before the directory.
enum WarrenDesktopTabTitle {
    private static let shellProcessNames: Set<String> = [
        "zsh", "bash", "sh", "dash", "fish", "ksh", "csh", "tcsh",
        "pwsh", "powershell", "cmd", "nu", "elvish", "xonsh", "oil", "osh",
    ]

    static func displayTitle(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        if let customTitle = session?.customTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !customTitle.isEmpty {
            return customTitle
        }
        let directory = directoryName(tab: tab, session: session, workspace: workspace)
        let command = resolvedCommand(tab: tab, session: session)
        if directory.isEmpty {
            if !command.isEmpty {
                return command
            }
            let title = session?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                return title
            }
            if !tab.title.isEmpty {
                return tab.title
            }
            return command.isEmpty ? "Shell" : command
        }
        if command.isEmpty { return directory }
        return "\(command) · \(directory)"
    }

    static func directoryName(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        let path = session?.workingDirectory.isEmpty == false
            ? session!.workingDirectory
            : (workspace?.path ?? "")
        guard !path.isEmpty else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func resolvedCommand(
        tab: ClientTab,
        session: WarrenDesktopSession?
    ) -> String {
        resolvedCommand(
            kind: session?.kind ?? tab.kind,
            process: session?.runtimeProcess ?? "",
            commandLine: session?.runtimeCommandLine ?? ""
        )
    }

    /// Resolves the command label a title or tab should show.
    ///
    /// The full command line wins over the bare process name so a running
    /// `npm run dev` reads better than `npm`. A foreground shell is not a
    /// command, so it resolves empty and the caller falls back to the
    /// directory.
    static func resolvedCommand(
        kind: TerminalSessionKind,
        process: String,
        commandLine: String
    ) -> String {
        if let managedPurpose = managedPurpose(for: kind) {
            return managedPurpose
        }
        let trimmedProcess = process.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommandLine = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCommandLine.isEmpty,
           !shellProcessNames.contains(executableName(trimmedCommandLine).lowercased()) {
            return trimmedCommandLine
        }
        if !trimmedProcess.isEmpty,
           !shellProcessNames.contains(executableName(trimmedProcess).lowercased()) {
            return trimmedProcess
        }
        if trimmedProcess.isEmpty, trimmedCommandLine.isEmpty {
            return purposeLabel(for: kind)
        }
        return ""
    }

    /// The executable a command line or process name refers to, without a
    /// leading login-shell dash.
    static func executableName(_ value: String) -> String {
        let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
        let base = (token as NSString).lastPathComponent
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }

    private static func managedPurpose(for kind: TerminalSessionKind) -> String? {
        switch kind {
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .pi: "pi"
        case .qoder: "qoder"
        case .antigravity: "antigravity"
        case .trae: "trae"
        case .shell, .custom: nil
        }
    }

    private static func purposeLabel(for kind: TerminalSessionKind) -> String {
        switch kind {
        case .shell: ""
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .pi: "pi"
        case .qoder: "qoder"
        case .antigravity: "antigravity"
        case .trae: "trae"
        case .custom: kind.displayName
        }
    }
}
