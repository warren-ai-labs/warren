import Foundation
import WarrenClientCore
import WarrenDomain

/// Desktop Session labels.
///
/// The rule itself lives in `WarrenDomain.SessionTitle` so the top bar, the
/// sidebar row, the split pane header, and the tab cannot drift. This type only
/// resolves the Desktop-specific workspace path before delegating.
enum WarrenDesktopTabTitle {
    static func displayTitle(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        guard let session else { return tab.title }
        return sessionTitle(for: session, worktreeRoot: workspace?.path ?? "").title
    }

    /// The Session's one name and, for a shell running a command, the
    /// command the top bar appends. See `SessionTitle`.
    static func sessionTitle(
        for session: WarrenDesktopSession,
        worktreeRoot: String
    ) -> SessionTitle {
        let resolved = SessionTitle.resolve(
            customTitle: session.customTitle,
            title: session.title,
            kind: session.presentedKind,
            process: session.runtimeProcess,
            commandLine: session.runtimeCommandLine,
            shellName: session.shellState?.shellName ?? "",
            runningCommand: session.shellState.map { $0.atPrompt ? "" : $0.runningCommand } ?? "",
            reportsPromptState: session.shellState != nil,
            directory: session.workingDirectory,
            worktreeRoot: worktreeRoot
        )
        guard resolved.title.isEmpty else { return resolved }
        return SessionTitle(
            title: session.presentedKind.displayName,
            runningCommand: resolved.runningCommand
        )
    }

    /// Resolves the command placeholder for the pane title template.
    static func resolvedCommand(
        kind: TerminalSessionKind,
        process: String,
        commandLine: String
    ) -> String {
        TerminalSessionPresentation.commandLabel(
            kind: kind,
            process: process,
            commandLine: commandLine
        )
    }
}
