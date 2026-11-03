import XCTest
import SwiftUI
import AppKit
import Combine
@testable import WarrenDesktop
import WarrenDesktopFixtures
import WarrenDesignSystem
import WarrenDomain
import WarrenClientCore
import WarrenObservation

/// Chrome must not depend on live metadata: a rendered title can be empty for a
/// moment while a Session's metadata is rewritten, and letting the pane header
/// disappear with it changes the pane's height by 28 pt, resizes the PTY, and
/// makes a full-screen TUI repaint end to end.
final class WarrenDesktopPaneHeaderTitleTests: XCTestCase {
    func testHeaderLabelNeverCollapsesToEmpty() {
        XCTAssertEqual(
            WarrenDesktopPaneView<EmptyView>.stablePaneHeaderTitle(
                rendered: "pi · main",
                sessionTitle: "Session",
                kindName: "pi"
            ),
            "pi · main"
        )
        XCTAssertEqual(
            WarrenDesktopPaneView<EmptyView>.stablePaneHeaderTitle(
                rendered: "   ",
                sessionTitle: "Session",
                kindName: "pi"
            ),
            "Session"
        )
        XCTAssertEqual(
            WarrenDesktopPaneView<EmptyView>.stablePaneHeaderTitle(
                rendered: "",
                sessionTitle: "\n",
                kindName: "pi"
            ),
            "pi"
        )
    }
}

struct TestTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        Text("surface:\(context.tab.id):\(context.workspace?.id.rawValue.uuidString ?? "none")")
            // Named so a test can assert the Terminal is still mounted. A lone
            // pane draws no Tab chip, so the track cannot answer that.
            .warrenSemanticElement(
                id: "test-terminal.\(context.tab.id)",
                role: .group,
                label: "Terminal \(context.tab.id)"
            )
    }
}

@MainActor
final class TabBarTestState: ObservableObject {
    @Published var tabs: [ClientTab]
    @Published var selectedTabID: String?

    init(tabs: [ClientTab], selectedTabID: String?) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }
}

struct TabBarTestHarness: View {
    @ObservedObject var state: TabBarTestState

    var body: some View {
        makeTabBar(tabs: state.tabs, selectedTabID: state.selectedTabID)
            .frame(width: 1000, height: WarrenLayoutMetrics.tabBarHeight)
    }
}

@MainActor
final class SidebarHostRowsTestState: ObservableObject {
    @Published var hosts: [WarrenDesktopSidebarHostProjection]
    let selection: WarrenDesktopSidebarResourceSelection?
    @Published private(set) var selectedResources: [WarrenDesktopSidebarResourceSelection] = []

    init(
        hosts: [WarrenDesktopSidebarHostProjection],
        selection: WarrenDesktopSidebarResourceSelection?
    ) {
        self.hosts = hosts
        self.selection = selection
    }

    func recordSelection(_ selection: WarrenDesktopSidebarResourceSelection) {
        selectedResources.append(selection)
    }
}

struct SidebarHostRowsTestHarness: View {
    @ObservedObject var state: SidebarHostRowsTestState
    let activeEndpointID: String
    var workspaceDisplayMode: WarrenDesktopWorkspaceDisplayMode = .compact
    var selectedTabID: String? = nil

    var body: some View {
        WarrenDesktopSidebarHostRows(
            hosts: state.hosts,
            showsActiveOnly: false,
            workspaceDisplayMode: workspaceDisplayMode,
            selection: state.selection,
            activeEndpointID: activeEndpointID,
            selectedTabID: selectedTabID,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in },
            onSelect: { state.recordSelection($0) },
            onOpenWorkspace: { _ in },
            onFocusTask: { _ in },
            onToggleActiveOnly: {},
            onRetry: { _ in }
        )
    }
}

@MainActor
func makeTabBar(
    tabs: [ClientTab],
    selectedTabID: String?,
    soloPane: WarrenDesktopSoloPaneIdentity.Model? = nil
) -> WarrenDesktopTabBar {
    WarrenDesktopTabBar(
        presentation: WarrenDesktopPaneBarPresentation(
            listings: tabs,
            showsTrack: soloPane == nil,
            solo: soloPane
        ),
        tabTitles: Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.title) }),
        tabMarks: [:],
        pinnedSessionIDs: [],
        selectedTabID: selectedTabID,
        isSidebarCollapsed: false,
        onToggleSidebar: {},
        onChromePopover: { _ in },
        rightSidebarOpen: false,
        rightSidebarAvailable: false,
        onToggleRightSidebar: {},
        onSelectTab: { _ in },
        onMoveTab: { _, _ in },
        sessionMoveTargets: [],
        sessionMoveDestinations: [:],
        onMoveSession: { _, _ in },
        canAddTab: true,
        isAddingTab: false,
        onAddTab: {},
        onCloseTab: { _ in },
        onCloseOtherTabs: { _ in },
        onCloseAllTabs: { _ in },
        onRequestRename: { _ in },
        onToggleSessionPin: { _, _ in },
        onDismissActivity: { _, _ in }
    )
}

@MainActor
final class WarrenDesktopTests: XCTestCase {





























































































































































































}

@MainActor
final class WarrenDragProbeWindow: NSWindow {
    var didRequestDrag = false
    var didToggleFullScreen = false

    override func performDrag(with event: NSEvent) {
        didRequestDrag = true
    }

    override func toggleFullScreen(_ sender: Any?) {
        didToggleFullScreen = true
    }
}

@MainActor
final class PausingTaskCreationFake {
    let callExpectations: [XCTestExpectation]
    var continuations: [CheckedContinuation<TaskID, Error>] = []
    private(set) var requests: [WarrenDesktopTaskCreationRequest] = []

    var callCount: Int { requests.count }

    init(callExpectations: [XCTestExpectation]) {
        self.callExpectations = callExpectations
    }

    func create(_ request: WarrenDesktopTaskCreationRequest) async throws -> TaskID {
        requests.append(request)
        callExpectations[requests.count - 1].fulfill()
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeed(_ taskID: TaskID) {
        continuations.removeFirst().resume(returning: taskID)
    }

    func fail(_ error: Error) {
        continuations.removeFirst().resume(throwing: error)
    }
}
