import XCTest
@testable import WarrenObservation

final class WarrenObservationTests: XCTestCase {

    func testSemanticSnapshotSortsAndFindsNodes() {
        let frame = WarrenSemanticRect(x: 1, y: 2, width: 3, height: 4)
        let snapshot = WarrenSemanticSnapshot(
            capturedAtNanoseconds: 1,
            nodes: [
                WarrenSemanticNode(id: "z", role: .button, label: "Z", frame: frame),
                WarrenSemanticNode(id: "a", role: .tab, label: "A", frame: frame),
            ]
        )

        XCTAssertEqual(snapshot.nodes.map(\.id), ["a", "z"])
        XCTAssertEqual(snapshot.node(id: "z")?.label, "Z")
    }

    @MainActor
    func testRecorderPerformsRegisteredTypedAction() throws {
        let recorder = WarrenSemanticRecorder()
        var presses = 0
        recorder.registerAction(id: "button", action: { presses += 1 })

        try recorder.perform(.press, on: "button")

        XCTAssertEqual(presses, 1)
    }

    @MainActor
    func testInteractionGuardDetectsFocusAndMouseChanges() {
        let initial = WarrenInteractionSnapshot(
            frontmostApplicationPID: 1,
            mouseX: 10,
            mouseY: 20
        )
        XCTAssertNoThrow(try WarrenInteractionGuard.verifyUnchanged(from: initial, to: initial))
        XCTAssertThrowsError(
            try WarrenInteractionGuard.verifyUnchanged(
                from: initial,
                to: WarrenInteractionSnapshot(
                    frontmostApplicationPID: 2,
                    mouseX: 10,
                    mouseY: 20
                )
            )
        )
        XCTAssertThrowsError(
            try WarrenInteractionGuard.verifyUnchanged(
                from: initial,
                to: WarrenInteractionSnapshot(
                    frontmostApplicationPID: 1,
                    mouseX: 11,
                    mouseY: 20
                )
            )
        )
    }
}
