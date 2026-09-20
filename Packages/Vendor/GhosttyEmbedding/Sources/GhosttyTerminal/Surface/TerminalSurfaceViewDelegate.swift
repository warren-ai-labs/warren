//
//  TerminalSurfaceViewDelegate.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import CoreGraphics
import Foundation
import GhosttyKit

@MainActor
public protocol TerminalSurfaceViewDelegate: AnyObject {}

@MainActor
public protocol TerminalSurfaceTitleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeTitle(_ title: String)
}

@MainActor
public protocol TerminalSurfaceGridResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics)
}

@MainActor
public protocol TerminalSurfaceResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(columns: Int, rows: Int)
}

@MainActor
public protocol TerminalSurfaceFocusDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeFocus(_ focused: Bool)
}

@MainActor
public protocol TerminalSurfaceBellDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRingBell()
}

@MainActor
public protocol TerminalSurfaceCloseDelegate: TerminalSurfaceViewDelegate {
    func terminalDidClose(processAlive: Bool)
}

// MARK: - Extended action delegates

/// State of an OSC 9;4 / DECSET progress report.
public enum TerminalProgressState: Sendable {
    case remove
    case set
    case error
    case indeterminate
    case pause

    init?(_ raw: ghostty_action_progress_report_state_e) {
        switch raw {
        case GHOSTTY_PROGRESS_STATE_REMOVE: self = .remove
        case GHOSTTY_PROGRESS_STATE_SET: self = .set
        case GHOSTTY_PROGRESS_STATE_ERROR: self = .error
        case GHOSTTY_PROGRESS_STATE_INDETERMINATE: self = .indeterminate
        case GHOSTTY_PROGRESS_STATE_PAUSE: self = .pause
        default: return nil
        }
    }
}

/// OSC 9;4 progress report (state + 0-100 percent, nil percent when the
/// emitter didn't provide one — e.g. INDETERMINATE / REMOVE).
@MainActor
public protocol TerminalSurfaceProgressReportDelegate: TerminalSurfaceViewDelegate {
    func terminalDidReportProgress(state: TerminalProgressState, percent: Int?)
}

/// Fires when a shell-integration-aware command exits. `exitCode` is nil
/// when not reported; `duration` is the wall clock in nanoseconds.
@MainActor
public protocol TerminalSurfaceCommandFinishedDelegate: TerminalSurfaceViewDelegate {
    func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64)
}

/// OSC 9 (iTerm2) / OSC 777 (rxvt-unicode) desktop notification.
/// Empty title/body surface as empty strings rather than nil.
@MainActor
public protocol TerminalSurfaceDesktopNotificationDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String)
}

public enum TerminalOpenURLKind: Sendable {
    case unknown
    case text
    case html

    init(_ raw: ghostty_action_open_url_kind_e) {
        switch raw {
        case GHOSTTY_ACTION_OPEN_URL_KIND_TEXT: self = .text
        case GHOSTTY_ACTION_OPEN_URL_KIND_HTML: self = .html
        default: self = .unknown
        }
    }
}

/// User activated (cmd-clicked) a hyperlink inside the terminal grid.
@MainActor
public protocol TerminalSurfaceOpenURLDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind)
}

/// Mouse hovered over a recognized hyperlink. nil = hover ended / link lost.
@MainActor
public protocol TerminalSurfaceHoverLinkDelegate: TerminalSurfaceViewDelegate {
    func terminalDidUpdateHoverLink(_ url: String?)
}

/// Pointer shape the terminal wants while the mouse is over its grid.
///
/// Ghostty raises `GHOSTTY_ACTION_MOUSE_SHAPE` whenever the shape changes: it
/// asks for `.text` over ordinary cells, `.pointer` over a hyperlink, and
/// whatever a mouse-mode program requests. Dropping the action leaves the
/// pointer as the window's plain arrow everywhere inside the terminal.
///
/// The set mirrors the CSS cursor keywords Ghostty models. Several have no
/// public AppKit equivalent on the platforms Warren supports; a host maps those
/// to its closest available cursor rather than this layer guessing for it.
public enum TerminalMouseShape: Sendable {
    case `default`
    case contextMenu
    case help
    case pointer
    case progress
    case wait
    case cell
    case crosshair
    case text
    case verticalText
    case alias
    case copy
    case move
    case noDrop
    case notAllowed
    case grab
    case grabbing
    case allScroll
    case colResize
    case rowResize
    case nResize
    case eResize
    case sResize
    case wResize
    case neResize
    case nwResize
    case seResize
    case swResize
    case ewResize
    case nsResize
    case neswResize
    case nwseResize
    case zoomIn
    case zoomOut

