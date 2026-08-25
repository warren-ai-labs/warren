import AppKit
import Darwin
import Foundation
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WebKit

struct WarrenEmbeddedEditorConfiguration: Equatable, Sendable {
    static let managedExtensionIDs = [
        "golang.go",
        "rust-lang.rust-analyzer",
    ]

    let executableURL: URL
    let userDataDirectory: URL
    let extensionsDirectory: URL
    let port: UInt16

    var serverURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    var sharedArguments: [String] {
        [
            "--user-data-dir", userDataDirectory.path,
            "--extensions-dir", extensionsDirectory.path,
        ]
    }

    var serverArguments: [String] {
        sharedArguments + [
            "--bind-addr", "127.0.0.1:\(port)",
            "--auth", "none",
            "--disable-telemetry",
            "--disable-update-check",
            "--ignore-last-opened",
        ]
    }

    func workspaceURL(path: String) -> URL {
        Self.workspaceURL(serverURL: serverURL, path: path)
    }

    static func workspaceURL(serverURL: URL, path: String) -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "folder", value: path)]
        return components.url!
    }

    func installArguments(extensionID: String) -> [String] {
        sharedArguments + ["--install-extension", extensionID]
    }
}

enum WarrenEmbeddedEditorExecutableResolver {
    static func candidates(environment: [String: String]) -> [URL] {
        var paths: [String] = []
        if let override = environment["WARREN_CODE_SERVER_PATH"], !override.isEmpty {
            paths.append(override)
        }
        paths.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/code-server" })
        if let home = environment["HOME"], !home.isEmpty {
            paths.append(home + "/.local/bin/code-server")
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/code-server",
            "/usr/local/bin/code-server",
        ])

        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    static func resolve(environment: [String: String]) -> URL? {
        candidates(environment: environment).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

enum WarrenEmbeddedEditorProfile {
    /// Keep these values aligned with WarrenColorTokens.dark. VS Code accepts
    /// CSS color strings at its settings boundary, while the native design
    /// system owns SwiftUI Color values.
    static let colorCustomizations: [String: String] = [
        "activityBar.background": "#1c1918",
        "activityBar.foreground": "#eae8e6",
        "activityBar.inactiveForeground": "#a8a5a3",
        "badge.background": "#e07850",
        "badge.foreground": "#151110",
        "breadcrumb.background": "#151110",
        "breadcrumb.foreground": "#a8a5a3",
        "breadcrumb.focusForeground": "#eae8e6",
        "breadcrumb.activeSelectionForeground": "#e07850",
        "button.background": "#eae8e6",
        "button.foreground": "#151110",
        "button.hoverBackground": "#d1cfcd",
        "button.secondaryBackground": "#2a2827",
        "button.secondaryForeground": "#eae8e6",
        "dropdown.background": "#201e1c",
        "dropdown.border": "#2a2827",
        "dropdown.foreground": "#eae8e6",
        "editor.background": "#151110",
        "editor.foreground": "#eae8e6",
        "editor.lineHighlightBackground": "#1c1918",
        "editor.selectionBackground": "#e0785040",
        "editorCursor.foreground": "#e07850",
        "editorError.foreground": "#cc4444",
        "editorGroup.border": "#2a2827",
        "editorGroupHeader.tabsBackground": "#1c1918",
        "editorIndentGuide.activeBackground1": "#3a3837",
        "editorIndentGuide.background1": "#2a2827",
        "editorInfo.foreground": "#61afef",
        "editorWarning.foreground": "#e5c07b",
        "focusBorder": "#3a3837",
        "input.background": "#181615",
        "input.border": "#2a2827",
        "input.foreground": "#eae8e6",
        "input.placeholderForeground": "#a8a5a3",
        "list.activeSelectionBackground": "#302e2c",
        "list.activeSelectionForeground": "#eae8e6",
        "list.focusBackground": "#302e2c",
        "list.highlightForeground": "#e07850",
        "list.hoverBackground": "#24201f",
        "list.inactiveSelectionBackground": "#2a2827",
        "menu.background": "#201e1c",
        "menu.border": "#2a2827",
        "menu.foreground": "#eae8e6",
        "menu.selectionBackground": "#2a2827",
        "menu.selectionForeground": "#eae8e6",
        "notificationCenterHeader.background": "#1c1918",
        "notifications.background": "#201e1c",
        "notifications.border": "#2a2827",
        "panel.background": "#151110",
        "panel.border": "#2a2827",
        "panelTitle.activeBorder": "#e07850",
        "panelTitle.activeForeground": "#eae8e6",
        "panelTitle.inactiveForeground": "#a8a5a3",
        "quickInput.background": "#201e1c",
        "quickInput.foreground": "#eae8e6",
        "quickInputList.focusBackground": "#2a2827",
        "scrollbarSlider.activeBackground": "#a8a5a366",
        "scrollbarSlider.background": "#a8a5a333",
        "scrollbarSlider.hoverBackground": "#a8a5a34d",
        "sideBar.background": "#1c1918",
        "sideBar.border": "#2a2827",
        "sideBar.foreground": "#a8a5a3",
        "sideBarSectionHeader.background": "#1c1918",
        "sideBarSectionHeader.foreground": "#eae8e6",
        "sideBarTitle.foreground": "#eae8e6",
        "statusBar.background": "#1c1918",
        "statusBar.border": "#2a2827",
        "statusBar.foreground": "#a8a5a3",
        "statusBar.noFolderBackground": "#1c1918",
        "tab.activeBackground": "#151110",
        "tab.activeForeground": "#eae8e6",
        "tab.border": "#2a2827",
        "tab.inactiveBackground": "#1c1918",
        "tab.inactiveForeground": "#a8a5a3",
        "titleBar.activeBackground": "#1c1918",
        "titleBar.activeForeground": "#eae8e6",
        "titleBar.border": "#2a2827",
    ]

    static var managedSettings: [String: Any] {
        [
            "breadcrumbs.enabled": true,
            "chat.disableAIFeatures": true,
            "editor.minimap.enabled": false,
            "editor.scrollbar.horizontalScrollbarSize": 8,
            "editor.scrollbar.verticalScrollbarSize": 8,
            "editor.stickyScroll.enabled": false,
            "explorer.compactFolders": true,
            "explorer.decorations.badges": false,
            "extensions.autoCheckUpdates": false,
            "extensions.autoUpdate": false,
            "extensions.ignoreRecommendations": true,
            "extensions.showRecommendationsOnlyOnDemand": true,
            "go.showWelcome": false,
            "go.survey.prompt": false,
            "go.toolsManagement.checkForUpdates": "off",
            "security.workspace.trust.enabled": false,
            "telemetry.telemetryLevel": "off",
            "update.showReleaseNotes": false,
            "window.commandCenter": false,
            "window.customTitleBarVisibility": "never",
            "window.density.editorTabHeight": "compact",
            "window.menuBarVisibility": "hidden",
            "workbench.activityBar.location": "top",
            "workbench.colorTheme": "Default Dark Modern",
            "workbench.colorCustomizations": colorCustomizations,
            "workbench.commandPalette.showAskInChat": false,
            "workbench.editor.editorActionsLocation": "hidden",
            "workbench.editor.empty.hint": "hidden",
            "workbench.editor.pinnedTabSizing": "compact",
            "workbench.editor.showTabs": "multiple",
            "workbench.editor.tabSizing": "shrink",
            "workbench.iconTheme": "vs-seti",
            "workbench.layoutControl.enabled": false,
            "workbench.navigationControl.enabled": false,
            "workbench.panel.defaultLocation": "bottom",
            "workbench.secondarySideBar.defaultVisibility": "hidden",
            "workbench.settings.showAISearchToggle": false,
            "workbench.sideBar.location": "right",
            "workbench.startupEditor": "none",
            "workbench.statusBar.visible": true,
            "workbench.tips.enabled": false,
            "workbench.tree.enableStickyScroll": false,
            "workbench.tree.indent": 10,
            "workbench.tree.renderIndentGuides": "none",
            "workbench.welcomePage.walkthroughs.openOnInstall": false,
        ]
    }

    static func mergingManagedSettings(
        into existing: [String: Any]
    ) -> [String: Any] {
        existing.merging(managedSettings) { _, managed in managed }
    }
}

enum WarrenEmbeddedEditorExtensionRegistry {
    static func installedExtensionIDs(
        in extensionsDirectory: URL,
        fileManager: FileManager = .default
    ) -> Set<String> {
        guard let extensionDirectories = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return Set(extensionDirectories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let publisher = manifest["publisher"] as? String,
                  let name = manifest["name"] as? String,
                  !publisher.isEmpty,
                  !name.isEmpty else {
                return nil
            }
            return "\(publisher).\(name)".lowercased()
        })
    }
}

enum WarrenEmbeddedEditorPointerBridge {
    static let installationSource = #"""
    (() => {
        const stateKey = "__warrenPointerState";
        const cancelFunction = "__warrenCancelPointerInteraction";

        window.addEventListener("pointerdown", (event) => {
            if (event.button !== 0 || !event.isPrimary) {
                return;
            }
            window[stateKey] = {
                target: event.target,
                pointerId: event.pointerId,
                pointerType: event.pointerType,
                isPrimary: event.isPrimary
            };
        }, true);
        window.addEventListener("mousedown", (event) => {
            if (event.button !== 0 || window[stateKey]) {
                return;
            }
            // WebKit occasionally delivers Monaco's mouse event without the
            // corresponding PointerEvent during multi-click trackpad input.
            window[stateKey] = {
                target: event.target,
                pointerId: 1,
                pointerType: "mouse",
                isPrimary: true
            };
        }, true);

        window.addEventListener("pointerup", (event) => {
            // Do not clear first: WKWebView may omit the following mouseup,
            // which would leave Monaco's mouse-driven selection monitor live.
            window[cancelFunction]?.(event);
        }, true);
        window.addEventListener("pointercancel", (event) => {
            window[cancelFunction]?.(event);
        }, true);
        window.addEventListener("lostpointercapture", (event) => {
            const state = window[stateKey];
            if (state && state.pointerId === event.pointerId) {
                window[cancelFunction]?.(event);
            }
        }, true);
        window.addEventListener("mouseup", (event) => {
            window[cancelFunction]?.(event);
        }, true);
        window.addEventListener("blur", () => {
            window[cancelFunction]?.();
        }, true);

        window[cancelFunction] = (sourceEvent) => {
            const state = window[stateKey];
            if (!state || !state.target) {
                return;
            }
            window[stateKey] = null;

            try {
                if (state.target.hasPointerCapture?.(state.pointerId)) {
                    state.target.releasePointerCapture(state.pointerId);
                }
            } catch (_) {
                // The target may already be detached while switching workspaces.
            }

            const pointerInit = {
                bubbles: true,
                cancelable: true,
                composed: true,
                pointerId: state.pointerId,
                pointerType: state.pointerType,
                isPrimary: state.isPrimary,
                button: 0,
                buttons: 0,
                clientX: sourceEvent?.clientX ?? 0,
                clientY: sourceEvent?.clientY ?? 0,
                screenX: sourceEvent?.screenX ?? 0,
                screenY: sourceEvent?.screenY ?? 0,
                ctrlKey: sourceEvent?.ctrlKey ?? false,
                metaKey: sourceEvent?.metaKey ?? false,
                altKey: sourceEvent?.altKey ?? false,
                shiftKey: sourceEvent?.shiftKey ?? false
            };
            if (sourceEvent?.type !== "pointerup") {
                state.target.dispatchEvent(new PointerEvent("pointercancel", pointerInit));
                state.target.dispatchEvent(new PointerEvent("pointerup", pointerInit));
                window.dispatchEvent(new PointerEvent("pointerup", pointerInit));
            }

            const mouseInit = {
                bubbles: true,
                cancelable: true,
                composed: true,
                button: 0,
                buttons: 0,
                clientX: sourceEvent?.clientX ?? 0,
                clientY: sourceEvent?.clientY ?? 0,
                screenX: sourceEvent?.screenX ?? 0,
                screenY: sourceEvent?.screenY ?? 0,
                ctrlKey: sourceEvent?.ctrlKey ?? false,
                metaKey: sourceEvent?.metaKey ?? false,
                altKey: sourceEvent?.altKey ?? false,
                shiftKey: sourceEvent?.shiftKey ?? false
            };
            if (sourceEvent?.type !== "mouseup") {
                state.target.dispatchEvent(new MouseEvent("mouseup", mouseInit));
                window.dispatchEvent(new MouseEvent("mouseup", mouseInit));
            }
        };

        const releaseStalePointer = (event) => {
            // WKWebView can omit pointerup after a macOS tap-to-click gesture.
            // VS Code #146486 and nyaterm #243 document the same stale selection.
            if (!window[stateKey] || event.buttons !== 0) {
                return;
            }
            event.stopImmediatePropagation();
            window[cancelFunction](event);
        };
        window.addEventListener("pointermove", releaseStalePointer, true);
        window.addEventListener("mousemove", releaseStalePointer, true);
    })();
    """#

    static let cancellationSource = "window.__warrenCancelPointerInteraction?.();"

    @MainActor
    static func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: installationSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }

    @MainActor
    static func cancel(in webView: WKWebView) {
        webView.evaluateJavaScript(cancellationSource, completionHandler: nil)
    }
}

enum WarrenEmbeddedEditorNativeSelectionBridge {
    static let installationSource = #"""
    (() => {
        const editorTextSelector = [
            ".monaco-editor .lines-content",
            ".monaco-editor .view-lines",
            ".monaco-editor .view-line"
        ].join(",");

        window.addEventListener("selectstart", (event) => {
            const target = event.target instanceof Element
                ? event.target
                : event.target?.parentElement;
            if (target?.closest(editorTextSelector)) {
                // Monaco renders its own selection. Letting WebKit also start a
                // DOM selection makes tap-to-click gestures remain selected.
                event.preventDefault();
            }
        }, true);
    })();
    """#

    @MainActor
    static func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: installationSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }
}

enum WarrenEmbeddedEditorChrome {
    static let reloadMessageHandlerName = "warrenEmbeddedEditor"
    static let readyMessage = "ready"

    static let statusBarSource = #"""
    (() => {
        const background = "#151110";
        const install = () => {
            if (!document.documentElement) {
                return false;
            }
            document.documentElement.style.setProperty(
                "background-color",
                background,
                "important"
            );
            document.documentElement.style.colorScheme = "dark";
            if (!document.getElementById("warren-editor-background-style")) {
                const style = document.createElement("style");
                style.id = "warren-editor-background-style";
                style.textContent = `:root {
                    color-scheme: dark !important;
                }
                html,
                body,
                #workbench-container,
                .monaco-workbench {
                    background-color: ${background} !important;
                }`;
                document.documentElement.appendChild(style);
            }
            return true;
        };

        if (!install()) {
            window.addEventListener("DOMContentLoaded", install, { once: true });
        }
    })();

