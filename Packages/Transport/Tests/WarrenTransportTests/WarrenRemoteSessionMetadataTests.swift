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

    func testSessionDecodesProgramStatus() throws {
        let json = Data("""
        {
          "id": "session-3",
          "title": "Shell",
          "kind": "shell",
          "lifecycle": "running",
          "programStatus": {
            "state": "blocked",
            "kind": "permission",
            "app": "terraform",
            "title": "deploy",
            "message": "Apply 3 to add, 1 to change, 0 to destroy?",
            "records": [
              { "state": "working", "app": "deploy" },
              { "id": "eu-west", "state": "blocked", "kind": "permission", "app": "deploy" }
            ]
          }
        }
        """.utf8)

        let session = try JSONDecoder().decode(WarrenRemoteSession.self, from: json)

        let status = try XCTUnwrap(session.programStatus)
        XCTAssertEqual(status.state, .blocked)
        XCTAssertEqual(status.kind, "permission")
        XCTAssertEqual(status.app, "terraform")
        XCTAssertEqual(status.title, "deploy")
        XCTAssertEqual(status.message, "Apply 3 to add, 1 to change, 0 to destroy?")
        XCTAssertEqual(status.records?.count, 2)
        XCTAssertEqual(status.records?.last?.state, .blocked)
        XCTAssertEqual(status.records?.last?.id, "eu-west")
    }

    /// A state added by a later protocol revision must not fail decoding: the
    /// row still renders, it just cannot name the state.
    func testSessionDecodesUnknownProgramStatusState() throws {
        let json = Data("""
        { "id": "session-4", "lifecycle": "running", "programStatus": { "state": "paused" } }
        """.utf8)

        let session = try JSONDecoder().decode(WarrenRemoteSession.self, from: json)

        XCTAssertEqual(session.programStatus?.state, .unknown)
    }

    func testSessionDecodesWithoutProgramStatus() throws {
        let json = Data("""
        { "id": "session-5", "lifecycle": "running" }
        """.utf8)

        let session = try JSONDecoder().decode(WarrenRemoteSession.self, from: json)

        XCTAssertNil(session.programStatus)
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
