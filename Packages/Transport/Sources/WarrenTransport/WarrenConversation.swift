import Foundation

/// The attention-first Conversation projection (RFC 0023 §9), shared by the
/// Desktop and iOS Conversation surfaces and kept in step with
/// `Web/src/conversation.js`.
///
/// It folds canonical Agent events into turns. A turn is what a person reads:
/// what they asked, one line summarizing the work, and the answer. A pending
/// decision is lifted out of the timeline into `decisions`, because the
/// surface shows it in one fixed place instead of wherever it scrolled.
public struct WarrenConversation: Equatable, Sendable {
    public var turns: [Turn] = []
    public var plan: Plan?
    public var context: Context?
    public var decisions: [Decision] = []
    /// The agent's selectors from the latest `config.updated` (RFC 0023 §6.11).
    public var config: [ConfigOption] = []

    public init() {}

    public struct Turn: Equatable, Sendable, Identifiable {
        public let id: String
        public var prompt: String?
        public var promptAttachments: [String] = []
        public var promptCausedBy: String?
        public var answer: String = ""
        public var answerComplete = false
        public var narration: [String] = []
        public var steps: [Step] = []
        public var reasoning = Reasoning()
        public var notices: [String] = []
        public var errors: [String] = []
        public var status: TurnStatus = .running
        public var startedAt: Date?
        public var endedAt: Date?
        public var files: [FileChange] = []
        public var summary: String = ""
        /// `Worked for 1m 12s · Read 4 files` once the turn has ended.
        public var settledLabel: String {
            var parts: [String] = []
            if let startedAt, let endedAt, endedAt.timeIntervalSince(startedAt) >= 1 {
                parts.append("Worked for \(WarrenConversation.formatElapsed(endedAt.timeIntervalSince(startedAt)))")
            }
            if !summary.isEmpty { parts.append(summary) }
            return parts.isEmpty ? "Worked" : parts.joined(separator: " · ")
        }

        fileprivate var messages: [Message] = []

        public init(id: String) { self.id = id }

        public var isEmpty: Bool {
            prompt == nil && messages.isEmpty && steps.isEmpty && errors.isEmpty && notices.isEmpty
        }
    }

    public enum TurnStatus: String, Equatable, Sendable {
        case running, completed, failed, cancelled, interrupted
    }

    public struct Reasoning: Equatable, Sendable {
        public var text: String = ""
        public var count = 0
        public var startedAt: Date?
        public var endedAt: Date?

        public var seconds: Int {
            guard let startedAt, let endedAt else { return 0 }
            return max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
        }
    }

    public struct Step: Equatable, Sendable, Identifiable {
        public enum Kind: String, Equatable, Sendable { case tool, decision }
        public enum Status: String, Equatable, Sendable { case pending, running, completed, failed }

        public let id: String
        public var kind: Kind
        public var toolKind: String = "tool"
        public var title: String = ""
        public var detail: String = ""
        public var status: Status = .pending
        public var output: String = ""
        public var error: String = ""
        public var diff: Diff?
        /// The agent terminal Session this step ran in (RFC 0023 §6.6).
        public var terminalSessionID: String?
        /// Decisions only: allowed, rejected, or expired, and the option label.
        public var outcome: String = ""
        public var choice: String = ""
        public var order: UInt64 = 0

        /// Public so the app model can format a child transcript's tool call,
        /// which arrives as payload fields rather than as a projected step.
        public init(
            id: String,
            kind: Kind,
            toolKind: String = "tool",
            title: String = "",
            detail: String = "",
            status: Status = .pending,
            output: String = "",
            error: String = "",
            diff: Diff? = nil,
            terminalSessionID: String? = nil,
            outcome: String = "",
            choice: String = "",
            order: UInt64 = 0
        ) {
            self.id = id
            self.kind = kind
            self.toolKind = toolKind
            self.title = title
            self.detail = detail
            self.status = status
            self.output = output
            self.error = error
            self.diff = diff
            self.terminalSessionID = terminalSessionID
            self.outcome = outcome
            self.choice = choice
            self.order = order
        }

        /// The verb and target shown on one line, for example ("Ran", "git status").
        public var line: (verb: String, target: String) { line(relativeTo: nil) }

