import SwiftUI

/// Typography tokens matching the confirmed Superset density hierarchy.
public enum WarrenTypography {
    /// Superset inherits the platform UI sans stack; regular weight carries
    /// most navigation and chrome, with weight reserved for active hierarchy.
    public static let navigationGroup = Font.system(size: 13, weight: .medium)
    public static let navigationItem = Font.system(size: 13, weight: .regular)
    /// Secondary row metadata is Superset's `text-xs` tier.
    public static let navigationMeta = Font.system(size: 12, weight: .regular)
    public static let externalIDEPath = Font.system(size: 11, weight: .regular, design: .monospaced)
    public static let settingsGroupLabel = Font.system(size: 11, weight: .medium)
    public static let settingsBody = Font.system(size: 14, weight: .regular)
    public static let settingsBodyEmphasis = Font.system(size: 14, weight: .regular)
    public static let settingsSupporting = Font.system(size: 13, weight: .regular)
    public static let settingsMeta = Font.system(size: 12, weight: .regular)
    /// Superset shortcuts are `text-xs tracking-widest`; Warren keeps the
    /// monospaced design for keyboard hints.
    public static let shortcut = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let chromeLabel = Font.system(size: 12, weight: .regular)
    /// The sidebar's two row weights.
    ///
    /// Projects and Tasks are containers: rows you open to
    /// find something rather than rows you land on. They read at `medium` so
    /// they can share depth 0 with the Workspaces inside them — weight carries
    /// the tier that indentation used to, and costs no width. Everything you
    /// actually navigate to stays `regular`.
    public static let sidebarContainerRow = navigationGroup
    public static let workspaceRow = navigationItem
    /// Section labels are intentionally compact and uppercase in their source.
    public static let sectionLabel = Font.system(size: 10, weight: .medium)
    /// Superset tab and pane titles use the compact text-xs tier.
    public static let tabTitle = Font.system(size: 12, weight: .regular)
    public static let paneHeader = Font.system(size: 12, weight: .medium)
    public static let badge = Font.system(size: 10, weight: .medium)
    /// Empty states stay regular: the kit never uses the light weight, which
    /// thins out on paper. Size and a quiet color carry the calm instead.
    public static let emptyState = Font.system(size: 18, weight: .regular)
    /// Empty-state titles use a larger size than the body so an empty page
    /// reads as calm guidance instead of shouting chrome.
    public static let emptyStateTitle = Font.system(size: 20, weight: .regular)
    public static let screenTitle = Font.system(size: 18, weight: .medium)
    /// Superset settings page headings are `text-xl` in medium weight.
    public static let pageTitle = Font.system(size: 20, weight: .medium)
    public static let dialogBody = Font.system(size: 13, weight: .regular)
    public static let dialogFieldLabel = Font.system(size: 12, weight: .regular)
    public static let dialogInput = Font.system(size: 13, weight: .regular)
    public static let dialogAction = Font.system(size: 13, weight: .regular)
    public static let dialogCriticalAction = Font.system(size: 13, weight: .medium)
    public static let dialogMeta = Font.system(size: 11.5, weight: .regular)
    /// Top-right chrome popovers (Web, endpoint, external IDE) share one text
    /// family so the controls read as one surface. Regular, like the
    /// navigation tiers beside them: 12pt light grey text was hard to read on
    /// paper, and the kit does not use the light weight.
    public static let popoverTitle = Font.system(size: 13, weight: .regular)
    public static let popoverItem = Font.system(size: 13, weight: .regular)
    public static let popoverMeta = Font.system(size: 12, weight: .regular)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    /// Superset `text-xs` descriptions and hints.
    public static let supporting = Font.system(size: 12, weight: .regular)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    /// The Conversation's reading role: 15/22 for the answer, the person's
    /// message, and the composer (the kit's `reading` tier). One size for all
    /// three keeps the transcript and the field it is written in on the same
    /// line grid.
    public static let reading = Font.system(size: 15, weight: .regular)
    public static let readingEmphasis = Font.system(size: 15, weight: .medium)
    public static let readingStrong = Font.system(size: 15, weight: .semibold)
    /// An answer's section heading: 16/22 semibold. It is the only text that
    /// outranks the reading body, and it never grows the leading.
    public static let readingTitle = Font.system(size: 16, weight: .semibold)
    /// The kit's caption role, 12/17; it replaces the old 11.5pt meta tier.
    public static let caption = Font.system(size: 12, weight: .regular)
    public static let captionEmphasis = Font.system(size: 12, weight: .medium)
    /// The kit's mono tiers: 12.5/20 for fenced code and 11/16 for a step's
    /// arguments.
    public static let mono = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let monoSmall = Font.system(size: 11, weight: .regular, design: .monospaced)
    /// The terminal find field uses Menlo rather than the system monospaced
    /// face so a typed query reads like the terminal grid it searches.
    public static let terminalSearchField = Font.custom("Menlo", size: 12)
}
