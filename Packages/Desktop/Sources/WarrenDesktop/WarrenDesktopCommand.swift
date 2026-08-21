import Foundation

/// Cross-process (within the app) command names used by the AppKit menu. The
/// Desktop shell observes these so the host executable can own the menu while
/// the reusable UI package stays free of AppDelegate dependencies.
public enum WarrenDesktopCommand {
    public static let commandPalette = Notification.Name("WarrenDesktopCommand.commandPalette")
    public static let newSession = Notification.Name("WarrenDesktopCommand.newSession")
    public static let nextTab = Notification.Name("WarrenDesktopCommand.nextTab")
    public static let previousTab = Notification.Name("WarrenDesktopCommand.previousTab")
    /// Posted with a 1-based `selectTabIndexKey` value for ⌘1…⌘9.
    public static let selectTab = Notification.Name("WarrenDesktopCommand.selectTab")
    public static let selectTabIndexKey = "WarrenDesktopCommand.selectTabIndex"
    public static let closeTab = Notification.Name("WarrenDesktopCommand.closeTab")
    public static let findInTerminal = Notification.Name("WarrenDesktopCommand.findInTerminal")
    public static let toggleSidebar = Notification.Name("WarrenDesktopCommand.toggleSidebar")
    /// Posted when the in-app Settings page closes. The shell stays mounted
    /// underneath Settings, so the composition root uses this to return
    /// keyboard focus and force a repaint of the terminal.
    public static let settingsDismissed = Notification.Name("WarrenDesktopCommand.settingsDismissed")
}
