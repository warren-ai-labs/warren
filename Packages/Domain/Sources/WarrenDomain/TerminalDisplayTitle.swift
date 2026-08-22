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
    public static let compactDirectoryMaxLength = 32

    public static let defaultValue = Self(rawValue: "{command} — {directoryName}")

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

    /// Render a pane title with a bounded, scannable directory path.
    ///
    /// The full title remains available from `render(_:)` for tooltips and
    /// copy actions; this presentation is only for the constrained pane bar.
    public func renderCompact(_ context: TerminalDisplayTitleContext) -> String {
        let compactContext = TerminalDisplayTitleContext(
            session: context.session,
            command: context.command,
            directory: Self.abbreviateDirectory(context.directory),
            workspace: context.workspace,
            branch: context.branch,
            host: context.host,
            user: context.user,
            os: context.os
        )
        return render(compactContext)
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
    public static let presetCommandTrae = "terminal.presetCommand.trae"
    public static let sessionPresetOrder = "terminal.presetOrder"
    public static let hiddenSessionPresets = "terminal.hiddenPresets"
    public static let noticeMuted = "notifications.muted"
    /// Legacy storage key retained so existing desktop preferences keep their
    /// value while the feature is presented as Public Access.
    public static let publicAccessEnabled = "web.gnarSharingEnabled"
    @available(*, deprecated, message: "Use publicAccessEnabled for Public Access.")
    public static let gnarSharingEnabled = publicAccessEnabled
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
