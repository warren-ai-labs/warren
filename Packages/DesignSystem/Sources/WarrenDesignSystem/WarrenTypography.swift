import SwiftUI

/// Typography tokens matching the confirmed Superset density hierarchy.
public enum WarrenTypography {
    /// Superset inherits the platform UI sans stack; regular weight carries
    /// most navigation and chrome, with weight reserved for active hierarchy.
    public static let navigationGroup = Font.system(size: 13, weight: .medium)
    public static let navigationItem = Font.system(size: 13, weight: .regular)
    /// Secondary row metadata is Superset's `text-xs` tier.
    public static let navigationMeta = Font.system(size: 12, weight: .regular)
    /// External IDE names use a light 13pt tier so the larger artwork does not
    /// make the menu or settings rows feel visually heavy.
    public static let externalIDEName = Font.system(size: 13, weight: .light)
    public static let externalIDEPath = Font.system(size: 11, weight: .light, design: .monospaced)
    /// Light settings navigation tiers. Settings chrome uses the light text
    /// family so the sidebar reads as calm metadata instead of competing with
    /// terminal content.
    public static let settingsNavigationItem = Font.system(size: 13, weight: .light)
    public static let settingsGroupLabel = Font.system(size: 10, weight: .light)
    public static let settingsScreenTitle = Font.system(size: 20, weight: .light)
    /// Superset group headings are `text-xs font-medium`.
    public static let groupHeading = Font.system(size: 12, weight: .medium)
    /// Superset shortcuts are `text-xs tracking-widest`; Warren keeps the
    /// monospaced design for keyboard hints.
    public static let shortcut = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let chromeLabel = Font.system(size: 12, weight: .regular)
    /// Compatibility aliases for clients that have not migrated yet. Ordinary
    /// project, workspace, and session rows use regular weight; group labels
    /// continue to use `navigationGroup` when they need hierarchy.
    public static let sidebarRow = navigationItem
    public static let workspaceRow = navigationItem
    /// Section labels are intentionally compact and uppercase in their source.
    public static let sectionLabel = Font.system(size: 10, weight: .medium)
    /// Superset tab and pane titles use the compact text-xs tier.
    public static let tabTitle = Font.system(size: 12, weight: .regular)
    public static let activeTabTitle = Font.system(size: 12, weight: .medium)
    /// Tab shell titles use the light text tier; the active tab separates
    /// itself with a brighter gray instead of a heavier weight.
    public static let tabShellTitle = Font.system(size: 12, weight: .light)
    /// The terminal pane title uses the same light text tier as tab shell
    /// titles so chrome reads as one family instead of competing with the
    /// terminal content.
    public static let paneShellTitle = Font.system(size: 12, weight: .light)
    public static let paneHeader = Font.system(size: 12, weight: .medium)
    public static let badge = Font.system(size: 10, weight: .medium)
    public static let activityChip = Font.system(size: 9, weight: .medium)
    public static let emptyState = Font.system(size: 18, weight: .semibold)
    /// Empty-state titles use the light text tier and a larger size so an
    /// empty page reads as calm guidance instead of shouting chrome.
    public static let emptyStateTitle = Font.system(size: 20, weight: .light)
    public static let screenTitle = Font.system(size: 18, weight: .semibold)
    /// Superset settings page headings are `text-xl`.
    public static let pageTitle = Font.system(size: 20, weight: .semibold)
    public static let dialogTitle = Font.system(size: 17, weight: .semibold)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    /// Superset `text-xs` descriptions and hints.
    public static let supporting = Font.system(size: 12, weight: .regular)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let compactCode = Font.system(size: 11, weight: .semibold, design: .monospaced)
}
