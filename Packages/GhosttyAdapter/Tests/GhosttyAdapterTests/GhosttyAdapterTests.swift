import XCTest
import WarrenDomain
import AppKit
import GhosttyKit
@testable import GhosttyTerminal
@testable import GhosttyAdapter

final class GhosttyAdapterTests: XCTestCase {
    func testDefaultRetentionBudgetSupportsNormalMultiAgentWorkflows() {
        let policy = TerminalSurfaceRetentionPolicy()

        XCTAssertEqual(policy.warmLimit, 8)
        XCTAssertEqual(policy.warmByteLimit, 1024 * 1024 * 1024)
    }

    func testRetentionPolicyKeepsOneActiveAndTwoMostRecentWarmSurfaces() {
        let ids = (0..<4).map { _ in TerminalSessionID(rawValue: UUID()) }
        var policy = TerminalSurfaceRetentionPolicy(warmLimit: 2)

        XCTAssertEqual(policy.activate(ids[0]), [])
        XCTAssertEqual(policy.activate(ids[1]), [])
        XCTAssertEqual(policy.activate(ids[2]), [])
        XCTAssertEqual(policy.activate(ids[3]), [ids[0]])

        XCTAssertEqual(policy.activeSessionID, ids[3])
        XCTAssertEqual(policy.warmSessionIDs, [ids[2], ids[1]])
        XCTAssertEqual(policy.residency(of: ids[3]), .active)
        XCTAssertEqual(policy.residency(of: ids[2]), .warm)
        XCTAssertEqual(policy.residency(of: ids[0]), .cold)
    }

    func testRetentionPolicyPromotionDoesNotDuplicateWarmSurface() {
        let first = TerminalSessionID(rawValue: UUID())
        let second = TerminalSessionID(rawValue: UUID())
        var policy = TerminalSurfaceRetentionPolicy(warmLimit: 2)

        _ = policy.activate(first)
        _ = policy.activate(second)
        XCTAssertEqual(policy.activate(first), [])

        XCTAssertEqual(policy.activeSessionID, first)
        XCTAssertEqual(policy.warmSessionIDs, [second])
    }

    func testRetentionPolicyDeactivationRespectsZeroWarmBudget() {
        let sessionID = TerminalSessionID(rawValue: UUID())
        var policy = TerminalSurfaceRetentionPolicy(warmLimit: 0)

        _ = policy.activate(sessionID)

        XCTAssertEqual(policy.deactivate(), [sessionID])
        XCTAssertNil(policy.activeSessionID)
        XCTAssertTrue(policy.warmSessionIDs.isEmpty)
    }

    func testRetentionPolicyEvictsWarmSurfaceAboveMemoryBudget() {
        let first = TerminalSessionID(rawValue: UUID())
        let second = TerminalSessionID(rawValue: UUID())
        var policy = TerminalSurfaceRetentionPolicy(
            warmLimit: 2,
            warmByteLimit: 100
        )
        _ = policy.updateEstimatedBytes(120, for: first)
        _ = policy.updateEstimatedBytes(80, for: second)
        _ = policy.activate(first)

        XCTAssertEqual(policy.activate(second), [first])
        XCTAssertEqual(policy.estimatedWarmBytes, 0)
        XCTAssertEqual(policy.residency(of: first), .cold)
    }

    func testRetentionPolicyRemainsBoundedAcrossFiveHundredSwitches() {
        let ids = (0..<11).map { _ in TerminalSessionID(rawValue: UUID()) }
        var policy = TerminalSurfaceRetentionPolicy(warmLimit: 2)
        var evicted: [TerminalSessionID] = []

        for index in 0..<500 {
            evicted.append(contentsOf: policy.activate(ids[index % ids.count]))
            XCTAssertLessThanOrEqual(policy.warmSessionIDs.count, 2)
            if let activeSessionID = policy.activeSessionID {
                XCTAssertFalse(policy.warmSessionIDs.contains(activeSessionID))
            }
            XCTAssertEqual(Set(policy.warmSessionIDs).count, policy.warmSessionIDs.count)
        }

        XCTAssertFalse(evicted.isEmpty)
        XCTAssertNotNil(policy.activeSessionID)
    }

