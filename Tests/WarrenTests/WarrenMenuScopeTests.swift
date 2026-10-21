import AppKit
import XCTest
@testable import Warren
@testable import WarrenDesktop

/// The menu bar serves the key window. These tests pin which commands belong
/// to the workspace window, and that a command posted from another key window
/// is dropped — the mechanism that keeps ⌘W and the pane commands off the
/// panes behind a Settings window.
@MainActor
final class WarrenMenuScopeTests: XCTestCase {
    func testPaneTabAndSessionCommandsBelongToTheWorkspaceWindow() {
        let expected: [Notification.Name] = [
            WarrenDesktopCommand.newSession,
            WarrenDesktopCommand.nextTab,
            WarrenDesktopCommand.previousTab,
            WarrenDesktopCommand.selectTab,
            WarrenDesktopCommand.commandPalette,
            WarrenDesktopCommand.findInTerminal,
            WarrenDesktopCommand.toggleSidebar,
            WarrenDesktopCommand.peekSidebar,
            WarrenDesktopCommand.toggleInspector,
            WarrenDesktopCommand.splitRight,
            WarrenDesktopCommand.splitBelow,
            WarrenDesktopCommand.closePane,
            WarrenDesktopCommand.maximizePane,
            WarrenDesktopCommand.otherPane,
            WarrenDesktopCommand.nextPaneGroup,
            WarrenDesktopCommand.previousPaneGroup,
        ]
        for command in expected {
            XCTAssertTrue(
                WarrenMenuScope.isWorkspaceCommand(command),
                "\(command.rawValue) must be scoped to the workspace window"
            )
        }
    }

    func testAppLevelCommandsKeepWorkingInEveryWindow() {
        let appLevel: [Notification.Name] = [
            WarrenDesktopCommand.openSettings,
            WarrenDesktopCommand.openEmbeddedEditor,
            Notification.Name("Web.copyLocalURL"),
            Notification.Name("Web.copySecureURL"),
        ]
        for command in appLevel {
            XCTAssertFalse(WarrenMenuScope.isWorkspaceCommand(command))
        }
    }

    func testWorkspaceCommandsAreDroppedWhileAnotherWindowIsKey() {
        let workspace = makeWindow()
        let settings = makeWindow()
        XCTAssertFalse(
            WarrenMenuScope.shouldPost(
                WarrenDesktopCommand.closePane,
                workspace: workspace,
                key: settings
            )
        )
        XCTAssertFalse(
            WarrenMenuScope.shouldPost(
                WarrenDesktopCommand.newSession,
                workspace: workspace,
                key: settings
            )
        )
        // App-level commands still reach the app from the Settings window.
        XCTAssertTrue(
            WarrenMenuScope.shouldPost(
                WarrenDesktopCommand.openSettings,
                workspace: workspace,
                key: settings
            )
        )
    }

    func testWorkspaceCommandsPostWhileTheWorkspaceWindowIsKey() {
        let workspace = makeWindow()
        XCTAssertTrue(
            WarrenMenuScope.shouldPost(
                WarrenDesktopCommand.closePane,
                workspace: workspace,
                key: workspace
            )
        )
    }

    /// A sheet or popover on the workspace window still belongs to it, so the
    /// commands a user runs from that window keep working.
    func testChildWindowOfTheWorkspaceWindowCountsAsKey() {
        let workspace = makeWindow()
        let child = makeWindow()
        workspace.addChildWindow(child, ordered: .above)
        defer { workspace.removeChildWindow(child) }
        XCTAssertTrue(WarrenMenuScope.isWorkspaceWindowKey(workspace: workspace, key: child))
    }

    /// A click can empty `NSApp.keyWindow` for a moment, and an inactive app
    /// has none at all. Neither is another window taking the keyboard, so the
    /// workspace keeps its commands instead of greying them out unpredictably.
    func testNoKeyWindowLeavesWorkspaceCommandsAvailable() {
        let workspace = makeWindow()
        XCTAssertTrue(WarrenMenuScope.isWorkspaceWindowKey(workspace: workspace, key: nil))
        XCTAssertTrue(WarrenMenuScope.isWorkspaceWindowKey(workspace: nil, key: nil))
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }
}