        /// The line with paths under `root` (the Session's directory) shown
        /// relative to it, and a leading `cd <dir> &&` dropped from commands.
        public func line(relativeTo root: String?) -> (verb: String, target: String) {
            if kind == .decision {
                let verb = outcome == "allowed" ? "Allowed" : outcome == "rejected" ? "Rejected" : "Expired"
                return (verb, WarrenConversation.displayTarget(detail.isEmpty ? title : detail, root: root))
            }
            let running = status == .pending || status == .running
            guard let verbs = WarrenConversation.stepVerbs[toolKind] else {
                return (title.isEmpty ? "Tool" : title, detail != title ? WarrenConversation.displayTarget(detail, root: root) : "")
            }
            if toolKind == "skill" {
                // A plugin skill is `plugin:name`; the name is what was used.
                let name = detail.split(separator: ":").last.map(String.init) ?? detail
                return (running ? verbs.0 : verbs.1, name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return (running ? verbs.0 : verbs.1, WarrenConversation.displayTarget(detail.isEmpty ? title : detail, root: root))
        }
    }

    public struct ConfigOption: Equatable, Sendable, Identifiable {
        public struct Choice: Equatable, Sendable, Identifiable {
            public var id: String { value }
            public var value: String
            public var name: String
            public var description: String
            public var group: String
        }
        public let id: String
        public var name: String
        public var category: String
        public var currentValue: String
        public var choices: [Choice]
        public var currentName: String {
            choices.first { $0.value == currentValue }?.name ?? currentValue
        }
        /// The current choice without a trailing note, so `Default
        /// (recommended)` reads `Default` in a chip.
        public var shortName: String {
            let name = currentName
            guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return name }
            return String(name[..<open.lowerBound])
        }
        /// An on/off selector reads better as a toggle than as a list.
        public var isToggle: Bool {
            Set(choices.map { $0.value.lowercased() }) == ["on", "off"]
        }
    }

    /// The composer's permission chip: the agent's `mode` selector.
    public var modeOption: ConfigOption? {
        config.first { $0.category == "mode" }
    }

    /// The composer's model chip: the model first, then its effort, then any
    /// other selector the agent publishes. Everything but the mode.
    public var modelOptions: [ConfigOption] {
        let rank = ["model": 0, "thought_level": 1]
        return config
            .filter { $0.category != "mode" }
            .enumerated()
            .sorted { (rank[$0.element.category] ?? 2, $0.offset) < (rank[$1.element.category] ?? 2, $1.offset) }
            .map(\.element)
    }

