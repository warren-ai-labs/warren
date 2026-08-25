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
            "--disable-update-check",
            "--ignore-last-opened",
        ])
        XCTAssertTrue(configuration.serverArguments.contains("127.0.0.1:54321"))
        XCTAssertTrue(configuration.serverArguments.contains("none"))
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
        XCTAssertTrue(source.contains("sourceEvent?.clientX"))
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
        await navigation.load("<button id='target'>Target</button>", in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const target = document.getElementById("target");
            const result = {
                pointerUps: 0,
                mouseUps: 0,
                staleMoves: 0,
                mouseOnlyPointerUps: 0,
                mouseOnlyMouseUps: 0,
                mouseDownOnlyMouseUps: 0,
                pointerOnlyMouseUps: 0,
                pointerOnlySelectionMoves: 0,
                normalMoves: 0
            };
            target.addEventListener("pointerup", () => result.pointerUps++);
            target.addEventListener("mouseup", () => result.mouseUps++);
            target.addEventListener("mousemove", () => result.staleMoves++);
            target.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                button: 0,
                buttons: 1,
                pointerId: 7,
                pointerType: "mouse",
                isPrimary: true
            }));
            target.dispatchEvent(new MouseEvent("mousemove", {
                bubbles: true,
                button: 0,
                buttons: 0,
                clientX: 20,
                clientY: 30
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
        XCTAssertEqual(scripts.count, 1)
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
        XCTAssertTrue(source.contains("postMessage(\"ready\")"))
        XCTAssertTrue(source.contains("warren-statusbar-hidden"))
        XCTAssertTrue(source.contains("const controlClass = \"warren-sidebar-control\""))
        XCTAssertTrue(source.contains("id: \"files\""))
        XCTAssertTrue(source.contains("icon: \"folder-opened\""))
        XCTAssertTrue(source.contains("id: \"search\""))
        XCTAssertTrue(source.contains("id: \"reload\""))
        XCTAssertTrue(source.contains("KeyE"))
        XCTAssertTrue(source.contains("KeyF"))
        XCTAssertTrue(source.contains("warrenEmbeddedEditor"))
        XCTAssertFalse(source.contains("warren-search-sidebar-close"))
        XCTAssertFalse(source.contains("KeyB"))
        XCTAssertTrue(source.contains("requestAnimationFrame"))
        XCTAssertFalse(source.contains("status.editor.encoding"))
        XCTAssertFalse(source.contains("status.editor.indentation"))
        XCTAssertFalse(source.contains("status.host"))
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
            .monaco-workbench,
            .split-view-container {
                height: 200px;
                position: relative;
            }
            .split-view-view {
                position: absolute;
                width: 320px;
            }
        </style>
        <div class="monaco-workbench">
            <div class="split-view-container">
                <div class="split-view-view title-row" style="top: 0px; height: 35px;">
                    <div class="part titlebar">workspace — code-server</div>
                </div>
                <div class="split-view-view main-row" style="top: 35px; height: 143px;">
                    <div class="part editor"></div>
                    <div class="part sidebar"></div>
                </div>
                <div class="split-view-view status-row" style="top: 178px; height: 22px;">
                    <div class="part statusbar"></div>
                </div>
            </div>
        </div>
        """#, in: webView)

        let result = try await webView.evaluateJavaScript(#"""
        (() => {
            const title = document.querySelector(".title-row");
            const main = document.querySelector(".main-row");
            const status = document.querySelector(".status-row");
            return JSON.stringify({
                titleDisplay: getComputedStyle(title).display,
                titleHeight: title.getBoundingClientRect().height,
                mainTop: Number.parseFloat(main.style.top),
                mainHeight: main.getBoundingClientRect().height,
                statusTop: Number.parseFloat(status.style.top)
            });
        })();
        """#)
        let data = try XCTUnwrap((result as? String)?.data(using: .utf8))
        let layout = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(layout["titleDisplay"] as? String, "none")
        XCTAssertEqual(layout["titleHeight"] as? Double, 0)
        XCTAssertEqual(layout["mainTop"] as? Double, 0)
        XCTAssertEqual(layout["mainHeight"] as? Double, 178)
        XCTAssertEqual(layout["statusTop"] as? Double, 178)
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
            window.addEventListener("keydown", (event) => {
                if (event.metaKey && event.shiftKey) {
                    shortcuts.push(event.code);
                }
            }, true);
            const files = document.querySelector(
                ".warren-sidebar-control-files .action-label"
            );
            const search = document.querySelector(
                ".warren-sidebar-control-search .action-label"
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
            const iconMetrics = [files, search, reload].map((control) => {
                const rect = control.getBoundingClientRect();
                const icon = getComputedStyle(control, "::before");
                return `${rect.width}x${rect.height}@${icon.fontSize}`;
            });
            files?.click();
            search?.click();
            reload?.click();
            return JSON.stringify({
                filesPresent: files !== null,
                searchPresent: search !== null,
                reloadPresent: reload !== null,
                controlsInHeader: [files, search, reload].every(
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
                shortcuts
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
        XCTAssertEqual(behavior["shortcuts"] as? [String], ["KeyE", "KeyF"])
        XCTAssertEqual(messageHandler.messages, ["reload"])
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
