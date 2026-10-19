import AppKit
import WarrenDomain

/// Applies the app icon colorway preference to the running application.
///
/// The bundle's own icon is always the default colorway; another colorway
/// replaces only the icon the Dock and the app switcher draw while Warren
/// runs. Changing what Finder shows would mean `NSWorkspace.setIcon` on the
/// app bundle, which writes into the signed bundle and breaks its signature,
/// so the bundle is left alone.
public enum WarrenDesktopDockIcon {
    /// Reads the stored preference and applies it.
    @MainActor
    public static func applyStoredColorway(defaults: UserDefaults = .standard) {
        apply(storedColorway(defaults: defaults))
    }

    /// `nil` hands the Dock back to the bundle's icon, so choosing the default
    /// again restores exactly what a fresh launch shows.
    @MainActor
    public static func apply(_ colorway: WarrenAppIconColorway) {
        NSApp?.applicationIconImage = colorway == .defaultValue ? nil : image(for: colorway)
    }

    /// The colorway's icon on the macOS icon grid, as the Dock would draw it.
    public static func image(for colorway: WarrenAppIconColorway) -> NSImage? {
        Bundle.module.image(forResource: resourceName(for: colorway))
    }

    static func resourceName(for colorway: WarrenAppIconColorway) -> String {
        "app-icon-\(colorway.rawValue)"
    }

    public static func storedColorway(defaults: UserDefaults = .standard) -> WarrenAppIconColorway {
        WarrenAppIconColorway(
            storedValue: defaults.string(forKey: WarrenPreferenceKey.appearanceAppIcon)
        )
    }
}
