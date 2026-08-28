import AppKit
import SwiftUI
import WebKit

/// Hosts the Web client's real FileDiffView so Desktop and Web share the same
/// Shiki grammar, Pierre theme, diff indicators, and virtualized renderer.
struct WarrenDesktopGitDiffWebView: NSViewRepresentable {
    @ObservedObject var model: WarrenDesktopGitPanelModel
    let baseURL: URL

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    @MainActor
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(context.coordinator, name: Coordinator.messageHandlerName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = false
        webView.underPageBackgroundColor = NSColor(
            red: 21 / 255,
            green: 17 / 255,
            blue: 16 / 255,
            alpha: 1
        )
        webView.load(URLRequest(url: Self.desktopDiffURL(from: baseURL)))
        return webView
    }

    @MainActor
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
        context.coordinator.send(model: model, to: webView)
    }

    @MainActor
    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName
        )
    }

    private static func desktopDiffURL(from baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "desktop-diff" }
        queryItems.append(URLQueryItem(name: "desktop-diff", value: "1"))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let messageHandlerName = "warrenDesktopDiff"

        var model: WarrenDesktopGitPanelModel
        private var isReady = false

        init(model: WarrenDesktopGitPanelModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            send(model: model, to: webView)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "close":
                model.closeFileView()
            case "viewTab":
                guard let value = body["value"] as? String else { return }
                model.diffViewTab = value == "file" ? .file : .diff
            case "diffStyle":
                guard let value = body["value"] as? String else { return }
                model.diffStyle = value == "split" ? .split : .unified
            default:
                break
            }
        }

        func send(model: WarrenDesktopGitPanelModel, to webView: WKWebView) {
            guard isReady else { return }
            let payload = WarrenDesktopGitDiffWebPayload(model: model)
            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let script = "window.__WARREN_DESKTOP_DIFF__ = \(json); window.dispatchEvent(new CustomEvent('warren-desktop-diff', { detail: window.__WARREN_DESKTOP_DIFF__ }));"
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }
}

private struct WarrenDesktopGitDiffWebPayload: Encodable {
    let path: String
    let staged: Bool
    let commit: String
    let loading: Bool
    let diff: String
    let content: String
    let error: String
    let notice: String
    let viewTab: String
    let diffStyle: String

    @MainActor
    init(model: WarrenDesktopGitPanelModel) {
        path = model.fileView?.path ?? ""
        staged = model.fileView?.staged ?? false
        commit = model.fileView?.commit ?? ""
        loading = model.fileDiff.loading
        diff = model.fileDiff.diff
        content = model.fileDiff.content
        error = model.fileDiff.errorMessage ?? ""
        notice = ""
        viewTab = model.diffViewTab.rawValue
        diffStyle = model.diffStyle.rawValue
    }
}
