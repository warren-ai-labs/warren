import Foundation
import WarrenDomain

/// One Workspace's durable Embedded Editor marker (RFC 0021 §6.1).
///
/// This is Desktop presentation state, not Host state: it records that a user
/// opened the editor for a Workspace on this Mac and which document they left
/// open. It must never carry tokens, credentials, or a copy of the Workspace
/// tree, and the Host is never told about it.
struct WarrenDesktopWorkspaceEditorState: Codable, Hashable, Sendable {
    /// Current record shape. Explicit so a later field can migrate rather than
    /// silently discard a user's marker.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Which Host issued `workspaceId`, named by the Endpoint the Desktop
    /// reached it through.
    ///
    /// Two Hosts can issue equal UUIDs, so a Workspace ID alone does not
    /// identify a Workspace. The Endpoint identity is what the rest of the
    /// Desktop already uses to keep one Host's resource IDs from being sent to
    /// another, and two Endpoint aliases for one Host keep separate markers
    /// rather than sharing a possibly wrong one.
    var hostId: String
    var workspaceId: WorkspaceID
    /// The durable marker: this Workspace's editor should come back on relaunch.
    /// Closing the region clears it, as does a confirmed Workspace deletion.
    var enabled: Bool
    /// Relative to the Workspace root, so moving a checkout does not invalidate
    /// it. Absolute paths would also leak the tree's location into defaults.
    var lastRelativeFile: String?
    var lastLine: Int?
    var lastColumn: Int?
    var updatedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        hostId: String,
        workspaceId: WorkspaceID,
        enabled: Bool,
        lastRelativeFile: String? = nil,
        lastLine: Int? = nil,
        lastColumn: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.hostId = hostId
        self.workspaceId = workspaceId
        self.enabled = enabled
        self.lastRelativeFile = lastRelativeFile
        self.lastLine = lastLine
        self.lastColumn = lastColumn
        self.updatedAt = updatedAt
    }
}

/// One document to open in the editor region, relative to the Workspace root.
public struct WarrenDesktopEditorDocument: Hashable, Sendable {
    public let relativeFile: String
    public let line: Int?
    public let column: Int?

    public init(relativeFile: String, line: Int? = nil, column: Int? = nil) {
        self.relativeFile = relativeFile
        self.line = line
        self.column = column
    }
}

/// The payload of `WarrenDesktopCommand.openEmbeddedEditor`.
///
/// The Workspace alone used to be enough, because the editor was a whole-page
/// mode with no document state to record. Now a request that arrived by opening
/// a terminal link is the one place Warren learns which file the user is on, so
/// the document travels with it and lands in the Workspace's marker.
public struct WarrenDesktopEmbeddedEditorRequest: Hashable, Sendable {
    public let workspaceID: WorkspaceID
    public let document: WarrenDesktopEditorDocument?

    public init(
        workspaceID: WorkspaceID,
        document: WarrenDesktopEditorDocument? = nil
    ) {
        self.workspaceID = workspaceID
        self.document = document
    }
}

/// The identity a record is stored under. A display name or a filesystem path
/// would collide across Hosts that mount similar trees.
struct WarrenDesktopWorkspaceEditorKey: Hashable, Sendable {
    let hostId: String
    let workspaceId: WorkspaceID
}

/// Folds the editor markers into the sidebar's activity projection (RFC 0021 §7).
///
/// `workspace.isActive` used to mean "has a running Warren Session", which hid
/// an editor-only Workspace behind the `Active only` filter — the one place the
/// user would look for it. This overlay adds the marked Workspaces without
/// inventing a Session or a Tab for them, and without reaching into the Host's
/// own projection: the marker is Desktop-local, so it is applied where the
/// sidebar is composed.
public struct WarrenDesktopEditorActivityOverlay: Hashable, Sendable {
    private let workspaceIDsByHost: [String: Set<WorkspaceID>]

    public init() {
        self.workspaceIDsByHost = [:]
    }

