import AppKit
import GhosttyKit
import WarrenDomain
import XCTest
@testable import GhosttyAdapter

@MainActor
final class TerminalSurfaceManagerTests: XCTestCase {
    // Native snapshot fixture used to exercise restoreSnapshotResult without
    // round-tripping a live terminal (same payload as GhosttyAdapterTests).
    private static let atomicSnapshotFixture = """
    R0hPU1RTTlABAAEAlAMAAO/6KIooAAgAAAAAAAAAAAAAAAcAAAAnAAAAAAEAdAAAAAEBAQEAAAAACAAEIgBkAAAAAAQiAGQAAAAABCIAZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAP//////////AAEBAQEdHyHMZma1vWjwxnSBor6ylLuKvrfFyMZmZmbVTlO5ykrnxUd6ptrDl9hwwLHq6uoAAAAAAF8AAIcAAK8AANcAAP8AXwAAX18AX4cAX68AX9cAX/8AhwAAh18Ah4cAh68Ah9cAh/8ArwAAr18Ar4cAr68Ar9cAr/8A1wAA118A14cA168A19cA1/8A/wAA/18A/4cA/68A/9cA//9fAABfAF9fAIdfAK9fANdfAP9fXwBfX19fX4dfX69fX9dfX/9fhwBfh19fh4dfh69fh9dfh/9frwBfr19fr4dfr69fr9dfr/9f1wBf119f14df169f19df1/9f/wBf/19f/4df/69f/9df//+HAACHAF+HAIeHAK+HANeHAP+HXwCHX1+HX4eHX6+HX9eHX/+HhwCHh1+Hh4eHh6+Hh9eHh/+HrwCHr1+Hr4eHr6+Hr9eHr/+H1wCH11+H14eH16+H19eH1/+H/wCH/1+H/4eH/6+H/9eH//+vAACvAF+vAIevAK+vANevAP+vXwCvX1+vX4evX6+vX9evX/+vhwCvh1+vh4evh6+vh9evh/+vrwCvr1+vr4evr6+vr9evr/+v1wCv11+v14ev16+v19ev1/+v/wCv/1+v/4ev/6+v/9ev///XAADXAF/XAIfXAK/XANfXAP/XXwDXX1/XX4fXX6/XX9fXX//XhwDXh1/Xh4fXh6/Xh9fXh//XrwDXr1/Xr4fXr6/Xr9fXr//X1wDX11/X14fX16/X19fX1//X/wDX/1/X/4fX/6/X/9fX////AAD/AF//AIf/AK//ANf/AP//XwD/X1//X4f/X6//X9f/X///hwD/h1//h4f/h6//h9f/h///rwD/r1//r4f/r6//r9f/r///1wD/11//14f/16//19f/1////wD//1///4f//6///9f///8ICAgSEhIcHBwmJiYwMDA6OjpEREROTk5YWFhiYmJsbGx2dnaAgICKioqUlJSenp6oqKiysrK8vLzGxsbQ0NDa2trk5OTu7u4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgA2AAAAddWM0gAAAQAAAAAAAAAAAAYAAgABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAMAowAAAKcxwt4oAAgAAQAAAIAAwAAAIAAAAAgAAAEAAAAAAAHwAAAAAAAAAAAAAAAFAGZpcnN0IBYAzAEABNABAATkAQAEsAEABJQBAASQAQAEgAAABIgBAASwAQAEhAEABLgBAASsAQAEgAAABIAAAASAAAAEgAAABIAAAASAAAAEgAAABIAAAASAAAAEgAAABAAEAGxhc3QAAAAAAAAAAAAAAAAAAAAAAAAABwAAAAAAJ4Bj0QUAAAAAAOQg7woEAAYAAAChEYpeAAAAAAAABgAAAAAAPutTPg==
    """

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

