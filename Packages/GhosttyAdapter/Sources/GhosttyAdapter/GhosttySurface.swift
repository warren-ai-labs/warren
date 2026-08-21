import Foundation
import AppKit
import GhosttyKit
import GhosttyTerminal
import WarrenDomain
import WarrenTerminalRenderer

@_exported import GhosttyTerminal

/// One Ghostty terminal surface backed by Warren's Host output stream.
///
/// The terminal process itself remains owned by tmux/Host; Ghostty only
/// renders the PTY byte stream and forwards input/resize back to Warren. This is
/// the same in-memory shape Termio uses for its companion/status architecture.
@MainActor
public final class GhosttySurface: Identifiable {
    /// Matches the 1.12 line-height used by the Web terminal while keeping
    /// Ghostty's cell grid authoritative for tmux resize calculations.
    private static let defaultCellHeightAdjustment = "12%"

    public let id: TerminalSessionID
    public let attachmentID: TerminalAttachmentID
    public let state: TerminalViewState
    public let inMemory: InMemoryTerminalSession
    /// Background output feed shared by the local and remote render paths.
    /// Immutable and thread-safe; scroll events stay on the main thread while
    /// Ghostty's ANSI parsing happens off it.
    public let outputWriter: WarrenGhosttyOutputWriter
    private let onViewportResize: @Sendable (Int, Int) -> Void
    private let ansiObserver = TerminalANSIObserver()
    /// Viewport fingerprint captured at demotion, used to detect a reattached
    /// surface whose viewport did not return to its previous position.
    private var reattachAnchorText: String?
    /// The AppKit terminal view currently backing this surface, kept weak so
    /// a recreated view is reflected on the next lookup. Used by diagnostics
    /// to distinguish "draw was called" from "draw could reach the screen".
    public weak var mountedTerminalView: TerminalView?

    public init(
        id: TerminalSessionID,
        attachmentID: TerminalAttachmentID,
        workingDirectory: String,
        font: TerminalFontPreference = .init(),
        outputRenderBudgetBytes: Int = 128 * 1024,
        outputRenderYield: Duration = .milliseconds(8),
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable (Int, Int) -> Void
    ) {
        self.id = id
        self.attachmentID = attachmentID
        self.onViewportResize = onResize

        let inMemory = InMemoryTerminalSession(
            write: onInput,
            resize: { viewport in
                onResize(Int(viewport.columns), Int(viewport.rows))
            }
        )
        let outputWriter = WarrenGhosttyOutputWriter(
            inMemory: inMemory,
            ansiObserver: ansiObserver,
            budgetBytes: outputRenderBudgetBytes,
            yield: outputRenderYield
        )
        self.inMemory = inMemory
        self.outputWriter = outputWriter

        let themeConfiguration = TerminalConfiguration { builder in
            builder.withBackground("#151110")
            builder.withForeground("#eae8e6")
            builder.withCursorColor("#e07850")
            builder.withCursorText("#151110")
            // Ghostty colors carry no alpha; blend Superset's 25% orange
            // selection over #151110 instead of using its rgba() value.
            builder.withSelectionBackground("#482b20")
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            for (index, color) in TerminalPalette.ember.enumerated() {
                builder.withPalette(index, color: Self.hex(color))
            }
        }
        // Warren is dark-only, but AppTerminalView can briefly report the
        // system's light appearance because it is mounted outside SwiftUI's
        // preferredColorScheme environment. Keep both variants identical so
        // that transient scheme updates cannot drop the colors Codex queries.
        let theme = TerminalTheme(
            light: themeConfiguration,
            dark: themeConfiguration
        )
        let controller = TerminalController(theme: theme) { _ in }
        controller.setTerminalConfiguration(Self.makeConfiguration(font: font))
        // Warren's desktop is intentionally dark and the terminal host is
        // mounted through a custom AppKit container rather than
        // TerminalSurfaceView. Apply the dark scheme here so Ghostty's own
        // OSC 10/11 replies use Warren's configured foreground/background
        // even before AppKit has propagated its appearance to the surface.
        controller.setColorScheme(.dark)
        let state = TerminalViewState(controller: controller)
        state.configuration = TerminalSurfaceOptions(
            backend: .inMemory(inMemory),
            workingDirectory: workingDirectory
        )
        self.state = state

        // Consume Ghostty's open-url action with Warren's own semantics.
        // Without a handler the embedded apprt falls back to spawning
        // `/usr/bin/open`, which floods os_log when a TUI renders a
        // clickable-but-missing path (see docs/lessons.md #002).
        state.openURLHandler = { [weak self] url, kind in
            Task { @MainActor in
                self?.handleOpenURL(url, kind: kind)
            }
        }
    }

