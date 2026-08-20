import AppKit
import Foundation
import Darwin

@main
enum WarrenDaemonMenuBarMain {
    @MainActor
    static func main() {
        guard WarrenDaemonMenuBarLock.acquire() else { return }
        let application = NSApplication.shared
        let delegate = WarrenDaemonMenuBarDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
private final class WarrenDaemonMenuBarDelegate: NSObject, NSApplicationDelegate {
    private enum DaemonState {
        case checking
        case running
        case stopped
        case failed(String)
    }

    private let healthURL = URL(string: "http://127.0.0.1:8789/healthz")!
    private let stateURL = URL(string: "http://127.0.0.1:8789/v1/state")!
    private var statusItem: NSStatusItem!
    private var statusDot: NSView?
    private var daemonProcess: Process?
    private var pollTask: Task<Void, Never>?
    private var autoStartDisabled = false
    private var buildVersion: String?
    private var ghostlineRPCVersion: String?
    private var ghostlineTagVersion: String?
    private var state: DaemonState = .checking {
        didSet { updateStatusItem() }
    }
    private let statusDotPulseDuration: CFTimeInterval = 2.2
    private let statusDotPulseKey = "statusDotPulse"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = warrenMenuBarImage() {
            statusItem.button?.image = image
            statusItem.button?.imageScaling = .scaleProportionallyDown
            statusItem.button?.imagePosition = .imageOnly
        } else {
            statusItem.button?.title = "W"
        }
        installStatusDot()
        statusItem.button?.toolTip = "Warren headless daemon"
        statusItem.menu = makeMenu()
        updateStatusItem()
        ensureDaemon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
    }

    /// `open Warren.app` can land on this process because the menu-bar helper
    /// shares the app bundle and therefore the same bundle identifier. Launch
    /// the foreground executable instead of silently activating an accessory
    /// process that has no desktop window.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        launchForegroundApplication()
        return false
    }

    @objc private func restartDaemon() {
        autoStartDisabled = false
        stopDaemon()
        ensureDaemon()
    }

    @objc private func stopDaemonAction() {
        autoStartDisabled = true
        stopDaemon()
    }

    @objc private func quitMenuBar() {
        NSApp.terminate(nil)
    }

    private func launchForegroundApplication() {
        let environment = ProcessInfo.processInfo.environment
        let executable: URL
        if let configured = environment["WARREN_APP_PATH"], !configured.isEmpty {
            executable = URL(fileURLWithPath: configured)
        } else {
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("Warren")
            let bundled = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/Warren")
            executable = FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : bundled
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSLog("Unable to reopen Warren desktop: %@ is not executable", executable.path)
            return
        }
        let process = Process()
        process.executableURL = executable
        do {
            try process.run()
        } catch {
            NSLog("Unable to reopen Warren desktop: %@", error.localizedDescription)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: "Headless: Checking…", action: nil, keyEquivalent: "")
        status.tag = 1
        status.isEnabled = false
        menu.addItem(status)
        let endpoint = NSMenuItem(title: "Endpoint: 127.0.0.1:8789", action: nil, keyEquivalent: "")
        endpoint.tag = 2
        endpoint.isEnabled = false
        menu.addItem(endpoint)
        let version = NSMenuItem(title: "Version: —", action: nil, keyEquivalent: "")
        version.tag = 3
        version.isEnabled = false
        menu.addItem(version)
        let ghostlineRPCVersion = NSMenuItem(title: "Ghostline RPC: —", action: nil, keyEquivalent: "")
        ghostlineRPCVersion.tag = 4
        ghostlineRPCVersion.isEnabled = false
        menu.addItem(ghostlineRPCVersion)
        let ghostlineTagVersion = NSMenuItem(title: "Ghostline tag: —", action: nil, keyEquivalent: "")
        ghostlineTagVersion.tag = 5
        ghostlineTagVersion.isEnabled = false
        menu.addItem(ghostlineTagVersion)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart Headless", action: #selector(restartDaemon), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Stop Headless", action: #selector(stopDaemonAction), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Warren Menu Bar", action: #selector(quitMenuBar), keyEquivalent: "q"))
        return menu
    }

    private func ensureDaemon() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await reconcileDaemon()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reconcileDaemon() async {
        if autoStartDisabled {
            state = .stopped
            return
        }
        if await isDaemonHealthy() {
            await markRunning()
            return
        }

        // A daemon can remain alive while its token file is temporarily
        // unavailable (for example, when ~/.warren was removed). Check the
        // unauthenticated health endpoint before starting another process so
        // the existing daemon has time to restore its token.
        if await isDaemonReachable() {
            state = .checking
            await waitUntilHealthy()
            return
        }

        if let process = daemonProcess, process.isRunning {
            state = .checking
            await waitUntilHealthy()
            return
        }
        daemonProcess = nil
        startDaemonProcess()
        await waitUntilHealthy()
    }

