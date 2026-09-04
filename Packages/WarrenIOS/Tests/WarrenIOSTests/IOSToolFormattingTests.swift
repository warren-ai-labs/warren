import XCTest
@testable import WarrenIOS
import WarrenTransport

final class IOSToolFormattingTests: XCTestCase {
    func testDisplayToolName() {
        XCTAssertEqual(displayToolName("exec"), "Shell")
        XCTAssertEqual(displayToolName("execute"), "Shell")
        XCTAssertEqual(displayToolName("run_command"), "Shell")
        XCTAssertEqual(displayToolName("shell"), "Shell")
        XCTAssertEqual(displayToolName("replace_file_content"), "Edit file")
        XCTAssertEqual(displayToolName("edit"), "Edit file")
        XCTAssertEqual(displayToolName("view_file"), "Read file")
        XCTAssertEqual(displayToolName("read"), "Read file")
        XCTAssertEqual(displayToolName("grep_search"), "Search files")
        XCTAssertEqual(displayToolName("grep"), "Search files")
        XCTAssertEqual(displayToolName("find_by_name"), "Find files")
        XCTAssertEqual(displayToolName("list_dir"), "Find files")
        XCTAssertEqual(displayToolName("search_web"), "Web search")
        XCTAssertEqual(displayToolName("read_url_content"), "Web fetch")
        XCTAssertEqual(displayToolName("invoke_subagent"), "Subagent")
        XCTAssertEqual(displayToolName("ask_question"), "Ask user")
        XCTAssertEqual(displayToolName("custom_tool"), "custom_tool")
        XCTAssertEqual(displayToolName(nil), "Tool")
        XCTAssertEqual(displayToolName(""), "Tool")
    }

    func testExtractPatchFiles() {
        let patch = """
        *** Update File: src/main.rs
        @@ -1,3 +1,4 @@
        +new line
        *** Add File: test.txt
        +++ b/pkg/util.go
        --- a/dev/null
        """
        let files = extractPatchFiles(patch)
        XCTAssertEqual(files, ["src/main.rs", "test.txt", "pkg/util.go"])
    }

    func testExtractExecCommands() {
        let raw = #"exec_command({ cmd: "git status --short" })"#
        let commands = extractExecCommands(raw)
        XCTAssertEqual(commands, ["git status --short"])

        let json = #"{"command": "npm test"}"#
        let jsonCommands = extractExecCommands(json)
        XCTAssertEqual(jsonCommands, ["npm test"])
    }

    func testFormatFileList() {
        XCTAssertEqual(formatFileList([]), "")
        XCTAssertEqual(formatFileList(["/Users/user/project/file.go"]), "file.go")
        XCTAssertEqual(formatFileList(["a.go", "b.go"]), "a.go, b.go")
        XCTAssertEqual(formatFileList(["a.go", "b.go", "c.go", "d.go"]), "a.go, b.go (+2 more)")
    }

