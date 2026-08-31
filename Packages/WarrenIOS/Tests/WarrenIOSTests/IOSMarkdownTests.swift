import XCTest
@testable import WarrenIOS

final class IOSMarkdownTests: XCTestCase {
    func testParagraphKeepsAgentLineBreaks() {
        XCTAssertEqual(
            IOSMarkdownParser.parse("first line\nsecond line"),
            [.paragraph("first line\nsecond line")]
        )
    }

    func testListsKeepMarkersTasksAndNesting() throws {
        let blocks = IOSMarkdownParser.parse(
            "- [x] shipped\n    - nested detail\n- [ ] pending\n\n1. next"
        )

        guard case .unorderedList(let unordered) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected an unordered list")
        }
        XCTAssertEqual(unordered.map(\.depth), [0, 1, 0])
        XCTAssertEqual(unordered.map(\.taskState), [true, nil, false])
        XCTAssertEqual(unordered.map(\.text), ["shipped", "nested detail", "pending"])

        guard case .orderedList(let ordered) = try XCTUnwrap(blocks.dropFirst().first) else {
            return XCTFail("Expected a second ordered list")
        }
        XCTAssertEqual(ordered.map(\.marker), ["1."])
    }

    func testGFMTableParsesRowsAndAlignment() throws {
        let blocks = IOSMarkdownParser.parse(
            "| Name | Score | Note |\n| :--- | ---: | :---: |\n| Ada | 10 | `ok` |\n| Bob | 8 | ready |"
        )

        guard case .table(let table) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected a Markdown table")
        }
        XCTAssertEqual(table.headers, ["Name", "Score", "Note"])
        XCTAssertEqual(table.rows, [["Ada", "10", "`ok`"], ["Bob", "8", "ready"]])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center])
    }

    func testFencedCodeIsKeptSeparateFromProse() throws {
        let blocks = IOSMarkdownParser.parse("Before\n\n```swift\nlet value = 1\n```\n\nAfter")

        XCTAssertEqual(blocks.count, 3)
        guard case .code(let language, let value) = blocks[1] else {
            return XCTFail("Expected a fenced code block")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(value, "let value = 1")
    }
}
