import SwiftUI
import XCTest
@testable import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain

@MainActor
final class WarrenDesktopPanelTests: XCTestCase {
    private func context(workspaceID: WorkspaceID? = nil) -> WarrenDesktopPanelContext {
        WarrenDesktopPanelContext(endpointID: "endpoint", workspaceID: workspaceID, workspaceName: "Workspace")
    }

    private func contribution(
        id: String,
        available: @escaping @MainActor (WarrenDesktopPanelContext) -> Bool = { _ in true },
        onGeneration: @escaping @MainActor (String, UInt64) -> Void = { _, _ in }
    ) -> WarrenDesktopPanelContribution {
        WarrenDesktopPanelContribution(
            descriptor: .init(id: id, title: id),
            availability: available,
            connectionGenerationWillChange: onGeneration
        )
    }

    func testRegistryKeepsStableIDsAndWorkspaceAvailability() {
        let registry = WarrenDesktopPanelRegistry()
        let first = contribution(id: "git", available: { $0.workspaceID != nil })
        let second = contribution(id: "inspector")
        XCTAssertEqual(registry.register(first), "git")
        XCTAssertEqual(registry.register(second), "inspector")
        XCTAssertEqual(registry.panelIDs, ["git", "inspector"])
        XCTAssertEqual(registry.availablePanelIDs(in: context()), ["inspector"])
        XCTAssertEqual(registry.availablePanelIDs(in: context(workspaceID: WorkspaceID())), ["git", "inspector"])
        XCTAssertEqual(registry.register(contribution(id: "git")), "git")
        XCTAssertEqual(registry.panelIDs, ["git", "inspector"])
    }

    func testActiveIDIsRetainedWhenContributionBecomesUnavailable() {
        let registry = WarrenDesktopPanelRegistry()
        let git = contribution(id: "git", available: { $0.workspaceID != nil })
        registry.register(git)
        let host = WarrenDesktopPanelHost()
        host.open(panelID: "git")
        XCTAssertEqual(host.activePanelID, "git")
        XCTAssertFalse(registry.isAvailable(panelID: "git", in: context()))
        XCTAssertEqual(host.activePanelID, "git")
    }

    func testConnectionGenerationBroadcastsToInactiveContributions() {
        let registry = WarrenDesktopPanelRegistry()
        var received: [String] = []
        registry.register(contribution(id: "git", available: { _ in false }, onGeneration: { endpoint, generation in
            received.append("git:\(endpoint):\(generation)")
        }))
        registry.register(contribution(id: "other", onGeneration: { endpoint, generation in
            received.append("other:\(endpoint):\(generation)")
        }))
        registry.broadcastConnectionWillChange(endpointID: "endpoint", generation: 7)
        XCTAssertEqual(received, ["git:endpoint:7", "other:endpoint:7"])
    }

    func testLifecycleCallbackDoesNotRetainRegistry() {
        weak var weakRegistry: WarrenDesktopPanelRegistry?
        var callback: (@MainActor (String, UInt64) -> Void)!
        do {
            let registry = WarrenDesktopPanelRegistry()
            weakRegistry = registry
            callback = registry.makeConnectionLifecycleCallback()
        }
        XCTAssertNil(weakRegistry)
        callback("endpoint", 1)
    }

    func testPanelWidthUsesContainerFirstRule() {
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: 400, containerCap: 500),
            400
        )
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: 100, containerCap: 500),
            WarrenLayoutMetrics.panelMinimumWidth
        )
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: 900, containerCap: 500),
            500
        )
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: 900, containerCap: 100),
            100
        )
    }

    func testWidthNormalizesNonFiniteInput() {
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: .nan, containerCap: 500),
            WarrenLayoutMetrics.panelDefaultWidth
        )
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: .infinity, containerCap: 500),
            WarrenLayoutMetrics.panelDefaultWidth
        )
        XCTAssertEqual(
            WarrenDesktopPanelLayout.resolvedWidth(requestedWidth: 400, containerCap: .nan),
            0
        )
    }

    func testInspectorShrinksToUltraNarrowContainerWithoutOverflow() {
        let width = WarrenDesktopPanelLayout.resolvedWidth(
            requestedWidth: WarrenLayoutMetrics.inspectorDefaultWidth,
            containerCap: 180,
            minimum: WarrenLayoutMetrics.inspectorMinimumWidth,
            maximum: WarrenLayoutMetrics.inspectorMaximumWidth
        )
        XCTAssertEqual(width, 180)
        XCTAssertLessThan(width, WarrenLayoutMetrics.inspectorMinimumWidth)
    }

    func testHostPersistsOneSharedRequestedWidth() {
        let suiteName = "WarrenDesktopPanelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let first = WarrenDesktopPanelHost(defaults: defaults)
        _ = first.resize(to: 410)
        let second = WarrenDesktopPanelHost(defaults: defaults)
        XCTAssertEqual(second.rightPanelWidth, 410)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLayoutModesAndExactThresholds() {
        let side = WarrenDesktopPanelLayout.sideBySideThreshold(inspectorOpen: true, panelOpen: true)
        let constrained = WarrenDesktopPanelLayout.constrainedThreshold(inspectorOpen: true)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: side, inspectorOpen: true, panelOpen: true), .wide)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: side - 1, inspectorOpen: true, panelOpen: true), .constrained)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: constrained, inspectorOpen: true, panelOpen: true), .constrained)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: constrained - 1, inspectorOpen: true, panelOpen: true), .ultraNarrow)
    }

    func testCenterMinimumIsPreservedWhenContainerCanSatisfyIt() {
        let resolution = WarrenDesktopPanelLayout.resolve(containerWidth: 1_400, inspectorOpen: true, panelOpen: true)
        XCTAssertGreaterThanOrEqual(resolution.centerWidth, WarrenLayoutMetrics.centerMinimumWidth)
        XCTAssertEqual(resolution.mode, .wide)
        let constrained = WarrenDesktopPanelLayout.resolve(containerWidth: 1_000, inspectorOpen: true, panelOpen: true)
        XCTAssertGreaterThanOrEqual(constrained.centerWidth, WarrenLayoutMetrics.centerMinimumWidth)
        XCTAssertEqual(constrained.panelPlacement, .drawer)
    }

    func testUltraNarrowOverlayUsesLastOpenedIntent() {
        let inspectorLast = WarrenDesktopPanelLayout.resolve(
            containerWidth: 500,
            inspectorOpen: true,
            panelOpen: true,
            lastOpened: .inspector
        )
        XCTAssertEqual(inspectorLast.inspectorPlacement, .overlay)
        XCTAssertEqual(inspectorLast.panelPlacement, .none)

        let panelLast = WarrenDesktopPanelLayout.resolve(
            containerWidth: 500,
            inspectorOpen: true,
            panelOpen: true,
            lastOpened: .panel
        )
        XCTAssertEqual(panelLast.inspectorPlacement, .none)
        XCTAssertEqual(panelLast.panelPlacement, .overlay)
    }
}
