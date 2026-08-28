import Foundation

/// Persisted per-workspace Git panel UI state, mirroring the web client's
/// localStorage snapshot (`Web/src/gitui.js`). Desktop stores the same shape
/// in `UserDefaults` so both clients keep the same normalization rules.
public struct WarrenDesktopGitPanelUIState: Codable, Hashable, Sendable {
    public var openPanes: [String]
    public var selectedKey: String?
    public var expanded: [String]
    public var branch: String?
    public var viewTab: String?
    public var diffStyle: String?
    public var fileView: WarrenDesktopGitFileViewSnapshot?

    public init(
        openPanes: [String] = [],
        selectedKey: String? = nil,
        expanded: [String] = [],
        branch: String? = nil,
        viewTab: String? = nil,
        diffStyle: String? = nil,
        fileView: WarrenDesktopGitFileViewSnapshot? = nil
    ) {
        self.openPanes = openPanes
        self.selectedKey = selectedKey
        self.expanded = expanded
        self.branch = branch
        self.viewTab = viewTab
        self.diffStyle = diffStyle
        self.fileView = fileView
    }
}

public struct WarrenDesktopGitFileViewSnapshot: Codable, Hashable, Sendable {
    public var path: String
    public var staged: Bool
    public var commit: String?

    public init(path: String, staged: Bool, commit: String?) {
        self.path = path
        self.staged = staged
        self.commit = commit
    }
}

@MainActor
public protocol WarrenDesktopGitPanelPersistence {
    func load(workspaceID: String) -> WarrenDesktopGitPanelUIState?
    func save(_ state: WarrenDesktopGitPanelUIState, workspaceID: String)
    func remove(workspaceID: String)
}

/// `UserDefaults`-backed persistence. Storage failures are best-effort and
/// never surface in the UI, matching the web client's snapshot contract.
public struct WarrenDesktopGitPanelUserDefaultsPersistence: WarrenDesktopGitPanelPersistence {
    private static let paneKeys = ["checkout", "pr", "changes", "history"]
    private static let viewTabs = ["diff", "file"]
    private static let diffStyles = ["split", "unified"]

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(workspaceID: String) -> WarrenDesktopGitPanelUIState? {
        let key = Self.key(workspaceID: workspaceID)
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode(WarrenDesktopGitPanelUIState.self, from: data) else {
            return nil
        }
        return Self.normalize(raw)
    }

    public func save(_ state: WarrenDesktopGitPanelUIState, workspaceID: String) {
        let normalized = Self.normalize(state)
        let key = Self.key(workspaceID: workspaceID)
        if Self.isEmpty(normalized) {
            defaults.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(normalized) {
            defaults.set(data, forKey: key)
        }
    }

    public func remove(workspaceID: String) {
        defaults.removeObject(forKey: Self.key(workspaceID: workspaceID))
    }

    private static func key(workspaceID: String) -> String {
        "warren.gitPanelUI.\(workspaceID)"
    }

    private static func normalize(_ raw: WarrenDesktopGitPanelUIState) -> WarrenDesktopGitPanelUIState {
        var state = raw
        state.openPanes = raw.openPanes.filter { paneKeys.contains($0) }
        if let selectedKey = raw.selectedKey, selectedKey.isEmpty {
            state.selectedKey = nil
        }
        state.expanded = raw.expanded.filter { !$0.isEmpty }
        if let branch = raw.branch, branch.isEmpty {
            state.branch = nil
        }
        if let viewTab = raw.viewTab, !viewTabs.contains(viewTab) {
            state.viewTab = nil
        }
        if let diffStyle = raw.diffStyle, !diffStyles.contains(diffStyle) {
            state.diffStyle = nil
        }
        if let fileView = raw.fileView, fileView.path.isEmpty {
            state.fileView = nil
        }
        return state
    }

    private static func isEmpty(_ state: WarrenDesktopGitPanelUIState) -> Bool {
        state.openPanes.isEmpty
            && state.selectedKey == nil
            && state.expanded.isEmpty
            && state.branch == nil
            && state.viewTab == nil
            && state.diffStyle == nil
            && state.fileView == nil
    }
}
