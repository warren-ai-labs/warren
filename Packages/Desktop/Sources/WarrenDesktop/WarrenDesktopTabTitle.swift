import Foundation
import WarrenClientCore
import WarrenDomain

/// Desktop tab and row labels.
///
/// The rule itself lives in `WarrenDomain.TerminalSessionPresentation` so the
/// Desktop, iOS, and Web clients cannot drift. This type only resolves the
/// Desktop-specific directory fallback (a Workspace path or Terminal Group
/// home) before delegating.
enum WarrenDesktopTabTitle {
    static func displayTitle(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        let sessionTitle = session?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TerminalSessionPresentation.tabTitle(
            customTitle: session?.customTitle,
            title: session?.title ?? tab.title,
            kind: session?.kind ?? tab.kind,
            process: session?.runtimeProcess ?? "",
            commandLine: session?.runtimeCommandLine ?? "",
            directory: directoryName(tab: tab, session: session, workspace: workspace),
            fallbackTitle: sessionTitle.isEmpty ? tab.title : sessionTitle
        )
    }

    static func directoryName(
        tab: ClientTab,
        session: WarrenDesktopSession?,
        workspace: Workspace?
    ) -> String {
        let path = session?.workingDirectory.isEmpty == false
            ? session!.workingDirectory
            : (workspace?.path ?? "")
        return TerminalSessionPresentation.directoryName(path)
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
