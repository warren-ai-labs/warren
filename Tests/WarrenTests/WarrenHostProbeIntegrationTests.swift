import AppKit
import SwiftUI
import XCTest
import WarrenObservation
@testable import WarrenDesktop
@testable import Warren

final class WarrenHostProbeIntegrationTests: XCTestCase {
    @MainActor
    func testEndpointSidebarButtonDoesNotSwitchTheExecutionServer() async throws {
        let recorder = WarrenSemanticRecorder()
        var selected: String?
        var visibilityChange: (endpointID: String, isDisplayed: Bool)?
        let view = WarrenDesktopEndpointPopover(
            connectionState: .attached,
            endpoints: [.init(id: "dev", label: "Development")],
            selectedID: "local",
            onSelect: { selected = $0 },
            onSetSidebarVisibility: { endpointID, isDisplayed in
                visibilityChange = (endpointID, isDisplayed)
            },
            onAddSSHHost: {},
            onRetry: {},
            onStop: {},
            onDismiss: {}
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 260)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()

        try recorder.perform(.press, on: "endpoint.dev.sidebar")

        XCTAssertNil(selected)
        XCTAssertEqual(visibilityChange?.endpointID, "dev")
        XCTAssertEqual(visibilityChange?.isDisplayed, true)
    }

    /// Opt-in acceptance against a running daemon, without changing its catalog
    /// or sessions. The image is the production popover rendered by AppKit.
    @MainActor
    func testLiveHostProbeRendersInExecutionServerMenu() async throws {
        guard let url = ProcessInfo.processInfo.environment["WARREN_HOST_PROBE_URL"] else {
            throw XCTSkip("Set WARREN_HOST_PROBE_URL to a running Headless HTTP root")
        }
        let endpoint = WarrenRemoteEndpointConfiguration(name: "Live Host", url: url)
        let model = WarrenRemoteApplicationModel()
        model.probeHosts([endpoint])
        let deadline = ContinuousClock.now + .seconds(8)
        while model.hostProbes[endpoint] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try XCTUnwrap(model.hostProbes[endpoint])
        XCTAssertFalse(result.isFailure, result.message)
        XCTAssertTrue(result.message.contains("Headless"))

        let recorder = WarrenSemanticRecorder()
        var selected: String?
        let view = WarrenDesktopEndpointPopover(
            connectionState: .disconnected,
            endpoints: [.init(id: endpoint.id, label: endpoint.name, detail: "Forwarded Host",
                              probeStatus: result.message, probeFailed: result.isFailure)],
            selectedID: endpoint.id,
            onSelect: { selected = $0 },
            onSetSidebarVisibility: { _, _ in
                XCTFail("Sidebar membership changed while testing Host probe rendering")
            },
            onAddSSHHost: {}, onRetry: {}, onStop: {}, onDismiss: {}
        )
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 360)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let node = try XCTUnwrap(recorder.snapshot().nodes.first { $0.id == "endpoint.\(endpoint.id)" })
        XCTAssertEqual(node.value, result.message)
        try recorder.perform(.press, on: node.id)
        XCTAssertEqual(selected, endpoint.id)

        if let path = ProcessInfo.processInfo.environment["WARREN_HOST_PROBE_IMAGE"] {
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
