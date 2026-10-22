import AppKit
import SwiftUI
import GhosttyAdapter
import WarrenDesktop
import WebKit

enum WebCommand {
    static let copyLocalURL = Notification.Name("Web.copyLocalURL")
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
    let kind: WarrenDesktopNotice.Kind

    init(
        title: String,
        message: String,
        actionLabel: String = "OK",
        kind: WarrenDesktopNotice.Kind = .info
    ) {
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.kind = kind
    }
}

enum WarrenWindowGeometry {
    /// Subtle corner radius for the borderless shell. The window keeps its
    /// own chrome edge-to-edge while the content is clipped into a rounded
    /// shape. 8pt stays clear of the 12pt traffic lights, which sit only 8pt
    /// from the top edge of the sidebar header.
    static let cornerRadius: CGFloat = 8
    /// Stable autosave name so AppKit persists the main window's frame across
    /// launches under `NSWindow Frame WarrenMainWindow`. Without this, a window
    /// dragged to an external display resets to the hard-coded contentRect on
    /// next launch and the autosaved position is lost.
    static let frameAutosaveName = "WarrenMainWindow"
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
/// tab bar chrome and sidebar header form one continuous surface from pixel zero;
/// the traffic lights are drawn inside the sidebar header.
@main
enum WarrenMain {
    @MainActor
    static func main() {
        TerminalDiagnostics.configure(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments
        )
        TerminalDiagnostics.log(
            "build_identity",
            WarrenBuildIdentity.current.diagnosticFields
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
private final class WarrenAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSMenuItemValidation {
    private var window: NSWindow?
    private var daemonMenuBarProcess: Process?
    private let updater = WarrenUpdater()
    private var availableRelease: WarrenRelease?
    private var updateMenuItem: NSMenuItem?
    private var updateCheckTask: Task<Void, Never>?
    private var updateInstallTask: Task<Void, Never>?
    private var cliInstallTask: Task<Void, Never>?
    private var updateNotificationObserver: NSObjectProtocol?
    private var endpointCapabilitiesObserver: NSObjectProtocol?
    private var screenChangeObserver: NSObjectProtocol?
    private var volumeMountObserver: NSObjectProtocol?
    /// Disk images already prompted for, keyed by volume path and version, so
    /// one mount of one image asks exactly once.
    private var offeredDiskImages: Set<String> = []
    private weak var copyLocalWebURLMenuItem: NSMenuItem?
    private weak var copyLocalWebURLSeparator: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the first window is built, so the initial paint is already in
        // the chosen appearance rather than flashing the default one.
        WarrenDesktopAppearance.applyStoredMode()
        WarrenDesktopDockIcon.applyStoredColorway()
        launchDaemonMenuBar()
        presentMainWindowIfNeeded()
        NSApp.mainMenu = buildMainMenu(target: self)
        // The catalog is shared with the CLI and is the authoritative endpoint
        // selection.
        let catalog = WarrenEndpointCatalog.load()
        let selectedEndpoint = catalog.current ?? "local"
        applyEndpointCapabilities(selectedEndpoint == "local" ? .local : .remote)
        endpointCapabilitiesObserver = NotificationCenter.default.addObserver(
            forName: WarrenDesktopEndpointCapabilitiesNotification.didChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let capabilities = notification.object as? WarrenDesktopEndpointCapabilities else {
                return
            }
            Task { @MainActor in
                self?.applyEndpointCapabilities(capabilities)
            }
        }
        updateNotificationObserver = NotificationCenter.default.addObserver(
            forName: WarrenUpdateNotification.installRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installAvailableUpdate()
            }
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverOrphanWindowIfNeeded()
            }
        }
        volumeMountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else {
                return
            }
            Task { @MainActor in
                self?.offerDiskImageUpdateIfPresent(onVolume: volumeURL)
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
        let terminalRequests = urls.compactMap(WarrenTerminalOpenRequest.init(url:))
        let settingsRequests = urls.compactMap(WarrenDesktopSettingsDeepLink.init(url:))
        guard !terminalRequests.isEmpty || !settingsRequests.isEmpty else { return }
        DispatchQueue.main.async {
            for request in terminalRequests {
                NotificationCenter.default.post(
                    name: WarrenAppCommand.openTerminal,
                    object: request
                )
            }
            for request in settingsRequests {
                NotificationCenter.default.post(
                    name: WarrenDesktopCommand.openSettings,
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
        if let endpointCapabilitiesObserver {
            NotificationCenter.default.removeObserver(endpointCapabilitiesObserver)
        }
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
        if let volumeMountObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(volumeMountObserver)
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
                    name: WarrenUpdateNotification.dismiss,
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
                try self.applyStagedUpdate(stagedApplication)
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
                    object: nil,
                    userInfo: [WarrenUpdateNotification.keyError: error.localizedDescription]
                )
            }
        }
    }

    /// Mounting a Warren disk image while Warren runs asks whether to install
    /// the app it carries. The prompt names both versions, so a same-version or
    /// older image is a visible choice instead of a silent no-op, and nothing
    /// is installed until the user picks Install.
    private func offerDiskImageUpdateIfPresent(onVolume volumeURL: URL) {
        guard updateInstallTask == nil,
              let update = updater.diskImageUpdate(onVolume: volumeURL) else { return }
        let promptKey = "\(volumeURL.path)#\(update.version)"
        guard !offeredDiskImages.contains(promptKey) else { return }
        offeredDiskImages.insert(promptKey)
        presentMainWindowIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        guard WarrenDiskImagePrompt.confirm(update) else {
            // Asking again on a later mount keeps the image usable after the
            // user dismissed this one.
            offeredDiskImages.remove(promptKey)
            return
        }
        installDiskImageUpdate(update)
    }

    private func installDiskImageUpdate(_ update: WarrenDiskImageUpdate) {
        guard updateInstallTask == nil else { return }
        updateMenuItem?.isEnabled = false
        updateMenuItem?.title = "Installing Update \(update.displayVersion)…"
        NotificationCenter.default.post(name: WarrenUpdateNotification.installing, object: nil)
        updateInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.updateInstallTask = nil }
            do {
                let stagedApplication = try await self.updater.prepareDiskImageUpdate(update)
                // The staged copy no longer needs the disk image; ejecting it
                // also closes its Finder window.
                try? NSWorkspace.shared.unmountAndEjectDevice(at: update.volumeURL)
                try self.applyStagedUpdate(stagedApplication)
            } catch {
                self.updateMenuItem?.isEnabled = true
                if let release = self.availableRelease {
                    self.updateMenuItem?.title = "Install Update \(release.displayVersion)…"
                    NotificationCenter.default.post(
                        name: WarrenUpdateNotification.available,
                        object: nil,
                        userInfo: [WarrenUpdateNotification.keyRelease: release]
                    )
                } else {
                    self.updateMenuItem?.title = "Check for Updates…"
                }
                NSLog("Unable to install Warren from disk image: %@", error.localizedDescription)
                NotificationCenter.default.post(
                    name: WarrenUpdateNotification.failed,
                    object: nil,
                    userInfo: [WarrenUpdateNotification.keyError: error.localizedDescription]
                )
            }
        }
    }

