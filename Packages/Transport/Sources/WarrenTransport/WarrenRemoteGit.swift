import Foundation

// The Host's Git surface for one Workspace (`git.panel`, `git.diff`, and the
// commands that change the checkout). The Web Git panel reads the same wire
// shapes; these types only decode them.

public struct WarrenRemoteGitPanel: Decodable, Sendable, Equatable {
    public let workspace: String
    public let branch: String
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let aheadOfMain: Int
    public let remote: String?
    public let mainBranch: String?
    public let merged: Bool
    public let operation: String?
    public let changes: [WarrenRemoteGitChange]
    public let commits: [WarrenRemoteGitCommit]
    public let unmergedCommits: [WarrenRemoteGitCommit]
    public let branches: [WarrenRemoteGitBranch]
    public let pullRequest: WarrenRemoteGitPullRequest?
    public let pullRequestError: String?
    public let refreshing: Bool

    enum CodingKeys: String, CodingKey {
        case workspace, branch, upstream, ahead, behind, aheadOfMain, remote, mainBranch, merged, operation
        case changes, commits, unmergedCommits, branches, pullRequest, pullRequestError, refreshing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspace = try container.decodeIfPresent(String.self, forKey: .workspace) ?? ""
        branch = try container.decodeIfPresent(String.self, forKey: .branch) ?? ""
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        aheadOfMain = try container.decodeIfPresent(Int.self, forKey: .aheadOfMain) ?? 0
        remote = try container.decodeIfPresent(String.self, forKey: .remote)
        mainBranch = try container.decodeIfPresent(String.self, forKey: .mainBranch)
        merged = try container.decodeIfPresent(Bool.self, forKey: .merged) ?? false
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        changes = try container.decodeIfPresent([WarrenRemoteGitChange].self, forKey: .changes) ?? []
        commits = try container.decodeIfPresent([WarrenRemoteGitCommit].self, forKey: .commits) ?? []
        unmergedCommits = try container.decodeIfPresent([WarrenRemoteGitCommit].self, forKey: .unmergedCommits) ?? []
        branches = try container.decodeIfPresent([WarrenRemoteGitBranch].self, forKey: .branches) ?? []
        pullRequest = try container.decodeIfPresent(WarrenRemoteGitPullRequest.self, forKey: .pullRequest)
        pullRequestError = try container.decodeIfPresent(String.self, forKey: .pullRequestError)
        refreshing = try container.decodeIfPresent(Bool.self, forKey: .refreshing) ?? false
    }

    /// The main line without its remote prefix: `origin/main` reads `main`.
    public var mainBranchShortName: String? {
        guard let mainBranch, !mainBranch.isEmpty else { return nil }
        let trimmed = mainBranch.replacingOccurrences(of: "refs/remotes/", with: "")
        guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}

public struct WarrenRemoteGitChange: Decodable, Sendable, Equatable, Hashable {
    public let path: String
    /// Porcelain status letter: M, A, D, R, C, U, or `?` for untracked.
    public let status: String
    public let staged: Bool
    public let renameFrom: String?
    public let added: Int
    public let deleted: Int

    enum CodingKeys: String, CodingKey {
        case path, status, staged, renameFrom, added, deleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        renameFrom = try container.decodeIfPresent(String.self, forKey: .renameFrom)
        added = try container.decodeIfPresent(Int.self, forKey: .added) ?? 0
        deleted = try container.decodeIfPresent(Int.self, forKey: .deleted) ?? 0
    }
}

public struct WarrenRemoteGitCommit: Decodable, Sendable, Equatable, Identifiable {
    public let hash: String
    public let short: String
    public let subject: String
    public let author: String
    public let time: Date?
    public let files: [WarrenRemoteGitChange]

    public var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, short, subject, author, time, files
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        short = try container.decodeIfPresent(String.self, forKey: .short) ?? String(hash.prefix(7))
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        files = try container.decodeIfPresent([WarrenRemoteGitChange].self, forKey: .files) ?? []
        let raw = try container.decodeIfPresent(String.self, forKey: .time) ?? ""
        time = Self.parseTime(raw)
    }

