import AppKit
import Foundation
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WebKit

/// Whether a pointer press decides the browser viewer's keyboard focus.
///
/// The press is the decision: it is what hands AppKit's first responder to the
/// web content, or takes it away. `nil` means this event decides nothing, which
/// is every event but a press — a release outside the region routinely ends a
/// drag that started inside it.
enum WarrenBrowserViewerFocusBoundary {
    static func keyboardFocusChange(
        for eventType: NSEvent.EventType,
        hitViewer: Bool
    ) -> Bool? {
        guard eventType == .leftMouseDown else { return nil }
        return hitViewer
    }
}

/// Keyboard-focus owner for the browser viewer regions.
///
/// A click inside a `WKWebView`'s content hands AppKit's first responder to the
/// web process without anything Warren can observe, so the Terminal cannot tell
/// "the keyboard moved into the viewer" from "the user never left the Terminal".
/// Terminal reconciliation claims focus for the selected pane, which pulled the
/// keyboard straight back out of the viewer. This is the same pointer-boundary
/// signal the Embedded Editor already publishes (RFC 0022 §8.4), narrowed to the
/// viewer's own web views: a left press decides, and a press anywhere else
/// releases.
@MainActor
final class WarrenBrowserViewerFocusModel: ObservableObject {
    static let shared = WarrenBrowserViewerFocusModel()

    /// True while the last pointer press landed inside a browser viewer.
    @Published private(set) var hasKeyboardFocus = false

    private var webViews: [String: WKWebView] = [:]
    private var mouseEventMonitor: Any?

    init() {}

    func register(sessionID: String, webView: WKWebView) {
        webViews[sessionID] = webView
        installMouseEventMonitorIfNeeded()
    }

    func unregister(sessionID: String) {
        webViews.removeValue(forKey: sessionID)
        if webViews.isEmpty {
            release()
        }
    }

    /// Drops every registration and the focus they imply.
    func release() {
        webViews.removeAll()
        releaseKeyboardFocus()
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
            self.mouseEventMonitor = nil
        }
    }

    /// Reports that the viewer no longer holds the keyboard.
    ///
    /// A region that closes while focused has to say so: the terminal keeps its
    /// `wantsTerminalFocus` from this flag, so leaving it set would make the
    /// Terminal refuse the keyboard until the next click.
    func releaseKeyboardFocus() {
        setKeyboardFocus(false)
    }

    /// Seeds the focus flag so a test can assert it is released on teardown.
    /// The real signal comes from the pointer boundary, which needs a window and
    /// a live click.
    func setKeyboardFocusForTesting(_ focused: Bool) {
        setKeyboardFocus(focused)
    }

    private func installMouseEventMonitorIfNeeded() {
        guard mouseEventMonitor == nil else { return }
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleMouseBoundary(event)
            return event
        }
    }

    private func handleMouseBoundary(_ event: NSEvent) {
        let interactiveWebViews = webViews.values.filter {
            $0.window != nil && !$0.isHidden
        }
        guard !interactiveWebViews.isEmpty else {
            // With no viewer on screen the flag has no owner. Clearing it here is
            // the backstop for a region that went away without a click.
            setKeyboardFocus(false)
            return
        }
        if let focused = WarrenBrowserViewerFocusBoundary.keyboardFocusChange(
            for: event.type,
            hitViewer: viewer(at: event, in: interactiveWebViews) != nil
        ) {
            setKeyboardFocus(focused)
        }
    }

    private func viewer(
        at event: NSEvent,
        in candidates: some Collection<WKWebView>
    ) -> WKWebView? {
        guard let contentView = event.window?.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(point) else { return nil }
        return candidates.first { webView in
            hitView === webView || hitView.isDescendant(of: webView)
        }
    }

    private func setKeyboardFocus(_ focused: Bool) {
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
    }
}

/// Hosts the Warren Browser viewer page for one browser Session (RFC 0022 §8.2).
///
/// The page owns the canvas, the stream WebSocket, and the input forwarding;
/// Warren owns nothing but this web view. That is the same division of labor the
/// Embedded Editor already has, and it is why the viewer is served by the Host
/// rather than shipped in a client bundle.
///
/// One web view per Session, cached and reused. `makeNSView` runs once per view
/// identity, and the browser region has one identity for every browser Session:
/// it sits at the same place in the same `WarrenDesktopCentralSplit`. Returning
/// the web view directly would therefore pin the region to whichever Session
/// happened to create the host first.
@MainActor
final class WarrenBrowserViewerCache {
    static let shared = WarrenBrowserViewerCache()