    (() => {
        let layoutObserver;
        let resizeObserver;
        let waitObserver;

        const setImportant = (element, property, value) => {
            if (element.style.getPropertyValue(property) === value
                && element.style.getPropertyPriority(property) === "important") {
                return;
            }
            element.style.setProperty(property, value, "important");
        };

        const pixels = (value, fallback) => {
            const parsed = Number.parseFloat(value);
            return Number.isFinite(parsed) ? parsed : fallback;
        };

        const attach = () => {
            const titlebar = document.querySelector(
                ".monaco-workbench .part.titlebar"
            );
            const titleRow = titlebar?.closest(".split-view-view");
            const container = titleRow?.parentElement;
            if (!titleRow
                || !container?.classList.contains("split-view-container")) {
                return false;
            }
            const rows = Array.from(container.children).filter(
                (child) => child.classList.contains("split-view-view")
            );
            const mainRow = rows.find(
                (row) => row !== titleRow && row.querySelector(".part.editor")
            );
            if (!mainRow) {
                return false;
            }
            const statusRow = rows.find(
                (row) => row.querySelector(".part.statusbar")
            );
            waitObserver?.disconnect();

            const sync = () => {
                const containerRect = container.getBoundingClientRect();
                const statusTop = statusRow
                    ? pixels(
                        statusRow.style.top,
                        statusRow.getBoundingClientRect().top - containerRect.top
                    )
                    : container.clientHeight;
                let mainTop = 0;
                for (const row of rows) {
                    if (row === titleRow || row === mainRow || row === statusRow) {
                        continue;
                    }
                    const height = pixels(
                        row.style.height,
                        row.getBoundingClientRect().height
                    );
                    setImportant(row, "top", `${mainTop}px`);
                    mainTop += height;
                }
                setImportant(titleRow, "display", "none");
                setImportant(titleRow, "height", "0px");
                setImportant(titleRow, "top", "0px");
                setImportant(mainRow, "top", `${mainTop}px`);
                setImportant(
                    mainRow,
                    "height",
                    `${Math.max(statusTop - mainTop, 0)}px`
                );
            };

            sync();
            layoutObserver = new MutationObserver(sync);
            for (const row of rows) {
                layoutObserver.observe(row, {
                    attributeFilter: ["style"],
                    attributes: true
                });
            }
            resizeObserver = new ResizeObserver(sync);
            resizeObserver.observe(container);
            return true;
        };

        if (!attach()) {
            const watch = () => {
                if (attach()) {
                    return;
                }
                waitObserver = new MutationObserver(attach);
                waitObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
            };
            if (document.documentElement) {
                watch();
            } else {
                window.addEventListener("DOMContentLoaded", watch, { once: true });
            }
        }
    })();