    /// Go writes RFC 3339 with or without fractional seconds.
    static func parseTime(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

public struct WarrenRemoteGitBranch: Decodable, Sendable, Equatable {
    public let name: String
    public let remote: Bool

    enum CodingKeys: String, CodingKey { case name, remote }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        remote = try container.decodeIfPresent(Bool.self, forKey: .remote) ?? false
    }
}

public struct WarrenRemoteGitPullRequest: Decodable, Sendable, Equatable {
    public let number: Int
    public let title: String
    public let body: String
    public let state: String
    public let draft: Bool
    public let url: String
    public let author: String
    public let base: String
    public let head: String

    enum CodingKeys: String, CodingKey { case number, title, body, state, draft, url, author, base, head }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decodeIfPresent(Int.self, forKey: .number) ?? 0
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        base = try container.decodeIfPresent(String.self, forKey: .base) ?? ""
        head = try container.decodeIfPresent(String.self, forKey: .head) ?? ""
    }
}

public struct WarrenRemoteGitDiff: Decodable, Sendable, Equatable {
    public let diff: String
    public let content: String
    public let diffTruncated: Bool
    public let contentTruncated: Bool

    enum CodingKeys: String, CodingKey { case diff, content, diffTruncated, contentTruncated }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        diff = try container.decodeIfPresent(String.self, forKey: .diff) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        diffTruncated = try container.decodeIfPresent(Bool.self, forKey: .diffTruncated) ?? false
        contentTruncated = try container.decodeIfPresent(Bool.self, forKey: .contentTruncated) ?? false
    }
}

public struct WarrenRemoteGitCommandResult: Decodable, Sendable, Equatable {
    public let message: String

    enum CodingKeys: String, CodingKey { case message }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }
}

extension WarrenRemoteClient {
    /// The Workspace's branch, changes, history, and pull request. A cached
    /// panel may come back with `refreshing` while the Host revalidates it.
    public func gitPanel(workspaceID: String, fetch: Bool = false, force: Bool = false) async throws -> WarrenRemoteGitPanel {
        try await request(
            "git.panel",
            params: ["workspace": workspaceID, "fetch": fetch ? "true" : "false", "force": force ? "true" : "false"],
            decoding: WarrenRemoteGitPanel.self
        )
    }

    /// One file's diff and content: in the working tree, in the index when
    /// `staged`, or as of `commit`.
    public func gitDiff(workspaceID: String, path: String, staged: Bool = false, commit: String? = nil) async throws -> WarrenRemoteGitDiff {
        var params = ["workspace": workspaceID, "path": path, "staged": staged ? "true" : "false"]
        if let commit, !commit.isEmpty { params["commit"] = commit }
        return try await request("git.diff", params: params, decoding: WarrenRemoteGitDiff.self)
    }

    public func gitCommit(workspaceID: String, message: String) async throws -> WarrenRemoteGitCommandResult {
        try await request("git.commit", params: ["workspace": workspaceID, "message": message], decoding: WarrenRemoteGitCommandResult.self)
    }

    public func gitPush(workspaceID: String) async throws -> WarrenRemoteGitCommandResult {
        try await request("git.push", params: ["workspace": workspaceID], decoding: WarrenRemoteGitCommandResult.self)
    }

    public func gitPull(workspaceID: String) async throws -> WarrenRemoteGitCommandResult {
        try await request("git.pull", params: ["workspace": workspaceID], decoding: WarrenRemoteGitCommandResult.self)
    }

    public func gitCreatePullRequest(workspaceID: String, title: String, body: String) async throws -> WarrenRemoteGitPullRequest {
        try await request(
            "git.pr.create",
            params: ["workspace": workspaceID, "title": title, "body": body],
            decoding: WarrenRemoteGitPullRequest.self
        )
    }
}
