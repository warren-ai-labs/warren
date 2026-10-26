import Foundation

/// The inline markers a Lead Agent writes in its assistant messages (RFC 0024
/// §4). The Host and the protocol do not change: clients parse these out of the
/// message text themselves, and both Conversation surfaces share this parser.
///
/// ```text
/// [#agent:<session-id>]               a Crew member
/// [#agent:<session-id>|<title>]       the same, with a title to use if closed
/// [#ask:<question>|<option>|<option>] a decision
/// [#accept:<what>|<where>]            one check
/// ```
///
/// A marker inside a fenced code block or an inline code span is left as
/// written, and so is anything malformed. The parser never drops text: every
/// byte of the input is present in the output, either as text or as a marker.
public enum WarrenLeadMarker: Equatable, Sendable {
    case agent(sessionID: String, title: String?)
    case ask(question: String, options: [String])
    case accept(what: String, where: String)
}

/// One run of a Lead message: ordinary Markdown text, or a marker between two
/// runs. A message that has no markers is one `.text` run.
public enum WarrenLeadSegment: Equatable, Sendable {
    case text(String)
    case marker(WarrenLeadMarker)
}

/// A Lead message with its markers grouped. Consecutive `#accept` markers are
/// one checklist, because the Lead writes them as a list and the person
/// resolves them together.
public struct WarrenLeadMessage: Equatable, Sendable {
    public struct AgentReference: Equatable, Sendable, Identifiable {
        public let sessionID: String
        public let title: String?
        public var id: String { sessionID }

        public init(sessionID: String, title: String? = nil) {
            self.sessionID = sessionID
            self.title = title
        }
    }

    public struct Decision: Equatable, Sendable {
        public let question: String
        public let options: [String]

        public init(question: String, options: [String]) {
            self.question = question
            self.options = options
        }
    }

    public struct Check: Equatable, Sendable, Identifiable {
        public let what: String
        public let at: String
        public var id: String { "\(what)|\(at)" }

        public init(what: String, at: String) {
            self.what = what
            self.at = at
        }
    }

    public enum Block: Equatable, Sendable {
        case text(String)
        case agent(AgentReference)
        case ask(Decision)
        case checks([Check])
    }

    public let blocks: [Block]

    public init(blocks: [Block]) {
        self.blocks = blocks
    }

    public var agentReferences: [AgentReference] {
        blocks.compactMap {
            guard case .agent(let reference) = $0 else { return nil }
            return reference
        }
    }

    public var asks: [Decision] {
        blocks.compactMap {
            guard case .ask(let decision) = $0 else { return nil }
            return decision
        }
    }

    public var checklists: [[Check]] {
        blocks.compactMap {
            guard case .checks(let checks) = $0 else { return nil }
            return checks
        }
    }

    public static func parse(_ text: String) -> Self {
        var blocks: [Block] = []
        var pendingChecks: [Check] = []

        func flushChecks() {
            guard !pendingChecks.isEmpty else { return }
            blocks.append(.checks(pendingChecks))
            pendingChecks.removeAll(keepingCapacity: true)
        }

        for segment in WarrenLeadMessageParser.segments(in: text) {
            switch segment {
            case .text(let value):
                // Whitespace between two checks is the list's own layout, not
                // a paragraph between two lists.
                if value.allSatisfy({ $0.isWhitespace }), !pendingChecks.isEmpty {
                    continue
                }
                flushChecks()
                if !value.isEmpty { blocks.append(.text(value)) }
            case .marker(.agent(let id, let title)):
                flushChecks()
                blocks.append(.agent(AgentReference(sessionID: id, title: title)))
            case .marker(.ask(let question, let options)):
                flushChecks()
                blocks.append(.ask(Decision(question: question, options: options)))
            case .marker(.accept(let what, let at)):
                pendingChecks.append(Check(what: what, at: at))
            }
        }
        flushChecks()
        return Self(blocks: blocks)
    }
}

/// Splits a message into text and markers without interpreting what a marker
/// refers to. Code fences and inline code are copied through untouched.
public enum WarrenLeadMessageParser {
    public static func segments(in text: String) -> [WarrenLeadSegment] {
        guard text.contains("[#") else { return text.isEmpty ? [] : [.text(text)] }
        let code = codeRanges(in: text)
        var result: [WarrenLeadSegment] = []
        var textStart = text.startIndex
        var index = text.startIndex

        func flushText(upTo end: String.Index) {
            guard end > textStart else { return }
            result.append(.text(String(text[textStart..<end])))
        }

        while index < text.endIndex {
            if code.contains(where: { $0.contains(index) }) {
                index = code.first(where: { $0.contains(index) })!.upperBound
                continue
            }

            if text[index] == "[", text[index...].hasPrefix("[#") {
                if let marker = parseMarker(text, from: index) {
                    flushText(upTo: index)
                    result.append(.marker(marker.marker))
                    index = marker.end
                    textStart = index
                    continue
                }
            }

            index = text.index(after: index)
        }

        flushText(upTo: text.endIndex)
        return result
    }

    // MARK: Fences and code spans

