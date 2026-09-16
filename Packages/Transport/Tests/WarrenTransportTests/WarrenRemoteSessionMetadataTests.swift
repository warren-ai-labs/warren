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

    func testRosterAppliesSessionMetadataDelta() throws {
        let baseline = try JSONDecoder().decode(WarrenRemoteRoster.self, from: Data("""
        {
          "revision": 5,
          "host": { "id": "host", "name": "Host" },
          "sessions": [{
            "id": "session-1",
            "title": "Shell",
            "kind": "shell",
            "lifecycle": "running",
            "process": "zsh",
            "directory": "/work/old"
          }]
        }
        """.utf8))
        let delta = try JSONDecoder().decode(WarrenRemoteRoster.Delta.self, from: Data("""
        {
          "baseRevision": 5,
          "revision": 6,
          "sessionMetadata": {
            "upsert": [{
              "id": "session-1",
              "process": "npm",
              "commandLine": "npm run dev",
              "directory": "/work/new"
            }]
          }
        }
        """.utf8))

        let updated = try XCTUnwrap(baseline.applying(delta))

        XCTAssertEqual(updated.revision, 6)
        let session = try XCTUnwrap(updated.sessions.first)
        XCTAssertEqual(session.process, "npm")
        XCTAssertEqual(session.commandLine, "npm run dev")
        XCTAssertEqual(session.directory, "/work/new")
    }
}
