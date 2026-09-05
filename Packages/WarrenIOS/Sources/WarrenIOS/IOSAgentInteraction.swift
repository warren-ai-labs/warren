import Foundation
import WarrenTransport

/// The compact Session rail has two stable presentation modes. Keeping the
/// threshold in one value-only helper makes the rule testable without
/// constructing SwiftUI views.
public enum IOSSessionRailLayout: Equatable, Sendable {
    case tabs
    case aggregate
}

public func sessionRailLayout(for sessionCount: Int) -> IOSSessionRailLayout {
    sessionCount <= 2 ? .tabs : .aggregate
}

/// Formats provider model identifiers for human-facing chrome. Protocol values
/// may include a provider prefix and use kebab/snake case; neither belongs in
/// the compact composer metadata.
public func formatAgentModel(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    var leaf = value.split(separator: "/").last.map(String.init) ?? value

    // Strip common tags like :latest, :free, @...
    if let colonIndex = leaf.lastIndex(of: ":") {
        let suffix = leaf[colonIndex...].lowercased()
        if suffix == ":latest" || suffix == ":free" {
            leaf = String(leaf[..<colonIndex])
        }
    }
    if let atIndex = leaf.lastIndex(of: "@") {
        leaf = String(leaf[..<atIndex])
    }

    // Strip trailing snapshot date / latest suffixes (e.g. -20250219, -2024-10-22, -latest)
    if let dateRange = leaf.range(of: #"-(?:20\d{6}|20\d{2}-\d{2}-\d{2}|latest)$"#, options: .regularExpression) {
        leaf.removeSubrange(dateRange)
    }

    // Convert hyphens between digits to decimal dots: e.g. 3-7 -> 3.7, 3-5 -> 3.5
    leaf = leaf.replacingOccurrences(of: #"(?<=\d)-(?=\d)"#, with: ".", options: .regularExpression)

    let words = leaf
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
        .split(separator: "-", omittingEmptySubsequences: true)
        .map(String.init)
    guard !words.isEmpty else { return nil }
    return words.map { word in
        let lower = word.lowercased()
        switch lower {
        case "gpt": return "GPT"
        case "llm": return "LLM"
        case "sol": return "Sol"
        case "sonnet": return "Sonnet"
        case "haiku": return "Haiku"
        case "opus": return "Opus"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        case "deepseek": return "DeepSeek"
        case "qwen": return "Qwen"
        case "llama": return "Llama"
        case "mistral": return "Mistral"
        case "codestral": return "Codestral"
        case "dbrx": return "DBRX"
        case "glm": return "Glm"
        default:
            if lower.range(of: #"^o[1-9]$"#, options: .regularExpression) != nil {
                return lower
            }
            if lower.range(of: #"^r\d+$"#, options: .regularExpression) != nil {
                return lower.uppercased()
            }
            if lower.range(of: #"^v\d+$"#, options: .regularExpression) != nil {
                return lower.uppercased()
            }
            if lower.range(of: #"^\d+b$"#, options: .regularExpression) != nil {
                return lower.dropLast() + "B"
            }
            guard let first = word.first else { return word }
            return String(first).uppercased() + word.dropFirst().lowercased()
        }
    }.joined(separator: " ")
}

public struct IOSAgentModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let provider: String?

    public init(id: String, label: String, provider: String? = nil) {
        self.id = id
        self.label = label
        self.provider = provider
    }
}

public enum IOSAgentReasoningEffort: String, CaseIterable, Identifiable, Sendable {
    case defaultEffort = "default"
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .defaultEffort: return "Default"
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    public var shortLabel: String {
        switch self {
        case .defaultEffort: return ""
        case .off: return "No Reasoning"
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        }
    }

    public var description: String {
        switch self {
        case .defaultEffort: return "Standard model reasoning"
        case .off: return "Disable extended thinking"
        case .low: return "Fast, minimal reasoning"
        case .medium: return "Balanced reasoning effort"
        case .high: return "Thorough, deep reasoning"
        }
    }
}

