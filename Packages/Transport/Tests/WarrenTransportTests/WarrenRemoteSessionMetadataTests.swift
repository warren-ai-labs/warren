import XCTest
@testable import WarrenTransport

final class WarrenRemoteSessionMetadataTests: XCTestCase {
    func testSessionDecodesForegroundMetadata() throws {
        let json = Data("""
        {
          "id": "session-1",
          "title": "Shell",
          "kind": "shell",
          "lifecycle": "running",
          "process": "npm",
          "commandLine": "npm run dev",
          "directory": "/Users/me/repo"
        }
        """.utf8)

        let session = try JSONDecoder().decode(WarrenRemoteSession.self, from: json)

        XCTAssertEqual(session.process, "npm")
        XCTAssertEqual(session.commandLine, "npm run dev")
        XCTAssertEqual(session.directory, "/Users/me/repo")
    }

    func testSessionDecodesWithoutForegroundMetadata() throws {
        let json = Data("""
        {
          "id": "session-2",
          "title": "Shell",
          "kind": "shell",
          "lifecycle": "running"
        }
        """.utf8)

        let session = try JSONDecoder().decode(WarrenRemoteSession.self, from: json)

        XCTAssertNil(session.process)
        XCTAssertNil(session.commandLine)
        XCTAssertNil(session.directory)
    }
}
