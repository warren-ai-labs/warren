import WarrenDomain

/// Presentation metadata for a built-in session launch request.
///
/// This is the single catalog used by both the pinned command bar and the full
/// session creator. User-defined presets can later conform to the same value
/// shape without changing the Desktop action channel.
public struct WarrenDesktopSessionPreset: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let symbolName: String
    public let createButtonTitle: String
    public let request: TerminalSessionLaunchRequest
    public let isPinned: Bool

    public init(
        id: String,
        title: String,
        subtitle: String,
        symbolName: String,
        createButtonTitle: String,
        request: TerminalSessionLaunchRequest,
        isPinned: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.createButtonTitle = createButtonTitle
        self.request = request
        self.isPinned = isPinned
    }

    public static let builtIns: [Self] = [
        Self(
            id: "shell",
            title: "Interactive Shell",
            subtitle: "Plain shell in the selected workspace",
            symbolName: "terminal",
            createButtonTitle: "Open Shell",
            request: .shell,
            isPinned: true
        ),
        Self(
            id: "claude",
            title: "Claude Code",
            subtitle: "Launch the claude CLI in this project",
            symbolName: "sparkles",
            createButtonTitle: "Start Claude Code",
            request: .claude,
            isPinned: true
        ),
        Self(
            id: "codex",
            title: "Codex",
            subtitle: "Launch the codex CLI in this project",
            symbolName: "curlybraces",
            createButtonTitle: "Start Codex",
            request: .codex,
            isPinned: true
        ),
        Self(
            id: "custom",
            title: "Custom Command",
            subtitle: "Run any command line, agent or development server",
            symbolName: "hammer",
            createButtonTitle: "Start Custom",
            request: TerminalSessionLaunchRequest(kind: .custom),
            isPinned: false
        ),
    ]

    public static let pinned = builtIns.filter(\.isPinned)

    public static var defaultOrderRawValue: String {
        pinned.map(\.id).joined(separator: ",")
    }

    public static func normalizedOrder(_ rawValue: String) -> [String] {
        let knownIDs = Set(pinned.map(\.id))
        var seen: Set<String> = []
        var result = rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { knownIDs.contains($0) && seen.insert($0).inserted }

        for id in pinned.map(\.id) where seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    public static func normalizedOrderRawValue(_ rawValue: String) -> String {
        normalizedOrder(rawValue).joined(separator: ",")
    }

    public static func orderedPinned(by rawValue: String) -> [Self] {
        let presetsByID = Dictionary(uniqueKeysWithValues: pinned.map { ($0.id, $0) })
        return normalizedOrder(rawValue).compactMap { presetsByID[$0] }
    }

    public static func moving(_ id: String, by offset: Int, in rawValue: String) -> String {
        var order = normalizedOrder(rawValue)
        guard let index = order.firstIndex(of: id) else {
            return normalizedOrderRawValue(rawValue)
        }
        let destination = index + offset
        guard order.indices.contains(destination) else {
            return normalizedOrderRawValue(rawValue)
        }
        order.swapAt(index, destination)
        return order.joined(separator: ",")
    }

    public static var firstAI: Self? {
        pinned.first { preset in
            preset.request.kind == .claude || preset.request.kind == .codex
        }
    }

    public static func firstAI(orderedBy rawValue: String) -> Self? {
        orderedPinned(by: rawValue).first { preset in
            preset.request.kind == .claude || preset.request.kind == .codex
        }
    }

    /// Compact labels mirror Superset's 24pt preset bar without weakening the
    /// descriptive names used by the full session launcher.
    public var presetBarTitle: String {
        switch id {
        case "shell": "Shell"
        case "claude": "Claude"
        case "codex": "Codex"
        default: title
        }
    }

    var presetBarIconName: String? {
        switch id {
        case "shell": "preset-shell"
        case "claude": "preset-claude"
        case "codex": "preset-codex"
        default: nil
        }
    }

    /// Returns the launch request with the user's Settings overrides applied.
    /// Commands are typed into a plain shell first, so quitting an agent CLI
    /// leaves the terminal alive; an empty shell command opens a bare shell.
    public func resolvedRequest(
        shellCommand: String,
        claudeCommand: String,
        codexCommand: String
    ) -> TerminalSessionLaunchRequest {
        let command: String?
        switch id {
        case "shell":
            command = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : shellCommand
        case "claude":
            command = claudeCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "claude" : claudeCommand
        case "codex":
            command = codexCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "codex --dangerously-bypass-hook-trust"
                : codexCommand
        default:
            command = request.command
        }
        return TerminalSessionLaunchRequest(kind: request.kind, command: command, title: request.title)
    }
}

extension TerminalSessionKind {
    /// Desktop-only icon metadata. Durable Host records keep only the stable
    /// kind and never depend on an SF Symbol name.
    var symbolName: String {
        switch self {
        case .shell: "terminal"
        case .claude: "sparkles"
        case .codex: "curlybraces"
        case .custom: "hammer"
        }
    }
}