    private struct FenceOpening {
        let marker: Character
        let length: Int
    }

    /// A fence opening at `index`, which is the start of a line: up to three
    /// spaces, then three or more backticks or tildes.
    private static func fenceInfo(_ text: String, from index: String.Index) -> FenceOpening? {
        var cursor = index
        var spaces = 0
        while cursor < text.endIndex, text[cursor] == " ", spaces < 3 {
            spaces += 1
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "`" || text[cursor] == "~" else { return nil }
        let marker = text[cursor]
        var length = 0
        while cursor < text.endIndex, text[cursor] == marker {
            length += 1
            cursor = text.index(after: cursor)
        }
        guard length >= 3 else { return nil }
        return FenceOpening(marker: marker, length: length)
    }

    /// The ranges a marker may not appear in: whole fenced blocks and inline
    /// code spans. Ranges include their delimiters and are sorted and disjoint.
    private static func codeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        var fence: (marker: Character, length: Int)?
        var fenceStart: String.Index?

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let lineAfter = lineEnd == text.endIndex
                ? lineEnd
                : text.index(after: lineEnd)

            if let current = fence {
                if let opening = fenceInfo(text, from: index),
                   opening.marker == current.marker,
                   opening.length >= current.length {
                    fence = nil
                    ranges.append((fenceStart ?? index)..<lineAfter)
                    fenceStart = nil
                }
            } else if let opening = fenceInfo(text, from: index) {
                fence = (opening.marker, opening.length)
                fenceStart = index
            } else {
                var cursor = index
                while cursor < lineEnd {
                    guard text[cursor] == "`" else {
                        cursor = text.index(after: cursor)
                        continue
                    }
                    if let span = inlineCodeSpan(text, from: cursor, lineEnd: lineEnd) {
                        ranges.append(cursor..<span)
                        cursor = span
                    } else {
                        while cursor < lineEnd, text[cursor] == "`" {
                            cursor = text.index(after: cursor)
                        }
                    }
                }
            }

            index = lineAfter
        }
        if let fenceStart { ranges.append(fenceStart..<text.endIndex) }
        return ranges
    }

    /// Just past the closing run of a code span that opens at `index`, or nil
    /// when there is no matching run on the same line. A span is run-length
    /// delimited, so a ``double`` span can contain a single backtick.
    private static func inlineCodeSpan(
        _ text: String,
        from index: String.Index,
        lineEnd: String.Index
    ) -> String.Index? {
        var openEnd = index
        while openEnd < lineEnd, text[openEnd] == "`" {
            openEnd = text.index(after: openEnd)
        }
        let length = text.distance(from: index, to: openEnd)
        guard length > 0 else { return nil }
        var cursor = openEnd
        while cursor < lineEnd {
            guard text[cursor] == "`" else {
                cursor = text.index(after: cursor)
                continue
            }
            var runEnd = cursor
            while runEnd < lineEnd, text[runEnd] == "`" {
                runEnd = text.index(after: runEnd)
            }
            if text.distance(from: cursor, to: runEnd) == length {
                return runEnd
            }
            cursor = runEnd
        }
        return nil
    }

    // MARK: Marker grammar

    private struct ParsedMarker {
        let marker: WarrenLeadMarker
        let end: String.Index
    }

    private static func parseMarker(_ text: String, from open: String.Index) -> ParsedMarker? {
        guard let close = text[open...].firstIndex(of: "]") else { return nil }
        let body = text[text.index(open, offsetBy: 1)..<close]
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let kind = String(body[body.startIndex..<colon])
        let fields = splitFields(String(body[body.index(after: colon)...]))

        let marker: WarrenLeadMarker?
        switch kind {
        case "#agent":
            guard fields.count == 1 || fields.count == 2 else { return nil }
            let id = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let title = fields.count == 2
                ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            if fields.count == 2, title?.isEmpty != false { return nil }
            marker = .agent(sessionID: id, title: title)
        case "#ask":
            guard fields.count >= 3 else { return nil }
            let question = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let options = fields.dropFirst().map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !question.isEmpty, options.allSatisfy({ !$0.isEmpty }) else { return nil }
            marker = .ask(question: question, options: options)
        case "#accept":
            guard fields.count == 2 else { return nil }
            let what = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let at = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !what.isEmpty, !at.isEmpty else { return nil }
            marker = .accept(what: what, where: at)
        default:
            marker = nil
        }
        guard let marker else { return nil }
        return ParsedMarker(marker: marker, end: text.index(after: close))
    }

    /// Splits a marker body on `|`, treating `\|` as a literal pipe so a
    /// question or title can carry one.
    private static func splitFields(_ body: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        fields.append(current)
        return fields
    }
}

// MARK: - Lead and Crew

/// What a Conversation's assistant messages say about the Lead and its Crew,
/// and which request is still waiting on the person.
///
/// The Host keeps no parent/child record (RFC 0024 §8), so this is a client
/// reading of the same message text. `isKnown` is the Session's live roster:
/// a reference that does not resolve is shown as written and does not enter the
/// Crew.
public struct WarrenLeadConversation: Equatable, Sendable {
    public struct CrewMember: Equatable, Sendable, Identifiable {
        public let sessionID: String
        /// The marker's own title, used when the Session is no longer live.
        public let markerTitle: String?
        public var id: String { sessionID }

