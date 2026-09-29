import XCTest
@testable import WarrenTransport

final class WarrenConversationTests: XCTestCase {
    private var sequence: UInt64 = 0

    private func event(_ type: String, _ payload: [String: WarrenRemoteJSONValue] = [:], turn: String = "1") -> WarrenRemoteAgentEvent {
        sequence += 1
        return WarrenRemoteAgentEvent(
            sequence: sequence,
            eventID: "e\(sequence)",
            streamID: "s",
            executionID: "s",
            turnID: turn.isEmpty ? nil : turn,
            type: type,
            occurredAt: "2026-09-28T10:00:\(String(format: "%02d", Int(sequence)))Z",
            payload: payload
        )
    }

    func testTurnSeparatesPromptWorkNarrationAndAnswer() {
        let events = [
            event("message.created", ["role": .string("user"), "content": .string("fix it"), "messageId": .string("u")]),
            event("turn.started"),
            event("reasoning.delta", ["content": .string("think"), "messageId": .string("r")]),
            event("message.created", ["role": .string("assistant"), "content": .string("Looking"), "messageId": .string("m1")]),
            event("message.delta", ["role": .string("assistant"), "content": .string(" first."), "messageId": .string("m1")]),
            event("tool.started", ["callId": .string("c1"), "toolKind": .string("read"), "toolDetail": .string("a.go")]),
            event("tool.completed", ["callId": .string("c1"), "toolKind": .string("read"), "output": .string("package a")]),
            event("tool.completed", ["callId": .string("c2"), "toolKind": .string("edit"), "toolDetail": .string("a.go"),
                                     "diff": .object(["file": .string("a.go"), "additions": .number(3), "deletions": .number(1), "diff": .string("+x")])]),
            event("message.created", ["role": .string("assistant"), "content": .string("Done."), "messageId": .string("m2")]),
            event("message.completed", ["role": .string("assistant"), "content": .string("Done."), "messageId": .string("m2")]),
            event("turn.completed"),
        ]
        let conversation = WarrenConversation.project(events)
        XCTAssertEqual(conversation.turns.count, 1)
        let turn = conversation.turns[0]
        XCTAssertEqual(turn.prompt, "fix it")
        XCTAssertEqual(turn.answer, "Done.")
        XCTAssertTrue(turn.answerComplete)
        XCTAssertEqual(turn.narration, ["Looking first."])
        XCTAssertEqual(turn.summary, "Read 1 file · Edited 1 file")
        XCTAssertEqual(turn.files.map(\.file), ["a.go"])
        XCTAssertEqual(turn.files.first?.additions, 3)
        XCTAssertEqual(turn.status, .completed)
        XCTAssertEqual(turn.reasoning.count, 1)
    }

    func testPendingPermissionIsADecisionUntilResolved() {
        let request = event("interaction.requested", [
            "interactionId": .string("p"), "kind": .string("permission"), "version": .number(1),
            "title": .string("Run rm"), "toolDetail": .string("rm -rf build"), "state": .string("pending"),
            "options": .array([
                .object(["id": .string("no"), "label": .string("Reject"), "kind": .string("reject_once")]),
                .object(["id": .string("yes"), "label": .string("Allow once"), "kind": .string("allow_once")]),
            ]),
        ], turn: "2")
        let prompt = event("message.created", ["role": .string("user"), "content": .string("clean"), "messageId": .string("u")], turn: "2")
        var conversation = WarrenConversation.project([prompt, request])
        XCTAssertEqual(conversation.decisions.map(\.id), ["p"])
        XCTAssertEqual(conversation.decisions.first?.options.map(\.kind), ["allow_once", "reject_once"])
        XCTAssertTrue(conversation.turns[0].steps.isEmpty)

        let answer = event("message.created", ["role": .string("assistant"), "content": .string("chose yes"), "messageId": .string("a")], turn: "2")
        let resolved = event("interaction.resolved", ["interactionId": .string("p"), "response": .object(["decision": .string("yes")])], turn: "")
        conversation = WarrenConversation.project([prompt, request, answer, resolved])
        XCTAssertTrue(conversation.decisions.isEmpty)
        XCTAssertEqual(conversation.turns[0].answer, "chose yes")
        XCTAssertEqual(conversation.turns[0].steps.first?.line.verb, "Allowed")
        XCTAssertEqual(conversation.turns[0].steps.first?.line.target, "rm -rf build")
    }

    func testStreamingTextGrowsInWholeWords() {
        XCTAssertEqual(WarrenConversation.visibleStreamingText("Hello wor", complete: false), "Hello ")
        XCTAssertEqual(WarrenConversation.visibleStreamingText("Hello wor", complete: true), "Hello wor")
        XCTAssertEqual(WarrenConversation.visibleStreamingText("你好，世界", complete: false), "你好，")
        XCTAssertEqual(WarrenConversation.formatElapsed(72), "1m 12s")
    }

