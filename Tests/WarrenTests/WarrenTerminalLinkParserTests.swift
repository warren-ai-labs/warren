import XCTest
@testable import Warren

final class WarrenTerminalLinkParserTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testIgnoresWebAndExternalSchemes() {
        XCTAssertNil(WarrenTerminalLinkParser.parse("http://example.com"))
        XCTAssertNil(WarrenTerminalLinkParser.parse("https://github.com/abcdlsj/warren"))
        XCTAssertNil(WarrenTerminalLinkParser.parse("mailto:support@warren.app"))
        XCTAssertNil(WarrenTerminalLinkParser.parse("tel:12345678"))
        XCTAssertNil(WarrenTerminalLinkParser.parse("warren://terminal?group=Inbox"))
    }

    func testIgnoresEmptyAndNonexistentPaths() {
        XCTAssertNil(WarrenTerminalLinkParser.parse(""))
        XCTAssertNil(WarrenTerminalLinkParser.parse("   "))
        XCTAssertNil(WarrenTerminalLinkParser.parse("/nonexistent/path/to/file.swift"))
        XCTAssertNil(WarrenTerminalLinkParser.parse("relative/missing.swift"))
    }

    func testParsesAbsolutePathWithLineAndColumn() throws {
        let testFile = tempDirectory.appendingPathComponent("main.swift")
        try "print(1)".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse("\(testFile.path):42:15")
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertEqual(target.line, 42)
        XCTAssertEqual(target.column, 15)
    }

    func testParsesAbsolutePathWithLineOnly() throws {
        let testFile = tempDirectory.appendingPathComponent("foo.go")
        try "package main".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse("\(testFile.path):100")
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertEqual(target.line, 100)
        XCTAssertNil(target.column)
    }

    func testParsesAbsolutePathWithoutLineNumber() throws {
        let testFile = tempDirectory.appendingPathComponent("README.md")
        try "# hello".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse(testFile.path)
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertNil(target.line)
        XCTAssertNil(target.column)
    }

    func testParsesFileURLWithLineAndColumn() throws {
        let testFile = tempDirectory.appendingPathComponent("app.py")
        try "print(42)".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse("file://\(testFile.path):12:4")
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertEqual(target.line, 12)
        XCTAssertEqual(target.column, 4)
    }

    func testParsesRelativePathUsingWorkingDirectory() throws {
        let testFile = tempDirectory.appendingPathComponent("src").appendingPathComponent("lib.rs")
        try FileManager.default.createDirectory(at: testFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pub fn run() {}".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse(
                "src/lib.rs:25:3",
                workingDirectory: tempDirectory.path,
                workspacePath: "/some/other/path"
            )
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertEqual(target.line, 25)
        XCTAssertEqual(target.column, 3)
    }

    func testParsesRelativePathUsingWorkspacePathFallback() throws {
        let testFile = tempDirectory.appendingPathComponent("config.json")
        try "{}".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse(
                "./config.json:5",
                workingDirectory: "/other/unrelated/directory",
                workspacePath: tempDirectory.path
            )
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertEqual(target.line, 5)
        XCTAssertNil(target.column)
    }

    func testStripsEnclosingQuotesAndTrailingPunctuation() throws {
        let testFile = tempDirectory.appendingPathComponent("test.ts")
        try "console.log()".write(to: testFile, atomically: true, encoding: .utf8)

        let target = try XCTUnwrap(
            WarrenTerminalLinkParser.parse(
                "\"\(testFile.path):8:2\",",
                workingDirectory: nil,
                workspacePath: nil
            )
        )
        XCTAssertEqual(target.path, testFile.path)
        XCTAssertEqual(target.line, 8)
        XCTAssertEqual(target.column, 2)
    }

    func testIgnoresDirectories() {
        XCTAssertNil(WarrenTerminalLinkParser.parse(tempDirectory.path))
    }
}
