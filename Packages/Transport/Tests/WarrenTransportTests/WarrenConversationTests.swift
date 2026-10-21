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

    func testDecisionReasonPrefersDescriptionAndFallsBackToTheToolTitle() {
        func reason(_ payload: [String: WarrenRemoteJSONValue]) -> String {
            var body = payload
            body["interactionId"] = .string("p")
            body["version"] = .number(1)
            body["kind"] = .string("permission")
            body["state"] = .string("pending")
            return WarrenConversation.project([
                event("interaction.requested", body, turn: "2"),
            ]).decisions.first?.reason ?? ""
        }
        // A provider that carries a description owns the wording.
        XCTAssertEqual(reason([
            "title": .string("Permission"),
            "description": .string("Claude requests permission to run Bash"),
            "toolDetail": .string("ls"),
        ]), "Claude requests permission to run Bash")
        // An ACP tool call has no description, so its tool title is the reason.
        XCTAssertEqual(reason([
            "title": .string("Run rm -rf build"),
            "toolDetail": .string("rm -rf build"),
        ]), "Run rm -rf build")
        // The "Permission" placeholder is not a reason.
        XCTAssertEqual(reason([
            "title": .string("Permission"),
            "toolDetail": .string("ls"),
        ]), "")
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

    func testSkillStepNamesTheSkillWithoutItsPluginPrefix() {
        let started = event("tool.started", [
            "callId": .string("s1"), "toolName": .string("skill"), "toolKind": .string("skill"),
            "toolDetail": .string("bilibili-backend-platform:observability-query"),
        ])
        let running = WarrenConversation.currentStep(after: nil, applying: [started])
        XCTAssertEqual(running?.line.verb, "Using skill")
        XCTAssertEqual(running?.line.target, "observability-query")
        let settled = WarrenConversation.currentStep(after: running, applying: [
            event("tool.completed", ["callId": .string("s1"), "toolKind": .string("skill")]),
        ])
        XCTAssertEqual(settled?.line.verb, "Used skill")
    }

    func testCurrentStepFollowsTheNewestStartedCallAndClearsAtTurnBoundaries() {
        let started = [
            event("turn.started"),
            event("tool.started", ["callId": .string("c1"), "toolKind": .string("ran"), "toolDetail": .string("cd /repo && git status")]),
        ]
        var step = WarrenConversation.currentStep(after: nil, applying: started)
        XCTAssertEqual(step?.id, "c1")
        XCTAssertEqual(step.map { "\($0.line(relativeTo: "/repo").verb) \($0.line(relativeTo: "/repo").target)" }, "Running git status")

        step = WarrenConversation.currentStep(after: step, applying: [
            event("tool.started", ["callId": .string("c2"), "toolKind": .string("read"), "toolDetail": .string("/repo/a.go")]),
            event("tool.completed", ["callId": .string("c1"), "toolKind": .string("ran")]),
        ])
        XCTAssertEqual(step?.id, "c2", "An older call settling does not take the line back")
        XCTAssertEqual(step?.line(relativeTo: "/repo").target, "a.go")

        step = WarrenConversation.currentStep(after: step, applying: [
            event("tool.completed", ["callId": .string("c2"), "toolKind": .string("read")]),
        ])
        XCTAssertEqual(step?.status, .completed)
        XCTAssertEqual(step?.line.verb, "Read")

        XCTAssertNil(WarrenConversation.currentStep(after: step, applying: [event("turn.completed")]))
        XCTAssertNil(WarrenConversation.currentStep(after: step, applying: [event("turn.started", turn: "2")]))
    }

    func testStepsKeepEveryCallOfTheTurnAndResetAtABoundary() {
        let events = [
            event("turn.started"),
            event("tool.started", ["callId": .string("c1"), "toolKind": .string("edit"), "toolDetail": .string("a.swift")]),
            event("tool.completed", ["callId": .string("c1"), "toolKind": .string("edit")]),
            event("tool.started", ["callId": .string("c2"), "toolKind": .string("ran"), "toolDetail": .string("swift test")]),
        ]
        let steps = WarrenConversation.steps(after: [], applying: events)
        XCTAssertEqual(steps.map(\.id), ["c1", "c2"])
        XCTAssertEqual(WarrenConversation.summarize(steps), "Edited 1 file · Ran 1 command")
        XCTAssertEqual(
            WarrenConversation.summaryItems(steps).map(\.kind),
            [.edited, .ran],
            "summaryItems is summarize as parts, in the same order"
        )
        XCTAssertEqual(
            WarrenConversation.steps(after: steps, applying: [event("turn.started", turn: "2")]),
            [],
            "A new turn starts with no steps"
        )
    }
}

extension WarrenConversationTests {
    private func commandStep(_ id: String, _ text: String, order: UInt64) -> WarrenConversation.Step {
        var step = WarrenConversation.Step(id: id, kind: .tool, order: order)
        step.toolKind = "ran"
        step.detail = text
        return step
    }