    /// The model chip's label, for example `Opus 5.5 · High`: the model, and
    /// its effort unless the effort is the agent's default.
    public var modelSummary: String {
        var parts: [String] = []
        if let model = config.first(where: { $0.category == "model" }) {
            parts.append(model.shortName)
        }
        if let effort = config.first(where: { $0.category == "thought_level" }), effort.currentValue != "default" {
            parts.append(effort.shortName)
        }
        if parts.isEmpty, let first = modelOptions.first {
            parts.append(first.shortName)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public struct Diff: Equatable, Sendable {
        public var file: String
        public var additions: Int
        public var deletions: Int
        public var text: String
    }

    public struct FileChange: Equatable, Sendable, Identifiable {
        public var id: String { file }
        public var file: String
        public var additions: Int
        public var deletions: Int
        public var diffs: [String]
    }

    public struct Plan: Equatable, Sendable {
        public struct Entry: Equatable, Sendable {
            public var title: String
            public var state: String
        }
        public var entries: [Entry]
        public var done: Int { entries.filter { $0.state == "completed" }.count }
        public var total: Int { entries.count }
        public var current: String {
            (entries.first { $0.state == "in_progress" } ?? entries.first { $0.state == "pending" })?.title ?? ""
        }
    }

    public struct Context: Equatable, Sendable {
        public var used: Int
        public var size: Int
    }

    public struct Decision: Equatable, Sendable, Identifiable {
        public struct Option: Equatable, Sendable, Identifiable {
            public var id: String
            public var label: String
            public var kind: String
            public var isReject: Bool { kind.hasPrefix("reject") }
        }
        public let id: String
        public var version: UInt64
        public var kind: String
        public var title: String
        public var toolKind: String
        public var detail: String
        /// Why the Agent is asking, when the provider says. Claude and Codex
        /// send a `description`; an ACP tool call carries only its `title`,
        /// which is what the tool is about to do.
        public var reason: String = ""
        public var diff: Diff?
        public var options: [Option]
        /// The question the dock asks, from the tool kind.
        public var question: String {
            switch toolKind {
            case "ran": "Run this command?"
            case "edit", "write": "Allow this change?"
            case "delete": "Allow this deletion?"
            case "move": "Allow this move?"
            case "read": "Allow reading this file?"
            case "fetch": "Allow this request?"
            case "mode": "Switch mode?"
            default: "Allow this step?"
            }
        }
        /// What the Agent wants to do, as the end of "<Agent> wants to …".
        public var verbPhrase: String {
            switch toolKind {
            case "ran": "run a command"
            case "edit", "write": "make a change"
            case "delete": "delete a file"
            case "move": "move a file"
            case "read": "read a file"
            case "fetch": "make a request"
            case "mode": "switch mode"
            default: "do this"
            }
        }
        /// The decision's headline. The Conversation's dock and the Desktop's
        /// approval tray both say it, so a request reads the same wherever it
        /// is answered.
        public func ask(providerName: String) -> String {
            "\(providerName) wants to \(verbPhrase)"
        }
    }

    fileprivate struct Message: Equatable, Sendable {
        var id: String
        var text: String
        var complete: Bool
        var order: UInt64
    }

    /// A step's target as a person reads it: without the `cd <dir> &&` an
    /// agent prefixes to every command, and with `root/` stripped from paths.
    public static func displayTarget(_ target: String, root: String?) -> String {
        var value = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("cd "), let joiner = value.range(of: " && ") {
            value = String(value[joiner.upperBound...])
        }
        guard var root, !root.isEmpty, root != "/" else { return value }
        if !root.hasSuffix("/") { root += "/" }
        return value.replacingOccurrences(of: root, with: "")
    }

    /// A changed file's path relative to `root` when it sits under it.
    public static func displayPath(_ path: String, root: String?) -> String {
        guard var root, !root.isEmpty, root != "/" else { return path }
        if !root.hasSuffix("/") { root += "/" }
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    fileprivate static let stepVerbs: [String: (String, String)] = [
        "read": ("Reading", "Read"),
        "edit": ("Editing", "Edited"),
        "write": ("Writing", "Wrote"),
        "delete": ("Deleting", "Deleted"),
        "move": ("Moving", "Moved"),
        "ran": ("Running", "Ran"),
        "grep": ("Searching", "Searched"),
        "glob": ("Listing", "Listed"),
        "search": ("Searching", "Searched"),
        "fetch": ("Fetching", "Fetched"),
        "think": ("Thinking", "Thought"),
        "mode": ("Switching mode", "Switched mode"),
        "skill": ("Using skill", "Used skill"),
    ]
}

// MARK: - Projection

extension WarrenConversation {
    /// Projects canonical events, in sequence order, into a conversation.
    public static func project(_ events: [WarrenRemoteAgentEvent]) -> WarrenConversation {
        var projector = Projector()
        projector.fold(events.sorted(by: { $0.sequence < $1.sequence }))
        return projector.conversation()
    }

    /// Folds a conversation forward as events arrive, so a streaming batch
    /// costs what it adds rather than a re-projection of the whole history.
    ///
    /// `project` is the same fold run once from empty; a projector given the
    /// same events in the same order produces the same conversation. Events
    /// must arrive past the last folded sequence: `append` refuses a batch that
    /// reaches back, and the caller re-projects from scratch.
    public struct Projector: Sendable {
        private var result = WarrenConversation()
        private var turnIndex: [String: Int] = [:]
        private var interactions: [String: (payload: [String: WarrenRemoteJSONValue], state: String, turn: String, order: UInt64)] = [:]
        private var interactionOrder: [String] = []
        private var compactions: Set<String> = []
        /// Turns as last finished, parallel to `result.turns`; only the turns
        /// an event touched since are finished again.
        private var finished: [Turn] = []
        private var dirty: Set<Int> = []
        public private(set) var lastSequence: UInt64?

        public init() {}

        /// Folds `events` when every one lies past `lastSequence`; returns
        /// false, folding nothing, when one reaches back.
        public mutating func append(_ events: [WarrenRemoteAgentEvent]) -> Bool {
            let ordered = events.sorted(by: { $0.sequence < $1.sequence })
            if let lastSequence, let first = ordered.first, first.sequence <= lastSequence { return false }
            fold(ordered)
            return true
        }

        fileprivate mutating func fold(_ ordered: [WarrenRemoteAgentEvent]) {
            for event in ordered { fold(event) }
            if let last = ordered.last { lastSequence = max(lastSequence ?? 0, last.sequence) }
        }

        /// The conversation so far, finishing only the turns that changed.
        public mutating func conversation() -> WarrenConversation {
            for index in dirty {
                var turn = result.turns[index]
                WarrenConversation.finish(&turn)
                finished[index] = turn
            }
            dirty.removeAll(keepingCapacity: true)
            var value = result
            value.turns = finished.filter { !$0.isEmpty }
            value.decisions = interactionOrder.compactMap { id in
                guard let record = interactions[id], record.state == "pending" else { return nil }
                return WarrenConversation.decision(id: id, payload: record.payload)
            }
            return value
        }

        private mutating func turnPosition(_ event: WarrenRemoteAgentEvent) -> Int {
            let explicit = event.turnID ?? event.turn.map(String.init) ?? ""
            let key = explicit.isEmpty ? (result.turns.last?.id ?? "0") : explicit
            let index: Int
            if let existing = turnIndex[key] {
                index = existing
            } else {
                result.turns.append(Turn(id: key))
                finished.append(Turn(id: key))
                index = result.turns.count - 1
                turnIndex[key] = index
            }
            dirty.insert(index)
            return index
        }

        private mutating func fold(_ event: WarrenRemoteAgentEvent) {
            let payload = event.payload ?? [:]
            let type = event.type.lowercased()
            switch type {
            case "turn.started":
                let index = turnPosition(event)
                result.turns[index].status = .running
                result.turns[index].startedAt = WarrenConversation.date(event)
            case "turn.completed", "turn.failed", "turn.cancelled", "turn.interrupted", "turn.aborted":
                let index = turnPosition(event)
                result.turns[index].status = switch type {
                case "turn.completed": .completed
                case "turn.failed": .failed
                case "turn.interrupted": .interrupted
                default: .cancelled
                }
                result.turns[index].endedAt = WarrenConversation.date(event)
            case "message.created", "message.delta", "message.completed":
                let index = turnPosition(event)
                let role = payload.string("role") ?? "assistant"
                let id = payload.string("messageId") ?? event.id
                let content = payload.string("content") ?? ""
                if role == "user" {
                    let previous = result.turns[index].prompt ?? ""
                    result.turns[index].prompt = type == "message.delta" ? previous + content : (content.isEmpty ? previous : content)
                    result.turns[index].promptCausedBy = result.turns[index].promptCausedBy ?? event.causedBy
                    if case let .array(items)? = payload["attachments"] {
                        result.turns[index].promptAttachments = items.compactMap { item in
                            if case let .object(value) = item { return value.string("name") }
                            return nil
                        }
                    }
                } else if role == "system" {
                    if !content.isEmpty { result.turns[index].notices.append(content) }
                } else {
                    // Mutate in place: copying the array out and back would
                    // copy the message's text on every delta.
                    if let position = result.turns[index].messages.firstIndex(where: { $0.id == id }) {
                        if type == "message.delta" {
                            result.turns[index].messages[position].text += content
                        } else if !content.isEmpty {
                            result.turns[index].messages[position].text = content
                        }
                        if type == "message.completed" { result.turns[index].messages[position].complete = true }
                    } else {
                        result.turns[index].messages.append(Message(id: id, text: content, complete: type == "message.completed", order: event.sequence))
                    }
                }
            case "reasoning.delta":
                let index = turnPosition(event)
                result.turns[index].reasoning.text += payload.string("content") ?? ""
                result.turns[index].reasoning.count += 1
                let at = WarrenConversation.date(event)
                if result.turns[index].reasoning.startedAt == nil { result.turns[index].reasoning.startedAt = at }
                result.turns[index].reasoning.endedAt = at
            case "tool.started", "tool.updated", "tool.completed", "tool.failed":
                let index = turnPosition(event)
                let id = payload.string("callId") ?? event.id
                let position = result.turns[index].steps.firstIndex { $0.kind == .tool && $0.id == id }
                var step = position.map { result.turns[index].steps[$0] }
                    ?? Step(id: id, kind: .tool, order: event.sequence)
                WarrenConversation.applyTool(type: type, payload: payload, to: &step)
                if let position {
                    result.turns[index].steps[position] = step
                } else {
                    result.turns[index].steps.append(step)
                }
            case "interaction.requested", "interaction.resolved", "interaction.expired":
                let id = payload.string("interactionId") ?? payload.string("requestId") ?? event.id
                var record = interactions[id] ?? (payload: [:], state: "pending", turn: "", order: event.sequence)
                if record.turn.isEmpty {
                    let index = turnPosition(event)
                    record.turn = result.turns[index].id
                }
                record.payload.merge(payload) { _, new in new }
                record.state = type == "interaction.requested"
                    ? (record.payload.string("state") ?? "pending")
                    : (type == "interaction.resolved" ? "resolved" : "expired")
                if interactions[id] == nil { interactionOrder.append(id) }
                interactions[id] = record
                if record.state != "pending", let index = turnIndex[record.turn] {
                    dirty.insert(index)
                    let step = WarrenConversation.decisionStep(id: id, payload: record.payload, state: record.state, order: record.order)
                    if let position = result.turns[index].steps.firstIndex(where: { $0.kind == .decision && $0.id == id }) {
                        result.turns[index].steps[position] = step
                    } else {
                        result.turns[index].steps.append(step)
                    }
                }
            case "plan.updated":
                if case let .array(items)? = payload["items"] {
                    let entries = items.compactMap { item -> Plan.Entry? in
                        guard case let .object(value) = item else { return nil }
                        let title = value.string("title") ?? value.string("label") ?? ""
                        return title.isEmpty ? nil : Plan.Entry(title: title, state: value.string("state") ?? "pending")
                    }
                    result.plan = Plan(entries: entries)
                }
            case "config.updated":
                if case let .array(items)? = payload["configOptions"] { result.config = WarrenConversation.config(items) }
            case "context.updated":
                result.context = Context(used: payload.int("used"), size: payload.int("size"))
            case "compaction.updated":
                // One notice per compaction, however often it is re-reported.
                let index = turnPosition(event)
                let id = payload.string("compactionId") ?? event.id
                if !compactions.contains(id) {
                    compactions.insert(id)
                    result.turns[index].notices.append("Context compacted")
                }
            case "error":
                let index = turnPosition(event)
                if let message = payload.string("error") ?? payload.string("content"), !message.isEmpty {
                    result.turns[index].errors.append(message)
                }
            default:
                break
            }
        }
    }

    /// Merges one `tool.*` event into the step it reports on.
    fileprivate static func applyTool(type: String, payload: [String: WarrenRemoteJSONValue], to step: inout Step) {
        if let value = payload.string("toolKind"), !value.isEmpty { step.toolKind = value }
        if let value = payload.string("toolName"), !value.isEmpty { step.title = value }
        if let value = payload.string("toolDetail"), !value.isEmpty { step.detail = value }
        if let value = payload.string("output"), !value.isEmpty { step.output = value }
        if let value = payload.string("error"), !value.isEmpty { step.error = value }
        if let diff = Self.diff(payload["diff"]) { step.diff = diff }
        if let value = payload.string("terminalSessionId"), !value.isEmpty { step.terminalSessionID = value }
        if type == "tool.completed" {
            step.status = .completed
        } else if type == "tool.failed" {
            step.status = .failed
        } else if payload.string("toolStatus") == "in_progress" {
            step.status = .running
        }
    }

    /// The tool step an Agent is on, folded forward over a batch of events.
    ///
    /// A turn boundary clears it, so a new turn never shows the last turn's
    /// work. A step that starts or updates takes over; a call that merely
    /// settles while another one is current does not, because parallel
    /// tools finish out of order and the newest started call is what the
    /// Agent is doing.
    public static func currentStep(after current: Step?, applying events: [WarrenRemoteAgentEvent]) -> Step? {
        var step = current
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let type = event.type.lowercased()
            let payload = event.payload ?? [:]
            switch type {
            case "turn.started", "turn.completed", "turn.failed", "turn.cancelled", "turn.interrupted", "turn.aborted":
                step = nil
            case "tool.started", "tool.updated", "tool.completed", "tool.failed":
                let id = payload.string("callId") ?? event.id
                if var existing = step, existing.id == id {
                    applyTool(type: type, payload: payload, to: &existing)
                    step = existing
                } else if step == nil || type == "tool.started" || type == "tool.updated" {
                    var next = Step(id: id, kind: .tool, order: event.sequence)
                    applyTool(type: type, payload: payload, to: &next)
                    step = next
                }
            default:
                break
            }
        }
        return step
    }

    /// The steps a turn has taken, folded forward over a batch of events.
    ///
    /// `currentStep` answers "what is it on now"; this keeps every call the turn
    /// made, because a resting row summarizes the whole turn and not just the
    /// last call. A turn boundary clears the list, and a call updates the step
    /// with its own id so an update never adds a second row.
    public static func steps(after current: [Step], applying events: [WarrenRemoteAgentEvent]) -> [Step] {
        var steps = current
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let type = event.type.lowercased()
            let payload = event.payload ?? [:]
            switch type {
            case "turn.started", "turn.completed", "turn.failed", "turn.cancelled", "turn.interrupted", "turn.aborted":
                steps = []
            case "tool.started", "tool.updated", "tool.completed", "tool.failed":
                let id = payload.string("callId") ?? event.id
                if let position = steps.firstIndex(where: { $0.kind == .tool && $0.id == id }) {
                    applyTool(type: type, payload: payload, to: &steps[position])
                } else {
                    var step = Step(id: id, kind: .tool, order: event.sequence)
                    applyTool(type: type, payload: payload, to: &step)
                    steps.append(step)
                }
            default:
                break
            }
        }
        return steps
    }

    fileprivate static func finish(_ turn: inout Turn) {
        let lastStep = turn.steps.map(\.order).max() ?? 0
        let visible = turn.messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let answer = visible.filter { $0.order > lastStep }
        turn.narration = visible.filter { $0.order <= lastStep }.map(\.text)
        turn.answer = answer.map(\.text).joined(separator: "\n\n")
        turn.answerComplete = !answer.isEmpty && answer.allSatisfy(\.complete)
        turn.files = filesChanged(turn.steps)
        turn.summary = summarize(turn.steps)
    }

    fileprivate static func decisionStep(id: String, payload: [String: WarrenRemoteJSONValue], state: String, order: UInt64) -> Step {
        var choiceID = ""
        if case let .object(response)? = payload["response"] {
            choiceID = response.string("decision") ?? response.string("value") ?? ""
        }
        let options = Self.options(payload["options"])
        let option = options.first { $0.id == choiceID }
        var outcome = "expired"
        if state == "resolved" { outcome = option?.isReject == true ? "rejected" : "allowed" }
        var step = Step(id: id, kind: .decision, order: order)
        step.toolKind = payload.string("toolKind") ?? ""
        step.title = payload.string("title") ?? "Permission"
        step.detail = payload.string("toolDetail") ?? ""
        step.outcome = outcome
        step.choice = option?.label ?? choiceID
        step.status = outcome == "allowed" ? .completed : .failed
        return step
    }

    fileprivate static func decision(id: String, payload: [String: WarrenRemoteJSONValue]) -> Decision {
        Decision(
            id: id,
            version: UInt64(max(1, payload.int("version"))),
            kind: payload.string("kind") ?? "permission",
            title: payload.string("title") ?? "Permission",
            toolKind: payload.string("toolKind") ?? "",
            detail: payload.string("toolDetail") ?? "",
            reason: decisionReason(payload),
            diff: diff(payload["diff"]),
            options: orderedOptions(options(payload["options"]))
        )
    }

    /// The provider's own sentence for why it is asking, if it has one.
    ///
    /// Providers that carry a `description` own the wording. An ACP tool call
    /// has no description, so its tool `title` is the reason; the "Permission"
    /// placeholder is not a reason and is dropped.
    private static func decisionReason(_ payload: [String: WarrenRemoteJSONValue]) -> String {
        let description = (payload.string("description") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        let title = (payload.string("title") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return title == "Permission" ? "" : title
    }

    fileprivate static func config(_ items: [WarrenRemoteJSONValue]) -> [ConfigOption] {
        items.compactMap { item in
            guard case let .object(option) = item, let id = option.string("id"), !id.isEmpty else { return nil }
            var choices: [ConfigOption.Choice] = []
            if case let .array(values)? = option["options"] {
                choices = values.compactMap { value in
                    guard case let .object(choice) = value, let raw = choice.string("value"), !raw.isEmpty else { return nil }
                    return ConfigOption.Choice(value: raw, name: choice.string("name") ?? raw, description: choice.string("description") ?? "", group: choice.string("group") ?? "")
                }
            }
            guard !choices.isEmpty else { return nil }
            return ConfigOption(id: id, name: option.string("name") ?? id, category: option.string("category") ?? "", currentValue: option.string("currentValue") ?? "", choices: choices)
        }
    }

    private static func options(_ value: WarrenRemoteJSONValue?) -> [Decision.Option] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap { item in
            guard case let .object(option) = item, let id = option.string("id"), !id.isEmpty else { return nil }
            return Decision.Option(id: id, label: option.string("label") ?? id, kind: option.string("kind") ?? "")
        }
    }

    /// Allow before reject, once before always.
    public static func orderedOptions(_ options: [Decision.Option]) -> [Decision.Option] {
        let rank = ["allow_once": 0, "allow_always": 1, "reject_once": 2, "reject_always": 3]
        return options.enumerated().sorted { left, right in
            let l = rank[left.element.kind] ?? 4
            let r = rank[right.element.kind] ?? 4
            return l == r ? left.offset < right.offset : l < r
        }.map(\.element)
    }

    private static func diff(_ value: WarrenRemoteJSONValue?) -> Diff? {
        guard case let .object(diff)? = value else { return nil }
        return Diff(
            file: diff.string("file") ?? "",
            additions: diff.int("additions"),
            deletions: diff.int("deletions"),
            text: diff.string("diff") ?? ""
        )
    }

    /// Totals the file changes a turn made, one row per file.
    public static func filesChanged(_ steps: [Step]) -> [FileChange] {
        var order: [String] = []
        var files: [String: FileChange] = [:]
        for step in steps {
            guard let diff = step.diff, step.status != .failed else { continue }
            let name = diff.file.isEmpty ? step.detail : diff.file
            guard !name.isEmpty else { continue }
            var row = files[name] ?? FileChange(file: name, additions: 0, deletions: 0, diffs: [])
            if files[name] == nil { order.append(name) }
            row.additions += diff.additions
            row.deletions += diff.deletions
            if !diff.text.isEmpty { row.diffs.append(diff.text) }
            files[name] = row
        }
        return order.compactMap { files[$0] }
    }

    /// One line for a turn's work: counts by kind of action, in a fixed order.
    public static func summarize(_ steps: [Step]) -> String {
        summaryItems(steps).map(\.label).joined(separator: " · ")
    }

    /// A turn's work as separate counts, so a caller that can show only part of
    /// the summary still uses the same wording as `summarize`.
    public struct TurnSummaryItem: Equatable, Sendable {
        /// The kind of action a count describes. A caller that ranks the items
        /// for one narrow surface reads this instead of re-parsing the label.
        public enum Kind: String, Equatable, Sendable {
            case edited, gitWrite, ran, fetched, searched, read, other, decision
        }

        public let kind: Kind
        public let label: String
    }

    /// How a `git` command counts in a turn's summary. A writing subcommand
    /// is a Git write; a read-only one counts as reading. `nil` means the
    /// command is not git.
    public enum GitCommandClass: Equatable, Sendable {
        case read
        case write
    }

    /// The `git` subcommands that change state. A command whose subcommand is
    /// not in this set counts as a read, so an unknown or ambiguous subcommand
    /// (`branch`, `tag`, `config`) never claims a write it did not earn.
    static let writingGitSubcommands: Set<String> = [
        "add", "am", "apply", "checkout", "cherry-pick", "clean", "clone",
        "commit", "fetch", "filter-branch", "gc", "init", "lfs", "merge",
        "mv", "notes", "prune", "pull", "push", "rebase", "reset", "restore",
        "revert", "rm", "stash", "submodule", "switch", "tag", "update-index",
        "update-ref", "worktree",
    ]

    /// Classifies a command line by its first `git` invocation and that
    /// invocation's subcommand. The scan is textual on purpose: the Host
    /// reports a command as one string, so `cd repo && git commit` has to be
    /// read the same as a bare `git commit`. A command that merely mentions
    /// `git` (for example inside a quoted string) is classified too; the
    /// counts are a presentation summary, not an audit.
    public static func gitCommandClass(_ command: String) -> GitCommandClass? {
        guard let subcommand = gitSubcommand(in: command) else { return nil }
        return writingGitSubcommands.contains(subcommand) ? .write : .read
    }

    /// The subcommand of the first `git` invocation in a command line, or nil
    /// when the line never invokes git. Git's own value-taking options are
    /// skipped so `git -C /repo status` reads as `status`.
    static func gitSubcommand(in command: String) -> String? {
        let separators: Set<Character> = [";", "&", "|", "(", ")", "\n", "\t"]
        let normalized = String(command.map { separators.contains($0) ? " " : $0 })
        let tokens = normalized.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let gitIndex = tokens.firstIndex(of: "git") else { return nil }
        let valueOptions: Set<String> = [
            "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
        ]
        var index = gitIndex + 1
        while index < tokens.count {
            let token = tokens[index]
            if valueOptions.contains(token) {
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                index += 1
                continue
            }
            return token.lowercased()
        }
        return nil
    }

    /// A turn's steps as ordered counts, in `summarize`'s fixed order. The
    /// sidebar re-ranks these by its own priority, which is why the kind is
    /// carried beside the label.
    public static func summaryItems(_ steps: [Step]) -> [TurnSummaryItem] {
        let tools = steps.filter { $0.kind == .tool && $0.toolKind != "think" }
        // A `ran` step is split by what its command is: a Git write is its own
        // count, a git read joins the reads, and everything else stays a ran
        // command. A non-git command is never a Git write.
        let gitWrites = tools.filter { $0.toolKind == "ran" && gitCommandClass($0.detail) == .write }
        let gitReads = tools.filter { $0.toolKind == "ran" && gitCommandClass($0.detail) == .read }
        let commands = tools.filter { $0.toolKind == "ran" && gitCommandClass($0.detail) == nil }
        let reads = tools.filter { $0.toolKind == "read" } + gitReads
        let edits = tools.filter { ["edit", "write", "delete", "move"].contains($0.toolKind) }
        let searches = tools.filter { ["grep", "glob", "search"].contains($0.toolKind) }
        let fetches = tools.filter { $0.toolKind == "fetch" }
        var used = Set((reads + edits + gitWrites + commands + searches + fetches).map(\.id))
        var items: [TurnSummaryItem] = []
        func append(_ kind: TurnSummaryItem.Kind, _ group: [Step], unique: Bool, _ one: String, _ many: (Int) -> String) {
            let count = unique ? Set(group.map { $0.detail.isEmpty ? $0.id : $0.detail }).count : group.count
            if count == 1 { items.append(.init(kind: kind, label: one)) }
            else if count > 1 { items.append(.init(kind: kind, label: many(count))) }
        }
        append(.read, reads, unique: true, "Read 1 file", { "Read \($0) files" })
        append(.edited, edits, unique: true, "Edited 1 file", { "Edited \($0) files" })
        append(.gitWrite, gitWrites, unique: false, "Git wrote 1 change", { "Git wrote \($0) changes" })
        append(.ran, commands, unique: false, "Ran 1 command", { "Ran \($0) commands" })
        append(.searched, searches, unique: false, "Searched once", { "Searched \($0) times" })
        append(.fetched, fetches, unique: false, "Fetched 1 page", { "Fetched \($0) pages" })
        let other = tools.filter { !used.contains($0.id) }.count
        if other == 1 { items.append(.init(kind: .other, label: "Used 1 tool")) }
        else if other > 1 { items.append(.init(kind: .other, label: "Used \(other) tools")) }
        let decisions = steps.filter { $0.kind == .decision }.count
        if decisions == 1 { items.append(.init(kind: .decision, label: "1 decision")) }
        else if decisions > 1 { items.append(.init(kind: .decision, label: "\(decisions) decisions")) }
        return items
    }

    /// The text to show while an answer streams: a trailing partial word is
    /// held back so the answer grows in whole words.
    public static func visibleStreamingText(_ text: String, complete: Bool) -> String {
        guard !complete else { return text }
        let boundaries: Set<Character> = [" ", "\n", "\t", ".", ",", ";", ":", "!", "?", ")", "]", "}", "，", "。", "；", "：", "！", "？", "、"]
        guard let last = text.lastIndex(where: { boundaries.contains($0) }) else { return "" }
        return String(text[...last])
    }

    /// Elapsed time in the compact form the status line uses.
    public static func formatElapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes < 60 { return rest > 0 ? "\(minutes)m \(rest)s" : "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    nonisolated(unsafe) private static let fractionalDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plainDate: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    fileprivate static func date(_ event: WarrenRemoteAgentEvent) -> Date? {
        guard let value = event.occurredAt ?? event.recordedAt, !value.isEmpty else { return nil }
        return fractionalDate.date(from: value) ?? plainDate.date(from: value)
    }
}

private extension Dictionary where Key == String, Value == WarrenRemoteJSONValue {
    func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let value)?: return value
        case .number(let value)?: return value == value.rounded() ? String(Int(value)) : String(value)
        default: return nil
        }
    }

    func int(_ key: String) -> Int {
        switch self[key] {
        case .number(let value)?: return Int(value)
        case .string(let value)?: return Int(value) ?? 0
        default: return 0
        }
    }
}
