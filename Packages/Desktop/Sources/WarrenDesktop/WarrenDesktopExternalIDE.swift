import AppKit
import Foundation
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

struct WarrenDesktopExternalIDE: Identifiable, Hashable, Sendable {
    enum ID: String, Hashable, Sendable {
        case xcode
        case visualStudioCode
        case cursor
        case windsurf
        case zed
        case intellijIDEA
        case intellijIDEACommunity
        case goLand
        case pyCharm
        case pyCharmCommunity
        case webStorm
        case phpStorm
        case rubyMine
        case clion
        case rider
        case dataGrip
        case rustRover
        case androidStudio
        case sublimeText
        case bbEdit
        case textMate
        case macVim
        case nova
    }

    let id: ID
    let name: String
    let bundleIdentifier: String

    static let supported = [
        Self(id: .xcode, name: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
        Self(id: .visualStudioCode, name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode"),
        Self(id: .cursor, name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        Self(id: .windsurf, name: "Windsurf", bundleIdentifier: "com.exafunction.windsurf"),
        Self(id: .zed, name: "Zed", bundleIdentifier: "dev.zed.Zed"),
        Self(id: .intellijIDEA, name: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij"),
        Self(id: .intellijIDEACommunity, name: "IntelliJ IDEA CE", bundleIdentifier: "com.jetbrains.intellij.ce"),
        Self(id: .goLand, name: "GoLand", bundleIdentifier: "com.jetbrains.goland"),
        Self(id: .pyCharm, name: "PyCharm", bundleIdentifier: "com.jetbrains.pycharm"),
        Self(id: .pyCharmCommunity, name: "PyCharm CE", bundleIdentifier: "com.jetbrains.pycharm.ce"),
        Self(id: .webStorm, name: "WebStorm", bundleIdentifier: "com.jetbrains.webstorm"),
        Self(id: .phpStorm, name: "PhpStorm", bundleIdentifier: "com.jetbrains.phpstorm"),
        Self(id: .rubyMine, name: "RubyMine", bundleIdentifier: "com.jetbrains.rubymine"),
        Self(id: .clion, name: "CLion", bundleIdentifier: "com.jetbrains.clion"),
        Self(id: .rider, name: "Rider", bundleIdentifier: "com.jetbrains.rider"),
        Self(id: .dataGrip, name: "DataGrip", bundleIdentifier: "com.jetbrains.datagrip"),
        Self(id: .rustRover, name: "RustRover", bundleIdentifier: "com.jetbrains.rustrover"),
        Self(id: .androidStudio, name: "Android Studio", bundleIdentifier: "com.google.android.studio"),
        Self(id: .sublimeText, name: "Sublime Text", bundleIdentifier: "com.sublimetext.4"),
        Self(id: .bbEdit, name: "BBEdit", bundleIdentifier: "com.barebones.bbedit"),
        Self(id: .textMate, name: "TextMate", bundleIdentifier: "com.macromates.TextMate"),
        Self(id: .macVim, name: "MacVim", bundleIdentifier: "org.vim.MacVim"),
        Self(id: .nova, name: "Nova", bundleIdentifier: "com.panic.Nova"),
    ]
}

/// A user-configured IDE entry: either an app bundle or an executable that
/// opens a workspace directory (for example /usr/local/bin/code).
struct WarrenDesktopCustomIDE: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String

    init(name: String, path: String) {
        self.id = UUID()
        self.name = name
        self.path = path
    }
}

enum WarrenDesktopCustomIDEStore {
    private static let storageKey = "warren.customExternalIDEs"

    static func load() -> [WarrenDesktopCustomIDE] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode([WarrenDesktopCustomIDE].self, from: data) else {
            return []
        }
        return value
    }

    static func save(_ value: [WarrenDesktopCustomIDE]) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

struct WarrenDesktopExternalIDEOption: Identifiable {
    let id: String
    let name: String
    let applicationURL: URL?
    let workspaceURL: URL?
    let icon: NSImage?

    var isEnabled: Bool { workspaceURL != nil && applicationURL != nil }
}

enum WarrenDesktopExternalIDEIcon {
    private static let cursorOpticalScale: CGFloat = 1.2

    static func opticalScale(for identifier: String) -> CGFloat {
        identifier == WarrenDesktopExternalIDE.ID.cursor.rawValue
            ? cursorOpticalScale
            : 1
    }

    /// AppKit menus can fall back to an NSImage's intrinsic 32pt/retina size
    /// instead of honoring the SwiftUI frame. Normalize the logical size at
    /// the boundary while retaining the original image representations.
    static func normalized(_ icon: NSImage, opticalScale: CGFloat = 1) -> NSImage {
        let targetSize = NSSize(
            width: WarrenLayoutMetrics.externalIDEIconSize,
            height: WarrenLayoutMetrics.externalIDEIconSize
        )
        if opticalScale > 1.001 {
            let normalized = NSImage(size: targetSize)
            normalized.lockFocus()
            let scaledSize = NSSize(
                width: targetSize.width * opticalScale,
                height: targetSize.height * opticalScale
            )
            icon.draw(
                in: NSRect(
                    x: (targetSize.width - scaledSize.width) / 2,
                    y: (targetSize.height - scaledSize.height) / 2,
                    width: scaledSize.width,
                    height: scaledSize.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            normalized.unlockFocus()
            return normalized
        }

        let normalized = (icon.copy() as? NSImage) ?? icon
        normalized.size = targetSize
        return normalized
    }
}

struct WarrenDesktopExternalIDEMenuPresentation {
    struct Item: Identifiable {
        let option: WarrenDesktopExternalIDEOption

        var id: String { option.id }
        var title: String { option.name }
        var icon: NSImage? { option.icon }
        var isEnabled: Bool { option.isEnabled }
    }

    static func items(
        from options: [WarrenDesktopExternalIDEOption]
    ) -> [Item] {
        options.map(Item.init)
    }
}

struct WarrenDesktopExternalIDEMenu: View {
    let options: [WarrenDesktopExternalIDEOption]
    let onOpen: (WarrenDesktopExternalIDEOption) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Menu {
            ForEach(WarrenDesktopExternalIDEMenuPresentation.items(from: options)) { item in
                Button {
                    onOpen(item.option)
                } label: {
                    Label {
                        Text(item.title)
                            .font(WarrenTypography.externalIDEName)
                    } icon: {
                        iconView(item.icon)
                    }
                }
                .disabled(!item.isEnabled)
            }
        } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: WarrenLayoutMetrics.chromeIconSize, weight: .medium))
                .accessibilityHidden(true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .foregroundStyle(tokens.mutedForeground)
        .accessibilityLabel("Open workspace in IDE")
        .accessibilityHint("Open the current worktree in an external IDE")
    }

    @ViewBuilder
    private func iconView(_ icon: NSImage?) -> some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
        } else {
            Image(systemName: "app")
                .font(.system(size: WarrenLayoutMetrics.externalIDEIconSize, weight: .regular))
                .frame(width: WarrenLayoutMetrics.externalIDEIconSize,
                       height: WarrenLayoutMetrics.externalIDEIconSize)
        }
    }
}

struct WarrenDesktopExternalIDEFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(ideName: String, error: Error) {
        title = "Unable to Open \(ideName)"
        message = error.localizedDescription
    }
}

