import AppKit
import SwiftUI
import GhosttyAdapter
import WarrenDesktop

enum WebCommand {
    static let copyLocalURL = Notification.Name("Web.copyLocalURL")
    static let startCloudflare = Notification.Name("Web.startCloudflare")
    static let stopCloudflare = Notification.Name("Web.stopCloudflare")
    static let startTailscale = Notification.Name("Web.startTailscaleServe")
    static let stopTailscale = Notification.Name("Web.stopTailscaleServe")
    static let copySecureURL = Notification.Name("Web.copySecureURL")
}

enum WarrenAppPresentation {
    static let message = Notification.Name("WarrenAppPresentation.message")
}

struct WarrenAppMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let actionLabel: String

    init(title: String, message: String, actionLabel: String = "OK") {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
    }
}

private enum WarrenWindowGeometry {
    /// Subtle corner radius for the borderless shell. The window keeps its
    /// own chrome edge-to-edge while the content is clipped into a rounded
    /// shape. 8pt stays clear of the 12pt traffic lights, which sit only 8pt
    /// from the top edge of the sidebar header.
    static let cornerRadius: CGFloat = 8
}

private extension NSWindow {
    /// Rounds the content view corners. Full-screen windows stay rectangular
    /// so the corners never cut into the display edge.
    func applyWindowCornerRadius(_ radius: CGFloat) {
        contentView?.wantsLayer = true
        contentView?.layer?.cornerRadius = radius
        contentView?.layer?.masksToBounds = true
        invalidateShadow()
    }
}

/// AppKit bootstrap for the macOS app.
///
/// A SwiftUI `WindowGroup` always reserves a system titlebar strip even with
/// `.hiddenTitleBar`. Warren runs a real borderless `NSWindow` instead, so the
/// 40pt chrome and sidebar header form one continuous surface from pixel zero;
/// the traffic lights are drawn inside the sidebar header.
@main
enum WarrenMain {
    @MainActor
    static func main() {
        TerminalDiagnostics.configure(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments
        )
        guard let instanceLock = WarrenSingleInstanceLock() else {
            WarrenSingleInstanceLock.activateExistingApplication()
            return
        }
        let app = NSApplication.shared
        let delegate = WarrenAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(instanceLock) {
            app.run()
        }
    }
}

