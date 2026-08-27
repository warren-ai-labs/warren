//
//  TerminalController+Callbacks.swift
//  WarrenGhosttyEmbedding
//

import Foundation
import GhosttyKit

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private enum TerminalCallbacks {
    static func wakeup(userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let controller = Unmanaged<TerminalController>.fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            controller.handleWakeup()
        }
    }

    static func action(
        appPtr: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        guard let appPtr else { return false }
        guard ghostty_app_userdata(appPtr) != nil else { return false }
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
        guard let surfacePtr = target.target.surface else { return false }
        guard let bridgePtr = ghostty_surface_userdata(surfacePtr) else { return false }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(bridgePtr)
            .takeUnretainedValue()

        // Open-url must be answered synchronously: Ghostty only skips its
        // `/usr/bin/open` fallback when the action callback returns true. The
        // embedder owns validation; a nil handler means "not handled" so the
        // fallback keeps the old behavior for apps without a handler.
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            guard let handler = bridge.openURLHandler else { return false }
            let payload = action.action.open_url
            let kind = TerminalOpenURLKind(payload.kind)
            let url: String = payload.url.map { ptr in
                let buf = UnsafeBufferPointer(start: ptr, count: Int(payload.len))
                return String(decoding: buf.map(UInt8.init), as: UTF8.self)
            } ?? ""
            handler(url, kind)
            return true
        }

        terminalRunOnMain {
            bridge.handleAction(action)
        }

        return false
    }

    static func closeSurface(
        userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let userdata else { return }
        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        terminalRunOnMain {
            bridge.handleClose(processAlive: processAlive)
        }
    }

    static func writeClipboard(
        userdata _: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        contents: UnsafePointer<ghostty_clipboard_content_s>?,
        contentsLen: Int,
        confirm _: Bool
    ) {
        guard contentsLen > 0 else { return }
        guard let content = contents?.pointee else { return }
        guard let data = content.data else { return }
        let string = String(cString: data)

        #if canImport(UIKit)
            UIPasteboard.general.string = string
        #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        #endif
    }

    static func readClipboard(
        userdata: UnsafeMutableRawPointer?,
        clipboard _: ghostty_clipboard_e,
        opaquePtr: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLength: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let userdata, let opaquePtr else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        #if canImport(UIKit)
            let string = UIPasteboard.general.string
        #elseif canImport(AppKit)
            let string = NSPasteboard.general.string(forType: .string)
        #endif

        var acceptsText = false
        if let mimes {
            for index in 0..<mimesLength {
                guard let mime = mimes[index] else { continue }
                if String(cString: mime).hasPrefix("text/plain") {
                    acceptsText = true
                    break
                }
            }
        }
        guard list || acceptsText else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        guard string != nil || list else {
            TerminalDebugLog.log(.input, "clipboard paste read empty")
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        if let string {
            TerminalDebugLog.log(
                .input,
                "clipboard paste read bytes=\(string.utf8.count) lines=\(TerminalInputText.lineCount(in: string))"
            )
        }
        completeClipboardRequest(
            surface: surface,
            string: acceptsText ? string : nil,
            opaquePtr: opaquePtr,
            includeAvailableTypes: list
        )
        TerminalDebugLog.log(.input, "clipboard paste complete")
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    static func confirmReadClipboard(
        userdata: UnsafeMutableRawPointer?,
        confirmation: UnsafePointer<ghostty_clipboard_confirm_s>?,
        opaquePtr: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let userdata, let confirmation, let opaquePtr else { return }

        let bridge = Unmanaged<TerminalCallbackBridge>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        guard let surface = bridge.rawSurface else { return }

        let value = confirmation.pointee
        let byteCount = value.contents?.pointee.len ?? 0
        TerminalDebugLog.log(
            .input,
            "clipboard paste confirm request=\(request.rawValue) bytes=\(byteCount)"
        )
        var complete = ghostty_clipboard_complete_s(
            contents: value.contents,
            contents_len: value.contents_len,
            available: value.available,
            available_len: value.available_len,
            confirmed: true,
            remember: false
        )
        ghostty_surface_complete_clipboard_request(surface, &complete, opaquePtr)
        TerminalDebugLog.log(.input, "clipboard paste confirmed")
    }

    private static func completeClipboardRequest(
        surface: ghostty_surface_t,
        string: String?,
        opaquePtr: UnsafeMutableRawPointer,
        includeAvailableTypes: Bool
    ) {
        "text/plain".withCString { mime in
            var available: UnsafePointer<CChar>? = mime
            withUnsafePointer(to: &available) { availablePointer in
                guard let string else {
                    var complete = ghostty_clipboard_complete_s(
                        contents: nil,
                        contents_len: 0,
                        available: includeAvailableTypes ? availablePointer : nil,
                        available_len: includeAvailableTypes ? 1 : 0,
                        confirmed: false,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, opaquePtr)
                    return
                }
                string.withCString { data in
                    var content = ghostty_clipboard_content_s(
                        mime: mime,
                        data: data,
                        len: string.utf8.count
                    )
                    withUnsafePointer(to: &content) { contentPointer in
                        var complete = ghostty_clipboard_complete_s(
                            contents: contentPointer,
                            contents_len: 1,
                            available: includeAvailableTypes ? availablePointer : nil,
                            available_len: includeAvailableTypes ? 1 : 0,
                            confirmed: false,
                            remember: false
                        )
                        ghostty_surface_complete_clipboard_request(surface, &complete, opaquePtr)
                    }
                }
            }
        }
    }
}

func terminalControllerWakeupCallback(userdata: UnsafeMutableRawPointer?) {
    TerminalCallbacks.wakeup(userdata: userdata)
}

func terminalControllerActionCallback(
    appPtr: ghostty_app_t?,
    target: ghostty_target_s,
    action: ghostty_action_s
) -> Bool {
    TerminalCallbacks.action(appPtr: appPtr, target: target, action: action)
}

func terminalControllerCloseSurfaceCallback(
    userdata: UnsafeMutableRawPointer?,
    processAlive: Bool
) {
    TerminalCallbacks.closeSurface(userdata: userdata, processAlive: processAlive)
}

func terminalControllerWriteClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    contents: UnsafePointer<ghostty_clipboard_content_s>?,
    contentsLen: Int,
    confirm: Bool
) {
    TerminalCallbacks.writeClipboard(
        userdata: userdata,
        clipboard: clipboard,
        contents: contents,
        contentsLen: contentsLen,
        confirm: confirm
    )
}

func terminalControllerReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    clipboard: ghostty_clipboard_e,
    opaquePtr: UnsafeMutableRawPointer?,
    mimes: UnsafePointer<UnsafePointer<CChar>?>?,
    mimesLength: Int,
    list: Bool
) -> ghostty_clipboard_read_result_e {
    TerminalCallbacks.readClipboard(
        userdata: userdata,
        clipboard: clipboard,
        opaquePtr: opaquePtr,
        mimes: mimes,
        mimesLength: mimesLength,
        list: list
    )
}

func terminalControllerConfirmReadClipboardCallback(
    userdata: UnsafeMutableRawPointer?,
    confirmation: UnsafePointer<ghostty_clipboard_confirm_s>?,
    opaquePtr: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
) {
    TerminalCallbacks.confirmReadClipboard(
        userdata: userdata,
        confirmation: confirmation,
        opaquePtr: opaquePtr,
        request: request
    )
}
