import AppKit
import SwiftUI
import XCTest

import WarrenDesignSystem
import WarrenObservation
@testable import WarrenDesktop

/// Renders the sidebar's foot, where Hosts are switched and managed, in each
/// of its states, plus the Host panel the top row opens and the delete
/// confirmation. Set `WARREN_SIDEBAR_IMAGES` to a directory to write PNGs.
final class WarrenDesktopSidebarFootRenderTests: XCTestCase {
    private static let width: CGFloat = 280

    private let current = WarrenDesktopSidebarOtherHost(
        id: "local",
        name: "studio",
        isLocal: true,
        address: "127.0.0.1:8789",
        isDisplayedInSidebar: true
    )
    private let others = [
        WarrenDesktopSidebarOtherHost(
            id: "fsn1",
            name: "fsn1-dev",
            address: "dev@fsn1",
            marks: [.inputNeeded],
            isDisplayedInSidebar: true
        ),
        WarrenDesktopSidebarOtherHost(id: "beelink", name: "beelink", address: "beelink"),
        WarrenDesktopSidebarOtherHost(id: "mba", name: "mba", isOnline: false),
    ]

    @MainActor
    private func bell() -> AnyView {
        AnyView(WarrenDesktopNoticeBell(
            notices: [],
            isPresented: .constant(false),
            onRead: { _ in },
            onDismissNotice: { _ in },
            onMarkAllRead: {},
            panelEdge: .above
        ))
    }

    @MainActor
    private func accessory(_ status: WarrenDesktopUpdateStatus) -> AnyView {
        AnyView(HStack(spacing: 2) {
            if status != .none {
                WarrenDesktopUpdateIcon(status: status, onAction: {})
            }
            bell()
        })
    }

    @MainActor
    private func foot(
        hosts: [WarrenDesktopSidebarOtherHost],
        update: WarrenDesktopUpdateStatus = .none,
        lifted: Bool = false,
        pulled: Bool = false,
        hot: Int? = nil
    ) -> some View {
        WarrenDesktopSidebarHostStack(
            hosts: hosts,
            currentHost: current,
            onSelectHost: { _ in },
            onAddHost: {},
            onSetSidebarVisibility: { _, _ in },
            onRenameHost: { _ in },
            onDeleteHost: { _ in },
            trailingAccessory: accessory(update),
            initiallyLifted: lifted,
            initiallyPulled: pulled,
            initialHotIndex: hot
        )
    }

    @MainActor
    private func card<Content: View>(height: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        let tokens = WarrenColorTokens.resolved(for: .dark)
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            content()
        }
        .frame(width: Self.width, height: height)
        .background(tokens.workbenchCardFill)
        .environment(\.colorScheme, .dark)
    }

    @MainActor
    private func write(_ view: some View, size: CGSize, name: String, to directory: String) throws {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return XCTFail("No bitmap for \(name)")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    @MainActor
    func testWritesEveryFootStateWhenAsked() throws {
        guard let directory = ProcessInfo.processInfo.environment["WARREN_SIDEBAR_IMAGES"] else {
            throw XCTSkip("Set WARREN_SIDEBAR_IMAGES to write sidebar PNGs")
        }
        let footSize = CGSize(width: Self.width, height: 60)
        let panelSize = CGSize(width: Self.width, height: 330)

        try write(card(height: 60) { foot(hosts: others) }, size: footSize,
                  name: "foot-1-other-hosts", to: directory)
        try write(card(height: 60) { foot(hosts: others, lifted: true, hot: 1) }, size: footSize,
                  name: "foot-2-lifted", to: directory)
        try write(card(height: 330) { foot(hosts: others, pulled: true, hot: 1) }, size: panelSize,
                  name: "foot-3-panel", to: directory)
        try write(card(height: 60) { foot(hosts: []) }, size: footSize,
                  name: "foot-4-add-host", to: directory)
        try write(card(height: 60) { foot(hosts: others, update: .available(version: "0.32.0")) },
                  size: footSize, name: "foot-5-update-available", to: directory)
        try write(card(height: 60) { foot(hosts: others, update: .updating) },
                  size: footSize, name: "foot-6-update-installing", to: directory)
        try write(card(height: 60) { foot(hosts: others, update: .failed) },
                  size: footSize, name: "foot-7-update-failed", to: directory)
        try write(card(height: 60) { foot(hosts: [], update: .available(version: "0.32.0")) },
                  size: footSize, name: "foot-8-add-host-with-update", to: directory)

        let topPanel = card(height: 170) {
            WarrenDesktopMenuSurface(width: Self.width - 16) {
                WarrenDesktopCurrentHostPanel(
                    connectionState: .failed,
                    onRetry: {},
                    onStop: {},
                    onDismiss: {},
                    publicAccess: WarrenDesktopHostPanelPublicAccess(
                        isOn: true,
                        url: URL(string: "https://studio.example.dev/"),
                        content: AnyView(EmptyView()),
                        copy: { _ in }
                    ),
                    onSettings: {}
                )
            }
            .padding(8)
            Spacer(minLength: 0)
        }
        try write(topPanel, size: CGSize(width: Self.width, height: 170),
                  name: "top-host-panel", to: directory)

        let dialog = WarrenDesktopDeleteHostConfirmation(
            hostName: "beelink",
            isWindowHost: false,
            onCancel: {},
            onConfirm: {}
        )
        .frame(width: 520, height: 300)
        .background(WarrenColorTokens.resolved(for: .dark).background)
        .environment(\.colorScheme, .dark)
        try write(dialog, size: CGSize(width: 520, height: 300), name: "delete-host-dialog", to: directory)
    }

    @MainActor
    func testPanelListsTheWindowHostCheckedAndSidebarToggleDoesNotSwitch() async throws {
        let recorder = WarrenSemanticRecorder()
        var selected: String?
        var membership: (String, Bool)?
        var deleted: String?
        let view = WarrenDesktopSidebarHostStack(
            hosts: others,
            currentHost: current,
            onSelectHost: { selected = $0 },
            onAddHost: {},
            onSetSidebarVisibility: { membership = ($0, $1) },
            onDeleteHost: { deleted = $0 },
            initiallyPulled: true,
            initialHotIndex: 1
        )
        .frame(width: Self.width, height: 330, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 330)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.node(id: "sidebar.other-host.local")?.isSelected, true)
        // The window's Host is always in the sidebar, so it has no toggle.
        XCTAssertNil(snapshot.node(id: "sidebar.other-host.local.sidebar"))

        try recorder.perform(.press, on: "sidebar.other-host.beelink.sidebar")
        XCTAssertNil(selected)
        XCTAssertEqual(membership?.0, "beelink")
        XCTAssertEqual(membership?.1, true)
        XCTAssertNil(deleted)
    }

    @MainActor
    func testFootWithoutOtherHostsOffersAddHost() async throws {
        let recorder = WarrenSemanticRecorder()
        var added = false
        let view = WarrenDesktopSidebarHostStack(
            hosts: [],
            currentHost: current,
            onSelectHost: { _ in },
            onAddHost: { added = true }
        )
        .frame(width: Self.width)
        .environment(\.colorScheme, .dark)
        .environment(\.warrenSemanticRecorder, recorder)
        .warrenSemanticObservationRoot(recorder: recorder)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: Self.width, height: 60)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertNil(recorder.snapshot().node(id: "sidebar.other-hosts"))
        try recorder.perform(.press, on: "sidebar.add-host")
        XCTAssertTrue(added)
    }

    func testOnlyThisMacCannotBeDeleted() {
        XCTAssertFalse(current.canDelete)
        XCTAssertTrue(others[0].canDelete)
    }
}