    func testToolSummaryCodexExecWithFiles() {
        let event = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "exec",
            toolInput: .object(["command": .string("git commit -m 'update'")]),
            files: ["src/agent.go"]
        )
        let summary = toolSummary(for: event)
        XCTAssertEqual(summary, "git commit -m 'update' · src/agent.go")
    }

    func testToolSummaryAntigravityKeys() {
        let cmdEvent = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "run_command",
            toolInput: .object([
                "CommandLine": .string("go test ./..."),
                "toolAction": .string("Running tests"),
            ])
        )
        XCTAssertEqual(toolSummary(for: cmdEvent), "go test ./...")

        let editEvent = WarrenRemoteAgentEvent(
            sequence: 2,
            type: "tool_call",
            toolName: "replace_file_content",
            toolInput: .object([
                "TargetFile": .string("/Users/lisongjian/Workspace/gh/abcdlsj/warren/main.go"),
                "toolAction": .string("Editing file"),
            ])
        )
        XCTAssertEqual(toolSummary(for: editEvent), "Editing file: main.go")
    }

    func testIsCommandTool() {
        XCTAssertTrue(isCommandTool("shell"))
        XCTAssertTrue(isCommandTool("exec"))
        XCTAssertTrue(isCommandTool("execute"))
        XCTAssertTrue(isCommandTool("run_command"))
        XCTAssertTrue(isCommandTool("bash"))
        XCTAssertTrue(isCommandTool("local_shell_call"))
        XCTAssertFalse(isCommandTool("read"))
        XCTAssertFalse(isCommandTool("view_file"))
        XCTAssertFalse(isCommandTool("apply_patch"))
        XCTAssertFalse(isCommandTool(nil))

        let cmdEvent = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "custom_tool",
            toolInput: .object(["command": .string("pytest")])
        )
        XCTAssertTrue(isCommandTool(call: cmdEvent))

        let nonCmdEvent = WarrenRemoteAgentEvent(
            sequence: 2,
            type: "tool_call",
            toolName: "view_file",
            toolInput: .object(["AbsolutePath": .string("/a/b.txt")])
        )
        XCTAssertFalse(isCommandTool(call: nonCmdEvent))
    }

    func testCodexArgsInToolSummary() {
        let event = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "shell",
            toolInput: .object(["args": .array([.string("npm"), .string("test")])])
        )
        XCTAssertEqual(toolSummary(for: event), "npm test")
    }

    func testLatestAgentActionCodexCommand() {
        let callEvent = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "shell",
            toolInput: .object(["command": .string("git status")]),
            callID: "call-1"
        )
        let outputEvent = WarrenRemoteAgentEvent(
            sequence: 2,
            type: "tool_output",
            toolName: "shell",
            callID: "call-1",
            output: "On branch main"
        )
        // For tool_call: command tool shows command directly
        XCTAssertEqual(latestAgentAction(from: [callEvent]), "git status")
        // For tool_output: traces back to tool_call and shows command directly
        XCTAssertEqual(latestAgentAction(from: [callEvent, outputEvent]), "git status")
    }

    func testLatestAgentActionNonCommandTool() {
        let callEvent = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "view_file",
            toolInput: .object(["AbsolutePath": .string("/Users/code/main.go")]),
            callID: "call-2"
        )
        let outputEvent = WarrenRemoteAgentEvent(
            sequence: 2,
            type: "tool_output",
            toolName: "view_file",
            callID: "call-2",
            output: "package main"
        )
        XCTAssertEqual(latestAgentAction(from: [callEvent]), "Read file main.go")
        XCTAssertEqual(latestAgentAction(from: [callEvent, outputEvent]), "Read file main.go")
    }

    func testToolOutputCorrelatesAcrossFlushedActivityBlocks() {
        let call = WarrenRemoteAgentEvent(
            sequence: 1,
            type: "tool_call",
            toolName: "find_by_name",
            callID: "step_1_0"
        )
        let assistantReply = WarrenRemoteAgentEvent(
            sequence: 2,
            type: "assistant",
            content: "Searching files..."
        )
        let output = WarrenRemoteAgentEvent(
            sequence: 3,
            type: "tool_output",
            toolName: "find_by_name",
            toolStatus: "success",
            callID: "step_1_0",
            output: "main.go\nREADME.md"
        )

        let blocks = agentDisplayBlocks(from: [call, assistantReply, output])
        // Verify: The tool output correlates into the existing activity group,
        // and does NOT produce a second duplicate tool output block!
        XCTAssertEqual(blocks.count, 2)
        guard case .activity(let group) = blocks[0] else {
            XCTFail("Expected first block to be activity group")
            return
        }
        XCTAssertEqual(group.entries.count, 1)
        guard case .tool(let toolBlock) = group.entries[0] else {
            XCTFail("Expected entry to be tool block")
            return
        }
        XCTAssertEqual(toolBlock.outputs.count, 1)
        XCTAssertEqual(toolBlock.outputs[0].output, "main.go\nREADME.md")
        XCTAssertEqual(toolBlock.status, "success")

        guard case .event(let event) = blocks[1] else {
            XCTFail("Expected second block to be assistant event")
            return
        }
        XCTAssertEqual(event.content, "Searching files...")
    }
}

