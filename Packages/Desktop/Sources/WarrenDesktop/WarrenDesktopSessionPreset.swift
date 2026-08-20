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
            id: "trae",
            title: "Trae Agent",
            subtitle: "Launch ByteDance's Trae Agent CLI in this project",
            symbolName: "sparkle.magnifyingglass",
            createButtonTitle: "Start Trae Agent",
            request: .trae,
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

    public static var defaultHiddenRawValue: String { "trae" }

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

    public static func normalizedHidden(_ rawValue: String) -> Set<String> {
        let knownIDs = Set(pinned.map(\.id))
        return Set(rawValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(knownIDs.contains))
    }

    public static func normalizedHiddenRawValue(_ rawValue: String) -> String {
        let hidden = normalizedHidden(rawValue)
        return pinned.map(\.id).filter(hidden.contains).joined(separator: ",")
    }

    public static func orderedVisible(by orderRawValue: String, hidden hiddenRawValue: String) -> [Self] {
        let hidden = normalizedHidden(hiddenRawValue)
        return orderedPinned(by: orderRawValue).filter { !hidden.contains($0.id) }
    }

    public static func settingVisibility(
        of id: String,
        visible: Bool,
        in hiddenRawValue: String
    ) -> String {
        var hidden = normalizedHidden(hiddenRawValue)
        if visible {
            hidden.remove(id)
        } else if pinned.contains(where: { $0.id == id }) {
            hidden.insert(id)
        }
        return pinned.map(\.id).filter(hidden.contains).joined(separator: ",")
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
        pinned.first(where: \.isAI)
    }

    public static func firstAI(orderedBy rawValue: String, hidden hiddenRawValue: String = "") -> Self? {
        orderedVisible(by: rawValue, hidden: hiddenRawValue).first(where: \.isAI)
    }

    /// Compact labels mirror Superset's 24pt preset bar without weakening the
    /// descriptive names used by the full session launcher.
    public var presetBarTitle: String {
        switch id {
        case "shell": "Shell"
        case "claude": "Claude"
        case "codex": "Codex"
        case "trae": "Trae"
        default: title
        }
    }

    var presetBarIconName: String? {
        switch id {
        case "shell": "preset-shell"
        case "claude": "preset-claude"
        case "codex": "preset-codex"
        case "trae": "preset-trae"
        default: nil
        }
    }

    public var isAI: Bool {
        switch request.kind {
        case .claude, .codex, .trae: true
        case .shell, .custom: false
        }
    }

    /// Returns the launch request with the user's Settings overrides applied.
    /// Commands are typed into a plain shell first, so quitting an agent CLI
    /// leaves the terminal alive; an empty shell command opens a bare shell.
    public func resolvedRequest(commandOverride: String) -> TerminalSessionLaunchRequest {
        let override = commandOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = override.isEmpty ? request.command : commandOverride
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
        case .trae: "sparkle.magnifyingglass"
        case .custom: "hammer"
        }
    }
}
