import AppKit
import Foundation
import SwiftUI
import WarrenDesignSystem
import WarrenDesktop
import WarrenDesktopFixtures
import WarrenDomain

/// Renders the production desktop tree to a PNG so a design change can be
/// looked at without building, signing, and installing the app.
///
/// This is the visual counterpart to `UIProbe`, which is deliberately
/// non-visual: that probe asserts the semantic contract and must never create a
/// bitmap. Here the bitmap is the whole point, so the two stay separate tools
/// rather than one tool with a flag that changes what its report means.
///
/// The window is never shown, never made key, and never ordered in front, so
/// running this does not take focus from whatever the user is doing.
@MainActor
private enum UIShot {
    struct Options {
        var appearance: ColorScheme = .dark
        var width: CGFloat = 1_440
        var height: CGFloat = 900
        var scale: CGFloat = 2
        /// Renders the tree with the pointer resting on the row a person would
        /// be over, so a hover-only affordance can be looked at without moving
        /// the real pointer.
        var hover = false
        /// Which surface to render. `root` is the whole window; the others
        /// isolate one floating surface so it can be judged on its own.
        var surface = "root"
        /// Which Settings page, when `surface` is `settings`.
        var section = "Appearance"
        var output: URL

        static func parse(_ arguments: [String]) -> Options {
            var options = Options(
                output: URL(fileURLWithPath: "/tmp/warren-observation/ui-shot/dark.png")
            )
            var index = 0
            while index < arguments.count {
                let flag = arguments[index]
                let value = index + 1 < arguments.count ? arguments[index + 1] : nil
                switch flag {
                case "--appearance":
                    options.appearance = value == "light" ? .light : .dark
                    index += 1
                case "--width":
                    if let value, let parsed = Double(value) { options.width = parsed }
                    index += 1
                case "--height":
                    if let value, let parsed = Double(value) { options.height = parsed }
                    index += 1
                case "--scale":
                    if let value, let parsed = Double(value) { options.scale = parsed }
                    index += 1
                case "--surface":
                    if let value { options.surface = value }
                    index += 1
                case "--section":
                    if let value { options.section = value }
                    index += 1
                case "--hover":
                    options.hover = true
                case "--out":
                    if let value { options.output = URL(fileURLWithPath: value) }
                    index += 1
                default:
                    break
                }
                index += 1
            }
            return options
        }
    }

    static func run() throws {
        let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

        let root = ShotSurface(name: options.surface, section: options.section)
        .environment(\.colorScheme, options.appearance)
        .environment(\.warrenForceHover, options.hover)
        .frame(width: options.width, height: options.height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(x: 0, y: 0, width: options.width, height: options.height)

        // A hosting view draws only once it has a window to resolve appearance
        // and screen scale against. The window is never ordered in.
        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.appearance = NSAppearance(
            named: options.appearance == .light ? .aqua : .darkAqua
        )
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        // Long enough for the surfaces that reveal themselves after a delay:
        // the update card waits before it appears, and a shot taken at 0.2s
        // photographed an empty window.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        hostingView.layoutSubtreeIfNeeded()

        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            throw NSError(
                domain: "Warren.UIShot",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The hosting view could not allocate a bitmap."]
            )
        }
        // `rep.size` is the point size the view draws in; the pixel count is
        // what carries the scale. Setting both to the scaled size draws the
        // view at 1x into one quadrant of the bitmap.
        rep.size = NSSize(width: options.width, height: options.height)
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "Warren.UIShot",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The bitmap could not be encoded as PNG."]
            )
        }
        try FileManager.default.createDirectory(
            at: options.output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: options.output)
        print("shot \(options.surface) \(Int(options.width))x\(Int(options.height)) @\(options.scale)x -> \(options.output.path)")
    }
}

/// The surface to render: the whole window, or one floating surface.
private struct ShotSurface: View {
    let name: String
    let section: String

    var body: some View {
        if let surface = WarrenDesktopShotGallery.Surface(rawValue: name) {
            WarrenDesktopShotGallery(
                surface: surface,
                projection: WarrenDesktopFixture.preview.projection,
                settingsSection: WarrenDesktopSettingsSection(rawValue: section) ?? .appearance
            )
        } else {
            WarrenDesktopRoot(
                projection: WarrenDesktopFixture.preview.projection,
                actions: WarrenDesktopActions { _ in },
                persistenceEnabled: false
            ) { context in
                ShotTerminalSurface(context: context)
            }
        }
    }
}

/// Stands in for the Ghostty surface, which cannot render without a real
/// window. The rest of the tree is the production tree.
private struct ShotTerminalSurface: View {
    let context: WarrenDesktopTerminalContext

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ warren session read \(context.tab.id.description.prefix(8))")
                .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 0.55))
            Text("Rendering the production desktop tree offscreen.")
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.72))
            Text("$ ")
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.72))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color.black)
        .font(.system(size: 12, design: .monospaced))
    }
}

try UIShot.run()
