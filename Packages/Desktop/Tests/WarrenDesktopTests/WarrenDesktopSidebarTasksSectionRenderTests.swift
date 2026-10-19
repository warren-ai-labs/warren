import AppKit
import SwiftUI
import XCTest
@testable import WarrenDesktop

/// The Tasks section at the top of the tree, mounted in a real hosting view.
///
/// An empty section draws nothing below its heading, so folding it away and
/// opening it must occupy the same height. A body that is built but has no
/// rows still claims the heading gap, which is invisible to every model test.
final class WarrenDesktopSidebarTasksSectionRenderTests: XCTestCase {
    @MainActor
    private func height(of state: WarrenDesktopSidebarTreeState) -> CGFloat {
        let rows = WarrenDesktopSidebarRows(
            taskGroups: [],
            groups: [],
            workspaceActivitySummaries: [:],
            tree: .constant(state),
            selection: nil,
            deletingProjectIDs: [],
            deletingWorkspaceIDs: [],
            endpointCapabilities: .local,
            isInteractionDisabled: false,
            onAddProject: {},
            onRequestTaskCreate: {},
            onFocusTask: { _ in },
            onAction: { _ in },
            onRequestRename: { _ in },
            onRequestDeletion: { _ in }
        )
        let hosting = NSHostingView(rootView: AnyView(rows.frame(width: 280)))
        hosting.frame = NSRect(x: 0, y: 0, width: 280, height: 10)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    @MainActor
    func testEmptyTasksSectionKeepsOneHeadingGapWhenFoldedOrOpened() {
        let folded = height(of: WarrenDesktopSidebarTreeState(tasksCollapsed: true))
        let opened = height(of: WarrenDesktopSidebarTreeState(tasksCollapsed: false))

        XCTAssertEqual(folded, opened, accuracy: 0.5)
    }
}