@MainActor
private final class WarrenAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var daemonMenuBarProcess: Process?
    private let updater = WarrenUpdater()
    private var availableRelease: WarrenRelease?
    private var updateMenuItem: NSMenuItem?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var cliInstallTask: Task<Void, Never>?
    private var updateNotificationObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchDaemonMenuBar()
        presentMainWindowIfNeeded()
        NSApp.mainMenu = buildMainMenu(target: self)
        updateNotificationObserver = NotificationCenter.default.addObserver(
            forName: WarrenUpdateNotification.installRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installAvailableUpdate()
            }
        }
        installCLIIfNeededInBackground()
        checkForUpdatesAutomatically()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        presentMainWindowIfNeeded()
        application.activate(ignoringOtherApps: true)
        // Defer delivery until the SwiftUI root has installed its observer.
        // This matters when LaunchServices starts Warren specifically for the
        // URL rather than delivering it to an already visible window.
        let requests = urls.compactMap(WarrenTerminalOpenRequest.init(url:))
        guard !requests.isEmpty else { return }
        DispatchQueue.main.async {
            for request in requests {
                NotificationCenter.default.post(
                    name: WarrenAppCommand.openTerminal,
                    object: request
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTask?.cancel()
        updateInstallTask?.cancel()
        cliInstallTask?.cancel()
        if let updateNotificationObserver {
            NotificationCenter.default.removeObserver(updateNotificationObserver)
        }
    }

    private func installCLIIfNeededInBackground() {
        cliInstallTask?.cancel()
        cliInstallTask = Task.detached(priority: .utility) {
            WarrenAppDelegate.installCLIIfNeeded()
        }
    }

    private nonisolated static func installCLIIfNeeded() {
        do {
            guard let result = try WarrenCLIInstaller.installIfNeeded() else { return }
            NSLog("Installed Warren CLI at %@", result.executableURL.path)
        } catch {
            // Keep launch non-blocking. The Tools > Install CLI action remains
            // available when a read-only home or a restricted shell profile
            // prevents automatic installation.
            NSLog("Unable to install Warren CLI automatically: %@", error.localizedDescription)
        }
    }

    private func checkForUpdatesAutomatically() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            do {
                if let release = try await self.updater.checkForUpdates() {
                    self.publishAvailableUpdate(release)
                }
            } catch {
                NSLog("Unable to check for Warren updates automatically: %@", error.localizedDescription)
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.failed,
                    object: nil
                )
            }
        }
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        guard updateInstallTask == nil else { return }
        if availableRelease != nil {
            installAvailableUpdate()
            return
        }
        updateMenuItem?.isEnabled = false
        updateMenuItem?.title = "Checking for Updates…"
        updateCheckTask?.cancel()
        updateCheckTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.updateMenuItem?.isEnabled = true
                self.updateMenuItem?.title = self.availableRelease.map {
                    "Install Update \($0.displayVersion)…"
                } ?? "Check for Updates…"
            }
            do {
                if let release = try await self.updater.checkForUpdates(force: true) {
                    self.publishAvailableUpdate(release)
                } else {
                    NotificationCenter.default.post(
                        name: WarrenUpdateNotification.dismiss,
                        object: nil
                    )
                }
            } catch {
                NSLog("Unable to check for Warren updates: %@", error.localizedDescription)
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.failed,
                    object: nil
                )
            }
        }
    }

    private func publishAvailableUpdate(_ release: WarrenRelease) {
        availableRelease = release
        updateMenuItem?.title = "Install Update \(release.displayVersion)…"
        NotificationCenter.default.post(
            name: WarrenUpdateNotification.available,
            object: nil,
            userInfo: [WarrenUpdateNotification.keyRelease: release]
        )
    }

    private func installAvailableUpdate() {
        guard let release = availableRelease, updateInstallTask == nil else { return }
        updateMenuItem?.isEnabled = false
        updateMenuItem?.title = "Downloading Update…"
        NotificationCenter.default.post(name: WarrenUpdateNotification.installing, object: nil)
        updateInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updateInstallTask = nil }
            do {
                let stagedApplication = try await self.updater.downloadAndPrepare(release)
                // Keep the user-level CLI in lockstep with the application
                // before the detached installer replaces the running bundle.
                _ = try WarrenCLIInstaller.install(
                    bundleExecutableURL: stagedApplication
                        .appendingPathComponent("Contents/MacOS/Warren")
                )
                try self.updater.launchInstaller(stagedApplicationURL: stagedApplication)
                self.updateMenuItem?.title = "Restarting Warren…"
                NSApp.terminate(nil)
            } catch {
                self.updateMenuItem?.isEnabled = true
                self.updateMenuItem?.title = "Install Update \(release.displayVersion)…"
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.available,
                    object: nil,
                    userInfo: [WarrenUpdateNotification.keyRelease: release]
                )
                NSLog("Unable to install Warren update: %@", error.localizedDescription)
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.failed,
                    object: nil
                )
            }
        }
    }

    private func makeMainWindow() -> NSWindow {
        let root = WarrenCompositionRoot()
            .preferredColorScheme(.dark)
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)

        let window = WarrenWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800),
            styleMask: [.borderless, .resizable, .miniaturizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.isMovableByWindowBackground = false
        // A borderless window is not full-screen-capable by default. Opt it
        // back into Spaces full-screen mode so the traffic-light toggle and
        // the ⌃⌘F menu item both work.
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Transparent backing lets the rounded content corners reveal the
        // desktop instead of painting a square background behind them.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView = hosting
        window.applyWindowCornerRadius(WarrenWindowGeometry.cornerRadius)
        window.delegate = self
        // Keep the window reference valid if AppKit ever closes it while the
        // process is still alive, so a later reopen can bring it back.
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        window?.applyWindowCornerRadius(0)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.applyWindowCornerRadius(WarrenWindowGeometry.cornerRadius)
    }

    /// Shows the main window, recreating it when a second launch activated an
    /// existing instance whose window was already gone. This is the recovery
    /// path for the single-instance lock: closing Warren must not leave a
    /// windowless process that later launches can only activate.
    private func presentMainWindowIfNeeded() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        if window == nil {
            window = makeMainWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        window?.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentMainWindowIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        presentMainWindowIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Let AppKit finish the termination without hiding the window first.
        // Ordering the window out before `.terminateNow` left a brief
        // windowless-but-alive process that the single-instance lock would
        // activate on relaunch instead of showing a fresh window.
        return .terminateNow
    }

    private func launchDaemonMenuBar() {
        guard daemonMenuBarProcess == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        let executable: URL?
        if let configured = environment["WARREN_DAEMON_MENUBAR_PATH"], !configured.isEmpty {
            executable = URL(fileURLWithPath: configured)
        } else {
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("WarrenDaemonMenuBar")
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WarrenDaemonMenuBar")
            executable = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling
                : (FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil)
        }
        guard let executable else { return }
        let process = Process()
        process.executableURL = executable
        var childEnvironment = environment
        childEnvironment["WARREN_APP_PATH"] = URL(fileURLWithPath: CommandLine.arguments[0]).path
        if childEnvironment["WARREN_HEADLESS_PATH"] == nil {
            let sibling = executable.deletingLastPathComponent().appendingPathComponent("warren-headless")
            if FileManager.default.isExecutableFile(atPath: sibling.path) {
                childEnvironment["WARREN_HEADLESS_PATH"] = sibling.path
            }
        }
        if childEnvironment["WARREN_WEB_ROOT"] == nil {
            let bundledResources = executable.deletingLastPathComponent()
                .appendingPathComponent("../Resources").standardizedFileURL
            let developmentResources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Web/dist")
            let resources = FileManager.default.fileExists(atPath: bundledResources.path)
                ? bundledResources : developmentResources
            if FileManager.default.fileExists(atPath: resources.appendingPathComponent("index.html").path) {
                childEnvironment["WARREN_WEB_ROOT"] = resources.path
            }
        }
        process.environment = childEnvironment
        do {
            try process.run()
            daemonMenuBarProcess = process
        } catch {
            NSLog("Unable to launch WarrenDaemonMenuBar: %@", error.localizedDescription)
        }
    }

    @objc private func postCommand(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String else { return }
        NotificationCenter.default.post(name: Notification.Name(rawValue), object: nil)
    }

    @objc private func toggleFullScreen(_ sender: NSMenuItem) {
        window?.toggleFullScreen(nil)
    }

    @objc private func selectTabNumber(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue else { return }
        NotificationCenter.default.post(
            name: WarrenDesktopCommand.selectTab,
            object: nil,
            userInfo: [WarrenDesktopCommand.selectTabIndexKey: index]
        )
    }

    @objc private func copyLocalWebURL(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.copyLocalURL, object: nil)
    }

    @objc private func startCloudflareWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.startCloudflare, object: nil)
    }

    @objc private func stopCloudflareWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.stopCloudflare, object: nil)
    }

    @objc private func startTailscaleWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.startTailscale, object: nil)
    }

    @objc private func stopTailscaleWebAccess(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.stopTailscale, object: nil)
    }

    @objc private func copySecureWebURL(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.copySecureURL, object: nil)
    }

    @objc private func installCLI(_ sender: NSMenuItem) {
        do {
            let result = try WarrenCLIInstaller.install()
            let pathMessage: String
            if let profileURL = result.pathProfileURL {
                pathMessage = "Added \(result.installDirectory.path) to \(profileURL.path). Open a new terminal for the PATH change to take effect."
            } else {
                pathMessage = "\(result.installDirectory.path) is already on your PATH."
            }
            showAlert(
                title: "CLI Installed",
                message: "The Warren CLI is ready at \(result.executableURL.path).\n\n\(pathMessage)",
                style: .informational
            )
        } catch {
            showAlert(
                title: "Unable to Install CLI",
                message: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func showAlert(
        title: String,
        message: String,
        style: NSAlert.Style
    ) {
        _ = style
        NotificationCenter.default.post(
            name: WarrenAppPresentation.message,
            object: WarrenAppMessage(title: title, message: message)
        )
    }

    private func buildMainMenu(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        let checkForUpdates = appMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(WarrenAppDelegate.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdates.target = target
        updateMenuItem = checkForUpdates
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Warren",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let sessionMenuItem = NSMenuItem()
        mainMenu.addItem(sessionMenuItem)
        let sessionMenu = NSMenu(title: "Session")
        let newSessionItem = sessionMenu.addItem(
            withTitle: "New Session…",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "t"
        )
        newSessionItem.target = target
        newSessionItem.representedObject = WarrenDesktopCommand.newSession.rawValue

        let nextTabItem = sessionMenu.addItem(
            withTitle: "Next Tab",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "x"
        )
        nextTabItem.target = target
        nextTabItem.keyEquivalentModifierMask = [.command]
        nextTabItem.representedObject = WarrenDesktopCommand.nextTab.rawValue

        let previousTabItem = sessionMenu.addItem(
            withTitle: "Previous Tab",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "x"
        )
        previousTabItem.target = target
        previousTabItem.keyEquivalentModifierMask = [.command, .shift]
        previousTabItem.representedObject = WarrenDesktopCommand.previousTab.rawValue

        sessionMenu.addItem(.separator())
        for index in 1...9 {
            let selectTabItem = sessionMenu.addItem(
                withTitle: "Select Tab \(index)",
                action: #selector(WarrenAppDelegate.selectTabNumber(_:)),
                keyEquivalent: String(index)
            )
            selectTabItem.target = target
            selectTabItem.keyEquivalentModifierMask = [.command]
            selectTabItem.representedObject = NSNumber(value: index)
        }
        sessionMenu.addItem(.separator())

        let closeTabItem = sessionMenu.addItem(
            withTitle: "Close Tab",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "w"
        )
        closeTabItem.target = target
        closeTabItem.representedObject = WarrenDesktopCommand.closeTab.rawValue

        sessionMenu.addItem(.separator())
        let paletteItem = sessionMenu.addItem(
            withTitle: "Command Palette…",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "k"
        )
        paletteItem.target = target
        paletteItem.representedObject = WarrenDesktopCommand.commandPalette.rawValue

        sessionMenu.addItem(.separator())
        let findItem = sessionMenu.addItem(
            withTitle: "Find in Terminal…",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "f"
        )
        findItem.target = target
        findItem.keyEquivalentModifierMask = [.command]
        findItem.representedObject = WarrenDesktopCommand.findInTerminal.rawValue

        sessionMenu.addItem(.separator())
        let sidebarItem = sessionMenu.addItem(
            withTitle: "Toggle Sidebar",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "b"
        )
        sidebarItem.target = target
        sidebarItem.representedObject = WarrenDesktopCommand.toggleSidebar.rawValue
        sessionMenuItem.submenu = sessionMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fullScreenItem = viewMenu.addItem(
            withTitle: "Toggle Full Screen",
            action: #selector(WarrenAppDelegate.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.target = target
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = viewMenu

        let webMenuItem = NSMenuItem()
        mainMenu.addItem(webMenuItem)
        let webMenu = NSMenu(title: "Web")
        let copyWebURL = webMenu.addItem(
            withTitle: "Copy Local Web URL",
            action: #selector(WarrenAppDelegate.copyLocalWebURL(_:)),
            keyEquivalent: ""
        )
        copyWebURL.target = target
        webMenu.addItem(.separator())
        let startCloudflare = webMenu.addItem(
            withTitle: "Start Cloudflare Tunnel",
            action: #selector(WarrenAppDelegate.startCloudflareWebAccess(_:)),
            keyEquivalent: ""
        )
        startCloudflare.target = target
        let stopCloudflare = webMenu.addItem(
            withTitle: "Stop Cloudflare Tunnel",
            action: #selector(WarrenAppDelegate.stopCloudflareWebAccess(_:)),
            keyEquivalent: ""
        )
        stopCloudflare.target = target
        let startTailscale = webMenu.addItem(
            withTitle: "Start Tailscale Serve",
            action: #selector(WarrenAppDelegate.startTailscaleWebAccess(_:)),
            keyEquivalent: ""
        )
        startTailscale.target = target
        let stopTailscale = webMenu.addItem(
            withTitle: "Stop Tailscale Serve",
            action: #selector(WarrenAppDelegate.stopTailscaleWebAccess(_:)),
            keyEquivalent: ""
        )
        stopTailscale.target = target
        webMenu.addItem(.separator())
        let copySecureURL = webMenu.addItem(
            withTitle: "Copy Secure Web URL",
            action: #selector(WarrenAppDelegate.copySecureWebURL(_:)),
            keyEquivalent: ""
        )
        copySecureURL.target = target
        webMenuItem.submenu = webMenu

        let toolsMenuItem = NSMenuItem()
        mainMenu.addItem(toolsMenuItem)
        let toolsMenu = NSMenu(title: "Tools")
        let installCLI = toolsMenu.addItem(
            withTitle: "Install CLI",
            action: #selector(WarrenAppDelegate.installCLI(_:)),
            keyEquivalent: ""
        )
        installCLI.target = target
        toolsMenuItem.submenu = toolsMenu
        return mainMenu
    }
}

private final class WarrenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