    private func applyStagedUpdate(_ stagedApplication: URL) throws {
        // Keep the user-level CLI in lockstep with the application
        // before the detached installer replaces the running bundle.
        _ = try WarrenCLIInstaller.install(
            bundleExecutableURL: stagedApplication
                .appendingPathComponent("Contents/MacOS/Warren")
        )
        try updater.launchInstaller(stagedApplicationURL: stagedApplication)
        updateMenuItem?.title = "Restarting Warren…"
        NSApp.terminate(nil)
    }

    private func makeMainWindow() -> NSWindow {
        // No `preferredColorScheme` here: the appearance preference drives
        // `NSApp.appearance`, which SwiftUI reads. Pinning a scheme on the root
        // view would override the user's choice for the SwiftUI subtree only,
        // leaving AppKit chrome on the other appearance.
        let root = WarrenCompositionRoot()
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
        // Register the autosave name before any frame is committed. AppKit
        // restores the saved frame on the first order-to-screen call, which
        // would otherwise be overridden by an unconditional center().
        window.setFrameAutosaveName(WarrenWindowGeometry.frameAutosaveName)
        if UserDefaults.standard.string(
            forKey: "NSWindow Frame \(WarrenWindowGeometry.frameAutosaveName)"
        ) == nil {
            window.center()
        }
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
            ensureWindowIsOnVisibleScreen(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        if window == nil {
            window = makeMainWindow()
        }
        if let window {
            ensureWindowIsOnVisibleScreen(window)
        }
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        window?.orderFrontRegardless()
    }

    /// If the window is no longer on any currently-attached screen, recenter
    /// it on the main screen. Catches the "dock click makes the window
    /// disappear" case where AppKit auto-restored a frame from a screen that
    /// was later unplugged.
    private func ensureWindowIsOnVisibleScreen(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else { return }
        let intersectsAny = visibleFrames.contains { window.frame.intersects($0) }
        if intersectsAny { return }
        if let main = NSScreen.main {
            window.setFrame(
                NSRect(
                    x: main.visibleFrame.midX - window.frame.width / 2,
                    y: main.visibleFrame.midY - window.frame.height / 2,
                    width: min(window.frame.width, main.visibleFrame.width),
                    height: min(window.frame.height, main.visibleFrame.height)
                ),
                display: true
            )
        }
    }

    /// Pull-back for `didChangeScreenParametersNotification`. Also called from
    /// the lifecycle hooks via `presentMainWindowIfNeeded`; idempotent.
    private func recoverOrphanWindowIfNeeded() {
        guard let window, window.isVisible else { return }
        ensureWindowIsOnVisibleScreen(window)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentMainWindowIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Activation restores the window that had the keyboard, and AppKit
        // finishes doing that after this callback. Re-fronting the workspace
        // window here took the keyboard from Settings, so the menu bar and the
        // key equivalents served a window the user had behind the one they
        // were working in. Ask once activation has settled, and only take the
        // foreground when no window of ours did.
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let keyWindow = NSApp.keyWindow, keyWindow !== self.window {
                if let window = self.window {
                    self.ensureWindowIsOnVisibleScreen(window)
                }
                return
            }
            self.presentMainWindowIfNeeded()
        }
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
        let sourceEnvironment = ProcessInfo.processInfo.environment
        let executable: URL?
        if let configured = sourceEnvironment["WARREN_DAEMON_MENUBAR_PATH"], !configured.isEmpty {
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
        var childEnvironment = WarrenProcessEnvironment.daemonEnvironment(from: sourceEnvironment)
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
        let command = Notification.Name(rawValue)
        // Validation greys these items out; the guard keeps a menu that was
        // validated for another window, or a key equivalent that skipped
        // validation, from acting on the panes behind the window in front.
        guard WarrenMenuScope.shouldPost(command, workspace: window, key: NSApp.keyWindow) else {
            return
        }
        NotificationCenter.default.post(name: command, object: nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // ⌘W follows the key window: a Pane here, the window itself elsewhere.
        // The title is set here so the View menu never claims to close a Pane
        // it cannot see.
        if menuItem.action == #selector(closeKeyWindow(_:)) {
            menuItem.title = isWorkspaceWindowKey ? "Close Pane" : "Close Window"
            return true
        }
        // Pane, tab and Session commands belong to the workspace window, so a
        // Settings window in front has nothing for them to act on.
        if !isWorkspaceWindowKey, isWorkspaceCommand(menuItem) {
            return false
        }
        guard WarrenEmbeddedEditorFocus.contains(window?.firstResponder) else { return true }
        if menuItem.action == #selector(selectTabNumber(_:)) {
            return true
        }
        if let raw = menuItem.representedObject as? String {
            switch raw {
            case WarrenDesktopCommand.splitBelow.rawValue,
                 WarrenDesktopCommand.splitRight.rawValue,
                 WarrenDesktopCommand.closePane.rawValue,
                 WarrenDesktopCommand.maximizePane.rawValue,
                 WarrenDesktopCommand.otherPane.rawValue:
                return true
            default:
                break
            }
        }
        return menuItem.action != #selector(postCommand(_:))
    }

