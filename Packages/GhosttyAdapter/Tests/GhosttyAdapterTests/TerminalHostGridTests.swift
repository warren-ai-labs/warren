import XCTest
import AppKit
import WarrenDomain
@testable import GhosttyTerminal
@testable import GhosttyAdapter

/// Main-actor owner of the view, so the applier closure can be Sendable.
@MainActor
private final class ViewBox {
    weak var view: AppTerminalView?

    init(_ view: AppTerminalView) { self.view = view }

    func apply(_ grid: TerminalSize) -> Bool {
        guard let view, let size = view.frameSize(columns: grid.columns, rows: grid.rows) else {
            return false
        }
        view.setFrameSize(size)
        view.fitToSize()
        return true
    }
}

/// Output the Host produced for one PTY size must be parsed against that size,
/// however early the size report arrives and wherever it falls in a chunk.
@MainActor
final class TerminalHostGridTests: XCTestCase {
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    func testGridChangeSplitsAChunkAtTheReportedSequence() async throws {
        let (surface, view) = try await makeHostGridSurface()
        let wide = try XCTUnwrap(surface.terminalSize)
        XCTAssertGreaterThan(wide.columns, 30, "precondition: the pane starts wider than the new grid")

        // The Host's report arrives ahead of the bytes it splits, the way the
        // control queue overtakes output.
        let narrow = try XCTUnwrap(TerminalSize(columns: 20, rows: wide.rows))
        let before = "\r\n"
        surface.outputWriter.enqueueGridChange(
            epoch: 1,
            sequence: UInt64(before.utf8.count),
            grid: narrow
        )
        // At 20 columns X wraps onto the next row, so the carriage return
        // lands there and Z replaces X. At the old width X stays on the B row
        // and Z replaces the first B.
        let after = String(repeating: "B", count: 20) + "X\rZ"
        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data((before + after).utf8))

        let end = UInt64((before + after).utf8.count)
        try await waitFor { surface.renderedSequence >= end }
        XCTAssertEqual(surface.terminalSize, narrow)
        XCTAssertEqual(view.frame.size, view.frameSize(columns: narrow.columns, rows: narrow.rows))
        let text = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(
            text.contains(String(repeating: "B", count: 20) + "Z"),
            "output after the mark was not parsed at 20 columns: \(text)"
        )
        surface.outputWriter.shutdown()
    }

    func testGridChangeWithNoFollowingOutputStillApplies() async throws {
        let (surface, _) = try await makeHostGridSurface()
        let wide = try XCTUnwrap(surface.terminalSize)
        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data("prompt".utf8))
        try await waitFor { surface.renderedSequence >= 6 }

        let narrow = try XCTUnwrap(TerminalSize(columns: 24, rows: wide.rows - 1))
        surface.outputWriter.enqueueGridChange(epoch: 1, sequence: 6, grid: narrow)
        try await waitFor { surface.terminalSize == narrow }
        surface.outputWriter.shutdown()
    }

    func testGridChangeForAnotherEpochWaitsForItsAnchor() async throws {
        let (surface, _) = try await makeHostGridSurface()
        let wide = try XCTUnwrap(surface.terminalSize)
        let narrow = try XCTUnwrap(TerminalSize(columns: 22, rows: wide.rows))
        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data("old".utf8))
        try await waitFor { surface.renderedSequence >= 3 }

        // A mark for the next stream must not resize the current one.
        surface.outputWriter.enqueueGridChange(epoch: 2, sequence: 0, grid: narrow)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(surface.terminalSize, wide)

        surface.outputWriter.enqueue(epoch: 2, sequence: 0, payload: Data("new".utf8))
        try await waitFor { surface.terminalSize == narrow }
        surface.outputWriter.shutdown()
    }

    func testGridChangeIsIgnoredWithoutAHostGrid() async throws {
        let (surface, _) = try await makeHostGridSurface(hostGrid: false)
        let wide = try XCTUnwrap(surface.terminalSize)
        let narrow = try XCTUnwrap(TerminalSize(columns: 20, rows: wide.rows))
        surface.outputWriter.enqueueGridChange(epoch: 1, sequence: 0, grid: narrow)
        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data("text".utf8))
        try await waitFor { surface.renderedSequence >= 4 }
        XCTAssertEqual(surface.terminalSize, wide)
        surface.outputWriter.shutdown()
    }

    /// Mounts one surface in a window and wires the writer's grid applier the
    /// way `TerminalSurfaceManager` does: lay the view out at the grid, then
    /// push it to Ghostty.
    private func makeHostGridSurface(
        hostGrid: Bool = true
    ) async throws -> (GhosttySurface, AppTerminalView) {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.window = window
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let view = AppTerminalView(frame: host.bounds)
        view.delegate = surface.state
        view.controller = surface.state.controller
        view.configuration = surface.state.configuration
        host.addSubview(view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await waitFor { surface.terminalSurfaceIsReady && surface.terminalSize != nil }

        if hostGrid {
            surface.outputWriter.setAnchorGrid(surface.terminalSize)
        }
        let box = ViewBox(view)
        surface.outputWriter.setGridApplier { grid in
            await MainActor.run { box.apply(grid) }
        }
        return (surface, view)
    }

    private func waitFor(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
