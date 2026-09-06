import Foundation
import WarrenTransport

/// The structured event kinds understood by the Agent View. Unknown kinds are
/// retained by the reducer for sequence accounting but are not rendered.
public enum IOSAgentStructuredEventKind: String, CaseIterable, Sendable {
    case question, permission, confirmation, plan, todo, activity, plugin, subagent, attachment
    case diff, diagnostics, config, compaction, queue

    /// Accept both the legacy projected kind (`plan`) and the canonical event
    /// suffix (`plan.updated`). The transport decoder intentionally keeps
    /// canonical types opaque, so this normalization belongs in the read model.
    public init?(eventType: String) {
        let normalized = eventType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let suffixStripped = normalized.hasSuffix("_updated")
            ? String(normalized.dropLast("_updated".count))
            : normalized
        // `tasks.updated` is the historical wire spelling for the todo card.
        // Keep the projection vocabulary singular even when a Host replays
        // that older canonical event name.
        self.init(rawValue: suffixStripped == "tasks" ? "todo" : suffixStripped)
    }

    public var isComposerMetadata: Bool {
        switch self {
        case .plan, .todo, .queue, .attachment, .config:
            return true
        default:
            return false
        }
    }
}

/// A sequence-stable projection row. `stableID` is the provider object ID when
/// present; the sequence fallback keeps malformed/legacy events distinct.
public struct IOSAgentTimelineEvent: Identifiable, Equatable, Sendable {
    public let epoch: UInt64
    public let sequence: UInt64
    public let stableID: String
    public let provider: String
    public let type: String
    public let event: WarrenRemoteAgentEvent

    public var id: String { "\(epoch):\(sequence):\(stableID)" }

    public init(epoch: UInt64, event: WarrenRemoteAgentEvent) {
        self.epoch = epoch
        self.sequence = event.sequence
        self.stableID = event.id.isEmpty ? "seq-\(event.sequence)" : event.id
        self.provider = event.provider
        self.type = event.type
        self.event = event
    }
}

/// Shared iOS event reducer for live batches and history pages. It advances
/// `lastSequence` for unknown events, resets on epoch changes, deduplicates
/// replayed sequence numbers, and replaces structured objects by stable ID.
public struct IOSAgentTimelineReducer: Sendable {
    public private(set) var epoch: UInt64?
    public private(set) var lastSequence: UInt64 = 0

    private var eventsBySequence: [UInt64: WarrenRemoteAgentEvent] = [:]

    public init(epoch: UInt64? = nil) {
        self.epoch = epoch
    }

    public mutating func reset(epoch: UInt64? = nil) {
        self.epoch = epoch
        lastSequence = 0
        eventsBySequence.removeAll(keepingCapacity: true)
    }

    public mutating func apply(epoch incomingEpoch: UInt64, events incoming: [WarrenRemoteAgentEvent]) {
        // Epoch zero is the wire-compatible "not provided" value used by
        // older Hosts. It must not clear a projection that already has a
        // concrete epoch; only two non-zero, different epochs start a reset.
        if incomingEpoch != 0 {
            if let current = epoch, current != incomingEpoch {
                reset(epoch: incomingEpoch)
            } else if epoch == nil {
                epoch = incomingEpoch
            }
        }
        for event in incoming {
            lastSequence = max(lastSequence, event.sequence)
            // A sequence is immutable in the Host stream. Keeping the first
            // value protects against an out-of-order duplicate replacing a
            // complete history row with a partial live delta.
            if eventsBySequence[event.sequence] == nil {
                eventsBySequence[event.sequence] = event
            }
        }
    }

    /// All sequence-bearing events in wire order, including unknown kinds.
    /// Views should normally use `structuredEvents` or their existing prose
    /// projection instead of rendering this lossless list directly.
    public var events: [WarrenRemoteAgentEvent] {
        eventsBySequence.values.sorted { $0.sequence < $1.sequence }
    }

    public var structuredEvents: [IOSAgentTimelineEvent] {
        var byID: [String: IOSAgentTimelineEvent] = [:]
        for event in events {
            guard let kind = IOSAgentStructuredEventKind(eventType: event.type) else { continue }
            let row = IOSAgentTimelineEvent(epoch: epoch ?? 0, event: event)
            // Updates carry a new sequence but the same stable ID. The latest
            // complete payload is the one a card should display.
            let identity = structuredEventIdentity(event, kind: kind)
            byID["\(kind.rawValue):\(identity)"] = row
        }
        return byID.values.sorted { left, right in
            if left.sequence != right.sequence { return left.sequence < right.sequence }
            return left.stableID < right.stableID
        }
    }

