import Foundation
import XCTest
@testable import WarrenDomain

final class WarrenDomainTests: XCTestCase {
    func testStrongIDsRoundTripThroughJSON() throws {
        let id = ProjectID(rawValue: UUID())
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ProjectID.self, from: data)

        XCTAssertEqual(id, decoded)
        XCTAssertNotEqual(id.rawValue, HostID(rawValue: UUID()).rawValue)
    }

    func testRelationshipsAreRepresentedByDifferentStrongIDs() throws {
        let host = Host(name: "Mac")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(projectID: project.id, name: "main", path: "/tmp/warren")
        let session = TerminalSession(workspaceID: workspace.id)
        let client = Client(name: "iPhone")
        let attachment = TerminalAttachment(sessionID: session.id, clientID: client.id)
        let lease = try XCTUnwrap(ControlLease(
            sessionID: session.id,
            attachmentID: attachment.id,
            issuedAt: .distantPast,
            expiresAt: .distantFuture
        ))

        XCTAssertEqual(project.hostID, host.id)
        XCTAssertEqual(workspace.projectID, project.id)
        XCTAssertEqual(attachment.sessionID, session.id)
        XCTAssertEqual(lease.attachmentID, attachment.id)
    }

    func testWorkspaceMergeStateRoundTripsAndLegacyPayloadDefaults() throws {
        let host = Host(name: "Mac")
        let project = Project(hostID: host.id, name: "Warren", rootPath: "/tmp/warren")
        let workspace = Workspace(
            projectID: project.id,
            name: "review",
            path: "/tmp/warren-review",
            branch: "review",
            mergeState: .merged
        )

        let encoded = try JSONEncoder().encode(workspace)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["mergeState"] as? String, "merged")
        XCTAssertEqual(
            try JSONDecoder().decode(Workspace.self, from: encoded).mergeState,
            .merged
        )

        var legacyObject = object
        legacyObject.removeValue(forKey: "mergeState")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(
            try JSONDecoder().decode(Workspace.self, from: legacyData).mergeState
        )
    }

    func testTerminalGroupAndSessionScopeRoundTripThroughJSON() throws {
        let host = Host(name: "Mac")
        let group = TerminalGroup(hostID: host.id, name: "Inbox", home: "/Users/test")
        let scope = TerminalSessionScope.terminalGroup(group.id)

        let decodedGroup = try JSONDecoder().decode(
            TerminalGroup.self,
            from: JSONEncoder().encode(group)
        )
        let decodedScope = try JSONDecoder().decode(
            TerminalSessionScope.self,
            from: JSONEncoder().encode(scope)
        )

        XCTAssertEqual(decodedGroup, group)
        XCTAssertEqual(decodedScope, scope)
    }

    func testSizeConstraintsRejectNonPositiveValues() {
        XCTAssertNotNil(LayoutSize(width: 320, height: 240))
        XCTAssertNil(LayoutSize(width: 0, height: 240))
        XCTAssertNil(LayoutSize(width: .infinity, height: 240))
        XCTAssertNotNil(TerminalSize(columns: 80, rows: 24))
        XCTAssertNil(TerminalSize(columns: 0, rows: 24))
    }

    func testRecoveryAnchorAndLeaseAreCodable() throws {
        let anchor = RecoveryAnchor(epoch: 2, sequence: 42)
        let lease = try XCTUnwrap(ControlLease(
            sessionID: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            issuedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        ))

        XCTAssertEqual(anchor, try JSONDecoder().decode(
            RecoveryAnchor.self,
            from: JSONEncoder().encode(anchor)
        ))
        XCTAssertEqual(lease, try JSONDecoder().decode(
            ControlLease.self,
            from: JSONEncoder().encode(lease)
        ))
    }

    func testControlLeaseRejectsInvalidIntervalAndHonorsBoundaries() throws {
        let issuedAt = Date(timeIntervalSince1970: 100)
        let expiresAt = Date(timeIntervalSince1970: 200)
        let sessionID = TerminalSessionID()
        let attachmentID = TerminalAttachmentID()

        XCTAssertNil(ControlLease(
            sessionID: sessionID,
            attachmentID: attachmentID,
            issuedAt: issuedAt,
            expiresAt: issuedAt
        ))
        XCTAssertNil(ControlLease(
            sessionID: sessionID,
            attachmentID: attachmentID,
            issuedAt: expiresAt,
            expiresAt: issuedAt
        ))

        let lease = try XCTUnwrap(ControlLease(
            sessionID: sessionID,
            attachmentID: attachmentID,
            issuedAt: issuedAt,
            expiresAt: expiresAt
        ))
        XCTAssertFalse(lease.isActive(at: issuedAt.addingTimeInterval(-0.001)))
        XCTAssertTrue(lease.isActive(at: issuedAt))
        XCTAssertTrue(lease.isActive(at: Date(timeIntervalSince1970: 150)))
        XCTAssertFalse(lease.isActive(at: expiresAt))
        XCTAssertFalse(lease.isActive(at: expiresAt.addingTimeInterval(0.001)))
    }

    func testTerminalDisplayTitleRendersSharedPlaceholders() {
        let context = TerminalDisplayTitleContext(
            session: "Claude",
            command: "claude",
            directory: "/Users/me/Workspace/warren",
            workspace: "warren",
            branch: "main",
            host: "studio",
            user: "me",
            os: "macOS 15"
        )

        XCTAssertEqual(
            TerminalDisplayTitleTemplate.defaultValue.render(context),
            "claude — warren"
        )
        XCTAssertEqual(
            TerminalDisplayTitleTemplate(
                rawValue: "{session} · {workspace}/{branch} · {user}@{host} · {os}"
            ).render(context),
            "Claude · warren/main · me@studio · macOS 15"
        )
    }

    func testTerminalDisplayTitleCompactsLongDirectoriesForPaneHeaders() {
        let directory = "/Users/lisongjian/Workspace/gh/abcdlsj/warren"
        let context = TerminalDisplayTitleContext(
            command: "zsh",
            directory: directory
        )

        XCTAssertEqual(
            TerminalDisplayTitleTemplate.abbreviateDirectory(directory),
            "/U/l/W/g/a/warren"
        )
        XCTAssertEqual(
            TerminalDisplayTitleTemplate(rawValue: "{command} — {directory}")
                .renderCompact(context),
            "zsh — /U/l/W/g/a/warren"
        )
        XCTAssertEqual(
            TerminalDisplayTitleTemplate(rawValue: "{command} — {directory}")
                .render(context),
            "zsh — " + directory
        )

        let veryLongDirectory = "/" + (0..<40).map { "segment-\($0)" }.joined(separator: "/")
        XCTAssertLessThanOrEqual(
            TerminalDisplayTitleTemplate.abbreviateDirectory(veryLongDirectory).count,
            TerminalDisplayTitleTemplate.compactDirectoryMaxLength
        )
    }

    func testTerminalDisplayTitleCleansMissingValuesAndFallsBackToSession() {
        let context = TerminalDisplayTitleContext(session: "Shell")

        XCTAssertEqual(
            TerminalDisplayTitleTemplate(rawValue: "{command} — {directoryName}").render(context),
            "Shell"
        )
        XCTAssertEqual(
            TerminalDisplayTitleTemplate(rawValue: "{workspace} / {branch} — {session}").render(context),
            "Shell"
        )
        XCTAssertEqual(
            TerminalDisplayTitleTemplate(rawValue: "   ").rawValue,
            TerminalDisplayTitleTemplate.defaultValue.rawValue
        )
    }

    func testTerminalFontPreferenceNormalizesInvalidValuesAtTheBoundary() {
        XCTAssertEqual(
            TerminalFontPreference(family: "   ", size: .nan),
            TerminalFontPreference()
        )
        XCTAssertEqual(
            TerminalFontPreference(family: "  JetBrains Mono  ", size: 2),
            TerminalFontPreference(family: "JetBrains Mono", size: 8)
        )
        XCTAssertEqual(
            TerminalFontPreference(family: "Berkeley Mono", size: 80),
            TerminalFontPreference(family: "Berkeley Mono", size: 32)
        )
    }
}