    init?(_ raw: ghostty_action_mouse_shape_e) {
        switch raw {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: self = .default
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: self = .contextMenu
        case GHOSTTY_MOUSE_SHAPE_HELP: self = .help
        case GHOSTTY_MOUSE_SHAPE_POINTER: self = .pointer
        case GHOSTTY_MOUSE_SHAPE_PROGRESS: self = .progress
        case GHOSTTY_MOUSE_SHAPE_WAIT: self = .wait
        case GHOSTTY_MOUSE_SHAPE_CELL: self = .cell
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: self = .crosshair
        case GHOSTTY_MOUSE_SHAPE_TEXT: self = .text
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: self = .verticalText
        case GHOSTTY_MOUSE_SHAPE_ALIAS: self = .alias
        case GHOSTTY_MOUSE_SHAPE_COPY: self = .copy
        case GHOSTTY_MOUSE_SHAPE_MOVE: self = .move
        case GHOSTTY_MOUSE_SHAPE_NO_DROP: self = .noDrop
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: self = .notAllowed
        case GHOSTTY_MOUSE_SHAPE_GRAB: self = .grab
        case GHOSTTY_MOUSE_SHAPE_GRABBING: self = .grabbing
        case GHOSTTY_MOUSE_SHAPE_ALL_SCROLL: self = .allScroll
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE: self = .colResize
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: self = .rowResize
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE: self = .nResize
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE: self = .eResize
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE: self = .sResize
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE: self = .wResize
        case GHOSTTY_MOUSE_SHAPE_NE_RESIZE: self = .neResize
        case GHOSTTY_MOUSE_SHAPE_NW_RESIZE: self = .nwResize
        case GHOSTTY_MOUSE_SHAPE_SE_RESIZE: self = .seResize
        case GHOSTTY_MOUSE_SHAPE_SW_RESIZE: self = .swResize
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE: self = .ewResize
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE: self = .nsResize
        case GHOSTTY_MOUSE_SHAPE_NESW_RESIZE: self = .neswResize
        case GHOSTTY_MOUSE_SHAPE_NWSE_RESIZE: self = .nwseResize
        case GHOSTTY_MOUSE_SHAPE_ZOOM_IN: self = .zoomIn
        case GHOSTTY_MOUSE_SHAPE_ZOOM_OUT: self = .zoomOut
        default: return nil
        }
    }
}

/// Both the shape above and pointer visibility reach the platform view through
/// coordinator callbacks rather than a delegate protocol. They describe how the
/// view should draw the pointer, not state a host acts on, which is the same
/// reason `onCellSizeChange` is a callback: the delegate carries terminal state
/// outward, and `TerminalViewState` has no reference to the view that would
/// have to apply a cursor.

/// OSC 7 working-directory update.
@MainActor
public protocol TerminalSurfacePwdDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeWorkingDirectory(_ path: String)
}

/// The renderer flipped its own health state. Ghostty raises
/// `GHOSTTY_ACTION_RENDERER_HEALTH` with `.unhealthy` after repeated Metal/GPU
/// errors and then paints its "This terminal is non-functional" panel INTO the
/// surface. Upstream drops this action, so the host is never told the surface
/// died and nothing rebuilds it. Forward it so a consumer can reload the
/// surface (or surface a reload affordance) instead of leaving a dead panel.
/// `healthy == false` means unhealthy.
@MainActor
public protocol TerminalSurfaceRendererHealthDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeRendererHealth(_ healthy: Bool)
}

/// User long-pressed to request a selection-page presentation.
public struct TerminalTextSelectionRequest: Sendable {
    /// Viewport text snapshot. Lines separated by `\n`.
    public let text: String

    /// Recommended pre-selection range in UTF-16 units, suitable for direct
    /// assignment to `UITextView.selectedRange`. `nil` means the host should
    /// `selectAll` instead.
    public let anchorRange: NSRange?

    /// Long-press point in the terminal view's coordinate space (points).
    /// Hosts may use this as a popover anchor.
    public let sourcePoint: CGPoint
}

@MainActor
public protocol TerminalSurfaceTextSelectionRequestDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest)
}

/// Notifies a delegate when the underlying ``TerminalSurface`` is created or
/// torn down. Useful when a consumer needs surface-level APIs (e.g.
/// ``TerminalSurface/sendText(_:)``) reachable from outside the platform view.
@MainActor
public protocol TerminalSurfaceLifecycleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidAttachSurface(_ surface: TerminalSurface)
    func terminalDidDetachSurface()
}
