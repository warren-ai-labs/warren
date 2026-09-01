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
    let leaf = value.split(separator: "/").last.map(String.init) ?? value
    let words = leaf
        .replacingOccurrences(of: "_", with: "-")
        .split(separator: "-", omittingEmptySubsequences: true)
        .map(String.init)
    guard !words.isEmpty else { return nil }
    return words.map { word in
        switch word.lowercased() {
        case "gpt": return "GPT"
        case "llm": return "LLM"
        case "sonnet": return "Sonnet"
        case "haiku": return "Haiku"
        case "opus": return "Opus"
        case "sol": return "Sol"
        default:
            guard let first = word.first else { return word }
            return String(first).uppercased() + word.dropFirst()
        }
    }.joined(separator: " ")
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
