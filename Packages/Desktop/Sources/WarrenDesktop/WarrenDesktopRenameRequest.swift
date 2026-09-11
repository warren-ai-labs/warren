import WarrenDomain

/// Identifies a rename interaction so the desktop root can own its modal
/// presentation independently from the row that initiated it.
enum WarrenDesktopRenameRequest: Hashable, Sendable {
    case task(TaskID, name: String)
    case project(ProjectID, name: String)
    case workspace(WorkspaceID, name: String)
    case session(TerminalSessionID, title: String)
    case endpoint(String, name: String)

    var initialValue: String {
        switch self {
        case .task(_, let name), .project(_, let name), .workspace(_, let name): name
        case .session(_, let title): title
        case .endpoint(_, let name): name
        }
    }

    var title: String {
        switch self {
        case .task: "Rename Task"
        case .project: "Rename Project"
        case .workspace: "Rename Workspace"
        case .session: "Rename Session"
        case .endpoint: "Customize Server Display Name"
        }
    }

    var message: String {
        switch self {
        case .task:
            "Only the task label changes; linked workspaces stay attached."
        case .project:
            "Only the sidebar label changes; the repository path stays the same."
        case .workspace:
            "The Git branch name and worktree path are unchanged."
        case .session:
            "Custom titles are stored on the Host and shared by every client."
        case .endpoint:
            "Only the label shown in Warren changes; the endpoint alias and connection remain unchanged."
        }
    }

    var fieldLabel: String {
        switch self {
        case .task: "Task name"
        case .project: "Project name"
        case .workspace: "Workspace name"
        case .session: "Session title"
        case .endpoint: "Display name"
        }
    }

    var confirmLabel: String {
        switch self {
        case .endpoint: "Save"
        default: "Rename"
        }
    }
}
