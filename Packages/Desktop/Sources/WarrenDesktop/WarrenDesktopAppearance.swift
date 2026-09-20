import AppKit
import SwiftUI
import WarrenDomain

/// Applies the appearance preference to the running application.
///
/// The authority is `NSApplication.appearance`, not SwiftUI's
/// `preferredColorScheme`. Three reasons, in order of how much they cost to
/// work around:
///
/// 1. Menus, scrollers, text selection highlights, tooltips and the open/save
///    panels read the application or window appearance. They never see a
///    SwiftUI environment value, so a `preferredColorScheme`-only
///    implementation leaves a light window carrying dark menus.
/// 2. SwiftUI derives `\.colorScheme` *from* the AppKit appearance, so setting
///    it here reaches all of Warren's existing token call sites without any of
///    them changing.
/// 3. `nil` is a real state at this layer: it means "no override", which is
///    exactly what System has to mean. It restores following the macOS
///    appearance including mid-session changes and the Auto schedule, which a
///    snapshot of the current scheme would not.
public enum WarrenDesktopAppearance {
    /// The `NSAppearance` override for a mode, or `nil` to follow the system.
    public static func appearance(for mode: WarrenAppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Reads the stored preference and applies it. Safe to call before the
    /// first window exists.
    @MainActor
    public static func applyStoredMode(defaults: UserDefaults = .standard) {
        apply(storedMode(defaults: defaults))
    }

    @MainActor
    public static func apply(_ mode: WarrenAppearanceMode) {
        NSApp?.appearance = appearance(for: mode)
    }

    public static func storedMode(defaults: UserDefaults = .standard) -> WarrenAppearanceMode {
        WarrenAppearanceMode(
            storedValue: defaults.string(forKey: WarrenPreferenceKey.appearanceMode)
        )
    }
}