    private var webViews: [String: WKWebView] = [:]
    /// Insertion order, so eviction is oldest-first and deterministic.
    private var order: [String] = []
    private let bound: Int

    init(bound: Int = 4) {
        self.bound = max(1, bound)
    }

    func webView(for sessionID: String, make: (String) -> WKWebView) -> WKWebView {
        if let existing = webViews[sessionID] {
            return existing
        }
        let webView = make(sessionID)
        webViews[sessionID] = webView
        order.append(sessionID)
        WarrenBrowserViewerFocusModel.shared.register(sessionID: sessionID, webView: webView)
        evictIfNeeded()
        return webView
    }

    func remove(sessionID: String) {
        guard webViews.removeValue(forKey: sessionID) != nil else { return }
        order.removeAll { $0 == sessionID }
        WarrenBrowserViewerFocusModel.shared.unregister(sessionID: sessionID)
    }

    func reset() {
        for webView in webViews.values {
            webView.stopLoading()
            webView.loadHTMLString("", baseURL: nil)
        }
        webViews.removeAll()
        order.removeAll()
        WarrenBrowserViewerFocusModel.shared.release()
    }

    private func evictIfNeeded() {
        while order.count > bound {
            let oldest = order.removeFirst()
            if let webView = webViews.removeValue(forKey: oldest) {
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil)
            }
            WarrenBrowserViewerFocusModel.shared.unregister(sessionID: oldest)
        }
    }
}

struct WarrenBrowserViewerHost: NSViewRepresentable {
    let sessionID: String
    let url: URL

    @MainActor
    final class ViewerNavigationDelegate: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The viewer is a single document. A link the user clicks inside the
            // page is a navigation the agent should perform, not something this
            // web view should follow out from under it.
            guard navigationAction.targetFrame == nil else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }

    private var webView: WKWebView {
        WarrenBrowserViewerCache.shared.webView(for: cacheKey) { _ in
            let configuration = WKWebViewConfiguration()
            // A per-Session data store, so one browser Session's cookies and
            // localStorage never reach another Session, the Embedded Editor, or
            // the user's system Chrome. RFC 0022 §5.4.
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = ViewerNavigationDelegate()
            webView.allowsMagnification = false
            webView.allowsBackForwardNavigationGestures = false
            webView.setValue(false, forKey: "drawsBackground")
            webView.load(URLRequest(url: url))
            return webView
        }
    }

    /// The cache is keyed on the viewer origin as well as the Session: the same
    /// Session on two Endpoints is two different browsers.
    private var cacheKey: String {
        "\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")/\(sessionID)"
    }

    func makeNSView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.mount(webView)
        return container
    }

    func updateNSView(_ container: ContainerView, context: Context) {
        container.mount(webView)
    }

    static func dismantleNSView(_ container: ContainerView, coordinator: Void) {
        // The region is coming off screen. Its web view stays cached for reuse,
        // but the keyboard belongs to whatever the user looks at next: leaving
        // the viewer's focus flag set would make the Terminal refuse the
        // keyboard until the next click.
        WarrenBrowserViewerFocusModel.shared.releaseKeyboardFocus()
    }

    final class ContainerView: NSView {
        private weak var mounted: WKWebView?

        func mount(_ webView: WKWebView) {
            guard mounted !== webView else { return }
            if let mounted, mounted.superview === self {
                mounted.removeFromSuperview()
            }
            mounted = webView
            webView.frame = bounds
            webView.autoresizingMask = [.width, .height]
            addSubview(webView)
        }
    }
}

/// The viewer page for one browser Session, or the reason there is none.
///
/// The URL is resolved by the application model rather than assembled here,
/// because only the model knows which Endpoint owns the browser and what its
/// credential is.
struct WarrenBrowserSurface: View {
    let sessionID: String
    let model: WarrenRemoteApplicationModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if let url = model.browserViewerURL(sessionID: sessionID) {
            WarrenBrowserViewerHost(sessionID: sessionID, url: url)
        } else {
            VStack(spacing: WarrenSpacing.standard) {
                Image(systemName: "network.slash")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(tokens.mutedForeground)
                Text("Host not connected")
                    .font(WarrenTypography.emptyStateTitle)
                Text("The browser runs on the Host that owns it. Reconnect to watch it.")
                    .font(WarrenTypography.body)
                    .foregroundStyle(tokens.mutedForeground)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tokens.background)
        }
    }
}