    init(states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState]) {
        var grouped: [String: Set<WorkspaceID>] = [:]
        for (key, state) in states where state.enabled {
            grouped[key.hostId, default: []].insert(key.workspaceId)
        }
        self.workspaceIDsByHost = grouped
    }

    /// The active set for one Host, widened by that Host's marked Workspaces.
    ///
    /// Scoped by Host so a marker written against one Endpoint cannot make a
    /// same-UUID Workspace on another Endpoint read as active.
    public func activeWorkspaceIDs(
        _ sessionActive: Set<WorkspaceID>,
        hostId: String
    ) -> Set<WorkspaceID> {
        guard let marked = workspaceIDsByHost[hostId] else { return sessionActive }
        return sessionActive.union(marked)
    }

    public func isEditorMarked(_ workspaceID: WorkspaceID, hostId: String) -> Bool {
        workspaceIDsByHost[hostId]?.contains(workspaceID) ?? false
    }
}

/// Versioned, client-local storage for the per-Workspace editor markers.
///
/// The whole table is one defaults value rather than a key per Workspace: the
/// store is read once per view identity and written whole on change, so a
/// removed marker cannot survive as an orphaned key.
enum WarrenDesktopWorkspaceEditorStateStore {
    private static let storageKey = "warren.desktop.workspaceEditorStates"

    static func restore(
        defaults: UserDefaults = .standard
    ) -> [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode(
                  [WarrenDesktopWorkspaceEditorState].self,
                  from: data
              ) else {
            return [:]
        }
        // A record from a newer Warren may carry fields this build cannot honor.
        // Dropping it silently would clear the user's marker, so unknown
        // versions are ignored in place and left on disk untouched.
        return Dictionary(
            records
                .filter { $0.schemaVersion == WarrenDesktopWorkspaceEditorState.currentSchemaVersion }
                .map { (key(for: $0), $0) },
            uniquingKeysWith: { first, second in
                first.updatedAt >= second.updatedAt ? first : second
            }
        )
    }

    static func save(
        _ states: [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState],
        defaults: UserDefaults = .standard
    ) {
        let records = states.values
            .filter(\.enabled)
            .sorted { lhs, rhs in
                (lhs.hostId, lhs.workspaceId.description)
                    < (rhs.hostId, rhs.workspaceId.description)
            }
        guard !records.isEmpty,
              let data = try? JSONEncoder().encode(records) else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        defaults.set(data, forKey: storageKey)
    }

    /// Restores the table, folding in any Workspace the superseded
    /// terminal/editor content mode had left selected on the editor.
    ///
    /// Before RFC 0021 the editor was a whole-page content mode, and the only
    /// thing persisted was the set of Workspaces whose mode was `.editor`. That
    /// set means exactly what the marker now means, so it migrates to
    /// `enabled = true` and the legacy key is retired. A user who had the editor
    /// open therefore finds it open, rather than finding it forgotten.
    static func restoreMigratingLegacyContentModes(
        scope: String,
        defaults: UserDefaults = .standard
    ) -> [WarrenDesktopWorkspaceEditorKey: WarrenDesktopWorkspaceEditorState] {
        var states = restore(defaults: defaults)
        let legacyKey = "\(legacyContentModeKeyPrefix).\(scope)"
        guard let legacyWorkspaceIDs = defaults.stringArray(forKey: legacyKey) else {
            return states
        }
        for value in legacyWorkspaceIDs {
            guard let workspaceID = WorkspaceID(uuidString: value) else { continue }
            let key = WarrenDesktopWorkspaceEditorKey(
                hostId: scope,
                workspaceId: workspaceID
            )
            // A record written by this build already knows more than the legacy
            // set does, so it wins.
            guard states[key] == nil else { continue }
            states[key] = WarrenDesktopWorkspaceEditorState(
                hostId: scope,
                workspaceId: workspaceID,
                enabled: true
            )
        }
        defaults.removeObject(forKey: legacyKey)
        save(states, defaults: defaults)
        return states
    }

    private static let legacyContentModeKeyPrefix = "warren.desktop.workspaceContentModes"

    static func key(
        for state: WarrenDesktopWorkspaceEditorState
    ) -> WarrenDesktopWorkspaceEditorKey {
        WarrenDesktopWorkspaceEditorKey(
            hostId: state.hostId,
            workspaceId: state.workspaceId
        )
    }
}
