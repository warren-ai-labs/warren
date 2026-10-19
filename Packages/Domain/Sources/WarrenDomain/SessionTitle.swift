import Foundation

/// The one name a Session goes by.
///
/// The top bar, the sidebar row, a split pane's header, a tab, and the window
/// title all call `resolve`, so a Session never has two names at once. The
/// order is:
///
/// 1. the name the user gave it;
/// 2. the generated (AI) title, when it says more than the kind;
/// 3. an Agent's own name (`Claude Code`), including an Agent the user
///    started inside a shell;
/// 4. a custom command's summary (`npm run dev`);
/// 5. a shell's location (`zsh`, `Sources/WarrenKit`, `~/Downloads`).
///
/// Every branch is short by construction, which is what keeps the title within
/// the width it is given.
public struct SessionTitle: Equatable, Sendable {
    /// The Session's name.
    public let title: String
    /// The summarized foreground command of a shell that is running one, for
    /// the top bar to append after the title (`zsh · git push`). Empty for
    /// every other Session, and while the shell is at its prompt.
    public let runningCommand: String

    public init(title: String, runningCommand: String = "") {
        self.title = title
        self.runningCommand = runningCommand
    }

    /// The Agent kinds that name themselves.
    public static let agentKinds: Set<TerminalSessionKind> = [
        .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae,
    ]

    /// The kind a Session is presented as: a shell or custom command the Host
    /// bound to an Agent reads as that Agent. Every client resolves the kind
    /// it passes to `resolve` through this, so an Agent started inside a shell
    /// is named the same way on the Mac and on the phone.
    public static func presentedKind(
        _ kind: TerminalSessionKind,
        agentProvider: TerminalSessionKind?
    ) -> TerminalSessionKind {
        guard let agentProvider else { return kind }
        switch kind {
        case .shell, .custom:
            return agentProvider
        case .claude, .codex, .opencode, .pi, .qoder, .antigravity, .trae, .browser:
            // A browser never carries a provider binding, and a dedicated
            // Agent already names its provider by kind.
            return kind
        }
    }

    /// - Parameters:
    ///   - kind: the kind to present, with any Agent binding already resolved.
    ///   - shellName: the shell's own name when known (`zsh`).
    ///   - runningCommand: the command a shell reports running, empty at its
    ///     prompt. Falls back to `commandLine` when the shell reported no
    ///     prompt state.
    ///   - reportsPromptState: whether `runningCommand` is authoritative.
    public static func resolve(
        customTitle: String?,
        title: String,
        kind: TerminalSessionKind,
        process: String,
        commandLine: String,
        shellName: String,
        runningCommand: String = "",
        reportsPromptState: Bool = false,
        directory: String,
        worktreeRoot: String
    ) -> SessionTitle {
        let name = TerminalSessionPresentation.sessionName(
            customTitle: customTitle,
            title: title,
            kind: kind
        )
        let foreground = foregroundCommand(
            process: process,
            commandLine: commandLine,
            runningCommand: runningCommand,
            reportsPromptState: reportsPromptState
        )
        if agentKinds.contains(kind) {
            return SessionTitle(title: name.isEmpty ? kind.displayName : name)
        }
        switch kind {
        case .browser:
            return SessionTitle(title: name.isEmpty ? kind.displayName : name)
        case .custom where name.isEmpty && !foreground.isEmpty:
            return SessionTitle(title: CommandSummary.summarize(foreground))
        default:
            break
        }
        let shell = shellName.isEmpty
            ? (TerminalSessionPresentation.shellName(process: process) ?? "")
            : shellName
        let location = name.isEmpty
            ? TerminalSessionPresentation.shellLocationTitle(
                customTitle: nil,
                title: "",
                kind: kind,
                shellName: shell,
                directory: directory,
                worktreeRoot: worktreeRoot
            )
            : name
        let summary = foreground.isEmpty ? "" : CommandSummary.summarize(foreground)
        return SessionTitle(
            title: location,
            runningCommand: summary == location ? "" : summary
        )
    }

    /// The command in the foreground, or empty when the shell itself is.
    private static func foregroundCommand(
        process: String,
        commandLine: String,
        runningCommand: String,
        reportsPromptState: Bool
    ) -> String {
        if reportsPromptState {
            return runningCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TerminalSessionPresentation.commandLabel(
            kind: .shell,
            process: process,
            commandLine: commandLine
        )
    }
}