    @MainActor
    func testSemanticSnapshotPreservesANSIStyleAndUnicodeWithoutWindow() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )
        let output =
            "plain \u{1b}[1;38;2;224;120;80morange\u{1b}[0m "
                + "\u{1b}[38;5;42mgreen\u{1b}[0m "
                + "\u{1b}[48;2;49;45;44mcomposer\u{1b}[0m"
        surface.receive(Data(output.utf8))

        let snapshot = surface.semanticSnapshot()
        XCTAssertEqual(snapshot.plainText, "plain orange green composer")
        XCTAssertTrue(snapshot.containsStyledText)
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "orange" }?.style.foreground,
            .rgb(red: 224, green: 120, blue: 80)
        )
        XCTAssertEqual(snapshot.runs.first { $0.text == "orange" }?.style.bold, true)
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "green" }?.style.foreground,
            .indexed(42)
        )
        XCTAssertEqual(
            snapshot.runs.first { $0.text == "composer" }?.style.background,
            .rgb(red: 49, green: 45, blue: 44)
        )
    }

    @MainActor
    func testOccludedSurfaceKeepsGridCurrentWhileBackgroundOutputDrains() async throws {
        let recorder = LockedInputRecorder()
        let (surface, view, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }

        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data("BEFORE-occlusion".utf8))
        for _ in 0..<100 where surface.renderedSequence < 15 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let before = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(
            before.contains("BEFORE-occlusion"),
            "precondition: grid should be current while visible: \(before)"
        )

        // Mimic a parked/warm surface: hide pixels and stop the display link,
        // without tearing the native surface down (this is what
        // TerminalSurfaceManager demote/promote does — it keeps the Ghostty
        // surface alive).
        view.setSurfaceVisible(false)

        surface.outputWriter.enqueue(epoch: 1, sequence: 15, payload: Data("WHILE-HIDDEN".utf8))
        for _ in 0..<100 where surface.inMemory.readViewportText()?.contains("WHILE-HIDDEN") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterOccluded = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(
            afterOccluded.contains("HIDDEN"),
            "occluded surface must keep its grid current from background output: \(afterOccluded)"
        )

        // Harder case: fully detach the view from the window, exactly like a
        // warm park. The surface is retained, only the AppKit view leaves the
        // hierarchy.
        view.removeFromSuperview()

        surface.outputWriter.enqueue(epoch: 1, sequence: 26, payload: Data("AFTER-DETACH".utf8))
        for _ in 0..<100 where surface.inMemory.readViewportText()?.contains("AFTER-DETACH") != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let afterDetach = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(
            afterDetach.contains("DETACH"),
            "detached (parked) surface must keep its grid current from background output: \(afterDetach)"
        )

        surface.outputWriter.shutdown()
    }

    @MainActor
    func testCellHeightAdjustmentMatchesWebTerminalLineHeight() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )

        XCTAssertNil(surface.state.controller.lastConfigurationIssue)
        XCTAssertTrue(surface.state.renderedConfig.contains("font-thicken = false"))
        XCTAssertTrue(surface.state.renderedConfig.contains("adjust-cell-height = 12%"))
        XCTAssertTrue(surface.state.renderedConfig.contains("copy-on-select = true"))
        XCTAssertTrue(surface.state.renderedConfig.contains("mouse-scroll-multiplier = precision:2"))
        XCTAssertTrue(surface.state.renderedConfig.contains("search-selected-background = #e07850"))
        let theme = surface.state.theme.dark.rendered
        XCTAssertTrue(theme.contains("palette = 0=#151110"))
        XCTAssertTrue(theme.contains("palette = 1=#dc6b6b"))
        XCTAssertTrue(theme.contains("palette = 8=#5c5856"))
        XCTAssertTrue(theme.contains("palette = 15=#ffffff"))
        XCTAssertTrue(theme.contains("cursor-text = #151110"))
        XCTAssertTrue(theme.contains("selection-background = #482b20"))
    }

    @MainActor
    func testAppLevelShortcutsAreUnboundFromGhostty() {
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { _ in },
            onResize: { _, _ in }
        )

        var shortcuts = ["super+t", "super+w", "super+x", "super+k", "super+b", "super+q", "super+f"]
        for index in 1...9 {
            shortcuts.append("super+\(index)")
            shortcuts.append("super+digit_\(index)")
        }

        for shortcut in shortcuts {
            XCTAssertTrue(
                surface.state.renderedConfig.contains("keybind = \(shortcut)=unbind"),
                "Expected \(shortcut) to be unbound so Warren shortcuts stay available."
            )
        }
    }

    @MainActor
    func testShiftEnterKeybindEmitsLiteralNewline() async throws {
        let recorder = LockedInputRecorder()
        let surface = GhosttySurface(
            id: TerminalSessionID(),
            attachmentID: TerminalAttachmentID(),
            workingDirectory: "/tmp",
            onInput: { recorder.append($0) },
            onResize: { _, _ in }
        )

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.delegate = surface.state
        view.controller = surface.state.controller
        view.configuration = surface.state.configuration
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let terminalSurface = try await waitUntilSurfaceAvailable(on: surface.state)
        // Nested terminal applications may request the kitty keyboard protocol
        // from their outer terminal.
        // Ghostty may then encode Shift+Enter as CSI 13;2u instead of firing
        // the text: keybind, which is exactly what Warren must handle.
        surface.receive(Data("\u{1b}[>1u".utf8))
        try await Task.sleep(for: .milliseconds(100))
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var event = ghostty_input_key_s()
            event.action = action
            event.keycode = 0x24 // kVK_Return
            event.mods = GHOSTTY_MODS_SHIFT
            event.consumed_mods = GHOSTTY_MODS_SHIFT
            event.text = nil
            event.unshifted_codepoint = 0x0D
            event.composing = false
            _ = terminalSurface.sendKeyEvent(event)
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            recorder.allBytes(),
            Data([0x0A]),
            "Shift+Enter should emit a literal newline (received bytes)"
        )
    }

    @MainActor
    func testHostManagedTerminalAnswersWarrenColorQueriesAfterMount() async throws {
        let recorder = LockedInputRecorder()
        let (surface, view, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }

        // AppKit can report a light appearance for this host-managed view even
        // though Warren's product theme is dark-only. Pin that lifecycle input
        // so the regression test does not depend on the test runner's theme.
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        try await Task.sleep(for: .milliseconds(50))

        // Codex batches OSC 10/11 during its startup probe. Exercise the
        // production output writer so the assertion covers the host-managed
        // PTY path rather than only the synchronous test helper.
        surface.outputWriter.enqueueRaw(
            Data("\u{1b}]10;?\u{1b}\\\u{1b}]11;?\u{1b}\\".utf8)
        )

        let expected = Data(
            "\u{1b}]10;rgb:eaea/e8e8/e6e6\u{1b}\\\u{1b}]11;rgb:1515/1111/1010\u{1b}\\".utf8
        )
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().count < expected.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            Array(recorder.allBytes()),
            Array(expected),
            "the Warren Ghostty surface should answer Codex's OSC 10/11 startup probe"
        )
    }

    @MainActor
    func testInternalTabDemotionSuppressesFocusLossReportButRealBlurReportsIt() async throws {
        let recorder = LockedInputRecorder()
        let (surface, view, window) = try await makeMountedTerminal(
            recorder: recorder,
            suppressFocusLossReporting: true
        )
        defer { window.orderOut(nil) }

        // Let the initial detached-view lifecycle settle before enabling focus
        // reporting; that setup transition is not the tab demotion under test.
        try await Task.sleep(for: .milliseconds(250))
        // Enable xterm focus reporting, the mode used by Codex, Claude, Vim,
        // and Neovim to receive FocusLost/FocusGained notifications.
        surface.receive(Data("\u{1b}[?1004h".utf8))
        try await Task.sleep(for: .milliseconds(100))
        recorder.clear()

        view.setFocusLossReportingSuppressed(true)
        view.core.setFocus(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(
            recorder.allBytes().containsSubsequence(Data("\u{1b}[O".utf8)),
            "an internal tab demotion must not write CSI O to the PTY"
        )

        view.setFocusLossReportingSuppressed(false)
        view.core.setFocus(true)
        view.core.setFocus(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !recorder.allBytes().containsSubsequence(Data("\u{1b}[O".utf8)),
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(
            recorder.allBytes().containsSubsequence(Data("\u{1b}[O".utf8)),
            "a real blur must write CSI O to the PTY"
        )
    }

    @MainActor
    func testDeferredDetachDoesNotReportFocusLossAfterImmediateReattach() async throws {
        let recorder = LockedInputRecorder()
        let (surface, view, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(250))
        surface.receive(Data("\u{1b}[?1004h".utf8))
        try await Task.sleep(for: .milliseconds(100))
        view.core.setFocus(true)
        recorder.clear()

        // AppKit defers the detached-view focus cleanup by one main-runloop
        // turn. Reattach before that cleanup runs to exercise the stale-task
        // guard; the terminal never actually lost user-visible focus.
        let placeholder = NSView(frame: view.frame)
        window.contentView = placeholder
        window.contentView = view
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(
            recorder.allBytes().containsSubsequence(Data("\u{1b}[O".utf8)),
            "a stale detached-view cleanup must not write CSI O after reattach"
        )
    }

    @MainActor
    func testArrowDownOutsideApplicationCursorModeEmitsCsi() async throws {
        let recorder = LockedInputRecorder()
        let (_, view, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }
        try sendKey(
            keyCode: 0x7D, // kVK_DownArrow
            characters: "\u{F701}",
            to: view,
            in: window
        )

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            Array(recorder.allBytes()),
            Array(Data("\u{1b}[B".utf8)),
            "Down arrow outside application cursor mode must stay CSI B"
        )
    }

    @MainActor
    func testArrowDownHonorsApplicationCursorKeysMode() async throws {
        let recorder = LockedInputRecorder()
        let (surface, view, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }

        // less (via smkx / DECCKM) asks the terminal to switch arrow keys
        // from CSI to SS3 encoding while a pager is active.
        surface.receive(Data("\u{1b}[?1h".utf8))
        try await Task.sleep(for: .milliseconds(100))
        try sendKey(
            keyCode: 0x7D, // kVK_DownArrow
            characters: "\u{F701}",
            to: view,
            in: window
        )

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            Array(recorder.allBytes()),
            Array(Data("\u{1b}OB".utf8)),
            "Down arrow in application cursor mode must be SS3 B, not CSI B"
        )
    }

    @MainActor
    func testHomeAndEndFollowApplicationCursorKeysMode() async throws {
        let recorder = LockedInputRecorder()
        let (surface, view, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }

        // smkx also switches Home/End to SS3 in less-style applications.
        surface.receive(Data("\u{1b}[?1h".utf8))
        try await Task.sleep(for: .milliseconds(100))
        try sendKey(
            keyCode: 0x73, // kVK_Home
            characters: "\u{F729}",
            to: view,
            in: window
        )
        var deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try sendKey(
            keyCode: 0x77, // kVK_End
            characters: "\u{F72B}",
            to: view,
            in: window
        )
        deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().count < 6, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            Array(recorder.allBytes()),
            Array(Data("\u{1b}OH\u{1b}OF".utf8)),
            "Home/End in application cursor mode must be SS3 H/F, not CSI H/F"
        )
    }

    func testDiagnosticSizeFormattingNeverTrapsOnExtremeValues() {
        XCTAssertEqual(
            GhosttyDiagnosticsFormat.finiteSize(
                CGSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.infinity
                )
            ),
            ">1Mxinf"
        )
        XCTAssertEqual(
            GhosttyDiagnosticsFormat.finiteSize(
                CGSize(width: CGFloat.nan, height: 0)
            ),
            "infx0"
        )
        XCTAssertEqual(
            GhosttyDiagnosticsFormat.finiteSize(CGSize(width: -800, height: 600)),
            "-800x600"
        )
    }

    @MainActor
    func testOutputWriterDrainsFramedAndRawBytesOffMainInOrder() async throws {
        let recorder = LockedInputRecorder()
        let (surface, _, window) = try await makeMountedTerminal(
            recorder: recorder,
            outputRenderBudgetBytes: 4,
            outputRenderYield: .milliseconds(1)
        )
        defer { window.orderOut(nil) }

        surface.outputWriter.enqueue(epoch: 1, sequence: 0, payload: Data("abcd".utf8))
        surface.outputWriter.enqueue(epoch: 1, sequence: 4, payload: Data("ef".utf8))
        surface.outputWriter.enqueueRaw(Data("gh".utf8))

        for _ in 0..<100 where surface.renderedSequence < 8 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(surface.semanticSnapshot().plainText, "abcdefgh")
        surface.outputWriter.shutdown()
    }

    func testOutputWriterRejectsEnqueueAfterShutdown() async throws {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let writer = WarrenGhosttyOutputWriter(
            inMemory: session,
            ansiObserver: TerminalANSIObserver(),
            budgetBytes: 1,
            yield: .milliseconds(1)
        )

        // Without a mounted surface the drain keeps its slice pending, which
        // gives shutdown a real in-flight task to cancel without entering the
        // native Ghostty path.
        writer.enqueue(epoch: 1, sequence: 0, payload: Data("before".utf8))
        await Task.yield()
        writer.shutdown()

        // A late transport callback belongs to the disposed surface and must
        // not recreate a drain or repopulate the pending buffer.
        writer.enqueue(epoch: 2, sequence: 0, payload: Data("after".utf8))
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(writer.bufferEpoch)
        XCTAssertEqual(writer.enqueuedSequence, 0)
        XCTAssertEqual(writer.renderedSequence, 0)
    }

    @MainActor
    func testOutputReceivedBeforeSurfaceMountIsFlushedAfterAttach() async throws {
        let recorder = LockedInputRecorder()
        let (surface, _, window) = try await makeMountedTerminal(
            recorder: recorder,
            preMountOutput: Data("BEFORE-MOUNT".utf8)
        )
        defer { window.orderOut(nil) }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while surface.inMemory.readViewportText()?.contains("BEFORE-MOUNT") != true,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        let viewport = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(
            viewport.contains("BEFORE-MOUNT"),
            "output received before the native surface attached must not be lost: \(viewport)"
        )
        surface.outputWriter.shutdown()
    }

    func testSnapshotRestoreRejectsEmptyOrMissingSurface() {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        XCTAssertFalse(session.restoreSnapshot(Data()))
        XCTAssertFalse(session.restoreSnapshot(Data("not-a-snapshot".utf8)))
    }

    @MainActor
    func testNativeSnapshotRestoreReplacesViewportAndContinuesAtCursor() async throws {
        let recorder = LockedInputRecorder()
        let (surface, _, window) = try await makeMountedTerminal(recorder: recorder)
        defer { window.orderOut(nil) }

        surface.receive(Data("old-content".utf8))
        let snapshot = try XCTUnwrap(Data(base64Encoded: Self.atomicSnapshotFixture))
        XCTAssertTrue(surface.restoreSnapshot(snapshot, epoch: 7, sequence: 100))

        recorder.clear()
        surface.receive(Data("\u{1b}]10;?\u{1b}\\\u{1b}]11;?\u{1b}\\".utf8))
        let colorQueryExpected = Data(
            "\u{1b}]10;rgb:eaea/e8e8/e6e6\u{1b}\\\u{1b}]11;rgb:1515/1111/1010\u{1b}\\".utf8
        )
        let colorQueryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while recorder.allBytes().count < colorQueryExpected.count,
              ContinuousClock.now < colorQueryDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            Array(recorder.allBytes()),
            Array(colorQueryExpected),
            "native snapshot restore must preserve Warren's configured default colors"
        )

        let restored = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(restored.contains("first"))
        XCTAssertTrue(restored.contains("styled blank"))
        XCTAssertTrue(restored.contains("last"))
        XCTAssertFalse(restored.contains("old-content"))

        let beforeInvalidRestore = surface.inMemory.readViewportText()
        XCTAssertFalse(surface.restoreSnapshot(Data("invalid".utf8), epoch: 8, sequence: 0))
        XCTAssertEqual(surface.inMemory.readViewportText(), beforeInvalidRestore)

        surface.outputWriter.enqueue(epoch: 7, sequence: 100, payload: Data("Z".utf8))
        for _ in 0..<100 where surface.renderedSequence < 101 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(surface.renderedEpoch, 7)
        XCTAssertEqual(surface.renderedSequence, 101)
        let continued = try XCTUnwrap(surface.inMemory.readViewportText())
        XCTAssertTrue(
            continued.contains("last  Z"),
            "live output should continue from the restored row-3 column-7 cursor: \(continued)"
        )
        surface.outputWriter.shutdown()
    }

    private static let atomicSnapshotFixture = """
    R0hPU1RTTlABAAEAlAMAAO/6KIooAAgAAAAAAAAAAAAAAAcAAAAnAAAAAAEAdAAAAAEBAQEAAAAACAAEIgBkAAAAAAQiAGQAAAAABCIAZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAAAAAP//////////AAEBAQEdHyHMZma1vWjwxnSBor6ylLuKvrfFyMZmZmbVTlO5ykrnxUd6ptrDl9hwwLHq6uoAAAAAAF8AAIcAAK8AANcAAP8AXwAAX18AX4cAX68AX9cAX/8AhwAAh18Ah4cAh68Ah9cAh/8ArwAAr18Ar4cAr68Ar9cAr/8A1wAA118A14cA168A19cA1/8A/wAA/18A/4cA/68A/9cA//9fAABfAF9fAIdfAK9fANdfAP9fXwBfX19fX4dfX69fX9dfX/9fhwBfh19fh4dfh69fh9dfh/9frwBfr19fr4dfr69fr9dfr/9f1wBf119f14df169f19df1/9f/wBf/19f/4df/69f/9df//+HAACHAF+HAIeHAK+HANeHAP+HXwCHX1+HX4eHX6+HX9eHX/+HhwCHh1+Hh4eHh6+Hh9eHh/+HrwCHr1+Hr4eHr6+Hr9eHr/+H1wCH11+H14eH16+H19eH1/+H/wCH/1+H/4eH/6+H/9eH//+vAACvAF+vAIevAK+vANevAP+vXwCvX1+vX4evX6+vX9evX/+vhwCvh1+vh4evh6+vh9evh/+vrwCvr1+vr4evr6+vr9evr/+v1wCv11+v14ev16+v19ev1/+v/wCv/1+v/4ev/6+v/9ev///XAADXAF/XAIfXAK/XANfXAP/XXwDXX1/XX4fXX6/XX9fXX//XhwDXh1/Xh4fXh6/Xh9fXh//XrwDXr1/Xr4fXr6/Xr9fXr//X1wDX11/X14fX16/X19fX1//X/wDX/1/X/4fX/6/X/9fX////AAD/AF//AIf/AK//ANf/AP//XwD/X1//X4f/X6//X9f/X///hwD/h1//h4f/h6//h9f/h///rwD/r1//r4f/r6//r9f/r///1wD/11//14f/16//19f/1////wD//1///4f//6///9f///8ICAgSEhIcHBwmJiYwMDA6OjpEREROTk5YWFhiYmJsbGx2dnaAgICKioqUlJSenp6oqKiysrK8vLzGxsbQ0NDa2trk5OTu7u4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgA2AAAAddWM0gAAAQAAAAAAAAAAAAYAAgABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAMAowAAAKcxwt4oAAgAAQAAAIAAwAAAIAAAAAgAAAEAAAAAAAHwAAAAAAAAAAAAAAAFAGZpcnN0IBYAzAEABNABAATkAQAEsAEABJQBAASQAQAEgAAABIgBAASwAQAEhAEABLgBAASsAQAEgAAABIAAAASAAAAEgAAABIAAAASAAAAEgAAABIAAAASAAAAEgAAABAAEAGxhc3QAAAAAAAAAAAAAAAAAAAAAAAAABwAAAAAAJ4Bj0QUAAAAAAOQg7woEAAYAAAChEYpeAAAAAAAABgAAAAAAPutTPg==
    """
}