        // Capture the promotion boundary before switching away. The display
        // must remain occluded until the hidden writer consumes this fixed
        // boundary; output arriving after it must not extend the wait.
        first.outputWriter.enqueueRaw(Data(repeating: 0x78, count: 100_000))
        try await waitUntil {
            first.outputWriter.enqueuedSequence > first.outputWriter.renderedSequence
        }
        let promotionTarget = first.outputWriter.enqueuedBoundary

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { manager.snapshot().activeSessionID == second.id }

        submit(first.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == first.id
                && first.terminalViewIsPresentable
        }
        if first.outputWriter.renderedBoundary != promotionTarget {
            XCTAssertFalse(
                manager.isDisplayVisible(first.id),
                "promotion must not reveal a partially drained output boundary"
            )
        }
        try await waitUntil(timeout: 5) {
            manager.isDisplayVisible(first.id)
        }
        XCTAssertTrue(manager.isDisplayVisible(first.id))
        XCTAssertTrue(
            first.outputWriter.renderedBoundary.epoch == promotionTarget.epoch
                && first.outputWriter.renderedBoundary.sequence >= promotionTarget.sequence,
            "promotion must render its captured boundary before reveal"
        )
    }

    func testWarmPromotionDoesNotWaitForAContinuouslyGrowingQueue() async throws {
        _ = NSApplication.shared
        let manager = TerminalSurfaceManager(warmLimit: 2)
        let first = makeSurface(
            outputRenderBudgetBytes: 128,
            outputRenderYield: .milliseconds(4)
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

        // Seed a backlog before promotion, then keep appending while the
        // presentation task is waiting. A moving endpoint must not turn the
        // tab switch into an unbounded wait.
        let writer = first.outputWriter
        writer.enqueueRaw(Data(repeating: 0x78, count: 20_000))
        try await waitUntil { writer.enqueuedSequence > writer.renderedSequence }

        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil { manager.snapshot().activeSessionID == second.id }

        let producer = Task.detached {
            for _ in 0..<200 {
                writer.enqueueRaw(Data(repeating: 0x79, count: 128))
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        defer { producer.cancel() }

        submit(first.id, to: manager, host: host)
        try await waitUntil(timeout: 5) {
            manager.snapshot().activeSessionID == first.id
                && manager.isDisplayVisible(first.id)
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

    func testInactiveWarmSurfaceCanInstallRecoveryAndPresentOnReactivate() async throws {
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

        // Activate first.
        submit(first.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == first.id
                && first.terminalViewIsPresentable
                && first.state.surface != nil
        }

        // Insert second and activate it, demoting first to warm/inactive.
        manager.insert(second)
        submit(second.id, to: manager, host: host)
        try await waitUntil {
            manager.snapshot().activeSessionID == second.id
                && second.terminalViewIsPresentable
        }
        XCTAssertEqual(manager.snapshot().warmSessionIDs, [first.id])
        XCTAssertFalse(manager.isActive(first.id))

        // The demoted surface keeps its native Ghostty surface ready even
        // though its AppKit view is parked. A snapshot arriving while the
        // tab is not selected must be installable (fixes the black-pane
        // retry spin) without requiring the tab to be active.
        XCTAssertTrue(first.terminalSurfaceIsReady)
        XCTAssertTrue(manager.isReadyToInstallRecovery(first.id))
        XCTAssertFalse(manager.isReadyForRecovery(first.id))

        let snapshot = try XCTUnwrap(Data(base64Encoded: Self.atomicSnapshotFixture))
        let result = manager.restoreSnapshotResult(
            snapshot,
            for: first.id,
            epoch: 7,
            sequence: 100
        )
        XCTAssertEqual(result, .restored)

        // Re-activating the tab must present normally (no deadlock).
        submit(first.id, to: manager, host: host)
        try await waitUntil(timeout: 8) {
            manager.snapshot().activeSessionID == first.id
                && manager.isDisplayVisible(first.id)
                && !(first.mountedTerminalView?.isHidden ?? true)
        }
        XCTAssertEqual(manager.snapshot().activeSessionID, first.id)
        XCTAssertTrue(manager.isDisplayVisible(first.id))
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
        outputRenderBudgetBytes: Int = 64 * 1024,
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
