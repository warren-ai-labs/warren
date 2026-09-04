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
}
