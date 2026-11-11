import Foundation

/// Locates the Desktop target's resource bundle.
///
/// SwiftPM's generated `Bundle.module` accessor only looks beside
/// `Bundle.main.bundleURL` and at the absolute build directory of the machine
/// that produced the binary, so a packaged app — whose resources live in
/// `Contents/Resources` — traps in `fatalError` on every other Mac. This
/// resolver searches the layouts the app, `swift run` and the test bundle
/// actually use, and returns `nil` instead of trapping.
enum WarrenDesktopResources {
    static let bundleName = "WarrenDesktop_WarrenDesktop.bundle"

    /// The layouts, in the order an installed app should find them: the host
    /// bundle's resource directory (`Contents/Resources` for an app), the host
    /// bundle itself (`swift run` keeps resources beside the executable) and
    /// the test bundle and its parent directory.
    static let bundle: Bundle? = locate(in: [
        Bundle.main.resourceURL,
        Bundle.main.bundleURL,
        Bundle(for: BundleToken.self).resourceURL,
        Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
    ])

    static func locate(
        in roots: [URL?],
        fileManager: FileManager = .default
    ) -> Bundle? {
        for case let root? in roots {
            let candidate = root.appendingPathComponent(bundleName, isDirectory: true)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if let bundle = Bundle(url: candidate) {
                return bundle
            }
        }
        return nil
    }
}

/// Anchors `Bundle(for:)` to whatever binary the Desktop sources are linked into.
private final class BundleToken {}
