import Foundation

/// Metadata available to a user-defined terminal display title.
///
/// A display title is presentation only. It never renames the durable Session
/// or the client-local Tab that opens it.
public struct TerminalDisplayTitleContext: Hashable, Sendable {
    public let session: String
    public let command: String
    public let directory: String
    public let workspace: String
    public let branch: String
    public let host: String
    public let user: String
    public let os: String

    public init(
        session: String = "",
        command: String = "",
        directory: String = "",
        workspace: String = "",
        branch: String = "",
        host: String = "",
        user: String = "",
        os: String = ""
    ) {
        self.session = session
        self.command = command
        self.directory = directory
        self.workspace = workspace
        self.branch = branch
        self.host = host
        self.user = user
        self.os = os
    }

    public var directoryName: String {
        guard !directory.isEmpty else { return "" }
        return URL(fileURLWithPath: directory).lastPathComponent
    }
}

public struct TerminalDisplayTitleTemplate: RawRepresentable, Hashable, Sendable {
    /// Maximum length applied independently to every placeholder when a title
    /// is rendered in the constrained pane header.
    public static let compactPlaceholderMaxLength = 32
    public static let compactDirectoryMaxLength = 32

    public static let defaultValue = Self(rawValue: "{session} · {directory} · {command}")

    public static let placeholders: [(token: String, description: String)] = [
        ("{session}", "Session name"),
        ("{command}", "Current process"),
        ("{directory}", "Full directory"),
        ("{directoryName}", "Directory name"),
        ("{workspace}", "Workspace name"),
        ("{branch}", "Git branch"),
        ("{host}", "Host name"),
        ("{user}", "User name"),
        ("{os}", "Operating system"),
    ]

    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? Self.defaultValue.rawValue : trimmed
    }

    public func render(_ context: TerminalDisplayTitleContext) -> String {
        return renderTemplate(values: values(for: context))
    }

    /// Render a pane title with bounded, scannable placeholder values.
    ///
    /// The full title remains available from `render(_:)` for tooltips and
    /// copy actions; this presentation is only for the constrained pane bar.
    public func renderCompact(_ context: TerminalDisplayTitleContext) -> String {
        return renderTemplate(values: compactValues(for: context))
    }

    public static func abbreviateDirectory(
        _ directory: String,
        maxLength: Int = compactDirectoryMaxLength
    ) -> String {
        guard !directory.isEmpty, maxLength > 0, directory.count > maxLength else {
            return directory
        }

        let absolute = directory.hasPrefix("/")
        let components = directory
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return directory }

        let parents = components.dropLast().map { component in
            String(component.prefix(1))
        }
        let last = components[components.count - 1]
        let compact = (absolute ? "/" : "") + (parents + [last]).joined(separator: "/")
        guard compact.count > maxLength else { return compact }
        return middleEllipsis(compact, maxLength: maxLength)
    }

    private func values(for context: TerminalDisplayTitleContext) -> [String: String] {
        [
            "{session}": context.session,
            "{command}": context.command,
            "{directory}": context.directory,
            "{directoryName}": context.directoryName,
            "{workspace}": context.workspace,
            "{branch}": context.branch,
            "{host}": context.host,
            "{user}": context.user,
            "{os}": context.os,
        ]
    }

    private func compactValues(for context: TerminalDisplayTitleContext) -> [String: String] {
        [
            "{session}": Self.abbreviate(context.session),
            "{command}": Self.abbreviate(context.command),
            "{directory}": Self.abbreviateDirectory(
                context.directory,
                maxLength: Self.compactDirectoryMaxLength
            ),
            "{directoryName}": Self.abbreviate(context.directoryName),
            "{workspace}": Self.abbreviate(context.workspace),
            "{branch}": Self.abbreviate(context.branch),
            "{host}": Self.abbreviate(context.host),
            "{user}": Self.abbreviate(context.user),
            "{os}": Self.abbreviate(context.os),
        ]
    }

    private static func abbreviate(
        _ value: String,
        maxLength: Int = compactPlaceholderMaxLength
    ) -> String {
        guard maxLength > 0, value.count > maxLength else { return value }
        return middleEllipsis(value, maxLength: maxLength)
    }

    private func renderTemplate(values: [String: String]) -> String {
        var rendered = rawValue
        for (token, value) in values {
            rendered = rendered.replacingOccurrences(of: token, with: value)
        }
        rendered = rendered
            .replacingOccurrences(of: #"\s+([—|·:-]|/(?!\S))\s*(?=([—|·:-]|/(?!\S)|$))"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "—|·:-")))
        return rendered.isEmpty ? (values["{session}"] ?? "") : rendered
    }

    private static func middleEllipsis(_ value: String, maxLength: Int) -> String {
        guard maxLength > 1 else { return String(value.prefix(maxLength)) }
        let visibleLength = maxLength - 1
        let leftLength = (visibleLength + 1) / 2
        let rightLength = visibleLength - leftLength
        return String(value.prefix(leftLength))
            + "…"
            + String(value.suffix(rightLength))
    }
}

public enum WarrenPreferenceKey {
    public static let terminalTitleTemplate = "terminal.titleTemplate"
    public static let terminalFontFamily = "terminal.fontFamily"
    public static let terminalFontSize = "terminal.fontSize"
    public static let presetCommandShell = "terminal.presetCommand.shell"
    public static let presetCommandClaude = "terminal.presetCommand.claude"
    public static let presetCommandCodex = "terminal.presetCommand.codex"
    public static let presetCommandOpenCode = "terminal.presetCommand.opencode"
    public static let presetCommandPi = "terminal.presetCommand.pi"
    public static let presetCommandQoder = "terminal.presetCommand.qoder"
    public static let presetCommandTrae = "terminal.presetCommand.trae"
    public static let sessionPresetOrder = "terminal.presetOrder"
    public static let hiddenSessionPresets = "terminal.hiddenPresets"
    public static let noticeMuted = "notifications.muted"
    public static let embeddedEditorDefaultIDE = "editor.openByDefault"
    public static let agentCompletionSoundEnabled = "notifications.agentCompletionSoundEnabled"
    public static let sidebarShowActiveSessions = "sidebar.showActiveSessions"
    public static let sidebarShowTasks = "sidebar.showTasks"
    public static let publicAccessEnabled = "web.publicAccessEnabled"
}

/// User-facing terminal typography shared by renderer adapters.
///
/// The value is normalized at the boundary so an invalid preference cannot
/// make Ghostty or a web terminal construct an unusable grid.
public struct TerminalFontPreference: Hashable, Sendable {
    public static let defaultFamily = "SF Mono"
    public static let defaultSize = 13.0
    public static let allowedSizeRange = 8.0...32.0

    public let family: String
    public let size: Double

    public init(family: String = defaultFamily, size: Double = defaultSize) {
        let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
        self.family = trimmed.isEmpty ? Self.defaultFamily : trimmed
        self.size = size.isFinite
            ? min(max(size, Self.allowedSizeRange.lowerBound), Self.allowedSizeRange.upperBound)
            : Self.defaultSize
    }
}
