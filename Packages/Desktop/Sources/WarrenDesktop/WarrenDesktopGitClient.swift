import Foundation

/// Transport boundary for the desktop Git panel. The shell never talks to the
/// wire directly; the composition root injects a client backed by the daemon
/// WebSocket, and tests inject an in-memory stub.
@MainActor
public protocol WarrenDesktopGitClient: Sendable {
    func panel(workspaceID: String, fetch: Bool, force: Bool) async throws -> WarrenDesktopGitPanel
    func diff(workspaceID: String, path: String, staged: Bool, commit: String?) async throws -> WarrenDesktopGitDiff
    func pull(workspaceID: String) async throws -> WarrenDesktopGitCommandResult
    func push(workspaceID: String) async throws -> WarrenDesktopGitCommandResult
    func checkout(workspaceID: String, branch: String, create: Bool) async throws -> WarrenDesktopGitCommandResult
    func commit(workspaceID: String, message: String) async throws -> WarrenDesktopGitCommandResult
    func createPullRequest(workspaceID: String, title: String, body: String) async throws -> WarrenDesktopGitPullRequest
}
