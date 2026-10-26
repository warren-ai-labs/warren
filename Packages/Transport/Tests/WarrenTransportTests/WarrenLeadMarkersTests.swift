import XCTest
@testable import WarrenTransport

final class WarrenLeadMarkersTests: XCTestCase {
    private let crewID = "11111111-1111-1111-1111-111111111111"
    private let otherID = "22222222-2222-2222-2222-222222222222"

    // MARK: Parser

    func testAgentReferenceWithAndWithoutTitle() {
        let bare = WarrenLeadMessage.parse("See [#agent:\(crewID)].")
        XCTAssertEqual(bare.agentReferences.map(\.sessionID), [crewID])
        XCTAssertNil(bare.agentReferences.first?.title)

        let titled = WarrenLeadMessage.parse("[#agent:\(crewID)|Parse markers]")
        XCTAssertEqual(titled.agentReferences.first?.sessionID, crewID)
        XCTAssertEqual(titled.agentReferences.first?.title, "Parse markers")
    }

    func testDecisionWithPipesAndEscapedPipe() {
        let message = WarrenLeadMessage.parse(
            "[#ask:Which branch\\|tag should I ship?|main|release|hotfix]"
        )
        XCTAssertEqual(message.asks.count, 1)
        XCTAssertEqual(message.asks.first?.question, "Which branch|tag should I ship?")
        XCTAssertEqual(message.asks.first?.options, ["main", "release", "hotfix"])
    }

    func testConsecutiveChecksBecomeOneList() {
        let message = WarrenLeadMessage.parse(
            "Check these:\n[#accept:References open the Session|main @ abc123]\n[#accept:Only decisions notify|the notice center]"
        )
        XCTAssertEqual(message.checklists.count, 1)
        XCTAssertEqual(message.checklists.first?.map(\.what), [
            "References open the Session",
            "Only decisions notify",
        ])
        XCTAssertEqual(message.checklists.first?.map(\.at), [
            "main @ abc123",
            "the notice center",
        ])
    }

    func testChecksSeparatedByParagraphAreTwoLists() {
        let message = WarrenLeadMessage.parse(
            "[#accept:A|main]\n\nSome words.\n\n[#accept:B|main]"
        )
        XCTAssertEqual(message.checklists.count, 2)
    }