@MainActor
struct WarrenDesktopExternalIDEService {
    typealias Launch = (URL, URL) async throws -> Void

    let resolveApplicationURL: (String) -> URL?
    let directoryExists: (URL) -> Bool
    let applicationIcon: (URL) -> NSImage?
    let loadCustomIDEs: () -> [WarrenDesktopCustomIDE]
    let launch: Launch

    init(
        resolveApplicationURL: @escaping (String) -> URL?,
        directoryExists: @escaping (URL) -> Bool,
        applicationIcon: @escaping (URL) -> NSImage? = { _ in nil },
        loadCustomIDEs: @escaping () -> [WarrenDesktopCustomIDE] = { [] },
        launch: @escaping Launch
    ) {
        self.resolveApplicationURL = resolveApplicationURL
        self.directoryExists = directoryExists
        self.applicationIcon = applicationIcon
        self.loadCustomIDEs = loadCustomIDEs
        self.launch = launch
    }

    /// Resolves every installed built-in IDE plus the user's custom entries.
    /// Only IDEs whose application is present on this Mac are listed, so the
    /// workspace menu shows options the desktop can actually open.
    func options(
        for workspace: Workspace?,
        isLocalEndpoint: Bool
    ) -> [WarrenDesktopExternalIDEOption] {
        let workspaceURL = workspace.map {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL
        }
        let availableWorkspaceURL = workspaceURL.flatMap { url in
            isLocalEndpoint && directoryExists(url) ? url : nil
        }

        var options: [WarrenDesktopExternalIDEOption] = []
        for ide in WarrenDesktopExternalIDE.supported {
            guard let applicationURL = resolveApplicationURL(ide.bundleIdentifier) else {
                continue
            }
            options.append(WarrenDesktopExternalIDEOption(
                id: ide.id.rawValue,
                name: ide.name,
                applicationURL: applicationURL,
                workspaceURL: availableWorkspaceURL,
                icon: applicationIcon(applicationURL).map {
                    WarrenDesktopExternalIDEIcon.normalized(
                        $0,
                        opticalScale: WarrenDesktopExternalIDEIcon.opticalScale(for: ide.id.rawValue)
                    )
                }
            ))
        }
        for custom in loadCustomIDEs() {
            let applicationURL = URL(fileURLWithPath: custom.path).standardizedFileURL
            options.append(WarrenDesktopExternalIDEOption(
                id: "custom:\(custom.id.uuidString)",
                name: custom.name,
                applicationURL: applicationURL,
                workspaceURL: availableWorkspaceURL,
                icon: applicationIcon(applicationURL).map {
                    WarrenDesktopExternalIDEIcon.normalized($0)
                }
            ))
        }
        return options
    }
}

enum WarrenDesktopExternalIDEError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The IDE or workspace is no longer available."
    }
}

extension WarrenDesktopExternalIDEService {
    func open(_ option: WarrenDesktopExternalIDEOption) async throws {
        guard let workspaceURL = option.workspaceURL,
              let applicationURL = option.applicationURL else {
            throw WarrenDesktopExternalIDEError.unavailable
        }
        try await launch(workspaceURL, applicationURL)
    }

    static func isApplicationBundle(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
            || FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Contents/Info.plist").path
            )
    }

    static let live = Self(
        resolveApplicationURL: { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        directoryExists: { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        },
        applicationIcon: { url in
            NSWorkspace.shared.icon(forFile: url.path)
        },
        loadCustomIDEs: WarrenDesktopCustomIDEStore.load,
        launch: { workspaceURL, applicationURL in
            if WarrenDesktopExternalIDEService.isApplicationBundle(applicationURL) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    NSWorkspace.shared.open(
                        [workspaceURL],
                        withApplicationAt: applicationURL,
                        configuration: NSWorkspace.OpenConfiguration()
                    ) { _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } else {
                let process = Process()
                process.executableURL = applicationURL
                process.arguments = [workspaceURL.path]
                try process.run()
            }
        }
    )
}