    func testPlanAndErrors() {
        let conversation = WarrenConversation.project([
            event("message.created", ["role": .string("user"), "content": .string("go"), "messageId": .string("u")], turn: "3"),
            event("plan.updated", ["items": .array([
                .object(["title": .string("Look"), "state": .string("completed")]),
                .object(["title": .string("Fix"), "state": .string("in_progress")]),
            ])], turn: "3"),
            event("error", ["error": .string("the agent exited")], turn: "3"),
            event("turn.failed", [:], turn: "3"),
        ])
        XCTAssertEqual(conversation.plan?.done, 1)
        XCTAssertEqual(conversation.plan?.current, "Fix")
        XCTAssertEqual(conversation.turns[0].errors, ["the agent exited"])
        XCTAssertEqual(conversation.turns[0].status, .failed)
    }

    func testConfigAndTerminalLinks() {
        let events = [
            event("config.updated", ["configOptions": .array([
                .object(["id": .string("model"), "name": .string("Model"), "category": .string("model"), "currentValue": .string("large"),
                         "options": .array([.object(["value": .string("small"), "name": .string("Small")]),
                                            .object(["value": .string("large"), "name": .string("Large"), "group": .string("Smart")])])]),
                .object(["id": .string("mode"), "name": .string("Mode"), "category": .string("mode"), "currentValue": .string("auto"),
                         "options": .array([.object(["value": .string("auto"), "name": .string("Auto")])])]),
                .object(["id": .string("empty"), "options": .array([])]),
            ])], turn: ""),
            event("turn.started"),
            event("tool.started", ["callId": .string("t"), "toolKind": .string("ran"), "terminalSessionId": .string("s-term")]),
            event("tool.completed", ["callId": .string("t"), "toolKind": .string("ran")]),
            event("turn.completed"),
        ]
        let conversation = WarrenConversation.project(events)
        XCTAssertEqual(conversation.config.map(\.id), ["model", "mode"])
        XCTAssertEqual(conversation.config[0].choices[1].group, "Smart")
        XCTAssertEqual(conversation.modeOption?.id, "mode")
        XCTAssertEqual(conversation.modelOptions.map(\.id), ["model"])
        XCTAssertEqual(conversation.modelSummary, "Large")
        XCTAssertEqual(conversation.turns.last?.steps.first?.terminalSessionID, "s-term")
        XCTAssertEqual(conversation.turns.last?.settledLabel, "Worked for 3s · Ran 1 command")
    }

    func testComposerChipsGroupTheSelectors() {
        func option(_ id: String, _ category: String, _ current: String, _ choices: [(String, String)]) -> WarrenRemoteJSONValue {
            .object(["id": .string(id), "name": .string(id), "category": .string(category), "currentValue": .string(current),
                     "options": .array(choices.map { .object(["value": .string($0.0), "name": .string($0.1)]) })])
        }
        let config = [
            option("mode", "mode", "auto", [("auto", "Auto"), ("plan", "Plan")]),
            option("fast", "model_config", "off", [("on", "On"), ("off", "Off")]),
            option("effort", "thought_level", "default", [("default", "Default"), ("high", "High")]),
            option("model", "model", "default", [("default", "Default (recommended)"), ("opus", "Opus 5.5")]),
        ]
        var conversation = WarrenConversation.project([event("config.updated", ["configOptions": .array(config)], turn: "")])
        XCTAssertEqual(conversation.modelOptions.map(\.id), ["model", "effort", "fast"])
        XCTAssertEqual(conversation.modelSummary, "Default")
        XCTAssertTrue(conversation.modelOptions[2].isToggle)

        conversation.config[3].currentValue = "opus"
        conversation.config[2].currentValue = "high"
        XCTAssertEqual(conversation.modelSummary, "Opus 5.5 · High")
    }

    func testStepTargetsReadWithoutDirectoryNoise() {
        XCTAssertEqual(WarrenConversation.displayTarget("cd /repo/wt && git status", root: "/repo/wt"), "git status")
        XCTAssertEqual(WarrenConversation.displayTarget("/repo/wt/Sources/A.swift", root: "/repo/wt"), "Sources/A.swift")
        XCTAssertEqual(WarrenConversation.displayTarget("rg foo /repo/wt/Web", root: "/repo/wt/"), "rg foo Web")
        XCTAssertEqual(WarrenConversation.displayTarget("ls /tmp", root: nil), "ls /tmp")
        XCTAssertEqual(WarrenConversation.displayPath("/repo/wt/a/b.md", root: "/repo/wt"), "a/b.md")
        XCTAssertEqual(WarrenConversation.displayPath("/tmp/x.md", root: "/repo/wt"), "/tmp/x.md")
    }

    func testCompactionIsOneNotice() {
        let events = [
            event("turn.started"),
            event("compaction.updated", ["compactionId": .string("c1"), "content": .string("summary")]),
            event("compaction.updated", ["compactionId": .string("c1"), "content": .string("summary")]),
            event("message.completed", ["role": .string("assistant"), "content": .string("done")]),
            event("turn.completed"),
        ]
        XCTAssertEqual(WarrenConversation.project(events).turns.last?.notices, ["Context compacted"])
    }
}
