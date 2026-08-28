import Foundation
import WarrenDesktop

/// Daemon-backed implementation of the desktop Git panel transport. It is a
/// thin JSON decoder over the same WebSocket request channel the rest of the
/// macOS client uses; the Git domain types live in `WarrenDesktop`.
@MainActor
struct WarrenRemoteGitClient: WarrenDesktopGitClient {
    private let request: @MainActor (String, [String: String]) async throws -> Data

    init(
        request: @escaping @MainActor (String, [String: String]) async throws -> Data
    ) {
        self.request = request
    }

    func panel(workspaceID: String, fetch: Bool, force: Bool) async throws -> WarrenDesktopGitPanel {
        try decode(await request("git.panel", [
            "workspace": workspaceID,
            "fetch": String(fetch),
            "force": String(force),
        ]))
    }

    func diff(
        workspaceID: String,
        path: String,
        staged: Bool,
        commit: String?
    ) async throws -> WarrenDesktopGitDiff {
        var params = [
            "workspace": workspaceID,
            "path": path,
            "staged": String(staged),
        ]
        if let commit {
            params["commit"] = commit
        }
        return try decode(await request("git.diff", params))
    }

    func pull(workspaceID: String) async throws -> WarrenDesktopGitCommandResult {
        try decode(await request("git.pull", ["workspace": workspaceID]))
    }

    func push(workspaceID: String) async throws -> WarrenDesktopGitCommandResult {
        try decode(await request("git.push", ["workspace": workspaceID]))
    }

    func checkout(
        workspaceID: String,
        branch: String,
        create: Bool
    ) async throws -> WarrenDesktopGitCommandResult {
        try decode(await request("git.checkout", [
            "workspace": workspaceID,
            "branch": branch,
            "create": String(create),
        ]))
    }

    func commit(workspaceID: String, message: String) async throws -> WarrenDesktopGitCommandResult {
        try decode(await request("git.commit", [
            "workspace": workspaceID,
            "message": message,
        ]))
    }

    func createPullRequest(
        workspaceID: String,
        title: String,
        body: String
    ) async throws -> WarrenDesktopGitPullRequest {
        try decode(await request("git.pr.create", [
            "workspace": workspaceID,
            "title": title,
            "body": body,
        ]))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}