    public func markRendered(epoch: UInt64, sequence: UInt64) {
        outputWriter.markRendered(epoch: epoch, sequence: sequence)
    }

    public var renderedEpoch: UInt64 {
        outputWriter.renderedEpoch
    }

    public var renderedSequence: UInt64 {
        outputWriter.renderedSequence
    }

    public func receive(_ payload: Data) {
        outputWriter.receive(payload)
    }

    /// Requests an immediate Ghostty display tick. The first reanchor
    /// snapshot can be written before the surface's display loop has painted
    /// anything; an explicit tick renders it without waiting for the next
    /// resize or keystroke.
    public func requestDisplayRefresh() {
        TerminalDiagnostics.logVerbose("display_refresh", [
            "session": id.description,
        ])
        state.controller.tick()
    }

    /// Presents the current grid inline. `ghostty_surface_refresh` alone can
    /// be a no-op when the pixel size is unchanged, which leaves a previously
    /// hidden surface on a stale/black framebuffer when it becomes active
    /// again without new output. A single inline draw forces the present.
    /// Presents the current grid inline and reports whether a draw actually
    /// happened. The draw is skipped while the AppKit view is not mounted
    /// (`state.surface` is nil), which happens right after a worktree switch
    /// recreates the terminal view. The render tick is only requested once the
    /// view is mounted, so polling while unmounted stays free of render work.
    @discardableResult
    public func presentNow() -> Bool {
        let size = state.surfaceSize.map {
            "\($0.columns)x\($0.rows)"
        } ?? "nil"
        let view = mountedTerminalView
        let viewAttached = view?.window != nil
        let viewHidden = view?.isHidden ?? true
        let viewVisible = view.map {
            $0.window != nil && !$0.isHidden && !$0.visibleRect.isEmpty
        } ?? false
        guard let raw = state.surface?.rawValue else {
            TerminalDiagnostics.log("present_now", [
                "session": id.description,
                "result": "false",
                "surfaceReady": "false",
                "size": size,
                "viewAttached": viewAttached ? "true" : "false",
                "viewHidden": viewHidden ? "true" : "false",
                "viewVisible": viewVisible ? "true" : "false",
            ])
            return false
        }
        state.controller.tick()
        ghostty_surface_draw(raw)
        let fields = [
            "session": id.description,
            "result": "true",
            "surfaceReady": "true",
            "size": size,
            "viewAttached": viewAttached ? "true" : "false",
            "viewHidden": viewHidden ? "true" : "false",
            "viewVisible": viewVisible ? "true" : "false",
        ]
        if viewVisible {
            TerminalDiagnostics.logVerbose("present_now", fields)
        } else {
            // A draw was issued while the view could not present it. This is
            // the closest cheap signal we can emit for a transient black pane
            // without enabling the full Ghostty render log on the hot path.
            TerminalDiagnostics.log("present_now", fields)
            TerminalDiagnostics.log("present_stall_suspected", [
                "session": id.description,
                "reason": view == nil
                    ? "no-mounted-view"
                    : (!viewAttached ? "view-not-attached"
                        : (viewHidden ? "view-hidden" : "view-not-visible")),
                "view": terminalViewDescription,
            ])
        }
        return true
    }

    public var terminalViewIsPresentable: Bool {
        guard let view = mountedTerminalView else { return false }
        return view.window != nil && !view.isHidden && !view.visibleRect.isEmpty
    }

    public var terminalSurfaceIsReady: Bool {
        state.surface?.rawValue != nil
    }

    public var terminalViewDescription: String {
        guard let view = mountedTerminalView else { return "nil" }
        let size = GhosttyDiagnosticsFormat.finiteSize(view.visibleRect.size)
        return "attached=\(view.window != nil ? "true" : "false") "
            + "hidden=\(view.isHidden ? "true" : "false") visible=\(size)"
    }

