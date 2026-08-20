import SwiftUI

/// Typography tokens matching the confirmed Superset density hierarchy.
public enum WarrenTypography {
    /// Superset inherits the platform UI sans stack; regular weight carries
    /// most navigation and chrome, with weight reserved for active hierarchy.
    public static let navigationGroup = Font.system(size: 13, weight: .medium)
    public static let navigationItem = Font.system(size: 13, weight: .regular)
    /// Secondary row metadata is Superset's `text-xs` tier.
    public static let navigationMeta = Font.system(size: 12, weight: .regular)
    /// External IDE labels remain readable in compact menus and settings rows.
    public static let externalIDEName = Font.system(size: 13, weight: .regular)
    public static let externalIDEPath = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// Settings is a functional surface rather than passive chrome. Keep its
    /// navigation readable at a larger size and never use a light weight for
    /// labels that users must scan or select.
    public static let settingsNavigationItem = Font.system(size: 14, weight: .regular)
    public static let settingsNavigationItemActive = Font.system(size: 14, weight: .regular)
    public static let settingsGroupLabel = Font.system(size: 12, weight: .regular)
    public static let settingsScreenTitle = Font.system(size: 22, weight: .light)
    public static let settingsSectionTitle = Font.system(size: 20, weight: .regular)
    public static let settingsBody = Font.system(size: 14, weight: .regular)
    public static let settingsBodyEmphasis = Font.system(size: 14, weight: .regular)
    public static let settingsSupporting = Font.system(size: 13, weight: .regular)
    public static let settingsControl = Font.system(size: 14, weight: .regular)
    public static let settingsAction = Font.system(size: 14, weight: .regular)
    public static let settingsMeta = Font.system(size: 12, weight: .regular)
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
    /// Business dialogs use a clearer hierarchy than dense navigation chrome.
    public static let dialogTitle = Font.system(size: 18, weight: .light)
    public static let dialogBody = Font.system(size: 14, weight: .regular)
    public static let dialogFieldLabel = Font.system(size: 13, weight: .regular)
    public static let dialogInput = Font.system(size: 14, weight: .regular)
    public static let dialogAction = Font.system(size: 14, weight: .regular)
    public static let dialogCriticalAction = Font.system(size: 14, weight: .medium)
    public static let dialogMeta = Font.system(size: 12, weight: .regular)
    /// Top-right chrome popovers (Web, endpoint, external IDE) share one calm
    /// light text family so the controls read as one surface.
    public static let popoverTitle = Font.system(size: 13, weight: .light)
    public static let popoverItem = Font.system(size: 13, weight: .light)
    public static let popoverMeta = Font.system(size: 12, weight: .light)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    /// Superset `text-xs` descriptions and hints.
    public static let supporting = Font.system(size: 12, weight: .regular)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    public static let compactCode = Font.system(size: 11, weight: .semibold, design: .monospaced)
}
