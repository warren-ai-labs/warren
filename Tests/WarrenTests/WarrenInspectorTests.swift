import AppKit
import SwiftUI
import XCTest
import WarrenDomain
import WarrenDesktop
import WarrenTransport
@testable import Warren

final class WarrenInspectorTests: XCTestCase {
    func testParsesUnifiedDiffIntoNumberedLines() {
        let diff = """
        diff --git a/main.go b/main.go
        --- a/main.go
        +++ b/main.go
        @@ -3,4 +3,5 @@ func main() {
         a
        -b
        +c
        +d
         e
        """
        let lines = WarrenDiffView.parse(diff)
        XCTAssertEqual(lines.map(\.kind), [.hunk, .context, .deletion, .addition, .addition, .context])
        XCTAssertEqual(lines[0].text, "func main() {")
        XCTAssertEqual(lines[1].old, 3)
        XCTAssertEqual(lines[1].new, 3)
        XCTAssertEqual(lines[2].old, 4)
        XCTAssertNil(lines[2].new)
        XCTAssertEqual(lines[3].new, 4)
        XCTAssertEqual(lines[5].old, 5)
        XCTAssertEqual(lines[5].new, 6)
    }

    func testBuildsAFolderFirstTree() {
        let tree = WarrenFileNode.tree(from: ["b.go", "a/z.go", "a/b/c.go", "README.md"])
        XCTAssertEqual(tree.map(\.name), ["a", "b.go", "README.md"])
        XCTAssertEqual(tree[0].children.map(\.name), ["b", "z.go"])
        XCTAssertEqual(tree[0].children[0].children.map(\.id), ["a/b/c.go"])
    }

    /// Opt-in acceptance against a running Host: renders the production
    /// Inspector for one Workspace through each tab, with a diff open.
    @MainActor
    func testLiveInspectorRenders() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WARREN_INSPECTOR_URL"],
              let token = environment["WARREN_INSPECTOR_TOKEN"],
              let workspaceID = environment["WARREN_INSPECTOR_WORKSPACE"],
              let path = environment["WARREN_INSPECTOR_PATH"] else {
            throw XCTSkip("Set WARREN_INSPECTOR_URL, _TOKEN, _WORKSPACE, and _PATH to render a live Inspector")
        }
        let prefix = environment["WARREN_INSPECTOR_IMAGE"] ?? "/tmp/warren-inspector"
        let model = WarrenRemoteApplicationModel()
        model.connect(WarrenRemoteEndpointConfiguration(name: "inspector-test", url: url, token: token))
        let id = try XCTUnwrap(WorkspaceID(uuidString: workspaceID))
        let deadline = ContinuousClock.now + .seconds(15)
        while model.projection.workspace(id: id) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        var workspace = try XCTUnwrap(model.projection.workspace(id: id))
        workspace.path = path
        let inspector = model.inspector(for: workspace)
        await inspector.refresh(force: true)
        let panel = try XCTUnwrap(inspector.panel)

        let width = Double(environment["WARREN_INSPECTOR_WIDTH"] ?? "") ?? 420
        let height = Double(environment["WARREN_INSPECTOR_HEIGHT"] ?? "") ?? 820
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        let light = environment["WARREN_INSPECTOR_APPEARANCE"] == "light"
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        // The panel draws no ground of its own — in the app it sits on the
        // sidebar's. An offscreen window without one composites the dark
        // palette onto white, which reads as grey-on-grey and shows nothing.
        window.backgroundColor = light ? .white : NSColor(calibratedWhite: 0.08, alpha: 1)
        let activity = WarrenDesktopInspectorActivity()
        func present(_ tab: WarrenDesktopInspectorTab) {
            let hosting = NSHostingView(
                rootView: WarrenInspectorSurface(
                    inspector: inspector,
                    readsLocalFiles: true,
                    tab: tab,
                    activity: activity
                )
                .environment(\.colorScheme, light ? .light : .dark)
            )
            hosting.frame = window.contentLayoutRect
            window.contentView = hosting
        }
        func currentView() throws -> NSView { try XCTUnwrap(window.contentView) }
        window.orderFrontRegardless()

        present(.changes)
        try await render(currentView(), to: "\(prefix)-changes.png", light: light)

        if let change = panel.changes.first(where: { $0.added + $0.deleted > 0 }) ?? panel.changes.first {
            inspector.toggleDiff(key: WarrenInspectorModel.changeKey(change), path: change.path, staged: change.staged, commit: nil, signature: "test")
            try await Task.sleep(for: .milliseconds(900))
            try await render(currentView(), to: "\(prefix)-diff.png", light: light)
        }

        if let commit = panel.unmergedCommits.first ?? panel.commits.first {
            inspector.toggle(WarrenInspectorModel.commitKey(commit))
            if let file = commit.files.first {
                inspector.toggleDiff(key: WarrenInspectorModel.commitFileKey(commit, file), path: file.path, staged: false, commit: commit.hash, signature: commit.hash)
            }
        }
        present(.history)
        try await Task.sleep(for: .milliseconds(900))
        try await render(currentView(), to: "\(prefix)-history.png", light: light)

        present(.files)
        try await Task.sleep(for: .milliseconds(900))
        try await render(currentView(), to: "\(prefix)-files.png", light: light)
        if let file = environment["WARREN_INSPECTOR_FILE"] {
            inspector.openFile = file
            try await Task.sleep(for: .milliseconds(900))
            try await render(currentView(), to: "\(prefix)-editor.png", light: light)
        }
        window.orderOut(nil)
    }

    @MainActor
    private func render(_ view: NSView, to path: String, light: Bool) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        // The panel draws no ground of its own — in the app the sidebar behind it
        // does. A cached view leaves that transparent, and a transparent PNG
        // reads as a white page, which is not the surface anyone sees.
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            (light ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