    (() => {
        let observer;
        let notified = false;
        const notifyWhenPainted = () => {
            if (notified
                || !document.querySelector(
                    ".monaco-workbench .part.editor"
                )) {
                return false;
            }
            notified = true;
            observer?.disconnect();
            requestAnimationFrame(() => {
                requestAnimationFrame(() => {
                    window.webkit?.messageHandlers?.\#(reloadMessageHandlerName)
                        ?.postMessage("\#(readyMessage)");
                });
            });
            return true;
        };

        if (!notifyWhenPainted()) {
            const watch = () => {
                if (notifyWhenPainted()) {
                    return;
                }
                observer = new MutationObserver(notifyWhenPainted);
                observer.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
            };
            if (document.documentElement) {
                watch();
            } else {
                window.addEventListener("DOMContentLoaded", watch, { once: true });
            }
        }
    })();

    (() => {
        const hiddenClass = "warren-statusbar-hidden";
        const visibleItems = new Set([
            "status.scm.0",
            "status.problems",
            "status.debug",
            "status.progress",
            "status.message",
            "status.editor.selection",
            "status.editor.mode",
            "status.notifications"
        ]);

        let waitObserver;
        const attach = () => {
            const statusBar = document.querySelector(
                ".monaco-workbench .part.statusbar"
            );
            if (!statusBar) {
                return false;
            }
            waitObserver?.disconnect();

            const style = document.createElement("style");
            style.textContent = `.${hiddenClass} { display: none !important; }`;
            document.documentElement.appendChild(style);

            const trim = () => {
                for (const item of statusBar.querySelectorAll(".statusbar-item")) {
                    item.classList.toggle(hiddenClass, !visibleItems.has(item.id));
                }
            };
            trim();
            new MutationObserver(trim).observe(statusBar, {
                childList: true,
                subtree: true
            });
            return true;
        };

        if (!attach()) {
            const watch = () => {
                if (attach()) {
                    return;
                }
                waitObserver = new MutationObserver(attach);
                waitObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
            };
            if (document.documentElement) {
                watch();
            } else {
                window.addEventListener("DOMContentLoaded", watch, { once: true });
            }
        }
    })();

