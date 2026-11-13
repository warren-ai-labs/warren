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
    /// A settings row's title: body size, one weight up, so the label outranks
    /// the description under it without growing.
    public static let settingsBodyEmphasis = Font.system(size: 14, weight: .medium)
    public static let settingsSupporting = Font.system(size: 13, weight: .regular)
    public static let settingsMeta = Font.system(size: 12, weight: .regular)
    /// A card's closing footnote: one step under body text, regular weight so
    /// it reads as an aside rather than as another label.
    public static let footnote = Font.system(size: 11, weight: .regular)
    /// A status chip's label: small, but a control, so it takes the weight the
    /// surrounding chrome labels do not.
    /// Avenir Next, like the other short labels a person reads once; the
    /// update chip beside its turning arc is the one most people see.
    public static let statusChip = Font.custom("AvenirNext-DemiBold", size: 11.5)
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
    /// A count drawn on its own: the number beside a section heading, the one
    /// on a tab, the one on a sync control. Tabular digits, so a changing
    /// number does not shift the text beside it.
    ///
    /// A `+12 −3` sum in a file list is a different role and stays in
    /// `monoSmall`: there the digits form a column down the rows, which only a
    /// monospaced cell gives them.
    public static let count = Font.system(size: 11, weight: .medium).monospacedDigit()
    /// Empty states stay regular: the kit never uses the light weight, which
    /// thins out on paper. Size and a quiet color carry the calm instead.
    ///
    /// Empty states, page titles and settings headings are read once rather
    /// than scanned, so they take Avenir Next; controls, body text and dense
    /// rows keep the system face. Avenir sizes run half a point over SF,
    /// because its lowercase sits lower.
    public static let emptyState = Font.custom("AvenirNext-Regular", size: 18.5)
    /// Empty-state titles use a larger size than the body so an empty page
    /// reads as calm guidance instead of shouting chrome.
    public static let emptyStateTitle = Font.custom("AvenirNext-Regular", size: 20.5)
    /// An empty content card's title and its one line: Avenir Next, as the
    /// whole stage is read once and points somewhere else.
    public static let emptyStageTitle = Font.custom("AvenirNext-DemiBold", size: 16.5)
    public static let emptyStageMessage = Font.custom("AvenirNext-Regular", size: 13.5)
    /// A sidebar section's empty state: why the tree is empty and the one way
    /// out of it. Avenir Next at the tree's own size, so the section reads as
    /// guidance in the voice of the names it stands in for instead of as one
    /// more system-face chrome row.
    public static let sidebarEmptyState = Font.custom("AvenirNext-Regular", size: 13.5)
    /// The second line under a sidebar empty state, a step under its title.
    public static let sidebarEmptyStateDetail = Font.custom("AvenirNext-Regular", size: 12)
    /// A settings page's title.
    public static let settingsPageTitle = Font.custom("AvenirNext-DemiBold", size: 20.5)
    /// A settings group's heading, a step above its rows.
    public static let settingsGroupTitle = Font.custom("AvenirNext-DemiBold", size: 13.5)
    /// A menu's group caption and the title of a submenu page. The rows under
    /// them are controls and stay in the system face, like a native menu; the
    /// captions take Avenir Next so they read as labels, not as more rows.
    public static let menuGroupHeader = Font.custom("AvenirNext-Medium", size: 12)
    public static let menuPageTitle = Font.custom("AvenirNext-DemiBold", size: 13.5)
    /// A tooltip's text and a hover card's labels. Avenir Next, in medium:
    /// its regular cut is thin on the floating surface. 11.5, the system
    /// tooltip's size: at 12.5 a bubble read louder than the row under it.
    public static let tooltip = Font.custom("AvenirNext-Medium", size: 11.5)
    public static let hoverCardLabel = Font.custom("AvenirNext-Medium", size: 11.5)
    /// The uppercase, tracked group labels in the settings navigation.
    public static let settingsNavigationLabel = Font.custom("AvenirNext-DemiBold", size: 10.5)
    public static let screenTitle = Font.system(size: 18, weight: .medium)
    /// Superset settings page headings are `text-xl` in medium weight.
    public static let pageTitle = Font.system(size: 20, weight: .medium)
    /// A dialog's title, and an empty stage's: the one heading on the
    /// surface, in Avenir Next like the other headings.
    public static let dialogTitle = Font.custom("AvenirNext-DemiBold", size: 15.5)
    public static let dialogBody = Font.system(size: 13, weight: .regular)
    /// A form field's label: a label above a control, so it is read once and
    /// takes Avenir Next like the other read-once roles on the surface. The
    /// input under it stays in the system face, where a caret lives.
    public static let fieldLabel = Font.custom("AvenirNext-Medium", size: 12)
    /// The dialogs' own name for `fieldLabel`, kept so every input in the app
    /// labels its field the same way.
    public static let dialogFieldLabel = fieldLabel
    public static let dialogInput = Font.system(size: 13, weight: .regular)
    public static let dialogAction = Font.system(size: 13, weight: .regular)
    public static let dialogCriticalAction = Font.system(size: 13, weight: .medium)
    public static let dialogMeta = Font.system(size: 11.5, weight: .regular)
    /// Top-right chrome popovers (Web, endpoint, external IDE) share one text
    /// family so the controls read as one surface. Regular, like the
    /// navigation tiers beside them: 12pt light grey text was hard to read on
    /// paper, and the kit does not use the light weight.
    /// A notice's title, in the notification list and its detail. Avenir
    /// Next, medium: a title is read once, and the rows beside it stay SF.
    public static let popoverTitle = Font.custom("AvenirNext-Medium", size: 13.5)
    /// A notice toast's title, one step under the list's.
    public static let toastTitle = Font.custom("AvenirNext-DemiBold", size: 12.5)
    /// Every floating surface's rows (menus, the Host panel, the Web and
    /// editor popovers, the command palette, notifications) and their
    /// second lines, in Avenir Next: they are read, one at a time, rather
    /// than scanned like the sidebar's dense rows.
    public static let popoverItem = Font.custom("AvenirNext-Regular", size: 13.5)
    public static let popoverMeta = Font.custom("AvenirNext-Regular", size: 12)
    /// A git branch where it names a place: the sidebar, the Inspector, a
    /// hover card. Avenir Next Condensed, so it sits with the project names
    /// in Avenir Next and a long ref keeps more of its letters.
    public static let branchName = Font.custom("AvenirNextCondensed-Medium", size: 12.5)
    /// A Host's heading inside the sidebar's tree, above the Projects it holds.
    ///
    /// Condensed like the branch names: the header shares its row with the
    /// rule, the Session marks and the disclosure, and a machine name in the
    /// wide cut pushed those out. DemiBold keeps it above its project names.
    public static let sidebarHostTitle = Font.custom("AvenirNextCondensed-DemiBold", size: 14.5)
    public static let sidebarHostTitleWide = Font.system(size: 14, weight: .semibold)
    /// A panel's tabs (the right sidebar's Changes / History / Files /
    /// Editor): Avenir Next, medium at rest and demibold when selected, so
    /// they read as the panel's headings rather than as buttons.
    public static let panelTab = Font.custom("AvenirNext-Medium", size: 13)
    public static let panelTabSelected = Font.custom("AvenirNext-DemiBold", size: 13)
    /// The sidebar header's Host: the column's own title, so DemiBold, with
    /// a CJK run in the system face at a half point less.
    public static let hostHeaderName = Font.custom("AvenirNext-DemiBold", size: 14)
    public static let hostHeaderNameWide = Font.system(size: 13.5, weight: .semibold)
    public static let hostHeaderMeta = Font.custom("AvenirNext-Regular", size: 11.5)
    /// A Host's name where it is chosen from: the Hosts panel and the
    /// sidebar's foot. A name a person gave the machine, so Avenir Next like
    /// a project's.
    public static let hostName = Font.custom("AvenirNext-Medium", size: 13.5)
    /// The glyph leading a floating surface's row: a step under the row's
    /// text, so the label rather than the icon carries the row.
    public static let popoverGlyph = Font.system(size: 13.5, weight: .regular)
    /// The Settings window's navigation: a page name, the scope a search
    /// result belongs to, and the version stamp at the rail's foot.
    public static let settingsNavigationItem = Font.custom("AvenirNext-Medium", size: 13.5)
    public static let settingsNavigationScope = Font.custom("AvenirNext-Regular", size: 11)
    public static let body = Font.system(size: 13, weight: .regular)
    public static let bodyEmphasis = Font.system(size: 13, weight: .medium)
    /// Superset `text-xs` descriptions and hints.
    public static let supporting = Font.system(size: 12, weight: .regular)
    public static let code = Font.system(size: 12, weight: .regular, design: .monospaced)
    /// The compact monospaced tier: a value the Settings pages read back (a
    /// stored path, a key chord, a command summary). Half a point under `code`
    /// so a readout sits with the 12pt label on its row rather than over it.
    public static let codeSmall = Font.system(size: 11.5, weight: .regular, design: .monospaced)
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