    public func apply(font: TerminalFontPreference) {
        _ = state.controller.setTerminalConfiguration(Self.makeConfiguration(font: font))
    }

    /// Terminal chrome that Warren owns as app-level shortcuts. Ghostty's
    /// default bindings for these keys would consume them while the surface is
    /// the first responder, so each one is explicitly unbound.
    private static func makeConfiguration(
        font: TerminalFontPreference
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withBackgroundOpacity(1)
            builder.withFontFamily(font.family)
            builder.withFontSize(Float(font.size))
            builder.withFontThicken(false)
            builder.withCustom("adjust-cell-height", Self.defaultCellHeightAdjustment)
            builder.withCustom("copy-on-select", "true")
            builder.withCustom("search-foreground", "#eae8e6")
            builder.withCustom("search-background", "#3a3837")
            builder.withCustom("search-selected-foreground", "#151110")
            builder.withCustom("search-selected-background", "#e07850")
            builder.withWindowPaddingX(0)
            builder.withWindowPaddingY(0)
            // Ghostty compresses cold scrollback pages while idle and restores
            // them lazily; a resize is what pulls compressed history back into
            // the active area. Warren reattaches the same warm surface on every
            // tab switch without a size change, so compressed pages can stay
            // unreachable until the user resizes the window. Disable idle
            // compression so history stays reachable on reattach; the
            // scrollback limit still bounds logical history, and only resident
            // memory grows (see docs/decisions/2026-08-17-warm-surface-memory.md).
            builder.withCustom("scrollback-compression", "false")
            // Ghostty's macOS app doubles precise trackpad deltas before they
            // reach the C API; libghostty-swift forwards raw pixels instead.
            // Compensate in the core so scroll pacing matches standalone
            // Ghostty instead of feeling half-speed and slightly choppy.
            builder.withCustom("mouse-scroll-multiplier", "precision:2")
            builder.withCustom("keybind", "super+t=unbind")
            builder.withCustom("keybind", "super+w=unbind")
            builder.withCustom("keybind", "super+x=unbind")
            builder.withCustom("keybind", "super+k=unbind")
            builder.withCustom("keybind", "super+b=unbind")
            builder.withCustom("keybind", "super+q=unbind")
            builder.withCustom("keybind", "super+f=unbind")
            // ⌘1…⌘9 are Warren's tab shortcuts, but Ghostty defaults them to
            // goto_tab/last_tab. Unbind both the character and physical-key
            // forms; recent Ghostty versions keep consuming the physical form
            // unless both are removed.
            for index in 1...9 {
                builder.withCustom("keybind", "super+\(index)=unbind")
                builder.withCustom("keybind", "super+digit_\(index)=unbind")
            }
            // Agent TUIs (Claude Code, Codex, etc.) use Enter to submit a
            // prompt. Ghostty otherwise sends Shift+Enter as a kitty-protocol
            // escape that these TUIs do not treat as a newline; map it to a
            // literal newline so multi-line prompts stay possible.
            builder.withCustom("keybind", "shift+enter=text:\\n")
        }
    }

    private static func hex(_ color: TerminalPaletteColor) -> String {
        String(
            format: "#%02x%02x%02x",
            color.red,
            color.green,
            color.blue
        )
    }

    public func semanticSnapshot() -> TerminalSemanticSnapshot {
        ansiObserver.snapshot()
    }

    /// Re-sync a reattached warm surface with Ghostty's viewport state.
    ///
    /// A warm surface keeps its native Ghostty state while demoted, but the
    /// viewport/page-list state can go stale (compressed history that is only
    /// restored lazily, a pinned offset that no longer matches the current
    /// page list, or a framebuffer that stopped repainting while occluded).
    /// The user-visible workaround for all of these is a resize, which forces
    /// Ghostty to reflow and repaint. This reproduces the essential part
    /// without changing the pixel size: pin the viewport to the live bottom
    /// (resetting any stale pin/offset cache) and draw immediately so the
    /// surface repaints even when no new output arrived.
    public func resyncForActivation() {
        scrollToBottom()
        requestDisplayRefresh()
        if terminalViewIsPresentable {
            _ = presentNow()
        }
    }

    /// Capture the current viewport content as the anchor for the next
    /// reattach. Called when the surface is demoted; the anchor is compared
    /// after reattach to decide whether a forced resync is needed.
    public func captureReattachAnchor() {
        guard let text = viewportText() else {
            reattachAnchorText = nil
            return
        }
        reattachAnchorText = text
    }

    /// Resync the reattached viewport only when it did not return to its
    /// pre-demotion position. A normal warm reattach keeps the same viewport
    /// content, so no scroll is performed and the user's scroll position is
    /// preserved. If the viewport moved (stale pin, clamped offset, or a blank
    /// resume), the forced resync recovers it.
    public func resyncIfNeeded() {
        let anchor = reattachAnchorText
        reattachAnchorText = nil
        guard let anchor, let text = viewportText(), text != anchor else {
            return
        }
        TerminalDiagnostics.log("activation_resync", [
            "session": id.description,
            "reason": "viewport-anchor-mismatch",
        ])
        resyncForActivation()
    }

    /// Re-submit Ghostty's current grid even when the renderer's pixel size
    /// has not changed. libghostty intentionally suppresses duplicate metric
    /// callbacks, while Warren must calibrate a newly adopted or re-selected
    /// tmux runtime that may not match the persisted last-requested size.
    public func synchronizeViewport() {
        guard let size = state.surfaceSize else { return }
        TerminalDiagnostics.log("viewport_sync", [
            "session": id.description,
            "size": "\(size.columns)x\(size.rows)",
        ])
        onViewportResize(Int(size.columns), Int(size.rows))
    }

    /// Warren's open semantics for terminal links. Only non-empty URLs with a
    /// known scheme or existing absolute paths are opened, through
    /// NSWorkspace; missing paths and empty targets are ignored. Ghostty's
    /// `/usr/bin/open` fallback is never used.
    private func handleOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        _ = kind
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let components = URLComponents(string: trimmed),
           let scheme = components.scheme?.lowercased(),
           let target = components.url,
           ["http", "https", "mailto", "tel", "file"].contains(scheme) {
            NSWorkspace.shared.open(target)
            return
        }
        let path = (trimmed as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

public enum TerminalSearchDirection: Sendable {
    case next
    case previous
}

public extension GhosttySurface {
    /// Starts (or replaces) a scrollback search inside Ghostty. An empty
    /// query stops the current search, matching Ghostty's `search:` action.
    func search(for query: String) {
        guard !query.isEmpty else {
            endSearch()
            return
        }
        _ = performBindingAction("search:\(query)")
    }

    func navigateSearch(_ direction: TerminalSearchDirection) {
        switch direction {
        case .next: _ = performBindingAction("navigate_search:next")
        case .previous: _ = performBindingAction("navigate_search:previous")
        }
    }

    func endSearch() {
        _ = performBindingAction("end_search")
    }

    /// Jump the viewport back to the live prompt at the bottom.
    func scrollToBottom() {
        _ = performBindingAction("scroll_to_bottom")
    }

    /// Current selection text, used to prefill the find box (⌘F with a
    /// selection behaves like Ghostty's "search selection").
    func readSelection() -> String? {
        guard let raw = state.surface?.rawValue else { return nil }
        var out = ghostty_text_s()
        guard ghostty_surface_read_selection(raw, &out) else { return nil }
        defer { ghostty_surface_free_text(raw, &out) }
        guard let text = out.text, out.text_len > 0 else { return nil }
        let bytes = UnsafeBufferPointer(start: text, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        let value = String(decoding: bytes, as: UTF8.self)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    private func performBindingAction(_ action: String) -> Bool {
        guard let raw = state.surface?.rawValue else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(raw, pointer, UInt(action.utf8.count))
        }
    }

    /// The current viewport text, used as a position fingerprint. Reads the
    /// terminal grid directly, so it reflects the true viewport even when the
    /// rendered frame is stale.
    private func viewportText() -> String? {
        guard let raw = state.surface?.rawValue else { return nil }
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
        guard ghostty_surface_read_text(raw, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(raw, &out) }
        guard let text = out.text, out.text_len > 0 else { return "" }
        let bytes = UnsafeBufferPointer(start: text, count: Int(out.text_len))
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