    func testMarkersInsideFencedCodeAreLeftAsWritten() {
        let source = """
        Before.
        ```text
        [#agent:\(crewID)|Parse markers]
        [#ask:Question?|Yes|No]
        ```
        After [#agent:\(crewID)]
        """
        let message = WarrenLeadMessage.parse(source)
        XCTAssertEqual(message.agentReferences.count, 1)
        XCTAssertEqual(message.asks.count, 0)
        let text = message.blocks.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }.joined()
        XCTAssertTrue(text.contains("[#ask:Question?|Yes|No]"))
    }

    func testMarkersInsideInlineCodeAreLeftAsWritten() {
        let message = WarrenLeadMessage.parse(
            "Write `[#agent:\(crewID)]` to refer; here is a real [#agent:\(otherID)]."
        )
        XCTAssertEqual(message.agentReferences.map(\.sessionID), [otherID])
        let text = message.blocks.compactMap { block -> String? in
            guard case .text(let value) = block else { return nil }
            return value
        }.joined()
        XCTAssertTrue(text.contains("`[#agent:\(crewID)]`"))
    }

    func testDoubleBacktickSpanCanContainSingleBackticks() {
        let message = WarrenLeadMessage.parse(
            "``a ` [#agent:\(crewID)] `` and [#agent:\(otherID)]"
        )
        XCTAssertEqual(message.agentReferences.map(\.sessionID), [otherID])
    }

    func testMalformedMarkersAreLeftAsWritten() {
        for source in [
            "[#agent:]",
            "[#agent:\(crewID)|]",
            "[#ask:Only a question?]",
            "[#ask:|Yes|No]",
            "[#ask:Question?|Yes|]",
            "[#accept:Only one field]",
            "[#accept:|main]",
            "[#unknown:value]",
            "[]",
        ] {
            let message = WarrenLeadMessage.parse(source)
            XCTAssertTrue(message.blocks == [.text(source)], "\(source) should stay written")
        }
    }

    func testUnknownReferenceStillParsesAndIsFilteredByDerivation() {
        let message = WarrenLeadMessage.parse("[#agent:not-a-session|Ghost]")
        XCTAssertEqual(message.agentReferences.first?.sessionID, "not-a-session")

        var conversation = WarrenConversation()
        var turn = WarrenConversation.Turn(id: "t1")
        turn.answer = "[#agent:not-a-session|Ghost]"
        conversation.turns = [turn]

        let unknown = WarrenLeadConversation.derive(from: conversation) { _ in false }
        XCTAssertFalse(unknown.isLead)
        XCTAssertTrue(unknown.crew.isEmpty)

        let known = WarrenLeadConversation.derive(from: conversation) { _ in true }
        XCTAssertTrue(known.isLead)
        XCTAssertEqual(known.crew.map(\.sessionID), ["not-a-session"])
    }

    // MARK: Lead and Crew derivation

    func testCrewKeepsFirstReferenceOrderAndIgnoresDuplicates() {
        var conversation = WarrenConversation()
        var first = WarrenConversation.Turn(id: "t1")
        first.answer = "[#agent:\(crewID)|First]"
        var second = WarrenConversation.Turn(id: "t2")
        second.answer = "[#agent:\(otherID)|Second]\n[#agent:\(crewID)|First again]"
        conversation.turns = [first, second]

        let lead = WarrenLeadConversation.derive(from: conversation)
        XCTAssertTrue(lead.isLead)
        XCTAssertEqual(lead.crew.map(\.sessionID), [crewID, otherID])
        XCTAssertEqual(lead.crew.map(\.markerTitle), ["First", "Second"])
    }

    func testMarkersInThePromptDoNotMakeALead() {
        var conversation = WarrenConversation()
        var turn = WarrenConversation.Turn(id: "t1")
        turn.prompt = "[#agent:\(crewID)|Quoted]"
        turn.answer = "No agents here."
        conversation.turns = [turn]

        XCTAssertFalse(WarrenLeadConversation.derive(from: conversation).isLead)
    }

    func testUnansweredAskNeedsAttentionAndALaterPromptAnswersIt() {
        var conversation = WarrenConversation()
        var turn = WarrenConversation.Turn(id: "t1")
        turn.prompt = "Start"
        turn.answer = "[#ask:Plain text for a TUI Lead?|Yes|No]"
        conversation.turns = [turn]

        let pending = WarrenLeadConversation.derive(from: conversation)
        XCTAssertTrue(pending.needsAttention)
        XCTAssertEqual(pending.pendingDecision?.question, "Plain text for a TUI Lead?")
        XCTAssertEqual(pending.pendingDecision?.options, ["Yes", "No"])

        var reply = WarrenConversation.Turn(id: "t2")
        reply.prompt = "Decision: Yes"
        conversation.turns.append(reply)
        let answered = WarrenLeadConversation.derive(from: conversation)
        XCTAssertFalse(answered.needsAttention)
    }

    func testChecksNeedAttentionUntilTheReplyTurnExists() {
        var conversation = WarrenConversation()
        var turn = WarrenConversation.Turn(id: "t1")
        turn.prompt = "Start"
        turn.answer = "[#accept:A|main]\n[#accept:B|main]"
        conversation.turns = [turn]
        XCTAssertTrue(WarrenLeadConversation.derive(from: conversation).needsAttention)
        XCTAssertEqual(WarrenLeadConversation.derive(from: conversation).pendingChecks?.checks.count, 2)

        var reply = WarrenConversation.Turn(id: "t2")
        reply.prompt = "Check passed: A\nCheck passed: B"
        conversation.turns.append(reply)
        XCTAssertFalse(WarrenLeadConversation.derive(from: conversation).needsAttention)
    }

    func testPlainLeadMessagesDoNotNeedAttention() {
        var conversation = WarrenConversation()
        var turn = WarrenConversation.Turn(id: "t1")
        turn.answer = "[#agent:\(crewID)|Crew] is still running."
        conversation.turns = [turn]
        let lead = WarrenLeadConversation.derive(from: conversation)
        XCTAssertTrue(lead.isLead)
        XCTAssertFalse(lead.needsAttention)
    }

    // MARK: Replies

    func testDecisionReplyIsAPlainUserMessage() {
        XCTAssertEqual(WarrenLeadReply.decision("Yes, plain text for now"), "Decision: Yes, plain text for now")
    }

    func testCheckReplyListsEachResultOnItsOwnLine() {
        let message = WarrenLeadReply.checks([
            .init(what: "References open the Session", outcome: .passed),
            .init(what: "Only decisions notify", outcome: .problem(note: "Crew finishing notified too")),
            .init(what: "Code fences stay written", outcome: .problem(note: "")),
        ])
        // Trailing spaces are Markdown's hard break: each result keeps its own
        // line in the transcript's renderer instead of being wrapped together.
        XCTAssertEqual(
            message,
            "Check passed: References open the Session  \n"
                + "Check problem: Only decisions notify — Crew finishing notified too  \n"
                + "Check problem: Code fences stay written"
        )
    }
}
