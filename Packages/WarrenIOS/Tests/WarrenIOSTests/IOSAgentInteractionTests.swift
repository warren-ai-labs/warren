import XCTest
@testable import WarrenIOS

final class IOSAgentInteractionTests: XCTestCase {
    func testAvailableAgentModelsForDifferentProviders() {
        let codexModels = availableAgentModels(for: "codex")
        XCTAssertTrue(codexModels.contains(where: { $0.id == "gpt-5" }))
        XCTAssertTrue(codexModels.contains(where: { $0.id == "o3-mini" }))

        let claudeModels = availableAgentModels(for: "claude")
        XCTAssertTrue(claudeModels.contains(where: { $0.id == "claude-3-7-sonnet" }))

        let antigravityModels = availableAgentModels(for: "antigravity")
        XCTAssertTrue(antigravityModels.contains(where: { $0.id == "gemini-2.5-pro" }))

        let piModels = availableAgentModels(for: "pi")
        XCTAssertTrue(piModels.contains(where: { $0.id == "anthropic/claude-3-7-sonnet" }))

        let fallbackModels = availableAgentModels(for: "unknown-agent")
        XCTAssertFalse(fallbackModels.isEmpty)
        XCTAssertTrue(fallbackModels.contains(where: { $0.id == "claude-3-7-sonnet" }))
    }

    func testAgentModelSwitchCommand() {
        XCTAssertEqual(agentModelSwitchCommand(modelId: "gpt-5"), "/model gpt-5")
        XCTAssertEqual(agentModelSwitchCommand(modelId: "  claude-3-7-sonnet  "), "/model claude-3-7-sonnet")
        XCTAssertEqual(agentModelSwitchCommand(modelId: ""), "")
        XCTAssertEqual(agentModelSwitchCommand(modelId: "   "), "")
    }

    func testAgentReasoningSwitchCommand() {
        XCTAssertNil(agentReasoningSwitchCommand(effort: .defaultEffort, sessionKind: "codex"))

        XCTAssertEqual(agentReasoningSwitchCommand(effort: .high, sessionKind: "codex"), "/effort high")
        XCTAssertEqual(agentReasoningSwitchCommand(effort: .medium, sessionKind: "claude"), "/effort medium")
        XCTAssertEqual(agentReasoningSwitchCommand(effort: .low, sessionKind: "antigravity"), "/effort low")
        XCTAssertEqual(agentReasoningSwitchCommand(effort: .off, sessionKind: "opencode"), "/effort off")

        // Pi session kind uses /thinking
        XCTAssertEqual(agentReasoningSwitchCommand(effort: .high, sessionKind: "pi"), "/thinking high")
        XCTAssertEqual(agentReasoningSwitchCommand(effort: .off, sessionKind: "pi"), "/thinking off")
        XCTAssertEqual(agentReasoningResetCommand(sessionKind: "pi"), "/thinking default")
        XCTAssertEqual(agentReasoningResetCommand(sessionKind: "codex"), "/effort default")
    }

    func testAgentLaunchCommandKeepsDefaultsAndAddsProviderFlags() {
        XCTAssertEqual(
            agentLaunchCommand(command: "codex --dangerously-bypass-hook-trust", sessionKind: "codex"),
            "codex --dangerously-bypass-hook-trust"
        )
        XCTAssertEqual(
            agentLaunchCommand(command: "claude", sessionKind: "claude", modelID: "claude-3-7-sonnet", reasoningEffort: .high),
            "claude --model 'claude-3-7-sonnet' --effort high"
        )
        XCTAssertEqual(
            agentLaunchCommand(command: "pi", sessionKind: "pi", modelID: "provider/model", reasoningEffort: .off),
            "pi --model 'provider/model' --thinking off"
        )
        XCTAssertEqual(
            agentLaunchCommand(command: "qoder", sessionKind: "qoder", modelID: "m", reasoningEffort: .medium),
            "qoder --model 'm' --reasoning-effort medium"
        )
        XCTAssertEqual(
            agentLaunchCommand(command: nil, sessionKind: "codex", modelID: "gpt-5"),
            "codex --dangerously-bypass-hook-trust --model 'gpt-5'"
        )
        XCTAssertEqual(
            agentModelSwitchCommand(modelId: "model\u{2028}id"),
            "/model model id"
        )
    }

    func testIOSAgentReasoningEffortProperties() {
        XCTAssertEqual(IOSAgentReasoningEffort.defaultEffort.displayName, "Default")
        XCTAssertEqual(IOSAgentReasoningEffort.high.displayName, "High")
        XCTAssertEqual(IOSAgentReasoningEffort.medium.displayName, "Medium")
        XCTAssertEqual(IOSAgentReasoningEffort.low.displayName, "Low")
        XCTAssertEqual(IOSAgentReasoningEffort.off.displayName, "Off")
    }
}