    private func waitUntilHealthy() async {
        for _ in 0..<30 where !Task.isCancelled {
            if await isDaemonHealthy() {
                await markRunning()
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        state = .failed("Headless did not become ready")
    }

    private func markRunning() async {
        state = .running
        await refreshVersions()
    }

    private func refreshVersions() async {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 1
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            buildVersion = (object["build"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ghostlineRPCVersion = ((object["ghostlineRPCVersion"] as? String) ?? (object["ghostlineVersion"] as? String)).flatMap { $0.isEmpty ? nil : $0 }
            ghostlineTagVersion = (object["ghostlineTagVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            updateStatusItem()
        } catch {
            return
        }
    }

    private func startDaemonProcess() {
        guard daemonProcess == nil else { return }
        let process = Process()
        process.executableURL = daemonExecutableURL()
        process.arguments = []
        var childEnvironment = ProcessInfo.processInfo.environment
        // A background daemon must not inherit an ambient NO_COLOR that only
        // applies to the launching agent's non-interactive commands. Terminal
        // sessions can still opt out by setting NO_COLOR in their own shell
        // config; dropping the inherited value keeps interactive TUIs colored
        // by default.
        childEnvironment.removeValue(forKey: "NO_COLOR")
        childEnvironment["PATH"] = executableSearchPath(from: childEnvironment["PATH"])
        process.environment = childEnvironment
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.daemonProcess = nil
                if case .running = self?.state { self?.state = .stopped }
            }
        }
        do {
            try process.run()
            daemonProcess = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func stopDaemon() {
        // Terminate only the control-plane daemon (the process this helper
        // spawned). The ghostline serve process is a separate long-lived
        // session owner: it must survive daemon restarts/updates so PTY
        // sessions keep running, and the next daemon reuses or adopts it.
        daemonProcess?.terminate()
        daemonProcess = nil
        state = .stopped
    }

    private func isDaemonHealthy() async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let tokenURL: URL
        if let configured = environment["WARREN_TOKEN_FILE"], !configured.isEmpty {
            tokenURL = URL(fileURLWithPath: configured)
        } else {
            tokenURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".warren/token")
        }
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        var request = URLRequest(url: stateURL)
        request.timeoutInterval = 1
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func isDaemonReachable() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 0.4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func daemonExecutableURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["WARREN_HEADLESS_PATH"], !configured.isEmpty {
            return URL(fileURLWithPath: configured)
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let sibling = executableDirectory.appendingPathComponent("warren-headless")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        let bundleBinary = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/warren-headless")
        return bundleBinary
    }

    private func executableSearchPath(from value: String?) -> String {
        var entries = (value ?? "").split(separator: ":").map(String.init)
        for path in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] where !entries.contains(path) {
            entries.append(path)
        }
        return entries.joined(separator: ":")
    }

    private func warrenMenuBarImage() -> NSImage? {
        let environment = ProcessInfo.processInfo.environment
        var baseCandidates: [URL] = []
        var retinaCandidates: [URL] = []
        if let configured = environment["WARREN_MENUBAR_ICON_PATH"], !configured.isEmpty {
            baseCandidates.append(URL(fileURLWithPath: configured))
        }
        if let bundled = Bundle.main.url(forResource: "menubar-template", withExtension: "png") {
            baseCandidates.append(bundled)
        }
        if let bundled2x = Bundle.main.url(forResource: "menubar-template@2x", withExtension: "png") {
            retinaCandidates.append(bundled2x)
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        baseCandidates.append(executableDirectory.appendingPathComponent("../Resources/menubar-template.png").standardizedFileURL)
        retinaCandidates.append(executableDirectory.appendingPathComponent("../Resources/menubar-template@2x.png").standardizedFileURL)
        baseCandidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/Brand/menubar-black-18.png"))
        retinaCandidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets/Brand/menubar-black-36.png"))
        for candidate in baseCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            let image = NSImage(size: NSSize(width: 18, height: 18))
            if let rep = NSImageRep(contentsOf: candidate) {
                image.addRepresentation(rep)
            }
            for retina in retinaCandidates where FileManager.default.fileExists(atPath: retina.path) {
                if let rep = NSImageRep(contentsOf: retina) {
                    image.addRepresentation(rep)
                }
            }
            image.isTemplate = true
            return image
        }
        return nil
    }

    private func installStatusDot() {
        guard let button = statusItem.button else { return }
        let size: CGFloat = 6.5
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        let green = NSColor(srgbRed: 126 / 255, green: 198 / 255, blue: 153 / 255, alpha: 1)
        dot.layer?.backgroundColor = green.cgColor
        dot.layer?.cornerRadius = size / 2
        dot.layer?.shadowColor = green.cgColor
        dot.layer?.shadowRadius = 2
        dot.layer?.shadowOpacity = 0.9
        dot.layer?.borderWidth = 1
        dot.layer?.borderColor = NSColor(srgbRed: 28 / 255, green: 25 / 255, blue: 24 / 255, alpha: 1).cgColor
        dot.isHidden = true
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: size),
            dot.heightAnchor.constraint(equalToConstant: size),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2),
        ])
        statusDot = dot
    }

    private func setStatusDotBreathing(_ breathing: Bool) {
        guard let dot = statusDot, let layer = dot.layer else { return }
        guard breathing else {
            layer.removeAnimation(forKey: statusDotPulseKey)
            layer.opacity = 1
            dot.isHidden = true
            return
        }

        dot.isHidden = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.removeAnimation(forKey: statusDotPulseKey)
            layer.opacity = 1
            return
        }

        // Health polling can publish the same state repeatedly. Keep the
        // existing animation alive so every poll does not restart its phase.
        guard layer.animation(forKey: statusDotPulseKey) == nil else { return }

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.55
        opacity.toValue = 1.0
        opacity.duration = statusDotPulseDuration

        let shadowOpacity = CABasicAnimation(keyPath: "shadowOpacity")
        shadowOpacity.fromValue = 0.35
        shadowOpacity.toValue = 0.9
        shadowOpacity.duration = statusDotPulseDuration

        let shadowRadius = CABasicAnimation(keyPath: "shadowRadius")
        shadowRadius.fromValue = 1.2
        shadowRadius.toValue = 2.4
        shadowRadius.duration = statusDotPulseDuration

        let pulse = CAAnimationGroup()
        pulse.animations = [opacity, shadowOpacity, shadowRadius]
        pulse.duration = statusDotPulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: statusDotPulseKey)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        switch state {
        case .checking:
            button.title = " Warren …"
        case .running:
            button.title = " Warren ●"
        case .stopped:
            button.title = " Warren ○"
        case .failed:
            button.title = " Warren !"
        }
        if button.image != nil { button.title = "" }
        let daemonRunning: Bool
        switch state {
        case .running:
            daemonRunning = true
        default:
            daemonRunning = false
        }
        setStatusDotBreathing(daemonRunning)
        var toolTip = switch state {
        case .checking: "Warren headless: Checking"
        case .running: "Warren headless: Running"
        case .stopped: "Warren headless: Stopped"
        case .failed: "Warren headless: Failed"
        }
        if let buildVersion {
            toolTip += " · \(buildVersion)"
        }
        if let ghostlineRPCVersion {
            toolTip += " · ghostline RPC \(ghostlineRPCVersion)"
        }
        if let ghostlineTagVersion {
            toolTip += " · ghostline tag \(ghostlineTagVersion)"
        }
        button.toolTip = toolTip
        if let status = statusItem.menu?.item(withTag: 1) {
            switch state {
            case .checking: status.title = "Headless: Checking…"
            case .running: status.title = "Headless: Running"
            case .stopped: status.title = "Headless: Stopped"
            case .failed(let reason): status.title = "Headless: \(reason)"
            }
        }
        if let endpoint = statusItem.menu?.item(withTag: 2) {
            endpoint.title = switch state {
            case .running: "Endpoint: 127.0.0.1:8789 · Web: 8789"
            case .checking: "Endpoint: 127.0.0.1:8789 · Checking…"
            case .stopped: "Endpoint: 127.0.0.1:8789 · Offline"
            case .failed: "Endpoint: 127.0.0.1:8789 · Unavailable"
            }
        }
        if let version = statusItem.menu?.item(withTag: 3) {
            version.title = "Version: \(buildVersion ?? "—")"
        }
        if let ghostlineRPCVersion = statusItem.menu?.item(withTag: 4) {
            ghostlineRPCVersion.title = "Ghostline RPC: \(self.ghostlineRPCVersion ?? "—")"
        }
        if let ghostlineTagVersion = statusItem.menu?.item(withTag: 5) {
            ghostlineTagVersion.title = "Ghostline tag: \(self.ghostlineTagVersion ?? "—")"
        }
    }
}

@MainActor
private enum WarrenDaemonMenuBarLock {
    private static var descriptor: Int32 = -1

    static func acquire() -> Bool {
        let path = "/tmp/warren-daemon-menubar.lock"
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            return false
        }
        return true
    }
}