public func availableAgentModels(for sessionKind: String?) -> [IOSAgentModelOption] {
    let kind = (sessionKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch kind {
    case "codex":
        return [
            IOSAgentModelOption(id: "gpt-5", label: "GPT-5", provider: "codex"),
            IOSAgentModelOption(id: "gpt-5-mini", label: "GPT-5 mini", provider: "codex"),
            IOSAgentModelOption(id: "o3", label: "o3", provider: "codex"),
            IOSAgentModelOption(id: "o3-mini", label: "o3-mini", provider: "codex"),
            IOSAgentModelOption(id: "o1", label: "o1", provider: "codex"),
            IOSAgentModelOption(id: "gpt-4.1", label: "GPT-4.1", provider: "codex"),
        ]
    case "claude", "claude-code":
        return [
            IOSAgentModelOption(id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet", provider: "claude"),
            IOSAgentModelOption(id: "claude-3-5-sonnet", label: "Claude 3.5 Sonnet", provider: "claude"),
            IOSAgentModelOption(id: "claude-3-5-haiku", label: "Claude 3.5 Haiku", provider: "claude"),
            IOSAgentModelOption(id: "claude-3-opus", label: "Claude 3 Opus", provider: "claude"),
        ]
    case "antigravity", "agy":
        return [
            IOSAgentModelOption(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro", provider: "antigravity"),
            IOSAgentModelOption(id: "gemini-2.5-flash", label: "Gemini 2.5 Flash", provider: "antigravity"),
            IOSAgentModelOption(id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet", provider: "antigravity"),
            IOSAgentModelOption(id: "auto", label: "Auto", provider: "antigravity"),
        ]
    case "opencode", "open-code":
        return [
            IOSAgentModelOption(id: "anthropic/claude-3-7-sonnet", label: "Claude 3.7 Sonnet", provider: "opencode"),
            IOSAgentModelOption(id: "openai/gpt-5", label: "GPT-5", provider: "opencode"),
            IOSAgentModelOption(id: "openai/o3-mini", label: "o3-mini", provider: "opencode"),
            IOSAgentModelOption(id: "deepseek/deepseek-r1", label: "DeepSeek R1", provider: "opencode"),
            IOSAgentModelOption(id: "deepseek/deepseek-chat", label: "DeepSeek V3", provider: "opencode"),
        ]
    case "pi":
        return [
            IOSAgentModelOption(id: "anthropic/claude-3-7-sonnet", label: "Claude 3.7 Sonnet", provider: "pi"),
            IOSAgentModelOption(id: "openai/gpt-5", label: "GPT-5", provider: "pi"),
            IOSAgentModelOption(id: "deepseek/deepseek-r1", label: "DeepSeek R1", provider: "pi"),
        ]
    case "qoder":
        return [
            IOSAgentModelOption(id: "efficient", label: "Efficient", provider: "qoder"),
            IOSAgentModelOption(id: "performance", label: "Performance", provider: "qoder"),
            IOSAgentModelOption(id: "gpt-5", label: "GPT-5", provider: "qoder"),
            IOSAgentModelOption(id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet", provider: "qoder"),
        ]
    default:
        return [
            IOSAgentModelOption(id: "claude-3-7-sonnet", label: "Claude 3.7 Sonnet"),
            IOSAgentModelOption(id: "claude-3-5-sonnet", label: "Claude 3.5 Sonnet"),
            IOSAgentModelOption(id: "gpt-5", label: "GPT-5"),
            IOSAgentModelOption(id: "o3-mini", label: "o3-mini"),
            IOSAgentModelOption(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro"),
            IOSAgentModelOption(id: "deepseek-r1", label: "DeepSeek R1"),
        ]
    }
}

public func agentModelSwitchCommand(modelId: String) -> String {
    let model = modelId
        .unicodeScalars
        .map { scalar in
            switch scalar.value {
            case 0...31, 127, 0x2028, 0x2029: return " "
            default: return String(scalar)
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !model.isEmpty else { return "" }
    return "/model \(model)"
}

public func agentReasoningSwitchCommand(effort: IOSAgentReasoningEffort, sessionKind: String?) -> String? {
    guard effort != .defaultEffort else { return nil }
    let kind = (sessionKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if kind == "pi" {
        return "/thinking \(effort.rawValue)"
    }
    return "/effort \(effort.rawValue)"
}

public func agentReasoningResetCommand(sessionKind: String?) -> String {
    let kind = (sessionKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return kind == "pi" ? "/thinking default" : "/effort default"
}

private func shellQuoteAgentArgument(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func defaultAgentLaunchCommand(for kind: String) -> String {
    switch kind {
    case "claude", "claude-code": return "claude"
    case "codex": return "codex --dangerously-bypass-hook-trust"
    case "antigravity", "agy": return "agy"
    case "opencode", "open-code": return "opencode"
    case "pi": return "pi"
    case "qoder": return "qoder"
    case "trae": return "trae-cli interactive"
    default: return ""
    }
}

private func normalizedAgentModelID(_ value: String) -> String {
    value.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0...31, 127, 0x2028, 0x2029: return " "
        default: return String(scalar)
        }
    }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Adds optional model/reasoning flags to a provider launch command. Empty or
/// default settings intentionally return the configured command unchanged.
public func agentLaunchCommand(
    command: String?,
    sessionKind: String?,
    modelID: String? = nil,
    reasoningEffort: IOSAgentReasoningEffort = .defaultEffort
) -> String? {
    let kind = (sessionKind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let configuredBase = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let base = configuredBase.isEmpty ? defaultAgentLaunchCommand(for: kind) : configuredBase
    var arguments: [String] = []
    if let modelID {
        let model = normalizedAgentModelID(modelID)
        if !model.isEmpty, ["claude", "claude-code", "codex", "antigravity", "agy", "opencode", "open-code", "pi", "qoder"].contains(kind) {
            arguments += ["--model", shellQuoteAgentArgument(model)]
        }
    }
    switch reasoningEffort {
    case .defaultEffort:
        break
    case .off:
        if kind == "pi" { arguments += ["--thinking", reasoningEffort.rawValue] }
    case .low, .medium, .high:
        if kind == "codex" {
            arguments += ["-c", "model_reasoning_effort=\(reasoningEffort.rawValue)"]
        } else if ["claude", "claude-code", "antigravity", "agy"].contains(kind) {
            arguments += ["--effort", reasoningEffort.rawValue]
        } else if kind == "pi" {
            arguments += ["--thinking", reasoningEffort.rawValue]
        } else if kind == "qoder" {
            arguments += ["--reasoning-effort", reasoningEffort.rawValue]
        }
    }
    let result = ([base] + arguments).filter { !$0.isEmpty }.joined(separator: " ")
    return result.isEmpty ? nil : result
}

/// Local queue entries are deliberately value-only. They never represent a
/// transcript event and therefore can be edited, reordered, retried, or
/// deleted without mutating Host history.
public struct IOSAgentQueuedMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// The primary composer action is derived from authoritative Agent status.
/// While working, the same primary button is an interrupt; text remains a
/// local queue operation and is never sent through a second protocol.
public enum IOSAgentComposerAction: Equatable, Sendable {
    case send
    case interrupt
    case unavailable
}

public func agentComposerAction(
    activity: WarrenRemoteAgentActivity?,
    hasControl: Bool,
    hasText: Bool,
    attention: WarrenRemoteAgentAttention? = nil
) -> IOSAgentComposerAction {
    guard hasControl else { return .unavailable }
    guard activity != .failed, activity != .stalled, activity != .exited, activity != .unknown else {
        return .unavailable
    }
    // Approval and warning attention must be handled in Terminal. Only a
    // Host-projected input question is answerable from this composer.
    if let attention, attention.kind != .input { return .unavailable }
    if activity == .blocked, attention?.kind != .input { return .unavailable }
    if activity == .working { return .interrupt }
    return hasText ? .send : .unavailable
}

/// Copy feedback is a transient presentation detail. These helpers normalize
/// whitespace and bound the preview so a large selected block cannot resize a
/// message row or become durable transcript data.
public func cleanCopiedText(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

public func truncateCopiedText(_ text: String, maxCharacters: Int = 120) -> String? {
    let cleaned = cleanCopiedText(text)
    guard !cleaned.isEmpty, maxCharacters > 0 else { return nil }
    if cleaned.count <= maxCharacters { return cleaned }
    let end = cleaned.index(cleaned.startIndex, offsetBy: maxCharacters)
    return String(cleaned[..<end]) + "…"
}
