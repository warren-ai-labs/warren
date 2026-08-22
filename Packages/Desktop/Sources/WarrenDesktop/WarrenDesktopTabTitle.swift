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
        let kind = session?.kind ?? tab.kind
        let process = session?.runtimeProcess
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let managedPurpose = managedPurpose(for: kind) {
            return managedPurpose
        }
        if !process.isEmpty, !shellProcessNames.contains(process) {
            return process
        }
        if session == nil || process.isEmpty {
            return purposeLabel(for: kind)
        }
        return ""
    }

    private static func managedPurpose(for kind: TerminalSessionKind) -> String? {
        switch kind {
        case .claude: "claude"
        case .codex: "codex"
        case .trae: "trae"
        case .shell, .custom: nil
        }
    }

    private static func purposeLabel(for kind: TerminalSessionKind) -> String {
        switch kind {
        case .shell: ""
        case .claude: "claude"
        case .codex: "codex"
        case .trae: "trae"
        case .custom: kind.displayName
        }
    }
}