private final class LockedInputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
    }

    func allBytes() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        bytes.removeAll(keepingCapacity: true)
    }
}

private extension Data {
    func containsSubsequence(_ needle: Data) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        let bytes = Array(self)
        let target = Array(needle)
        return bytes.indices.contains { index in
            guard index + target.count <= bytes.count else { return false }
            return Array(bytes[index..<(index + target.count)]) == target
        }
    }
}

@MainActor
private func makeMountedTerminal(
    recorder: LockedInputRecorder,
    outputRenderBudgetBytes: Int = 128 * 1024,
    outputRenderYield: Duration = .milliseconds(8),
    suppressFocusLossReporting: Bool = false,
    preMountOutput: Data? = nil
) async throws -> (GhosttySurface, AppTerminalView, NSWindow) {
    let surface = GhosttySurface(
        id: TerminalSessionID(),
        attachmentID: TerminalAttachmentID(),
        workingDirectory: "/tmp",
        outputRenderBudgetBytes: outputRenderBudgetBytes,
        outputRenderYield: outputRenderYield,
        onInput: { recorder.append($0) },
        onResize: { _, _ in }
    )
    if let preMountOutput {
        surface.receive(preMountOutput)
    }

    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    view.delegate = surface.state
    view.controller = surface.state.controller
    view.configuration = surface.state.configuration
    if suppressFocusLossReporting {
        view.setFocusLossReportingSuppressed(true)
    }
    window.contentView = view
    view.layoutSubtreeIfNeeded()

    _ = try await waitUntilSurfaceAvailable(on: surface.state)
    return (surface, view, window)
}

@MainActor
private func sendKey(
    keyCode: UInt16,
    characters: String,
    to view: AppTerminalView,
    in window: NSWindow
) throws {
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else {
        struct KeyEventUnavailable: Error {}
        throw KeyEventUnavailable()
    }
    view.keyDown(with: event)
}

@MainActor
private func waitUntilSurfaceAvailable(
    on state: TerminalViewState
) async throws -> TerminalSurface {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while state.surface == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    guard let surface = state.surface else {
        struct SurfaceUnavailable: Error {}
        throw SurfaceUnavailable()
    }
    return surface
}