    (() => {
        const controlClass = "warren-sidebar-control";
        let waitObserver;

        const installStyle = () => {
            if (document.getElementById("warren-sidebar-toolbar-style")) {
                return;
            }
            const style = document.createElement("style");
            style.id = "warren-sidebar-toolbar-style";
            style.textContent = `
                .monaco-workbench .part.titlebar {
                    display: none !important;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .monaco-action-bar
                    .actions-container {
                    align-items: center;
                    display: flex;
                    gap: 1px;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .monaco-action-bar
                    .actions-container
                    > .action-item:not(.${controlClass}) {
                    display: none !important;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    > .global-actions,
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    > .global-actions-left,
                .monaco-workbench .part.sidebar
                    > .title
                    > .global-actions,
                .monaco-workbench .part.sidebar
                    > .title
                    > .global-actions-left {
                    display: none !important;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .${controlClass} {
                    align-items: center;
                    box-sizing: border-box;
                    display: flex;
                    height: 28px !important;
                    justify-content: center;
                    margin: 0 !important;
                    padding: 0 !important;
                    width: 28px !important;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .${controlClass} > .action-label {
                    align-items: center;
                    border-radius: 5px;
                    box-sizing: border-box;
                    color: var(--vscode-activityBarTop-foreground);
                    cursor: pointer;
                    display: flex;
                    font-size: 16px !important;
                    height: 26px !important;
                    justify-content: center;
                    line-height: 16px !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    text-decoration: none;
                    width: 26px !important;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .${controlClass} > .action-label::before {
                    font-size: 16px !important;
                    height: 16px;
                    line-height: 16px !important;
                    text-align: center;
                    width: 16px;
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .${controlClass} > .action-label:hover {
                    background: var(--vscode-toolbar-hoverBackground);
                }
                .monaco-workbench .part.sidebar
                    > .header-or-footer.header
                    .${controlClass} > .action-label:focus-visible {
                    outline: 1px solid var(--vscode-focusBorder);
                    outline-offset: -1px;
                }
            `;
            document.documentElement.appendChild(style);
        };

        const dispatchShortcut = (event, key, code) => {
            event.preventDefault();
            event.stopPropagation();
            const target = document.activeElement ?? document.body;
            const keyboardEvent = (type) => new KeyboardEvent(type, {
                key,
                code,
                metaKey: true,
                shiftKey: true,
                bubbles: true,
                cancelable: true,
                composed: true
            });
            target.dispatchEvent(keyboardEvent("keydown"));
            target.dispatchEvent(keyboardEvent("keyup"));
        };

        const makeAction = ({ id, icon, label, activate }) => {
            const item = document.createElement("li");
            item.className = `action-item ${controlClass} ${controlClass}-${id}`;
            const action = document.createElement("a");
            action.className = `action-label codicon codicon-${icon}`;
            action.setAttribute("role", "button");
            action.setAttribute("aria-label", label);
            action.setAttribute("tabindex", "0");
            action.title = label;
            action.addEventListener("click", activate);
            action.addEventListener("keydown", (event) => {
                if (event.key === "Enter" || event.key === " ") {
                    activate(event);
                }
            });
            item.appendChild(action);
            return item;
        };

        const controls = [
            {
                id: "files",
                icon: "folder-opened",
                label: "Files",
                activate: (event) => dispatchShortcut(event, "e", "KeyE")
            },
            {
                id: "search",
                icon: "search",
                label: "Search",
                activate: (event) => dispatchShortcut(event, "f", "KeyF")
            },
            {
                id: "reload",
                icon: "refresh",
                label: "Reload Editor",
                activate: (event) => {
                    event.preventDefault();
                    event.stopPropagation();
                    window.webkit?.messageHandlers?.\#(reloadMessageHandlerName)
                        ?.postMessage("reload");
                }
            }
        ];

        const attach = () => {
            const workbench = document.querySelector(".monaco-workbench");
            if (!workbench) {
                return false;
            }
            waitObserver?.disconnect();
            installStyle();

            const sync = () => {
                const actions = workbench.querySelector(
                    ".part.sidebar > .header-or-footer.header "
                        + ".monaco-action-bar .actions-container"
                );
                if (!actions
                    || actions.querySelector(`.${controlClass}-files`)) {
                    return;
                }
                actions.append(...controls.map(makeAction));
            };

            sync();
            new MutationObserver(sync).observe(workbench, {
                childList: true,
                subtree: true
            });
            return true;
        };

        if (!attach()) {
            const watch = () => {
                if (attach()) {
                    return;
                }
                waitObserver = new MutationObserver(attach);
                waitObserver.observe(document.documentElement, {
                    childList: true,
                    subtree: true
                });
            };
            if (document.documentElement) {
                watch();
            } else {
                window.addEventListener("DOMContentLoaded", watch, { once: true });
            }
        }
    })();
    """#

    @MainActor
    static func install(in configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(WKUserScript(
            source: statusBarSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
    }
}

enum WarrenEmbeddedEditorPointerBoundary {
    enum Action: Equatable {
        case cancelInactiveEditors
        case cancelAllAfterDispatch
        case none
    }

    static func action(for eventType: NSEvent.EventType) -> Action {
        switch eventType {
        case .leftMouseDown:
            .cancelInactiveEditors
        case .leftMouseUp:
            .cancelAllAfterDispatch
        default:
            .none
        }
    }
}

enum WarrenEmbeddedEditorPageVisibility {
    @MainActor
    static func conceal(_ webView: WKWebView) {
        webView.isHidden = true
    }

    @MainActor
    static func reveal(_ webView: WKWebView) {
        webView.isHidden = false
    }
}

@MainActor
private final class WarrenEmbeddedEditorNavigationDelegate:
    NSObject,
    WKNavigationDelegate,
    WKScriptMessageHandler
{
    private var revealFallbacks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(
        _ webView: WKWebView,
        didStartProvisionalNavigation navigation: WKNavigation?
    ) {
        cancelRevealFallback(for: webView)
        WarrenEmbeddedEditorPageVisibility.conceal(webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        scheduleRevealFallback(for: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let destination = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if destination.host == "127.0.0.1" {
            decisionHandler(.allow)
        } else {
            NSWorkspace.shared.open(destination)
            decisionHandler(.cancel)
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == WarrenEmbeddedEditorChrome.reloadMessageHandlerName,
              let action = message.body as? String,
              let webView = message.webView else { return }
        switch action {
        case WarrenEmbeddedEditorChrome.readyMessage:
            cancelRevealFallback(for: webView)
            WarrenEmbeddedEditorPageVisibility.reveal(webView)
        case "reload":
            cancelRevealFallback(for: webView)
            WarrenEmbeddedEditorPointerBridge.cancel(in: webView)
            WarrenEmbeddedEditorPageVisibility.conceal(webView)
            webView.stopLoading()
            webView.reloadFromOrigin()
        default:
            break
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelRevealFallback(for: webView)
        WarrenEmbeddedEditorPointerBridge.cancel(in: webView)
        WarrenEmbeddedEditorPageVisibility.conceal(webView)
        webView.reload()
    }

    private func scheduleRevealFallback(for webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        cancelRevealFallback(for: webView)
        revealFallbacks[identifier] = Task { @MainActor [weak self, weak webView] in
            defer { self?.revealFallbacks.removeValue(forKey: identifier) }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled,
                  let webView,
                  webView.isHidden else { return }
            WarrenEmbeddedEditorPageVisibility.reveal(webView)
        }
    }

    private func cancelRevealFallback(for webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        revealFallbacks.removeValue(forKey: identifier)?.cancel()
    }
}

private final class WarrenEmbeddedEditorWKWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil, newWindow == nil {
            WarrenEmbeddedEditorPointerBridge.cancel(in: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

@MainActor
final class WarrenEmbeddedEditorModel: ObservableObject {
    typealias ExecutableResolver = ([String: String]) -> URL?

    enum Phase: Equatable {
        case idle
        case preparing
        case starting
        case ready(URL)
        case unavailable
        case failed(String)
    }

    @Published private(set) var activeWorkspacePath: String?
    @Published private(set) var phase: Phase = .idle

    private var webViews: [String: WKWebView] = [:]
    private var requestedWorkspacePaths: Set<String> = []
    private var process: Process?
    private var launchTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var extensionTask: Task<Void, Never>?
    private var mouseEventMonitor: Any?
    private var generation = UUID()
    private let environment: [String: String]
    private let supportDirectory: URL
    private let executableResolver: ExecutableResolver
    private let navigationDelegate = WarrenEmbeddedEditorNavigationDelegate()

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportDirectory: URL? = nil,
        executableResolver: @escaping ExecutableResolver = WarrenEmbeddedEditorExecutableResolver.resolve
    ) {
        self.environment = environment
        self.supportDirectory = supportDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Warren/EmbeddedEditor", isDirectory: true)
        self.executableResolver = executableResolver
    }

    isolated deinit {
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
        }
    }

    func activate(workspacePath: String, force: Bool = false) {
        activeWorkspacePath = workspacePath
        requestedWorkspacePaths.insert(workspacePath)

        if !force {
            switch phase {
            case .preparing, .starting:
                return
            case .ready(let serverURL):
                ensureWebView(workspacePath: workspacePath, serverURL: serverURL)
                return
            case .idle, .unavailable, .failed:
                break
            }
        }

        let requestedPaths = requestedWorkspacePaths
        stop(resetPhase: false)
        requestedWorkspacePaths = requestedPaths
        activeWorkspacePath = workspacePath
        phase = .preparing
        let requestGeneration = UUID()
        generation = requestGeneration
        launchTask = Task { [weak self] in
            await self?.launch(generation: requestGeneration)
        }
    }

    func stop() {
        stop(resetPhase: true)
    }

    func webView(workspacePath: String) -> WKWebView? {
        webViews[workspacePath]
    }

    private func stop(resetPhase: Bool) {
        generation = UUID()
        launchTask?.cancel()
        launchTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        extensionTask?.cancel()
        extensionTask = nil
        clearWebViews()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        activeWorkspacePath = nil
        requestedWorkspacePaths = []
        if resetPhase {
            phase = .idle
        }
    }

    private func launch(generation: UUID) async {
        guard let executableURL = executableResolver(environment) else {
            guard isCurrent(generation) else { return }
            phase = .unavailable
            return
        }

        do {
            let port = try Self.reserveLoopbackPort()
            let configuration = WarrenEmbeddedEditorConfiguration(
                executableURL: executableURL,
                userDataDirectory: supportDirectory.appendingPathComponent(
                    "user-data",
                    isDirectory: true
                ),
                extensionsDirectory: supportDirectory.appendingPathComponent(
                    "extensions",
                    isDirectory: true
                ),
                port: port
            )
            try await Self.prepare(configuration: configuration)
            guard isCurrent(generation), !Task.isCancelled else { return }

            phase = .starting
            let process = Process()
            process.executableURL = configuration.executableURL
            process.arguments = configuration.serverArguments
            process.environment = environment.merging([
                "CS_DISABLE_GETTING_STARTED_OVERRIDE": "1",
            ]) { _, new in new }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            self.process = process

            try await waitUntilReady(
                at: configuration.serverURL,
                process: process,
                generation: generation
            )
            guard isCurrent(generation), !Task.isCancelled else { return }
            for path in requestedWorkspacePaths.sorted() {
                ensureWebView(workspacePath: path, serverURL: configuration.serverURL)
            }
            phase = .ready(configuration.serverURL)
            installManagedExtensions(configuration: configuration)
            monitor(process: process, generation: generation)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(generation) else { return }
            process = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func isCurrent(_ requestGeneration: UUID) -> Bool {
        generation == requestGeneration
    }

    private func monitor(process: Process, generation: UUID) {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled, process.isRunning {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled,
                  let self,
                  self.isCurrent(generation) else { return }
            self.process = nil
            self.clearWebViews()
            self.phase = .failed("code-server stopped. Retry to reopen the editor.")
        }
    }

    private func ensureWebView(workspacePath: String, serverURL: URL) {
        guard webViews[workspacePath] == nil else { return }
        objectWillChange.send()
        webViews[workspacePath] = makeWebView(
            url: WarrenEmbeddedEditorConfiguration.workspaceURL(
                serverURL: serverURL,
                path: workspacePath
            )
        )
    }

    private func makeWebView(url: URL) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        WarrenEmbeddedEditorPointerBridge.install(in: configuration)
        WarrenEmbeddedEditorNativeSelectionBridge.install(in: configuration)
        WarrenEmbeddedEditorChrome.install(in: configuration)
        configuration.userContentController.add(
            navigationDelegate,
            name: WarrenEmbeddedEditorChrome.reloadMessageHandlerName
        )
        installMouseEventMonitorIfNeeded()
        let webView = WarrenEmbeddedEditorWKWebView(
            frame: .zero,
            configuration: configuration
        )
        webView.navigationDelegate = navigationDelegate
        let backgroundColor = NSColor(
            red: 21 / 255,
            green: 17 / 255,
            blue: 16 / 255,
            alpha: 1
        )
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.underPageBackgroundColor = backgroundColor
        WarrenEmbeddedEditorPageVisibility.conceal(webView)
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.load(URLRequest(url: url))
        return webView
    }

    private func clearWebViews() {
        for webView in webViews.values {
            WarrenEmbeddedEditorPointerBridge.cancel(in: webView)
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: WarrenEmbeddedEditorChrome.reloadMessageHandlerName
            )
        }
        webViews = [:]
        if let mouseEventMonitor {
            NSEvent.removeMonitor(mouseEventMonitor)
            self.mouseEventMonitor = nil
        }
    }

    private func installMouseEventMonitorIfNeeded() {
        guard mouseEventMonitor == nil else { return }
        mouseEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseBoundary(event)
            return event
        }
    }

    private func handleMouseBoundary(_ event: NSEvent) {
        let hitWebView = embeddedEditor(at: event)
        switch WarrenEmbeddedEditorPointerBoundary.action(for: event.type) {
        case .cancelInactiveEditors:
            for webView in webViews.values where webView !== hitWebView {
                WarrenEmbeddedEditorPointerBridge.cancel(in: webView)
            }
        case .cancelAllAfterDispatch:
            let affectedWebViews = hitWebView.map { [$0] } ?? Array(webViews.values)
            DispatchQueue.main.async {
                for webView in affectedWebViews {
                    WarrenEmbeddedEditorPointerBridge.cancel(in: webView)
                }
            }
        case .none:
            break
        }
    }

    private func embeddedEditor(at event: NSEvent) -> WKWebView? {
        guard let contentView = event.window?.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(point) else { return nil }
        return webViews.values.first { webView in
            hitView === webView || hitView.isDescendant(of: webView)
        }
    }

    private func waitUntilReady(
        at url: URL,
        process: Process,
        generation: UUID
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard isCurrent(generation), process.isRunning else {
                throw WarrenEmbeddedEditorError.exitedBeforeReady
            }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let response = response as? HTTPURLResponse,
               (200..<500).contains(response.statusCode) {
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw WarrenEmbeddedEditorError.startupTimedOut
    }

    nonisolated private static func prepare(
        configuration: WarrenEmbeddedEditorConfiguration
    ) async throws {
        try await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: configuration.userDataDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: configuration.extensionsDirectory,
                withIntermediateDirectories: true
            )
            try writeManagedSettings(configuration: configuration)
        }.value
    }

    private func installManagedExtensions(
        configuration: WarrenEmbeddedEditorConfiguration
    ) {
        extensionTask?.cancel()
        extensionTask = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            let installed = WarrenEmbeddedEditorExtensionRegistry.installedExtensionIDs(
                in: configuration.extensionsDirectory
            )

            for extensionID in WarrenEmbeddedEditorConfiguration.managedExtensionIDs
            where !installed.contains(extensionID.lowercased()) {
                guard !Task.isCancelled else { return }
                _ = try? await Self.runAndCapture(
                    executableURL: configuration.executableURL,
                    arguments: configuration.installArguments(extensionID: extensionID)
                )
            }
        }
    }

    nonisolated private static func writeManagedSettings(
        configuration: WarrenEmbeddedEditorConfiguration
    ) throws {
        let settingsDirectory = configuration.userDataDirectory
            .appendingPathComponent("User", isDirectory: true)
        let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: true
        )
        let existingSettings: [String: Any]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            let existingData = try Data(contentsOf: settingsURL)
            guard let object = try JSONSerialization.jsonObject(with: existingData)
                as? [String: Any] else {
                throw WarrenEmbeddedEditorError.invalidProfileSettings
            }
            existingSettings = object
        } else {
            existingSettings = [:]
        }
        let settings = WarrenEmbeddedEditorProfile.mergingManagedSettings(
            into: existingSettings
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        if (try? Data(contentsOf: settingsURL)) == data { return }
        try data.write(to: settingsURL, options: .atomic)
    }

    nonisolated private static func runAndCapture(
        executableURL: URL,
        arguments: [String]
    ) async throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
            }
            try Task.checkCancellation()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw WarrenEmbeddedEditorError.commandFailed
            }
            return String(decoding: data, as: UTF8.self)
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    nonisolated private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw WarrenEmbeddedEditorError.portUnavailable }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw WarrenEmbeddedEditorError.portUnavailable }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { throw WarrenEmbeddedEditorError.portUnavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}

private enum WarrenEmbeddedEditorError: LocalizedError {
    case commandFailed
    case exitedBeforeReady
    case invalidProfileSettings
    case portUnavailable
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .commandFailed:
            "An editor background task failed."
        case .exitedBeforeReady:
            "code-server exited before the editor was ready."
        case .invalidProfileSettings:
            "Warren could not update the embedded editor settings."
        case .portUnavailable:
            "Warren could not reserve a local editor port."
        case .startupTimedOut:
            "The embedded editor did not become ready in time."
        }
    }
}

struct WarrenEmbeddedEditorSurface: View {
    let workspace: Workspace
    @ObservedObject var model: WarrenEmbeddedEditorModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Group {
            phaseContent(model.phase, tokens: tokens)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tokens.background)
        .task(id: workspace.path) {
            model.activate(workspacePath: workspace.path)
        }
    }

    @ViewBuilder
    private func phaseContent(
        _ phase: WarrenEmbeddedEditorModel.Phase,
        tokens: WarrenColorTokens
    ) -> some View {
        switch phase {
        case .idle, .preparing:
            progress("Preparing editor…", tokens: tokens)
        case .starting:
            progress("Starting editor…", tokens: tokens)
        case .ready:
            if let webView = model.webView(workspacePath: workspace.path) {
                WarrenEmbeddedEditorWebViewHost(webView: webView)
            } else {
                progress("Restoring editor…", tokens: tokens)
            }
        case .unavailable:
            unavailable(tokens: tokens)
        case .failed(let message):
            failure(message, tokens: tokens)
        }
    }

    private func progress(_ label: String, tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.compact) {
            WarrenBrailleSpinner(size: 20, accessibilityLabel: label)
            Text(label)
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private func unavailable(tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 22, weight: .light))
            Text("code-server is required")
                .font(WarrenTypography.emptyStateTitle)
            Text("Install it with Homebrew, then retry. Warren keeps a separate editor profile and prepares language extensions after the editor opens.")
                .font(WarrenTypography.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(tokens.mutedForeground)
                .frame(maxWidth: 460)
            HStack(spacing: WarrenSpacing.compact) {
                Button("Copy install command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install code-server", forType: .string)
                }
                .buttonStyle(WarrenSecondaryButtonStyle())
                Button("Retry") {
                    model.activate(workspacePath: workspace.path, force: true)
                }
                .buttonStyle(WarrenPrimaryButtonStyle())
            }
        }
        .foregroundStyle(tokens.mutedForeground)
        .padding(WarrenSpacing.large)
        .accessibilityElement(children: .contain)
    }

    private func failure(_ message: String, tokens: WarrenColorTokens) -> some View {
        VStack(spacing: WarrenSpacing.standard) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(tokens.warning)
            Text("Editor unavailable")
                .font(WarrenTypography.emptyStateTitle)
            Text(message)
                .font(WarrenTypography.body)
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
            Button("Retry") {
                model.activate(workspacePath: workspace.path, force: true)
            }
            .buttonStyle(WarrenPrimaryButtonStyle())
        }
        .padding(WarrenSpacing.large)
        .accessibilityElement(children: .contain)
    }
}

private struct WarrenEmbeddedEditorWebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}
}
