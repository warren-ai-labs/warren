import XCTest
import WebKit
@testable import Warren

final class WarrenEmbeddedEditorTests: XCTestCase {
    func testExecutableCandidatesPreferExplicitOverrideAndDeduplicatePaths() {
        let candidates = WarrenEmbeddedEditorExecutableResolver.candidates(environment: [
            "WARREN_CODE_SERVER_PATH": "/custom/code-server",
            "PATH": "/custom:/opt/tools",
            "HOME": "/Users/developer",
        ])

        XCTAssertEqual(candidates.first?.path, "/custom/code-server")
        XCTAssertEqual(candidates.filter { $0.path == "/custom/code-server" }.count, 1)
        XCTAssertTrue(candidates.contains { $0.path == "/opt/tools/code-server" })
        XCTAssertTrue(candidates.contains {
            $0.path == "/Users/developer/.local/bin/code-server"
        })
    }

    func testServerConfigurationStaysOnLoopbackAndUsesManagedProfile() {
        let configuration = WarrenEmbeddedEditorConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/code-server"),
            userDataDirectory: URL(fileURLWithPath: "/data/user"),
            extensionsDirectory: URL(fileURLWithPath: "/data/extensions"),
            port: 54_321
        )

        XCTAssertEqual(configuration.serverURL.absoluteString, "http://127.0.0.1:54321/")
        XCTAssertEqual(configuration.serverArguments.suffix(2), [
            "--idle-timeout-seconds",
            "900",
        ])
        XCTAssertTrue(configuration.serverArguments.contains("127.0.0.1:54321"))
        XCTAssertTrue(configuration.serverArguments.contains("none"))
        XCTAssertTrue(configuration.serverArguments.contains("--disable-workspace-trust"))
        XCTAssertFalse(configuration.serverArguments.contains("--install-extension"))
        XCTAssertFalse(configuration.serverArguments.contains("/work/warren feature"))
        XCTAssertEqual(
            URLComponents(
                url: configuration.workspaceURL(path: "/work/warren feature"),
                resolvingAgainstBaseURL: false
            )?.queryItems,
            [URLQueryItem(name: "folder", value: "/work/warren feature")]
        )
        XCTAssertEqual(WarrenEmbeddedEditorConfiguration.managedExtensionIDs, [
            "golang.go",
            "rust-lang.rust-analyzer",
        ])
    }

    func testServerConfigurationUsesAnIsolatedSessionSocket() {
        let sessionSocket = URL(fileURLWithPath: "/data/sessions/editor.sock")
        let configuration = WarrenEmbeddedEditorConfiguration(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/code-server"),
            userDataDirectory: URL(fileURLWithPath: "/data/user"),
            extensionsDirectory: URL(fileURLWithPath: "/data/extensions"),
            port: 54_321,
            sessionSocket: sessionSocket
        )

        let arguments = configuration.serverArguments
        guard let index = arguments.firstIndex(of: "--session-socket") else {
            return XCTFail("Expected an isolated session socket argument")
        }
        XCTAssertEqual(arguments[index + 1], sessionSocket.path)
        XCTAssertEqual(
            arguments[arguments.firstIndex(of: "--idle-timeout-seconds")! + 1],
            String(WarrenEmbeddedEditorConfiguration.idleTimeoutSeconds)
        )
    }

    func testManagedProfileMovesFileTreeRightAndPreservesUnownedSettings() {
        let settings = WarrenEmbeddedEditorProfile.mergingManagedSettings(into: [
            "editor.fontFamily": "Berkeley Mono",
            "workbench.sideBar.location": "left",
        ])

        XCTAssertEqual(settings["editor.fontFamily"] as? String, "Berkeley Mono")
        XCTAssertEqual(settings["workbench.sideBar.location"] as? String, "right")
        XCTAssertEqual(settings["workbench.activityBar.location"] as? String, "top")
        XCTAssertEqual(settings["workbench.colorTheme"] as? String, "Default Dark Modern")
        XCTAssertEqual(settings["workbench.iconTheme"] as? String, "vs-seti")
        XCTAssertEqual(settings["window.customTitleBarVisibility"] as? String, "never")
        XCTAssertEqual(settings["window.density.editorTabHeight"] as? String, "compact")
        XCTAssertEqual(settings["editor.minimap.enabled"] as? Bool, false)
        XCTAssertEqual(settings["chat.disableAIFeatures"] as? Bool, true)
        XCTAssertEqual(settings["extensions.autoCheckUpdates"] as? Bool, false)
        XCTAssertEqual(settings["extensions.autoUpdate"] as? Bool, false)
        XCTAssertEqual(settings["extensions.ignoreRecommendations"] as? Bool, true)
        XCTAssertEqual(
            settings["extensions.showRecommendationsOnlyOnDemand"] as? Bool,
            true
        )
        XCTAssertEqual(settings["git.autoRepositoryDetection"] as? String, "openEditors")
        XCTAssertEqual(settings["git.detectWorktrees"] as? Bool, false)
        XCTAssertEqual(settings["git.openDiffOnClick"] as? Bool, false)
        XCTAssertEqual(settings["git.showInlineOpenFileAction"] as? Bool, true)
        XCTAssertEqual(settings["git.showCommitInput"] as? Bool, true)
        XCTAssertEqual(settings["git.untrackedChanges"] as? String, "mixed")
        XCTAssertEqual(settings["scm.graph.pageOnScroll"] as? Bool, false)
        XCTAssertEqual(settings["scm.graph.pageSize"] as? Int, 20)
        XCTAssertEqual(settings["go.showWelcome"] as? Bool, false)
        XCTAssertEqual(settings["go.survey.prompt"] as? Bool, false)
        XCTAssertEqual(settings["go.toolsManagement.checkForUpdates"] as? String, "off")
        XCTAssertEqual(settings["update.showReleaseNotes"] as? Bool, false)
        let colors = settings["workbench.colorCustomizations"] as? [String: String]
        XCTAssertEqual(colors?["editor.background"], "#151110")
        XCTAssertEqual(colors?["sideBar.background"], "#1c1918")
        XCTAssertEqual(colors?["editorCursor.foreground"], "#e07850")
    }

    func testExtensionRegistryReadsInstalledIDsWithoutStartingCodeServer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goExtension = root.appendingPathComponent("golang.go-0.56.0", isDirectory: true)
        let incompleteExtension = root.appendingPathComponent("incomplete", isDirectory: true)
        try FileManager.default.createDirectory(
            at: goExtension,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: incompleteExtension,
            withIntermediateDirectories: true
        )
        try Data(#"{"publisher":"GoLang","name":"Go"}"#.utf8).write(
            to: goExtension.appendingPathComponent("package.json")
        )
        try Data(#"{"name":"missing-publisher"}"#.utf8).write(
            to: incompleteExtension.appendingPathComponent("package.json")
        )

        XCTAssertEqual(
            WarrenEmbeddedEditorExtensionRegistry.installedExtensionIDs(in: root),
            ["golang.go"]
        )
    }

    @MainActor
    func testMissingExecutableProducesRecoverableUnavailableState() async {
        let model = WarrenEmbeddedEditorModel(
            environment: [:],
            supportDirectory: FileManager.default.temporaryDirectory,
            executableResolver: { _ in nil }
        )

        model.activate(workspacePath: "/work/warren")
        await Task.yield()

        XCTAssertEqual(model.activeWorkspacePath, "/work/warren")
        XCTAssertEqual(model.phase, .unavailable)
        model.stop()
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor
    func testPrewarmStaysIdleWithoutExecutableAndDefersToActivation() async {
        let model = WarrenEmbeddedEditorModel(
            environment: [:],
            supportDirectory: FileManager.default.temporaryDirectory,
            executableResolver: { _ in nil }
        )

        // Prewarming is opportunistic: without a code-server binary it must
        // not flip the UI into an editor failure state before the pane is
        // even opened.
        model.prewarm()
        await Task.yield()
        XCTAssertEqual(model.phase, .idle)

        model.activate(workspacePath: "/work/warren")
        await Task.yield()
        XCTAssertEqual(model.phase, .unavailable)
        model.stop()
        XCTAssertEqual(model.phase, .idle)
    }

    @MainActor
    func testStandardEditMenuRoutesPasteThroughTheResponderChain() {
        let menu = WarrenStandardEditMenu.make()
        let paste = menu.items.first { $0.title == "Paste" }

        XCTAssertEqual(paste?.action, #selector(NSText.paste(_:)))
        XCTAssertEqual(paste?.keyEquivalent, "v")
        XCTAssertEqual(paste?.keyEquivalentModifierMask, .command)
        XCTAssertNil(paste?.target)
    }

    @MainActor
    func testEditorFocusRecognizesWebViewDescendantsOnly() {
        let editor = WKWebView()
        let editorContent = NSView()
        editor.addSubview(editorContent)

        XCTAssertTrue(WarrenEmbeddedEditorFocus.contains(editor))
        XCTAssertTrue(WarrenEmbeddedEditorFocus.contains(editorContent))
        XCTAssertFalse(WarrenEmbeddedEditorFocus.contains(NSView()))
        XCTAssertFalse(WarrenEmbeddedEditorFocus.contains(nil))
    }

    @MainActor
    func testEditorPageVisibilityCanStayConcealedUntilFirstPaint() {
        let webView = WKWebView()

        WarrenEmbeddedEditorPageVisibility.conceal(webView)
        XCTAssertTrue(webView.isHidden)

        WarrenEmbeddedEditorPageVisibility.reveal(webView)
        XCTAssertFalse(webView.isHidden)
    }

    func testEmbeddedNavigationPolicyNeverOpensCustomSchemes() {
        XCTAssertEqual(
            WarrenEmbeddedEditorNavigationPolicy.decision(
                for: URL(string: "http://127.0.0.1:3000/vscode-webview")!
            ),
            .allow
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorNavigationPolicy.decision(
                for: URL(string: "https://127.0.0.1:3000/vscode-webview")!
            ),
            .allow
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorNavigationPolicy.decision(
                for: URL(string: "https://example.com")!
            ),
            .openExternally
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorNavigationPolicy.decision(
                for: URL(string: "vscode-webview://preview/index.html")!
            ),
            .cancel
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorNavigationPolicy.decision(
                for: URL(string: "vscode-resource://preview/file.md")!
            ),
            .cancel
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorNavigationPolicy.decision(
                for: URL(string: "mailto:someone@example.com")!
            ),
            .cancel
        )
    }

    @MainActor
    func testPointerBridgeInstallsBeforeTheEditorDocumentLoads() {
        let configuration = WKWebViewConfiguration()

        WarrenEmbeddedEditorPointerBridge.install(in: configuration)

        let scripts = configuration.userContentController.userScripts
        let script = scripts.first
        let injectionTime = script?.injectionTime
        let isForMainFrameOnly = script?.isForMainFrameOnly
        let source = script?.source ?? ""
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(injectionTime, .atDocumentStart)
        XCTAssertEqual(isForMainFrameOnly, true)
        XCTAssertTrue(source.contains("pointercancel"))
        XCTAssertTrue(source.contains("pointerup"))
        XCTAssertTrue(source.contains("mouseup"))
        XCTAssertTrue(source.contains("lostpointercapture"))
        XCTAssertTrue(source.contains("blur"))
        XCTAssertTrue(source.contains("event.buttons !== 0"))
        XCTAssertTrue(source.contains("stopImmediatePropagation"))
        XCTAssertTrue(source.contains("sourceEvent?.type !== \"pointerup\""))
        XCTAssertTrue(source.contains("collapseToOrigin"))
        XCTAssertTrue(source.contains("lastActiveAt"))
        XCTAssertTrue(source.contains("pointermove"))
        XCTAssertTrue(source.contains("mousemove"))
    }

    func testPointerBoundaryAlwaysReleasesAfterNativeMouseUp() {
        XCTAssertEqual(
            WarrenEmbeddedEditorPointerBoundary.action(for: .leftMouseDown),
            .cancelInactiveEditors
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorPointerBoundary.action(for: .leftMouseUp),
            .cancelAllAfterDispatch
        )
        XCTAssertEqual(
            WarrenEmbeddedEditorPointerBoundary.action(for: .mouseMoved),
            .none
        )
    }

    @MainActor
    func testNativeSelectionBridgeOnlyBlocksTheMonacoTextSurface() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorNativeSelectionBridge.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <style>
            .view-line { user-select: text; -webkit-user-select: text; }
        </style>
        <div class="monaco-editor">
            <div class="lines-content">
                <div class="view-lines">
                    <div class="view-line"><span id="editor-text">Editor</span></div>
                </div>
            </div>
        </div>
        <div id="outside">Outside</div>
        """#, in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const event = () => new Event("selectstart", {
                bubbles: true,
                cancelable: true,
                composed: true
            });
            return JSON.stringify({
                editorAllowed: document.getElementById("editor-text")
                    .dispatchEvent(event()),
                outsideAllowed: document.getElementById("outside")
                    .dispatchEvent(event()),
                caretHitTestingAvailable:
                    document.caretRangeFromPoint(12, 12) !== null
            });
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let behavior = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Bool]
        )

        XCTAssertEqual(behavior["editorAllowed"], false)
        XCTAssertEqual(behavior["outsideAllowed"], true)
        XCTAssertEqual(behavior["caretHitTestingAvailable"], true)
    }

    @MainActor
    func testPointerBridgeRecoversAStaleWebKitSelectionMove() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorPointerBridge.install(in: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <button id='target'>Target</button>
        <button id='fresh-target'>Fresh</button>
        """#, in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const target = document.getElementById("target");
            const result = {
                pointerUps: 0,
                mouseUps: 0,
                staleMoves: 0,
                staleUpClientX: null,
                staleUpClientY: null,
                freshUpClientX: null,
                freshUpClientY: null,
                mouseOnlyPointerUps: 0,
                mouseOnlyMouseUps: 0,
                mouseDownOnlyMouseUps: 0,
                pointerOnlyMouseUps: 0,
                pointerOnlySelectionMoves: 0,
                normalMoves: 0
            };
            target.addEventListener("pointerup", () => result.pointerUps++);
            target.addEventListener("mouseup", (event) => {
                result.mouseUps++;
                result.staleUpClientX = event.clientX;
                result.staleUpClientY = event.clientY;
            });
            target.addEventListener("mousemove", () => result.staleMoves++);
            target.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                button: 0,
                buttons: 1,
                pointerId: 7,
                pointerType: "mouse",
                isPrimary: true
            }));
            // Simulate a tap whose press went idle long before the drift;
            // the collapsed mouseup must land on the original position.
            window.__warrenPointerState.lastActiveAt = performance.now() - 5000;
            target.dispatchEvent(new MouseEvent("mousemove", {
                bubbles: true,
                button: 0,
                buttons: 0,
                clientX: 20,
                clientY: 30
            }));

            const freshTarget = document.getElementById("fresh-target");
            freshTarget.addEventListener("mouseup", (event) => {
                result.freshUpClientX = event.clientX;
                result.freshUpClientY = event.clientY;
            });
            freshTarget.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                button: 0,
                buttons: 1,
                pointerId: 11,
                pointerType: "mouse",
                isPrimary: true
            }));
            // A press that kept moving until the buttonless move counts as a
            // dropped release; the synthetic mouseup keeps the drag endpoint.
            freshTarget.dispatchEvent(new MouseEvent("mousemove", {
                bubbles: true,
                button: 0,
                buttons: 1,
                clientX: 5,
                clientY: 6
            }));
            freshTarget.dispatchEvent(new MouseEvent("mousemove", {
                bubbles: true,
                button: 0,
                buttons: 0,
                clientX: 70,
                clientY: 80
            }));

            const mouseOnlyTarget = document.createElement("button");
            document.body.appendChild(mouseOnlyTarget);
            mouseOnlyTarget.addEventListener(
                "pointerup",
                () => result.mouseOnlyPointerUps++
            );
            mouseOnlyTarget.addEventListener(
                "mouseup",
                () => result.mouseOnlyMouseUps++
            );
            mouseOnlyTarget.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                button: 0,
                buttons: 1,
                pointerId: 8,
                pointerType: "mouse",
                isPrimary: true
            }));
            mouseOnlyTarget.dispatchEvent(new MouseEvent("mouseup", {
                bubbles: true,
                button: 0,
                buttons: 0
            }));

            const mouseDownOnlyTarget = document.createElement("button");
            document.body.appendChild(mouseDownOnlyTarget);
            mouseDownOnlyTarget.addEventListener(
                "mouseup",
                () => result.mouseDownOnlyMouseUps++
            );
            mouseDownOnlyTarget.dispatchEvent(new MouseEvent("mousedown", {
                bubbles: true,
                button: 0,
                buttons: 1
            }));
            window.__warrenCancelPointerInteraction();

            const pointerOnlyTarget = document.createElement("button");
            document.body.appendChild(pointerOnlyTarget);
            let pointerOnlyDragging = false;
            pointerOnlyTarget.addEventListener("mousedown", () => {
                pointerOnlyDragging = true;
            });
            pointerOnlyTarget.addEventListener("mouseup", () => {
                pointerOnlyDragging = false;
                result.pointerOnlyMouseUps++;
            });
            pointerOnlyTarget.addEventListener("mousemove", () => {
                if (pointerOnlyDragging) {
                    result.pointerOnlySelectionMoves++;
                }
            });
            pointerOnlyTarget.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                button: 0,
                buttons: 1,
                pointerId: 10,
                pointerType: "mouse",
                isPrimary: true
            }));
            pointerOnlyTarget.dispatchEvent(new MouseEvent("mousedown", {
                bubbles: true,
                button: 0,
                buttons: 1
            }));
            pointerOnlyTarget.dispatchEvent(new PointerEvent("pointerup", {
                bubbles: true,
                button: 0,
                buttons: 0,
                pointerId: 10,
                pointerType: "mouse",
                isPrimary: true
            }));
            pointerOnlyTarget.dispatchEvent(new MouseEvent("mousemove", {
                bubbles: true,
                button: 0,
                buttons: 0
            }));

            const normalTarget = document.createElement("button");
            document.body.appendChild(normalTarget);
            normalTarget.addEventListener("mousemove", () => result.normalMoves++);
            normalTarget.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                button: 0,
                buttons: 1,
                pointerId: 9,
                pointerType: "mouse",
                isPrimary: true
            }));
            normalTarget.dispatchEvent(new MouseEvent("mousemove", {
                bubbles: true,
                button: 0,
                buttons: 1
            }));
            normalTarget.dispatchEvent(new PointerEvent("pointerup", {
                bubbles: true,
                button: 0,
                buttons: 0,
                pointerId: 9,
                pointerType: "mouse",
                isPrimary: true
            }));
            return JSON.stringify(result);
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let counters = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Int]
        )

            XCTAssertEqual(counters["pointerUps"], 1)
            XCTAssertEqual(counters["mouseUps"], 1)
            XCTAssertEqual(counters["staleMoves"], 0)
            // Idle-press drift collapses back to the original click point.
            XCTAssertEqual(counters["staleUpClientX"], 0)
            XCTAssertEqual(counters["staleUpClientY"], 0)
            // A dropped release after continuous movement keeps the endpoint.
            XCTAssertEqual(counters["freshUpClientX"], 70)
            XCTAssertEqual(counters["freshUpClientY"], 80)
            XCTAssertEqual(counters["mouseOnlyPointerUps"], 1)
        XCTAssertEqual(counters["mouseOnlyMouseUps"], 1)
        XCTAssertEqual(counters["mouseDownOnlyMouseUps"], 1)
        XCTAssertEqual(counters["pointerOnlyMouseUps"], 1)
        XCTAssertEqual(counters["pointerOnlySelectionMoves"], 0)
        XCTAssertEqual(counters["normalMoves"], 1)
    }

    @MainActor
    func testEditorChromeKeepsOnlyCoreStatusBarItems() {
        let configuration = WKWebViewConfiguration()

        WarrenEmbeddedEditorChrome.install(in: configuration)

        let scripts = configuration.userContentController.userScripts
        let script = scripts.first
        let source = script?.source ?? ""
        XCTAssertEqual(scripts.count, 2)
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertEqual(script?.isForMainFrameOnly, true)
        XCTAssertTrue(source.contains("status.scm.0"))
        XCTAssertTrue(source.contains("status.problems"))
        XCTAssertTrue(source.contains("status.editor.selection"))
        XCTAssertTrue(source.contains("status.editor.mode"))
        XCTAssertTrue(source.contains("status.notifications"))
        XCTAssertTrue(source.contains("MutationObserver"))
        XCTAssertTrue(source.contains("warren-editor-background-style"))
        XCTAssertTrue(source.contains("#workbench-container"))
        XCTAssertTrue(source.contains(".monaco-workbench .part.editor"))
        XCTAssertTrue(source.contains(".monaco-progress-container"))
        XCTAssertTrue(source.contains("document.fonts"))
        XCTAssertTrue(source.contains("postMessage(\"ready\")"))
        XCTAssertTrue(source.contains("warren-statusbar-hidden"))
        XCTAssertTrue(source.contains("warren-workbench-fill-style"))
        XCTAssertTrue(source.contains(".monaco-workbench > .monaco-grid-view"))
        XCTAssertTrue(source.contains(".part.titlebar"))
        XCTAssertTrue(source.contains("const controlClass = \"warren-sidebar-control\""))
        XCTAssertTrue(source.contains("id: \"files\""))
        XCTAssertTrue(source.contains("icon: \"folder-opened\""))
        XCTAssertTrue(source.contains("id: \"search\""))
        XCTAssertTrue(source.contains("id: \"git\""))
        XCTAssertTrue(source.contains("icon: \"git-commit\""))
        XCTAssertTrue(source.contains("label: \"Git Commit Changes\""))
        XCTAssertTrue(source.contains("id: \"markdown-preview\""))
        XCTAssertTrue(source.contains("icon: \"open-preview\""))
        XCTAssertTrue(source.contains("label: \"Markdown Preview\""))
        XCTAssertTrue(source.contains("id: \"reload\""))
        XCTAssertTrue(source.contains("KeyE"))
        XCTAssertTrue(source.contains("KeyF"))
        XCTAssertTrue(source.contains("KeyG"))
        XCTAssertTrue(source.contains("KeyV"))
        XCTAssertTrue(source.contains("usesMetaModifier"))
        XCTAssertTrue(source.contains("navigator.platform"))
        XCTAssertTrue(source.contains("codicon-source-control-view-icon"))
        XCTAssertTrue(source.contains("scm-viewlet"))
        XCTAssertTrue(source.contains("scm-provider"))
        XCTAssertTrue(source.contains("history-item-change"))
        XCTAssertTrue(source.contains("codicon-go-to-file"))
        XCTAssertTrue(source.contains("warrenEmbeddedEditor"))
        XCTAssertFalse(source.contains("warren-search-sidebar-close"))
        XCTAssertFalse(source.contains("KeyB"))
        XCTAssertTrue(source.contains("requestAnimationFrame"))
        XCTAssertFalse(source.contains("status.editor.encoding"))
        XCTAssertFalse(source.contains("status.editor.indentation"))
        XCTAssertFalse(source.contains("status.host"))

        let previewScript = scripts.first { !$0.isForMainFrameOnly }
        XCTAssertEqual(previewScript?.injectionTime, .atDocumentStart)
        XCTAssertTrue(previewScript?.source.contains("/vs/workbench/contrib/webview/browser/pre/") == true)
        XCTAssertTrue(previewScript?.source.contains("warren-markdown-preview-dark-style") == true)
        XCTAssertTrue(previewScript?.source.contains("color-scheme: dark") == true)
        XCTAssertTrue(previewScript?.source.contains("--vscode-editor-background") == true)
    }

    @MainActor
    func testEditorChromeReclaimsTheHiddenTitlebarRow() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorChrome.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <style>
            body { margin: 0; }
            .monaco-workbench {
                height: 200px;
                position: relative;
            }
            .split-view-container {
                height: 100%;
                position: relative;
            }
            .split-view-view {
                position: absolute;
                width: 100%;
            }
            .monaco-split-view2.horizontal .split-view-view {
                height: 100%;
                width: auto;
            }
        </style>
        <div class="monaco-workbench">
          <div class="monaco-grid-view">
            <div class="monaco-grid-branch-node">
              <div class="monaco-split-view2 vertical">
                <div class="monaco-scrollable-element">
                  <div class="split-view-container">
                    <div class="split-view-view title-row" style="top: 0px; height: 30px;">
                        <div class="part titlebar">workspace — code-server</div>
                    </div>
                    <div class="split-view-view main-row" style="top: 30px; height: 148px;">
                      <div class="monaco-grid-view">
                        <div class="monaco-grid-branch-node">
                          <div class="monaco-split-view2 horizontal">
                            <div class="monaco-scrollable-element">
                              <div class="split-view-container middle-columns" style="width: 320px;">
                                <div class="split-view-view center-column" style="left: 0px; width: 240px;">
                                  <div class="monaco-split-view2 vertical">
                                    <div class="monaco-scrollable-element">
                                      <div class="split-view-container center-stack">
                                        <div class="split-view-view editor-row" style="top: 0px; height: 126px;">
                                            <div class="part editor"></div>
                                        </div>
                                        <div class="split-view-view panel-row" style="top: 126px; height: 22px; display: none;">
                                            <div class="part panel"></div>
                                        </div>
                                      </div>
                                    </div>
                                  </div>
                                </div>
                                <div class="split-view-view side-column" style="left: 240px; width: 80px;">
                                    <div class="part sidebar"></div>
                                </div>
                              </div>
                            </div>
                          </div>
                        </div>
                      </div>
                    </div>
                    <div class="split-view-view status-row" style="top: 178px; height: 22px;">
                        <div class="part statusbar"></div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
        """#, in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const metrics = (selector) => {
                const element = document.querySelector(selector);
                const rect = element.getBoundingClientRect();
                return {
                    top: Math.round(rect.top),
                    bottom: Math.round(rect.bottom),
                    height: Math.round(rect.height),
                    display: getComputedStyle(element).display
                };
            };
            return JSON.stringify({
                title: metrics(".title-row"),
                main: metrics(".main-row"),
                editorRow: metrics(".editor-row"),
                sidebar: metrics(".side-column"),
                status: metrics(".status-row")
            });
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let layout = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let title = try XCTUnwrap(layout["title"] as? [String: Any])
        let main = try XCTUnwrap(layout["main"] as? [String: Any])
        let editorRow = try XCTUnwrap(layout["editorRow"] as? [String: Any])
        let sidebar = try XCTUnwrap(layout["sidebar"] as? [String: Any])
        let status = try XCTUnwrap(layout["status"] as? [String: Any])

        XCTAssertEqual(title["display"] as? String, "none")
        XCTAssertEqual(main["top"] as? Int, 0)
        XCTAssertEqual(main["height"] as? Int, 178)
        // The nested editor stack absorbs the reclaimed title bar height too,
        // otherwise the freed space leaks out as a gap above the status bar.
        XCTAssertEqual(editorRow["top"] as? Int, 0)
        XCTAssertEqual(editorRow["height"] as? Int, 178)
        XCTAssertEqual(sidebar["bottom"] as? Int, 178)
        XCTAssertEqual(status["top"] as? Int, 178)
    }

    @MainActor
    func testEditorChromeSwitchesSidebarViewsAndRequestsNativeReload() async throws {
        let configuration = WKWebViewConfiguration()
        let reloadReceived = expectation(description: "Native reload requested")
        let messageHandler = WarrenEmbeddedEditorTestMessageHandler(
            expectation: reloadReceived
        )
        configuration.userContentController.add(
            messageHandler,
            name: WarrenEmbeddedEditorChrome.reloadMessageHandlerName
        )
        WarrenEmbeddedEditorChrome.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <style>
            .part.sidebar {
                display: block;
                height: 175px;
                position: relative;
                width: 240px;
            }
            .part.sidebar > .header-or-footer.header {
                box-sizing: border-box;
                display: flex;
                height: 35px;
            }
            .part.sidebar > .title {
                box-sizing: border-box;
                display: flex;
                height: 35px;
                padding: 0 8px;
            }
            .part.sidebar > .content {
                height: 105px;
                position: absolute;
                top: 35px;
            }
        </style>
        <div class="monaco-workbench">
            <div class="part titlebar">
                <div>workspace — code-server</div>
                <div>User Settings</div>
            </div>
            <div class="part sidebar">
                <div class="header-or-footer header">
                    <div class="composite-bar-container">
                        <div class="composite-bar">
                            <div class="monaco-action-bar">
                                <ul class="actions-container">
                                    <li class="action-item native-panel"></li>
                                </ul>
                            </div>
                        </div>
                    </div>
                    <div class="global-actions-left">Panel</div>
                    <div class="global-actions">User Settings</div>
                </div>
                <div class="title">
                    <div class="global-actions-left title-panel">Panel</div>
                    <div class="title-label">Explorer</div>
                    <div class="title-actions">
                        <div class="monaco-action-bar">
                            <ul class="actions-container"></ul>
                        </div>
                    </div>
                    <div class="global-actions title-global-actions">User Settings</div>
                </div>
                <div class="content"></div>
            </div>
        </div>
        """#, in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const shortcuts = [];
            const keyCodes = [];
            const modifiers = [];
            window.addEventListener("keydown", (event) => {
                if ((event.ctrlKey || event.metaKey) && event.shiftKey) {
                    shortcuts.push(event.code);
                    keyCodes.push(event.keyCode);
                    modifiers.push(
                        `${event.code}:${event.ctrlKey ? "ctrl" : "meta"}`
                    );
                }
            }, true);
            const files = document.querySelector(
                ".warren-sidebar-control-files .action-label"
            );
            const search = document.querySelector(
                ".warren-sidebar-control-search .action-label"
            );
            const git = document.querySelector(
                ".warren-sidebar-control-git .action-label"
            );
            const markdownPreview = document.querySelector(
                ".warren-sidebar-control-markdown-preview .action-label"
            );
            const reload = document.querySelector(
                ".warren-sidebar-control-reload .action-label"
            );
            const header = document.querySelector(".header-or-footer.header");
            const titlebar = document.querySelector(".part.titlebar");
            const titleLabel = document.querySelector(".title-label");
            const content = document.querySelector(".part.sidebar > .content");
            const titlePanel = document.querySelector(".title-panel");
            const titleGlobalActions = document.querySelector(".title-global-actions");
            const iconMetrics = [files, search, git, reload].map((control) => {
                const rect = control.getBoundingClientRect();
                const icon = getComputedStyle(control, "::before");
                return `${rect.width}x${rect.height}@${icon.fontSize}`;
            });
            files?.click();
            search?.click();
            git?.click();
            markdownPreview?.click();
            reload?.click();
            return JSON.stringify({
                filesPresent: files !== null,
                searchPresent: search !== null,
                gitPresent: git !== null,
                markdownPreviewPresent: markdownPreview !== null,
                markdownPreviewVisible:
                    getComputedStyle(markdownPreview.parentElement).display !== "none",
                reloadPresent: reload !== null,
                controlsInHeader: [files, search, git, markdownPreview, reload].every(
                    (control) => control?.closest(".header-or-footer.header") === header
                ),
                separateToolbarRow:
                    header.getBoundingClientRect().bottom
                        <= titleLabel.getBoundingClientRect().top,
                titlebarHidden:
                    getComputedStyle(titlebar).display === "none",
                titlePanelHidden:
                    getComputedStyle(titlePanel).display === "none",
                titleGlobalActionsHidden:
                    getComputedStyle(titleGlobalActions).display === "none",
                contentHeight: content.getBoundingClientRect().height,
                iconMetrics,
                shortcuts,
                keyCodes,
                modifiers
            });
        })();
        """#)
        await fulfillment(of: [reloadReceived], timeout: 1)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let behavior = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(behavior["filesPresent"] as? Bool, true)
        XCTAssertEqual(behavior["searchPresent"] as? Bool, true)
        XCTAssertEqual(behavior["gitPresent"] as? Bool, true)
        XCTAssertEqual(behavior["markdownPreviewPresent"] as? Bool, true)
        XCTAssertEqual(behavior["markdownPreviewVisible"] as? Bool, false)
        XCTAssertEqual(behavior["reloadPresent"] as? Bool, true)
        XCTAssertEqual(behavior["controlsInHeader"] as? Bool, true)
        XCTAssertEqual(behavior["separateToolbarRow"] as? Bool, true)
        XCTAssertEqual(behavior["titlebarHidden"] as? Bool, true)
        XCTAssertEqual(behavior["titlePanelHidden"] as? Bool, true)
        XCTAssertEqual(behavior["titleGlobalActionsHidden"] as? Bool, true)
        XCTAssertEqual(behavior["contentHeight"] as? Double, 105)
        XCTAssertEqual(
            Set(behavior["iconMetrics"] as? [String] ?? []).count,
            1
        )
        // WKWebView tests run on macOS. Git uses Control because code-server's
        // web binding explicitly maps Source Control to Ctrl+Shift+G.
        XCTAssertEqual(
            behavior["shortcuts"] as? [String],
            ["KeyE", "KeyF", "KeyG", "KeyV"]
        )
        XCTAssertEqual(behavior["keyCodes"] as? [Int], [69, 70, 71, 86])
        XCTAssertEqual(
            behavior["modifiers"] as? [String],
            ["KeyE:meta", "KeyF:meta", "KeyG:ctrl", "KeyV:meta"]
        )
        XCTAssertEqual(messageHandler.messages, ["reload"])
    }

    @MainActor
    func testEditorChromeGitButtonUsesNativeSourceControlAction() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorChrome.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <div class="monaco-workbench">
            <div class="part sidebar">
                <div class="header-or-footer header">
                    <div class="composite-bar-container">
                        <div class="composite-bar">
                            <div class="monaco-action-bar">
                                <ul class="actions-container">
                                    <li class="action-item">
                                        <a class="action-label codicon codicon-source-control-view-icon"
                                           aria-label="Source Control"></a>
                                    </li>
                                </ul>
                            </div>
                        </div>
                    </div>
                </div>
                <div class="title">
                    <div class="title-actions">
                        <div class="action-item">View Actions</div>
                    </div>
                </div>
                <div class="content">
                    <div class="composite viewlet scm-viewlet">
                        <div class="pane-header">
                            <div class="actions">Changes Actions</div>
                        </div>
                        <div class="scm-provider">
                            <div class="actions">Repository Actions</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <script>
            window.sourceControlClicks = 0;
            document.querySelector(
                ".codicon-source-control-view-icon"
            ).addEventListener("click", () => {
                window.sourceControlClicks += 1;
            });
        </script>
        """#, in: webView)
        // Give the injected observers a moment to mount the sidebar controls.
        try await Task.sleep(for: .milliseconds(400))

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const git = document.querySelector(
                ".warren-sidebar-control-git .action-label"
            );
            git?.click();
            const display = (selector) => getComputedStyle(
                document.querySelector(selector)
            ).display;
            return JSON.stringify({
                sourceControlClicks: window.sourceControlClicks,
                shortcutEvents: window.__warrenShortcutEvents ?? 0,
                titleActions: display(".part.sidebar > .title > .title-actions"),
                changesActions: display(
                    ".scm-viewlet .pane-header > .actions"
                ),
                providerActions: display(
                    ".scm-viewlet .scm-provider > .actions"
                )
            });
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let behavior = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(behavior["sourceControlClicks"] as? Int, 1)
        XCTAssertEqual(behavior["shortcutEvents"] as? Int, 0)
        XCTAssertEqual(behavior["titleActions"] as? String, "none")
        XCTAssertEqual(behavior["changesActions"] as? String, "none")
        XCTAssertEqual(behavior["providerActions"] as? String, "none")
    }

    @MainActor
    func testEditorChromeShowsMarkdownPreviewOnlyForMarkdownAndUsesEditorContext() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorChrome.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <div class="monaco-workbench">
            <div class="part sidebar">
                <div class="header-or-footer header">
                    <div class="monaco-action-bar">
                        <ul class="actions-container"></ul>
                    </div>
                </div>
            </div>
            <div class="monaco-editor focused" data-mode-id="markdown">
                <textarea class="inputarea"></textarea>
            </div>
        </div>
        <script>
            window.previewTargets = [];
            document.addEventListener("keydown", (event) => {
                if (event.code === "KeyV") {
                    window.previewTargets.push(event.target.className);
                }
            }, true);
        </script>
        """#, in: webView)
        try await Task.sleep(for: .milliseconds(400))

        let initial = try await webView.evaluateJavaScript(#"""
        (() => {
            const preview = document.querySelector(
                ".warren-sidebar-control-markdown-preview .action-label"
            );
            preview?.click();
            return JSON.stringify({
                visible: getComputedStyle(preview.parentElement).display !== "none",
                target: window.previewTargets[0]
            });
        })();
        """#)
        let initialData = try XCTUnwrap((initial as? String)?.data(using: .utf8))
        let initialBehavior = try XCTUnwrap(
            JSONSerialization.jsonObject(with: initialData) as? [String: Any]
        )

        XCTAssertEqual(initialBehavior["visible"] as? Bool, true)
        XCTAssertEqual(initialBehavior["target"] as? String, "inputarea")

        _ = try await webView.evaluateJavaScript(#"""
        document.querySelector(".monaco-editor").setAttribute("data-mode-id", "typescript");
        """#)
        try await Task.sleep(for: .milliseconds(100))
        let nonMarkdown = try await webView.evaluateJavaScript(#"""
        (() => {
            const preview = document.querySelector(
                ".warren-sidebar-control-markdown-preview .action-label"
            );
            return getComputedStyle(preview.parentElement).display !== "none";
        })();
        """#)
        XCTAssertEqual(nonMarkdown as? Bool, false)

        _ = try await webView.evaluateJavaScript(#"""
        document.querySelector(".monaco-editor").setAttribute("data-mode-id", "markdown");
        """#)
        try await Task.sleep(for: .milliseconds(100))
        let markdown = try await webView.evaluateJavaScript(#"""
        (() => {
            const preview = document.querySelector(
                ".warren-sidebar-control-markdown-preview .action-label"
            );
            return getComputedStyle(preview.parentElement).display !== "none";
        })();
        """#)
        XCTAssertEqual(markdown as? Bool, true)
    }

    @MainActor
    func testEditorChromeSupportsCurrentVSCodeMarkdownEditorDOM() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorChrome.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <div class="monaco-workbench">
            <div class="part sidebar">
                <div class="header-or-footer header">
                    <div class="monaco-action-bar">
                        <ul class="actions-container"></ul>
                    </div>
                </div>
            </div>
            <div class="part statusbar">
                <div class="statusbar-item" id="status.editor.mode"
                     aria-label="Markdown">Markdown</div>
            </div>
            <div class="monaco-editor">
                <div class="native-edit-context" role="textbox" tabindex="0"></div>
            </div>
        </div>
        <script>
            window.previewTargets = [];
            document.addEventListener("keydown", (event) => {
                if (event.code === "KeyV") {
                    window.previewTargets.push(event.target.className);
                }
            }, true);
        </script>
        """#, in: webView)
        try await Task.sleep(for: .milliseconds(400))

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const preview = document.querySelector(
                ".warren-sidebar-control-markdown-preview .action-label"
            );
            preview?.click();
            return JSON.stringify({
                visible: getComputedStyle(preview.parentElement).display !== "none",
                target: window.previewTargets[0]
            });
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let behavior = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(behavior["visible"] as? Bool, true)
        XCTAssertEqual(behavior["target"] as? String, "native-edit-context")

        _ = try await webView.evaluateJavaScript(#"""
        document.querySelector("#status\\.editor\\.mode")
            .setAttribute("aria-label", "TypeScript");
        """#)
        try await Task.sleep(for: .milliseconds(100))
        let nonMarkdown = try await webView.evaluateJavaScript(#"""
        (() => {
            const preview = document.querySelector(
                ".warren-sidebar-control-markdown-preview .action-label"
            );
            return getComputedStyle(preview.parentElement).display !== "none";
        })();
        """#)
        XCTAssertEqual(nonMarkdown as? Bool, false)
    }

    @MainActor
    func testEditorChromeOpensHistoryChangesAsFilesInsteadOfDiffs() async throws {
        let configuration = WKWebViewConfiguration()
        WarrenEmbeddedEditorChrome.install(in: configuration)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 200),
            configuration: configuration
        )
        let navigation = WarrenEmbeddedEditorTestNavigation()
        await navigation.load(#"""
        <div class="scm-history-view">
            <div class="history-item-change">
                <div class="monaco-list-row" id="changed-file">
                    <span class="file-label">Sources/Warren.swift</span>
                    <a class="action-label codicon codicon-go-to-file"
                       aria-label="Open File"></a>
                </div>
            </div>
        </div>
        <script>
            const row = document.getElementById("changed-file");
            const openFile = row.querySelector(".codicon-go-to-file");
            window.historyClickCount = 0;
            window.openFileClickCount = 0;
            row.addEventListener("click", (event) => {
                if (event.target === row) {
                    window.historyClickCount += 1;
                }
            });
            openFile.addEventListener("click", () => window.openFileClickCount += 1);
        </script>
        """#, in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const row = document.getElementById("changed-file");
            const event = new MouseEvent("click", {
                bubbles: true,
                cancelable: true,
                button: 0
            });
            const dispatched = row.dispatchEvent(event);
            return JSON.stringify({
                dispatched,
                defaultPrevented: event.defaultPrevented,
                historyClickCount: window.historyClickCount,
                openFileClickCount: window.openFileClickCount
            });
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let behavior = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(behavior["dispatched"] as? Bool, false)
        XCTAssertEqual(behavior["defaultPrevented"] as? Bool, true)
        XCTAssertEqual(behavior["historyClickCount"] as? Int, 0)
        XCTAssertEqual(behavior["openFileClickCount"] as? Int, 1)
    }
}

@MainActor
private final class WarrenEmbeddedEditorTestMessageHandler:
    NSObject,
    WKScriptMessageHandler
{
    let expectation: XCTestExpectation
    private(set) var messages: [String] = []

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? String else { return }
        messages.append(body)
        expectation.fulfill()
    }
}

@MainActor
private final class WarrenEmbeddedEditorTestNavigation: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?

    func load(_ html: String, in webView: WKWebView) async {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        continuation?.resume()
        continuation = nil
    }
}
