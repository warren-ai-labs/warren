import Foundation
import XCTest
import WarrenTransport
@testable import Warren
@testable import WarrenDesktop

/// The application roster is decoded from the transport roster through JSON, so
/// a field the transport model does not carry is silently dropped before the
/// stopped-Tab rule ever sees it. These tests go through that round trip on
/// purpose.
final class WarrenStoppedSessionRosterTests: XCTestCase {
    private func rosterJSON(endReason: String, lifecycle: String) -> Data {
        Data(
            """
            {
              "host": {"id": "11111111-1111-4111-8111-111111111111", "name": "Mac"},
              "projects": [],
              "workspaces": [
                {
                  "id": "22222222-2222-4222-8222-222222222222",
                  "project": "33333333-3333-4333-8333-333333333333",
                  "name": "main",
                  "path": "/tmp/main"
                }
              ],
              "sessions": [
                {
                  "id": "44444444-4444-4444-8444-444444444444",
                  "workspace": "22222222-2222-4222-8222-222222222222",
                  "title": "Shell",
                  "kind": "shell",
                  "lifecycle": "\(lifecycle)",
                  "endReason": "\(endReason)"
                }
              ]
            }
            """.utf8
        )
    }

    private func applicationRoster(_ data: Data) throws -> RemoteRoster {
        let transport = try JSONDecoder().decode(WarrenRemoteRoster.self, from: data)
        let encoded = try JSONEncoder().encode(transport)
        return try JSONDecoder().decode(RemoteRoster.self, from: encoded)
    }

    private func stoppedIDs(_ roster: RemoteRoster) -> Set<String> {
        Set(
            WarrenDesktopStoppedSessionRoster.stoppedSessionIDs(
                roster.sessions.map { session in
                    WarrenDesktopStoppedSessionInput(
                        sessionID: session.id,
                        lifecycle: session.lifecycle,
                        kind: session.kind,
                        runtimeKind: session.runtimeKind,
                        endReason: session.endReason,
                        resumedFrom: session.resumedFrom
                    )
                }
            )
        )
    }

    func testEndReasonSurvivesTheApplicationRosterRoundTrip() throws {
        let roster = try applicationRoster(rosterJSON(endReason: "runtimeMissing", lifecycle: "ended"))
        XCTAssertEqual(roster.sessions.first?.endReason, "runtimeMissing")
        XCTAssertEqual(
            stoppedIDs(roster),
            ["44444444-4444-4444-8444-444444444444"]
        )
    }

    func testARunningSessionKeepsNoStoppedTabAfterTheRoundTrip() throws {
        let roster = try applicationRoster(rosterJSON(endReason: "", lifecycle: "running"))
        XCTAssertTrue(stoppedIDs(roster).isEmpty)
    }
}
