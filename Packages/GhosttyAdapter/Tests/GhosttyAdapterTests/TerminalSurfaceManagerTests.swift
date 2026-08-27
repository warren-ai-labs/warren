import AppKit
import GhosttyKit
import WarrenDomain
import XCTest
@testable import GhosttyAdapter

@MainActor
final class TerminalSurfaceManagerTests: XCTestCase {
    func testManagerParksWarmViewAndReattachesSameNativeSurface() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let first = makeSurface()
        let second = makeSurface()
        manager.insert(first)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        XCTAssertTrue(host.subviews.isEmpty, "Submitting intent must not mutate AppKit synchronously")
        XCTAssertNil(first.state.surface, "Submitting intent must not create Ghostty synchronously")
        try await waitUntil { first.state.surface != nil }
        let firstNativeSurface = first.state.surface
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertTrue(first.mountedTerminalView?.window === window)

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { second.state.surface != nil }
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertNil(first.mountedTerminalView?.window)
        XCTAssertNotNil(first.state.surface)
        XCTAssertEqual(manager.snapshot().warmSessionIDs, [first.id])

        submit(first.id, to: manager, host: host)
        try await waitUntil { first.mountedTerminalView?.window === window }
        XCTAssertTrue(first.state.surface === firstNativeSurface)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertEqual(manager.snapshot().activeSessionID, first.id)
    }

    func testPresentRequestBeforeActivationIsRetainedByLifecycleTransition() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = makeSurface()
        manager.insert(surface)

        manager.requestPresent(surface.id)
        XCTAssertEqual(manager.snapshot().hiddenRenderAttemptCount, 0)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(surface.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == surface.id
                && surface.terminalViewIsPresentable
        }

        XCTAssertNotNil(surface.state.surface)
        XCTAssertEqual(manager.snapshot().hiddenRenderAttemptCount, 0)
    }

    func testAttachRetriesWhenHostWindowAppearsAfterFirstLayoutTurn() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = makeSurface()
        manager.insert(surface)
        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        manager.submit(
            host: host,
            intent: TerminalPresentationIntent(
                activeSessionID: surface.id,
                viewportSize: host.bounds.size,
                wantsTerminalFocus: false
            ),
            onFocused: { _, _ in },
            onBlurred: { _ in }
        )
        // The first reconciliation runs before AppKit has attached the host
        // to a window. It must retry instead of leaving the surface black.
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(surface.mountedTerminalView?.window)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }
        try await waitUntil {
            surface.mountedTerminalView?.window === window
                && !(surface.mountedTerminalView?.isHidden ?? true)
        }
    }

    func testRecoveryGateEnablesDisplayOnlyAfterSynced() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = makeSurface()
        manager.insert(surface, recoveryGated: true)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(surface.id, to: manager, host: host)
        try await waitUntil { surface.mountedTerminalView?.window === window }
        manager.beginRecovery(for: surface.id)
        manager.requestPresent(surface.id)
        XCTAssertFalse(manager.isDisplayVisible(surface.id))

        manager.endRecovery(for: surface.id)
        // Ending the protocol recovery gate schedules the final present, but
        // keeps the display occluded until the writer has caught up.
        XCTAssertFalse(manager.isDisplayVisible(surface.id))
        try await waitUntil { manager.isDisplayVisible(surface.id) }
        try await waitUntil { !(surface.mountedTerminalView?.isHidden ?? true) }
    }

    func testWarmPromotionHoldsDisplayUntilQueuedOutputIsRendered() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let first = makeSurface(
            outputRenderBudgetBytes: 256,
            outputRenderYield: .milliseconds(2)
        )
        let second = makeSurface()
        manager.insert(first)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            first.state.surface != nil
                && first.terminalViewIsPresentable
                && manager.isDisplayVisible(first.id)
        }

        // Build a deliberate warm-surface backlog. The old promotion path
        // revealed the view immediately and made these bytes visibly stream
        // past at render speed instead of showing one settled frame.
        first.outputWriter.enqueueRaw(Data(repeating: 0x78, count: 500_000))
        try await waitUntil {
            first.outputWriter.enqueuedSequence > first.outputWriter.renderedSequence
        }

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { manager.snapshot().activeSessionID == second.id }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == first.id
                && first.terminalViewIsPresentable
                && first.outputWriter.enqueuedSequence > first.outputWriter.renderedSequence
        }
        XCTAssertFalse(
            manager.isDisplayVisible(first.id),
            "warm promotion must keep the display hidden while queued output drains"
        )

        try await waitUntil(timeout: 12) {
            manager.isDisplayVisible(first.id)
                && first.outputWriter.renderedSequence >= first.outputWriter.enqueuedSequence
        }
    }

    func testAttachUsesMeasuredHostGeometryWhenIntentIsStale() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surface = makeSurface()
        manager.insert(surface)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        // Simulate an NSViewRepresentable update that still carries the
        // previous pane size while AppKit has already measured the host.
        manager.submit(
            host: host,
            intent: TerminalPresentationIntent(
                activeSessionID: surface.id,
                viewportSize: CGSize(width: 320, height: 200),
                wantsTerminalFocus: false
            ),
            onFocused: { _, _ in },
            onBlurred: { _ in }
        )
        // Keep the stale intent in place so the attach path itself must use
        // the measured host bounds rather than a later layout callback.
        host.manager = nil

        try await waitUntil {
            surface.mountedTerminalView?.window === window
        }
        XCTAssertEqual(surface.mountedTerminalView?.frame.size, host.bounds.size)
    }

    func testManagerEvictsLeastRecentlyUsedWarmSurface() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let surfaces = (0..<3).map { _ in makeSurface() }
        var disposed: [TerminalSessionID] = []
        manager.onSurfaceDisposed = { disposed.append($0) }

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        for surface in surfaces {
            manager.insert(surface)
            submit(surface.id, to: manager, host: host)
            try await waitUntil { manager.snapshot().activeSessionID == surface.id }
        }

        XCTAssertNil(manager.surface(for: surfaces[0].id))
        XCTAssertNotNil(manager.surface(for: surfaces[1].id))
        XCTAssertNotNil(manager.surface(for: surfaces[2].id))
        XCTAssertEqual(manager.snapshot().retainedSurfaceCount, 2)
        XCTAssertEqual(manager.snapshot().surfaceDisposalCount, 1)
        XCTAssertEqual(disposed, [surfaces[0].id])
    }

    func testManagerMaintainsSingleHostAcrossFiveHundredSwitches() {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 1)
        let first = makeSurface()
        let second = makeSurface()
        manager.insert(first)
        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        manager.insert(second)
        submit(second.id, to: manager, host: host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        for index in 0..<500 {
            let sessionID = index.isMultiple(of: 2) ? first.id : second.id
            submit(sessionID, to: manager, host: host)
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            XCTAssertLessThanOrEqual(host.subviews.count, 1)
        }

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let snapshot = manager.snapshot()
        XCTAssertEqual(snapshot.activeSessionID, second.id)
        XCTAssertEqual(snapshot.retainedSurfaceCount, 2)
        XCTAssertEqual(host.subviews.count, 1)
        XCTAssertEqual(snapshot.hiddenRenderAttemptCount, 0)
    }

    func testShutdownDefersNativeViewReleaseUntilOutputDrainExits() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let surface = makeSurface()
        manager.insert(surface)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.orderOut(nil as Any?)
        }

        submit(surface.id, to: manager, host: host)
        try await waitUntil {
            surface.state.surface != nil && surface.terminalViewIsPresentable
        }

        // Keep a drain in flight while the manager is asked to tear down.
        surface.outputWriter.enqueueRaw(makeLines(start: 0, count: 1000))
        manager.shutdown()

        // The entry must leave the live roster immediately, but its native
        // view/surface release has to wait for the background writer to exit.
        XCTAssertEqual(manager.retainedSurfaceCount, 0)
        XCTAssertEqual(manager.snapshot().surfaceDisposalCount, 1)

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while manager.pendingDisposalCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(manager.pendingDisposalCount, 0)
    }

    func testReattachPreservesPinnedViewport() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let first = makeSurface()
        let second = makeSurface()
        manager.insert(first)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            first.state.surface != nil
                && first.terminalViewIsPresentable
                && manager.isDisplayVisible(first.id)
        }
        let raw = try XCTUnwrap(first.state.surface?.rawValue)

        first.receive(makeLines(start: 0, count: 2000))
        try await waitForViewport(on: first, containing: "line-1999")
        _ = "scroll_to_top".withCString { pointer in
            ghostty_surface_binding_action(raw, pointer, UInt("scroll_to_top".utf8.count))
        }
        try await waitForViewport(on: first, containing: "line-0000")
        let pinned = try viewportText(on: first)
        XCTAssertFalse(pinned.contains("line-1999"), "pinned viewport must not already be at bottom")

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { manager.snapshot().activeSessionID == second.id }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == first.id && first.terminalViewIsPresentable
        }

        // A normal warm reattach must keep the pinned viewport where it was.
        let reattached = try viewportText(on: first)
        XCTAssertTrue(reattached.contains("line-0000"), "normal reattach must preserve scroll position")
        XCTAssertFalse(reattached.contains("line-1999"), "normal reattach must not jump to live bottom")
    }

    func testReattachResyncsWhenViewportDidNotReturnToAnchor() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let first = makeSurface()
        let second = makeSurface()
        manager.insert(first)

        let host = TerminalHostContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            manager.shutdown()
            window.orderOut(nil as Any?)
        }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            first.state.surface != nil
                && first.terminalViewIsPresentable
                && manager.isDisplayVisible(first.id)
        }
        let raw = try XCTUnwrap(first.state.surface?.rawValue)

        first.receive(makeLines(start: 0, count: 2000))
        try await waitForViewport(on: first, containing: "line-1999")
        _ = "scroll_to_top".withCString { pointer in
            ghostty_surface_binding_action(raw, pointer, UInt("scroll_to_top".utf8.count))
        }
        try await waitForViewport(on: first, containing: "line-0000")
        let pinned = try viewportText(on: first)
        XCTAssertFalse(pinned.contains("line-1999"), "pinned viewport must not already be at bottom")

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { manager.snapshot().activeSessionID == second.id }

        // While warm, the viewport moves away from the anchor captured at
        // demotion; reattach must detect the mismatch and resync to bottom.
        _ = "scroll_to_bottom".withCString { pointer in
            ghostty_surface_binding_action(raw, pointer, UInt("scroll_to_bottom".utf8.count))
        }
        try await waitForViewport(on: first, containing: "line-1999")

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == first.id && first.terminalViewIsPresentable
        }
        try await waitForViewport(on: first, containing: "line-1999")
    }

    private func makeLines(start: Int, count: Int) -> Data {
        var data = Data()
        for index in start..<(start + count) {
            data.append(Data("line-\(String(format: "%04d", index))\n".utf8))
        }
        return data
    }

    private func viewportText(on surface: GhosttySurface) throws -> String {
        guard let raw = surface.state.surface?.rawValue else {
            struct NoSurface: Error {}
            throw NoSurface()
        }
        let topLeft = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(raw, selection, &out) else {
            struct ReadFailed: Error {}
            throw ReadFailed()
        }
        defer { ghostty_surface_free_text(raw, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(start: text, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func waitForViewport(
        on surface: GhosttySurface,
        containing needle: String,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if try viewportText(on: surface).contains(needle) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        struct Timeout: Error {}
        throw Timeout()
    }

    private func makeSurface(
        outputRenderBudgetBytes: Int = 8 * 1024 * 1024,
        outputRenderYield: Duration = .milliseconds(1)
    ) -> GhosttySurface {
        GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            outputRenderBudgetBytes: outputRenderBudgetBytes,
            outputRenderYield: outputRenderYield,
            onInput: { _ in },
            onResize: { _, _ in }
        )
    }

    private func submit(
        _ sessionID: TerminalSessionID,
        to manager: TerminalSurfaceManager,
        host: TerminalHostContainerView
    ) {
        manager.submit(
            host: host,
            intent: TerminalPresentationIntent(
                activeSessionID: sessionID,
                viewportSize: host.bounds.size,
                wantsTerminalFocus: false
            ),
            onFocused: { _, _ in },
            onBlurred: { _ in }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard condition() else {
            struct Timeout: Error {}
            throw Timeout()
        }
    }
}
