import SwiftUI

/// The workbench type ramp.
///
/// Seven styles, three weights. Every role below is one of them, so a view
/// picks a role by what the text is rather than by a size. Interface text is
/// SF Pro; mono is reserved for what the machine wrote — output tails, paths,
/// shortcuts, diff stats. The terminal grid keeps the person's own font.
///
/// Light (300) is gone on purpose: thin strokes disappear on glass.
public enum WarrenTypography {
    // MARK: Ramp

    /// Settings page titles and empty-state headings. 22/28 semibold.
    public static let display = Font.system(size: 22, weight: .semibold)
    /// Dialog titles, section titles, pane titles. 15/20 semibold.
    public static let title = Font.system(size: 15, weight: .semibold)
    /// Rows, controls, and running text. 13/18 regular.
    public static let body = Font.system(size: 13, weight: .regular)
    /// The selected item, a container row, an emphasized label. 13/18 medium.
    public static let bodyStrong = Font.system(size: 13, weight: .medium)
    /// Secondary lines, hints, metadata. 11.5/15 regular.
    public static let caption = Font.system(size: 11.5, weight: .regular)
    /// Command lines and code. 12.5/20 regular.
    public static let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    /// Output tails, shortcuts, diff stats. 11/16 regular.
    public static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)

    // MARK: Roles

    public static let navigationGroup = bodyStrong
    public static let navigationItem = body
    public static let navigationMeta = caption
    public static let externalIDEName = body
    public static let externalIDEPath = monoSmall
    public static let settingsNavigationItem = body
    public static let settingsNavigationItemActive = bodyStrong
    public static let settingsGroupLabel = caption
    public static let settingsScreenTitle = display
    public static let settingsSectionTitle = display
    public static let settingsBody = body
    public static let settingsBodyEmphasis = bodyStrong
    public static let settingsSupporting = caption
    public static let settingsControl = body
    public static let settingsAction = body
    public static let settingsMeta = caption
    /// Kept for the call sites that asked for a quieter row; it is the regular
    /// body style now, and the caller's color carries the quietness.
    public static let navigationItemLight = body
    public static let groupHeading = caption
    public static let shortcut = monoSmall
    public static let chromeLabel = body
    /// The sidebar's two row weights.
    ///
    /// Projects, Tasks, and Terminal Groups are containers: rows you open to
    /// find something rather than rows you land on. They read at `medium` so
    /// they can share depth 0 with the Workspaces inside them — weight carries
    /// the tier that indentation used to, and costs no width. Everything you
    /// actually navigate to stays `regular`.
    public static let sidebarContainerRow = navigationGroup
    public static let sidebarRow = navigationItem
    public static let workspaceRow = navigationItem
    public static let sectionLabel = caption
    public static let tabTitle = body
    public static let activeTabTitle = bodyStrong
    public static let tabShellTitle = body
    public static let paneShellTitle = body
    public static let paneHeader = bodyStrong
    public static let badge = caption
    public static let activityChip = caption
    public static let emptyState = title
    public static let emptyStateTitle = display
    public static let screenTitle = title
    public static let pageTitle = display
    public static let dialogTitle = title
    public static let dialogBody = body
    public static let dialogFieldLabel = caption
    public static let dialogInput = body
    public static let dialogAction = body
    public static let dialogCriticalAction = bodyStrong
    public static let dialogMeta = caption
    public static let popoverTitle = bodyStrong
    public static let popoverItem = body
    public static let popoverMeta = caption
    public static let bodyEmphasis = bodyStrong
    public static let supporting = caption
    public static let code = mono
    /// The terminal find field uses Menlo rather than the system monospaced
    /// face so a typed query reads like the terminal grid it searches.
    public static let terminalSearchField = Font.custom("Menlo", size: 12)
    public static let compactCode = monoSmall
}