    /// Whether the key window is the workspace window, or a sheet or popover
    /// attached to it, so its commands have somewhere to act.
    private var isWorkspaceWindowKey: Bool {
        WarrenMenuScope.isWorkspaceWindowKey(workspace: window, key: NSApp.keyWindow)
    }

    private func isWorkspaceCommand(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(selectTabNumber(_:)) {
            return true
        }
        guard let rawValue = menuItem.representedObject as? String else { return false }
        return WarrenMenuScope.isWorkspaceCommand(Notification.Name(rawValue))
    }

    private func applyEndpointCapabilities(_ capabilities: WarrenDesktopEndpointCapabilities) {
        let isVisible = capabilities.canCopyLocalWebURL
        copyLocalWebURLMenuItem?.isHidden = !isVisible
        copyLocalWebURLSeparator?.isHidden = !isVisible
    }

    @objc private func toggleFullScreen(_ sender: NSMenuItem) {
        (NSApp.keyWindow ?? window)?.toggleFullScreen(nil)
    }

    /// ⌘W. The workspace window closes the selected Pane; any other window
    /// closes itself, which is what the shortcut means in Xcode and Safari.
    @objc private func closeKeyWindow(_ sender: NSMenuItem) {
        guard isWorkspaceWindowKey else {
            NSApp.keyWindow?.performClose(nil)
            return
        }
        NotificationCenter.default.post(name: WarrenDesktopCommand.closePane, object: nil)
    }

