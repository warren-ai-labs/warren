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
        onActivate: @escaping @MainActor (WarrenDesktopPanelContext) -> Void = { _ in },
        onGeneration: @escaping @MainActor (String, UInt64) -> Void = { _, _ in }
    ) -> WarrenDesktopPanelContribution {
        WarrenDesktopPanelContribution(
            descriptor: .init(id: id, title: id),
            availability: available,
            activate: onActivate,
            connectionGenerationWillChange: onGeneration
        )
    }

    func testRegistryKeepsStableIDsAndWorkspaceAvailability() {
        let registry = WarrenDesktopPanelRegistry()
        let first = contribution(id: "git", available: { $0.workspaceID != nil })
        let second = contribution(id: "other")
        XCTAssertEqual(registry.register(first), "git")
        XCTAssertEqual(registry.register(second), "other")
        XCTAssertEqual(registry.panelIDs, ["git", "other"])
        XCTAssertEqual(registry.availablePanelIDs(in: context()), ["other"])
        XCTAssertEqual(registry.availablePanelIDs(in: context(workspaceID: WorkspaceID())), ["git", "other"])
        XCTAssertEqual(registry.register(contribution(id: "git")), "git")
        XCTAssertEqual(registry.panelIDs, ["git", "other"])
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

    func testOpenPanelSyncUsesTheNewWorkspaceContext() {
        let firstWorkspaceID = WorkspaceID()
        let secondWorkspaceID = WorkspaceID()
        var activatedWorkspaceIDs: [WorkspaceID?] = []
        let registry = WarrenDesktopPanelRegistry()
        registry.register(contribution(
            id: "git",
            available: { $0.workspaceID != nil },
            onActivate: { activatedWorkspaceIDs.append($0.workspaceID) }
        ))
        let host = WarrenDesktopPanelHost(defaults: nil)

        XCTAssertTrue(host.open(
            panelID: "git",
            context: context(workspaceID: firstWorkspaceID),
            registry: registry
        ))
        host.sync(
            context: context(workspaceID: secondWorkspaceID),
            registry: registry
        )

        XCTAssertEqual(activatedWorkspaceIDs, [firstWorkspaceID, secondWorkspaceID])
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

    func testPanelShrinksToUltraNarrowContainerWithoutOverflow() {
        let width = WarrenDesktopPanelLayout.resolvedWidth(
            requestedWidth: WarrenLayoutMetrics.panelDefaultWidth,
            containerCap: 180,
            minimum: WarrenLayoutMetrics.panelMinimumWidth,
            maximum: WarrenLayoutMetrics.panelMaximumWidth
        )
        XCTAssertEqual(width, 180)
        XCTAssertLessThan(width, WarrenLayoutMetrics.panelMinimumWidth)
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
        let side = WarrenDesktopPanelLayout.sideBySideThreshold()
        let constrained = WarrenLayoutMetrics.centerMinimumWidth
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: side, panelOpen: true), .wide)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: side - 1, panelOpen: true), .constrained)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: constrained, panelOpen: true), .constrained)
        XCTAssertEqual(WarrenDesktopPanelLayout.mode(containerWidth: constrained - 1, panelOpen: true), .ultraNarrow)
    }

    func testCenterMinimumIsPreservedWhenContainerCanSatisfyIt() {
        let resolution = WarrenDesktopPanelLayout.resolve(containerWidth: 1_400, panelOpen: true)
        XCTAssertGreaterThanOrEqual(resolution.centerWidth, WarrenLayoutMetrics.centerMinimumWidth)
        XCTAssertEqual(resolution.mode, .wide)
        let constrained = WarrenDesktopPanelLayout.resolve(containerWidth: 800, panelOpen: true)
        XCTAssertGreaterThanOrEqual(constrained.centerWidth, WarrenLayoutMetrics.centerMinimumWidth)
        XCTAssertEqual(constrained.panelPlacement, .drawer)
    }

    func testUltraNarrowUsesPanelOverlay() {
        let resolution = WarrenDesktopPanelLayout.resolve(containerWidth: 500, panelOpen: true)
        XCTAssertEqual(resolution.mode, .ultraNarrow)
        XCTAssertEqual(resolution.panelPlacement, .overlay)
    }
}