        public init(sessionID: String, markerTitle: String? = nil) {
            self.sessionID = sessionID
            self.markerTitle = markerTitle
        }
    }

    public struct PendingDecision: Equatable, Sendable {
        public let id: String
        public let turnID: String
        public let question: String
        public let options: [String]

        public init(id: String, turnID: String, question: String, options: [String]) {
            self.id = id
            self.turnID = turnID
            self.question = question
            self.options = options
        }
    }

    public struct PendingChecks: Equatable, Sendable {
        public let id: String
        public let turnID: String
        public let checks: [WarrenLeadMessage.Check]

        public init(id: String, turnID: String, checks: [WarrenLeadMessage.Check]) {
            self.id = id
            self.turnID = turnID
            self.checks = checks
        }
    }

    public let isLead: Bool
    /// Crew in first-reference order.
    public let crew: [CrewMember]
    public let pendingDecision: PendingDecision?
    public let pendingChecks: PendingChecks?

    public var needsAttention: Bool {
        pendingDecision != nil || pendingChecks != nil
    }

    public init(
        isLead: Bool = false,
        crew: [CrewMember] = [],
        pendingDecision: PendingDecision? = nil,
        pendingChecks: PendingChecks? = nil
    ) {
        self.isLead = isLead
        self.crew = crew
        self.pendingDecision = pendingDecision
        self.pendingChecks = pendingChecks
    }

    /// Reads the Conversation. Only assistant text is considered: a marker the
    /// person quotes back to the Lead is not a request from the Lead.
    public static func derive(
        from conversation: WarrenConversation,
        isKnown: (String) -> Bool = { _ in true }
    ) -> Self {
        var crew: [CrewMember] = []
        var crewIDs: Set<String> = []
        var pendingDecision: PendingDecision?
        var pendingChecks: PendingChecks?
        var latestMarkedTurn: Int?

        for (turnIndex, turn) in conversation.turns.enumerated() {
            var message = WarrenLeadMessage(blocks: [])
            for narration in turn.narration {
                let parsed = WarrenLeadMessage.parse(narration)
                message = WarrenLeadMessage(blocks: message.blocks + parsed.blocks)
            }
            let answer = WarrenLeadMessage.parse(turn.answer)
            message = WarrenLeadMessage(blocks: message.blocks + answer.blocks)

            for reference in message.agentReferences where isKnown(reference.sessionID) {
                guard crewIDs.insert(reference.sessionID).inserted else { continue }
                crew.append(CrewMember(
                    sessionID: reference.sessionID,
                    markerTitle: reference.title
                ))
            }

            let asks = message.asks
            let checklists = message.checklists
            guard !asks.isEmpty || !checklists.isEmpty else { continue }

            latestMarkedTurn = turnIndex
            pendingDecision = asks.last.map {
                PendingDecision(
                    id: "\(turn.id)|ask|\(asks.count)",
                    turnID: turn.id,
                    question: $0.question,
                    options: $0.options
                )
            }
            pendingChecks = checklists.last.map {
                PendingChecks(
                    id: "\(turn.id)|checks|\(checklists.count)",
                    turnID: turn.id,
                    checks: $0
                )
            }
        }

        // A reply is an ordinary user message, so a turn after the marker's
        // own turn that carries a prompt is the answer. The dock disappears
        // immediately when the person sends theirs; this is what keeps it
        // answered after a relaunch.
        if let latestMarkedTurn {
            let answered = conversation.turns
                .suffix(from: latestMarkedTurn + 1)
                .contains { turn in
                    guard let prompt = turn.prompt else { return false }
                    return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            if answered {
                pendingDecision = nil
                pendingChecks = nil
            }
        }

        return Self(
            isLead: !crew.isEmpty,
            crew: crew,
            pendingDecision: pendingDecision,
            pendingChecks: pendingChecks
        )
    }
}

/// The ordinary user messages a Lead's requests turn into. Formatting lives
/// here so every client and every provider sends the same words.
public enum WarrenLeadReply {
    public enum CheckOutcome: Equatable, Sendable {
        case passed
        case problem(note: String)
    }

    public struct CheckResult: Equatable, Sendable {
        public let what: String
        public let outcome: CheckOutcome

        public init(what: String, outcome: CheckOutcome) {
            self.what = what
            self.outcome = outcome
        }
    }

    public static func decision(_ option: String) -> String {
        "Decision: \(option)"
    }

    public static func checks(_ results: [CheckResult]) -> String {
        results.map { result in
            switch result.outcome {
            case .passed:
                return "Check passed: \(result.what)"
            case .problem(let note):
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? "Check problem: \(result.what)"
                    : "Check problem: \(result.what) — \(trimmed)"
            }
        }
        // A Markdown hard break keeps one check per line in the transcript. A
        // plain newline reads as a soft wrap there, so a line long enough to
        // have wrapped would be joined back onto the one above it.
        .joined(separator: "  \n")
    }
}