    @objc private func selectTabNumber(_ sender: NSMenuItem) {
        guard isWorkspaceWindowKey,
              let index = (sender.representedObject as? NSNumber)?.intValue else { return }
        NotificationCenter.default.post(
            name: WarrenDesktopCommand.selectTab,
            object: nil,
            userInfo: [WarrenDesktopCommand.selectTabIndexKey: index]
        )
    }

    @objc private func copyLocalWebURL(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: WebCommand.copyLocalURL, object: nil)
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
        let kind: WarrenDesktopNotice.Kind = switch style {
        case .critical: .error
        case .warning: .warning
        default: .info
        }
        NotificationCenter.default.post(
            name: WarrenAppPresentation.message,
            object: WarrenAppMessage(title: title, message: message, kind: kind)
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
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = target
        settingsItem.representedObject = WarrenDesktopCommand.openSettings.rawValue
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Warren",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = WarrenStandardEditMenu.make()
        mainMenu.addItem(editMenuItem)

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
        // The dwell-free entry to the collapsed sidebar. It stays off Esc and
        // the shell's own chords, and the button's hover still peeks.
        let peekSidebarItem = sessionMenu.addItem(
            withTitle: "Reveal Sidebar",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "s"
        )
        peekSidebarItem.target = target
        peekSidebarItem.keyEquivalentModifierMask = [.control, .command]
        peekSidebarItem.representedObject = WarrenDesktopCommand.peekSidebar.rawValue
        let inspectorItem = sessionMenu.addItem(
            withTitle: "Toggle Right Sidebar",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "b"
        )
        inspectorItem.keyEquivalentModifierMask = [.command, .option]
        inspectorItem.target = target
        inspectorItem.representedObject = WarrenDesktopCommand.toggleInspector.rawValue
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

        // Split commands ship with Command shortcuts so they never take a key
        // away from the shell. The optional Emacs C-x chords (Settings ›
        // Splits) reach the same notifications.
        viewMenu.addItem(.separator())
        let splitRightItem = viewMenu.addItem(
            withTitle: "Split Right",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "d"
        )
        splitRightItem.target = target
        splitRightItem.keyEquivalentModifierMask = [.command]
        splitRightItem.representedObject = WarrenDesktopCommand.splitRight.rawValue

        let splitBelowItem = viewMenu.addItem(
            withTitle: "Split Below",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "d"
        )
        splitBelowItem.target = target
        splitBelowItem.keyEquivalentModifierMask = [.command, .shift]
        splitBelowItem.representedObject = WarrenDesktopCommand.splitBelow.rawValue

        // ⌘W closes a Pane in the workspace window and the window itself
        // everywhere else; validation sets the title that matches.
        let closePaneItem = viewMenu.addItem(
            withTitle: "Close Pane",
            action: #selector(WarrenAppDelegate.closeKeyWindow(_:)),
            keyEquivalent: "w"
        )
        closePaneItem.target = target
        closePaneItem.keyEquivalentModifierMask = [.command]

        let maximizePaneItem = viewMenu.addItem(
            withTitle: "Maximize Pane",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "\r"
        )
        maximizePaneItem.target = target
        maximizePaneItem.keyEquivalentModifierMask = [.command, .shift]
        maximizePaneItem.representedObject = WarrenDesktopCommand.maximizePane.rawValue

        let otherPaneItem = viewMenu.addItem(
            withTitle: "Cycle Pane Focus",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "]"
        )
        otherPaneItem.target = target
        otherPaneItem.keyEquivalentModifierMask = [.command]
        otherPaneItem.representedObject = WarrenDesktopCommand.otherPane.rawValue

        let nextPaneGroupItem = viewMenu.addItem(
            withTitle: "Next Pane Group",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "`"
        )
        nextPaneGroupItem.target = target
        nextPaneGroupItem.keyEquivalentModifierMask = [.command]
        nextPaneGroupItem.representedObject = WarrenDesktopCommand.nextPaneGroup.rawValue

        let previousPaneGroupItem = viewMenu.addItem(
            withTitle: "Previous Pane Group",
            action: #selector(WarrenAppDelegate.postCommand(_:)),
            keyEquivalent: "`"
        )
        previousPaneGroupItem.target = target
        previousPaneGroupItem.keyEquivalentModifierMask = [.command, .shift]
        previousPaneGroupItem.representedObject = WarrenDesktopCommand.previousPaneGroup.rawValue

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
        copyLocalWebURLMenuItem = copyWebURL
        let copyWebURLSeparator = NSMenuItem.separator()
        webMenu.addItem(copyWebURLSeparator)
        copyLocalWebURLSeparator = copyWebURLSeparator
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

/// The one question a mounted Warren disk image asks. Both versions are named
/// so the relation is read from numbers, not from which button appeared.
@MainActor
private enum WarrenDiskImagePrompt {
    static func confirm(_ update: WarrenDiskImageUpdate) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = update.relation == .older ? .warning : .informational
        alert.messageText = "Install Warren \(update.displayVersion)?"
        alert.informativeText = message(for: update)
        alert.addButton(withTitle: update.relation == .older ? "Install Older Version" : "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func message(for update: WarrenDiskImageUpdate) -> String {
        let installed = update.displayInstalledVersion
        let relation: String
        switch update.relation {
        case .newer:
            relation = "This disk image is newer than the installed Warren (\(installed))."
        case .same:
            relation = "This disk image matches the installed Warren (\(installed))."
        case .older:
            relation = "This disk image is older than the installed Warren (\(installed)), so installing downgrades it."
        }
        return "\(relation) Running Sessions keep running through the install."
    }
}

/// Which menu commands belong to the workspace window.
///
/// A Settings window is key while the user is in it, and the menu bar serves
/// that window: pane, tab and Session commands have nothing to act on then, so
/// they are disabled and their shortcuts do nothing. Commands that reach the
/// app or the key window itself — Settings…, Quit, the Edit menu, full screen,
/// copying a Web URL — are unchanged.
@MainActor
enum WarrenMenuScope {
    static let workspaceCommands: Set<Notification.Name> = [
        WarrenDesktopCommand.newSession,
        WarrenDesktopCommand.nextTab,
        WarrenDesktopCommand.previousTab,
        WarrenDesktopCommand.selectTab,
        WarrenDesktopCommand.commandPalette,
        WarrenDesktopCommand.findInTerminal,
        WarrenDesktopCommand.toggleSidebar,
        WarrenDesktopCommand.peekSidebar,
        WarrenDesktopCommand.toggleInspector,
        WarrenDesktopCommand.splitRight,
        WarrenDesktopCommand.splitBelow,
        WarrenDesktopCommand.closePane,
        WarrenDesktopCommand.maximizePane,
        WarrenDesktopCommand.otherPane,
        WarrenDesktopCommand.nextPaneGroup,
        WarrenDesktopCommand.previousPaneGroup,
    ]

    static func isWorkspaceCommand(_ command: Notification.Name) -> Bool {
        workspaceCommands.contains(command)
    }

    /// Whether a menu command may reach its observers. The workspace commands
    /// only do while the workspace window owns the keyboard, so a click that
    /// skipped menu validation cannot close a Pane behind another window.
    static func shouldPost(
        _ command: Notification.Name,
        workspace: NSWindow?,
        key: NSWindow?
    ) -> Bool {
        guard isWorkspaceCommand(command) else { return true }
        return isWorkspaceWindowKey(workspace: workspace, key: key)
    }

    /// Whether `key` belongs to the workspace window: it is that window, or a
    /// sheet or popover attached to it. No key window at all means the app is
    /// inactive, where no key equivalent can arrive from another app's window.
    static func isWorkspaceWindowKey(workspace: NSWindow?, key: NSWindow?) -> Bool {
        guard let workspace, let key else { return true }
        return key === workspace || key.sheetParent === workspace || key.parent === workspace
    }
}

enum WarrenStandardEditMenu {
    @MainActor
    static func make() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = menu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        return menu
    }
}

enum WarrenEmbeddedEditorFocus {
    @MainActor
    static func contains(_ responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}

private final class WarrenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Clamp drag/resize/setFrame: results to the destination screen's
    /// visibleFrame so the title bar (and at least a thin strip of the
    /// window) always stays grabbable. This is the primary defense against
    /// the multi-monitor case where a window dragged to a smaller screen
    /// would otherwise land fully off-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        let target = screen ?? self.screen ?? NSScreen.main
        guard let visible = target?.visibleFrame else { return frameRect }
        var constrained = frameRect
        let minVisibleStrip: CGFloat = 28
        if constrained.maxX <= visible.minX + 1 {
            constrained.origin.x = visible.minX
        } else if constrained.minX >= visible.maxX - 1 {
            constrained.origin.x = visible.maxX - constrained.width
        }
        if constrained.maxY <= visible.minY + 1 {
            constrained.origin.y = visible.minY
        } else if constrained.minY >= visible.maxY - minVisibleStrip {
            constrained.origin.y = visible.maxY - minVisibleStrip
        }
        constrained.size.width = min(constrained.size.width, visible.width)
        constrained.size.height = min(constrained.size.height, visible.height)
        return constrained
    }
}
