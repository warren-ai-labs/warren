import WarrenDomain

public enum WarrenDesktopAutomaticSessionPolicy {
    public static func workspaceID(
        for action: WarrenDesktopAction,
        in projection: WarrenDesktopProjection,
        creatingWorkspaceIDs: Set<WorkspaceID>
    ) -> WorkspaceID? {
        let workspaceID: WorkspaceID?
        switch action {
        case .selectWorkspace(let id):
            workspaceID = id
        case .selectProject(let id):
            workspaceID = projection.firstWorkspace(in: id)?.id
        default:
            return nil
        }

        guard let workspaceID,
              projection.workspace(id: workspaceID) != nil,
              projection.tabs(in: workspaceID).isEmpty,
              !creatingWorkspaceIDs.contains(workspaceID) else {
            return nil
        }
        return workspaceID
    }
}