    private func structuredEventIdentity(
        _ event: WarrenRemoteAgentEvent,
        kind: IOSAgentStructuredEventKind
    ) -> String {
        let payload = event.payload ?? [:]
        let keys: [String]
        switch kind {
        case .question, .permission, .confirmation:
            keys = ["interactionId", "requestId"]
        case .plan:
            keys = ["planId"]
        case .todo:
            keys = ["todoId", "taskListId"]
        case .activity:
            keys = ["activityId"]
        case .plugin:
            keys = ["pluginId"]
        case .subagent:
            keys = ["subagentId"]
        case .attachment:
            keys = ["attachmentId"]
        case .diff:
            keys = ["diffId", "file"]
        case .diagnostics:
            keys = ["diagnosticsId", "file"]
        case .config:
            keys = ["configId"]
        case .compaction:
            keys = ["compactionId"]
        case .queue:
            keys = ["queueId", "itemId", "requestId"]
        }
        for key in keys {
            if case .string(let value) = payload[key], !value.isEmpty {
                return value
            }
        }
        return rowIdentity(event)
    }

    private func rowIdentity(_ event: WarrenRemoteAgentEvent) -> String {
        event.id.isEmpty ? "seq-\(event.sequence)" : event.id
    }
}

public enum IOSAgentQueueStatus: String, Codable, CaseIterable, Sendable {
    case queued, sending, failed
}

public enum IOSAgentAttachmentState: String, CaseIterable, Sendable {
    case selected, uploading, ready, failed, aborted
}

/// A local composer attachment. `data` is intentionally transient and is
/// never Codable or written to the draft store; only `reference` may cross
/// the Host boundary after a successful upload.
public struct IOSAgentLocalAttachment: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let mime: String
    public let size: Int64
    public let data: Data
    public var state: IOSAgentAttachmentState
    public var progress: Double
    public var failureReason: String?
    public var reference: WarrenRemoteAgentAttachmentRef?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        mime: String,
        data: Data,
        state: IOSAgentAttachmentState = .selected,
        progress: Double = 0,
        failureReason: String? = nil,
        reference: WarrenRemoteAgentAttachmentRef? = nil
    ) {
        self.id = id
        self.name = name
        self.mime = mime
        self.size = Int64(data.count)
        self.data = data
        self.state = state
        self.progress = progress
        self.failureReason = failureReason
        self.reference = reference
    }
}

public struct IOSAgentQueueItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var attachments: [WarrenRemoteAgentAttachmentRef]
    public let createdAt: Date
    public var status: IOSAgentQueueStatus
    public var failureReason: String?
    public var failureCode: String
    public var indeterminate: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        createdAt: Date = Date(),
        status: IOSAgentQueueStatus = .queued,
        failureReason: String? = nil,
        failureCode: String = "",
        indeterminate: Bool = false
    ) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.status = status
        self.failureReason = failureReason
        self.failureCode = failureCode
        self.indeterminate = indeterminate
    }
}

/// Device-local queue operations. The queue never writes to Host history and
/// identifies edits by stable item ID, so reordering cannot target the wrong
/// message.
public struct IOSAgentMessageQueue: Sendable, Equatable {
    public private(set) var items: [IOSAgentQueueItem]

    public init(items: [IOSAgentQueueItem] = []) {
        self.items = items
    }

    @discardableResult
    public mutating func enqueue(_ item: IOSAgentQueueItem) -> String {
        items.append(item)
        return item.id
    }

