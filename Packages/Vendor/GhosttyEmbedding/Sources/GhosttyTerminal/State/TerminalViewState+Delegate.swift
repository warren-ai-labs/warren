//
//  TerminalViewState+Delegate.swift
//  WarrenGhosttyEmbedding
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

extension TerminalViewState:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceFocusDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceCommandFinishedDelegate,
    TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate
{
    public func terminalDidChangeTitle(_ title: String) {
        // Ghostty callbacks run synchronously on the main thread, including
        // during NSViewRepresentable updates when a surface is (re)created.
        // Any @Published write here would publish from inside a SwiftUI view
        // update; defer like the resize/focus writes.
        Task { @MainActor [weak self] in
            guard let self, self.title != title else { return }
            self.title = title
        }
    }

    public func terminalDidResize(_ size: TerminalGridMetrics) {
        // Ghostty can report grid metrics synchronously from AppKit layout and
        // NSViewRepresentable updates (fitToSize -> synchronizeMetrics).
        // Writing the @Published property here publishes from inside a SwiftUI
        // view update, which SwiftUI rejects with a runtime fault and can
        // re-enter layout forever. Defer one main-actor hop so SwiftUI
        // observes the value outside the current transaction; the value is
        // unchanged.
        Task { @MainActor [weak self] in
            guard let self, self.surfaceSize != size else { return }
            self.surfaceSize = size
        }
    }

    public func terminalDidChangeFocus(_ focused: Bool) {
        // makeFirstResponder/synchronizeFocus can run inside a SwiftUI update
        // and publish isFocused mid-transaction. Same deferral as resize.
        Task { @MainActor [weak self] in
            guard let self, self.isFocused != focused else { return }
            self.isFocused = focused
        }
    }

    public func terminalDidClose(processAlive: Bool) {
        onClose?(processAlive)
    }

    public func terminalDidRingBell() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bellCount += 1
            self.lastBellAt = Date()
        }
    }

    public func terminalDidRequestDesktopNotification(title: String, body: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastDesktopNotificationTitle = title
            self.lastDesktopNotificationBody = body
            self.lastDesktopNotificationAt = Date()
        }
    }

    public func terminalDidChangeWorkingDirectory(_ path: String) {
        Task { @MainActor [weak self] in
            guard let self, self.workingDirectory != path else { return }
            self.workingDirectory = path
        }
    }

    public func terminalDidFinishCommand(exitCode: Int?, durationNanos: UInt64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.lastCommandExitCode = exitCode
            self.lastCommandDurationNanos = durationNanos
        }
    }

    public func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        openURLHandler?(url, kind)
    }

    public func terminalDidAttachSurface(_ surface: TerminalSurface) {
        self.surface = surface
    }

    public func terminalDidDetachSurface() {
        surface = nil
    }
}
