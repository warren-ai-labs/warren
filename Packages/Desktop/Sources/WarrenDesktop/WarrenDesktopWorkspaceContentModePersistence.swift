import Foundation
import WarrenDomain

enum WarrenDesktopWorkspaceContentModePersistence {
    private static let keyPrefix = "warren.desktop.workspaceContentModes"

    static func restore(
        scope: String,
        defaults: UserDefaults = .standard
    ) -> [WorkspaceID: WarrenDesktopWorkspaceContentMode] {
        Dictionary(uniqueKeysWithValues: (
            defaults.stringArray(forKey: storageKey(scope: scope)) ?? []
        ).compactMap { value in
            guard let rawValue = UUID(uuidString: value) else { return nil }
            return (WorkspaceID(rawValue: rawValue), .editor)
        })
    }

    static func save(
        _ modes: [WorkspaceID: WarrenDesktopWorkspaceContentMode],
        scope: String,
        validWorkspaceIDs: Set<WorkspaceID>,
        defaults: UserDefaults = .standard
    ) {
        let editorWorkspaceIDs = modes.compactMap { workspaceID, mode in
            mode == .editor && validWorkspaceIDs.contains(workspaceID)
                ? workspaceID.description
                : nil
        }.sorted()
        let key = storageKey(scope: scope)
        if editorWorkspaceIDs.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(editorWorkspaceIDs, forKey: key)
        }
    }

    private static func storageKey(scope: String) -> String {
        "\(keyPrefix).\(scope)"
    }
}