    @discardableResult
    public mutating func edit(id: String, text: String, attachments: [WarrenRemoteAgentAttachmentRef]? = nil) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != .sending else { return false }
        items[index].text = text
        if let attachments { items[index].attachments = attachments }
        items[index].failureReason = nil
        items[index].failureCode = ""
        items[index].indeterminate = false
        items[index].status = .queued
        return true
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != .sending else { return false }
        items.remove(at: index)
        return true
    }

    /// Removes an item after the Host has acknowledged delivery. Unlike the
    /// user-facing `remove`, this is allowed for an item marked `sending`.
    @discardableResult
    public mutating func deliver(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    @discardableResult
    public mutating func move(id: String, beforeID: String?) -> Bool {
        guard let sourceIndex = items.firstIndex(where: { $0.id == id }), items[sourceIndex].status != .sending else { return false }
        let item = items.remove(at: sourceIndex)
        let destination = beforeID.flatMap { value in items.firstIndex(where: { $0.id == value }) } ?? items.endIndex
        items.insert(item, at: destination)
        return true
    }

    @discardableResult
    public mutating func moveToFront(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status != .sending else { return false }
        if index == 0 { return true }
        return move(id: id, beforeID: items.first?.id)
    }

    @discardableResult
    public mutating func markSending(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .queued else { return false }
        items[index].status = .sending
        items[index].failureReason = nil
        items[index].failureCode = ""
        items[index].indeterminate = false
        return true
    }

    /// Returns an in-flight item to the queue after a connection or focus
    /// lease disappears before the Host acknowledged it. The stable ID is
    /// preserved so retrying cannot create a second delivery identity.
    @discardableResult
    public mutating func markQueued(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .sending else { return false }
        items[index].status = .queued
        items[index].failureReason = nil
        items[index].failureCode = ""
        items[index].indeterminate = false
        return true
    }

    @discardableResult
    public mutating func markFailed(
        id: String,
        reason: String,
        code: String = "",
        indeterminate: Bool = false
    ) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].status = .failed
        items[index].failureReason = reason
        items[index].failureCode = code
        items[index].indeterminate = indeterminate
        return true
    }

    @discardableResult
    public mutating func retry(id: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .failed else { return false }
        if items[index].indeterminate {
            items[index].id = UUID().uuidString.lowercased()
        }
        items[index].status = .queued
        items[index].failureReason = nil
        items[index].failureCode = ""
        items[index].indeterminate = false
        return true
    }
}

public enum IOSAgentMessageActions {
    /// Returns only user/assistant prose suitable for the system pasteboard.
    /// Tool input/output, reasoning and protocol metadata are never copied.
    public static func copyableText(for event: WarrenRemoteAgentEvent) -> String? {
        let type = event.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let role = event.role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard type == "user" || type == "assistant" || role == "user" || role == "assistant" else { return nil }
        let value = event.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    public static func assistantProse(
        from events: [WarrenRemoteAgentEvent],
        turn: UInt64? = nil
    ) -> String {
        events
            .filter { event in
                let type = event.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard type == "assistant" || event.role?.lowercased() == "assistant" else { return false }
                guard turn == nil || event.turn == turn else { return turn == nil }
                return true
            }
            .compactMap(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

public extension IOSLocalStore {
    static let agentDraftMaximumBytes = 64 * 1024

    /// The identity intentionally excludes the endpoint token. URL + local
    /// endpoint name distinguishes Hosts while keeping the key safe to log.
    /// Each component is hex encoded so endpoint/session punctuation (including
    /// the separator itself) cannot create key collisions.
    static func agentDraftKey(endpointIdentity: String, sessionID: String) -> String {
        let endpoint = agentDraftKeyPart(endpointIdentity)
        let session = agentDraftKeyPart(sessionID)
        return "warren.agent-draft.\(endpoint).\(session)"
    }

    private static func agentDraftKeyPart(_ value: String) -> String {
        value.utf8.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0\(digits)" : digits
        }.joined()
    }

    var agentEndpointIdentity: String {
        guard let endpoint else { return "" }
        return "\(endpoint.name)|\(endpoint.url)"
    }

    func agentDraft(sessionID: String, endpointIdentity: String? = nil) -> String? {
        let identity = endpointIdentity ?? agentEndpointIdentity
        guard !identity.isEmpty else { return nil }
        return localObject(forKey: Self.agentDraftKey(endpointIdentity: identity, sessionID: sessionID)) as? String
    }

    @discardableResult
    func saveAgentDraft(_ text: String, sessionID: String, endpointIdentity: String? = nil) -> Bool {
        let identity = endpointIdentity ?? agentEndpointIdentity
        guard !identity.isEmpty, text.utf8.count <= Self.agentDraftMaximumBytes else { return false }
        setLocalObject(text, forKey: Self.agentDraftKey(endpointIdentity: identity, sessionID: sessionID))
        return true
    }

    func removeAgentDraft(sessionID: String, endpointIdentity: String? = nil) {
        let identity = endpointIdentity ?? agentEndpointIdentity
        guard !identity.isEmpty else { return }
        removeLocalObject(forKey: Self.agentDraftKey(endpointIdentity: identity, sessionID: sessionID))
    }
}