    private func readStep(_ id: String, _ text: String, order: UInt64) -> WarrenConversation.Step {
        var step = WarrenConversation.Step(id: id, kind: .tool, order: order)
        step.toolKind = "read"
        step.detail = text
        return step
    }

    /// A git command is read or written from its own text, and an unknown
    /// subcommand never claims a write.
    func testGitCommandClassReadsTheSubcommand() {
        XCTAssertEqual(WarrenConversation.gitCommandClass("git status"), .read)
        XCTAssertEqual(WarrenConversation.gitCommandClass("git -C /repo log --oneline"), .read)
        XCTAssertEqual(WarrenConversation.gitCommandClass("git branch --list"), .read)
        XCTAssertEqual(WarrenConversation.gitCommandClass("git commit -m x"), .write)
        XCTAssertEqual(WarrenConversation.gitCommandClass("cd /repo && git commit -m x"), .write)
        XCTAssertEqual(WarrenConversation.gitCommandClass("sudo git push origin main"), .write)
        XCTAssertEqual(
            WarrenConversation.gitCommandClass("git frobnicate"),
            .read,
            "An unknown subcommand is read, so it never claims a write it did not earn"
        )
        XCTAssertNil(WarrenConversation.gitCommandClass("swift test"))
        XCTAssertNil(WarrenConversation.gitCommandClass("echo hello"))
    }

    /// A git write is its own count, a git read joins the file reads, and a
    /// plain command stays a ran command.
    func testGitWritesAndReadsSplitOutOfTheRanCount() {
        let steps = [
            commandStep("c1", "git status", order: 1),
            commandStep("c2", "git commit -m x", order: 2),
            readStep("c3", "a.go", order: 3),
            commandStep("c4", "git log --oneline", order: 4),
            commandStep("c5", "swift test", order: 5),
        ]
        let items = WarrenConversation.summaryItems(steps)
        XCTAssertEqual(items.map(\.kind), [.read, .gitWrite, .ran])
        XCTAssertEqual(
            items.map(\.label),
            ["Read 3 files", "Git wrote 1 change", "Ran 1 command"]
        )
    }

    /// A tool the summary has no vocabulary for is still named honestly.
    func testUnknownToolsCountAsUsedTools() {
        var step = WarrenConversation.Step(id: "x1", kind: .tool, order: 1)
        step.toolKind = "browser"
        step.detail = "example.com"
        XCTAssertEqual(WarrenConversation.summarize([step]), "Used 1 tool")
        var second = WarrenConversation.Step(id: "x2", kind: .tool, order: 2)
        second.toolKind = "browser"
        second.detail = "example.org"
        XCTAssertEqual(WarrenConversation.summarize([step, second]), "Used 2 tools")
    }

    func testProjectorFoldedInBatchesMatchesAWholeProjection() {
        let events = [
            event("message.created", ["role": .string("user"), "content": .string("fix it"), "messageId": .string("u")]),
            event("turn.started"),
            event("message.created", ["role": .string("assistant"), "content": .string("Look"), "messageId": .string("m1")]),
            event("message.delta", ["role": .string("assistant"), "content": .string("ing"), "messageId": .string("m1")]),
            event("tool.started", ["callId": .string("c1"), "toolKind": .string("read"), "toolDetail": .string("a.go")]),
            event("tool.completed", ["callId": .string("c1"), "toolKind": .string("read")]),
            event("interaction.requested", ["interactionId": .string("p"), "state": .string("pending"), "title": .string("Run")]),
            event("interaction.resolved", ["interactionId": .string("p")]),
            event("message.created", ["role": .string("assistant"), "content": .string("Do"), "messageId": .string("m2")]),
            event("message.delta", ["role": .string("assistant"), "content": .string("ne."), "messageId": .string("m2")]),
            event("turn.completed"),
            event("message.created", ["role": .string("user"), "content": .string("again"), "messageId": .string("u2")], turn: "2"),
        ]
        var projector = WarrenConversation.Projector()
        var snapshots: [WarrenConversation] = []
        for start in stride(from: 0, to: events.count, by: 3) {
            XCTAssertTrue(projector.append(Array(events[start..<min(start + 3, events.count)])))
            snapshots.append(projector.conversation())
            XCTAssertEqual(snapshots.last, WarrenConversation.project(Array(events[0..<min(start + 3, events.count)])))
        }
        XCTAssertEqual(projector.lastSequence, events.last?.sequence)
        XCTAssertEqual(snapshots.last?.turns.map(\.answer), ["Done.", ""])
    }

    func testProjectorRefusesABatchThatReachesBack() {
        let first = event("message.created", ["role": .string("assistant"), "content": .string("a"), "messageId": .string("m")])
        let second = event("message.delta", ["role": .string("assistant"), "content": .string("b"), "messageId": .string("m")])
        var projector = WarrenConversation.Projector()
        XCTAssertTrue(projector.append([second]))
        XCTAssertFalse(projector.append([first]))
        XCTAssertEqual(projector.conversation().turns.first?.answer, "b")
    }
}
