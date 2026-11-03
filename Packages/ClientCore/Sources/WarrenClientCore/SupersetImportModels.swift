import Foundation
import WarrenDomain

public enum SupersetImportCandidateStatus: String, Codable, Hashable, Sendable {
    case ready
    case missing
    case invalid
}

public struct SupersetImportWorkspaceCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sourceWorkspaceID: String?
    public let sourceWorktreeID: String?
    public let sourceProjectID: String
    public let name: String
    public let path: String
    public let branch: String?
    public let kind: String
    public let status: SupersetImportCandidateStatus
    public let diagnostic: String?

    public init(
        id: String,
        sourceWorkspaceID: String?,
        sourceWorktreeID: String?,
        sourceProjectID: String,
        name: String,
        path: String,
        branch: String?,
        kind: String,
        status: SupersetImportCandidateStatus,
        diagnostic: String? = nil
    ) {
        self.id = id
        self.sourceWorkspaceID = sourceWorkspaceID
        self.sourceWorktreeID = sourceWorktreeID
        self.sourceProjectID = sourceProjectID
        self.name = name
        self.path = path
        self.branch = branch
        self.kind = kind
        self.status = status
        self.diagnostic = diagnostic
    }
}

public struct SupersetImportProjectCandidate: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let sourceProjectID: String
    public let name: String
    public let repositoryPath: String
    public let status: SupersetImportCandidateStatus
    public let diagnostic: String?
    public let workspaces: [SupersetImportWorkspaceCandidate]

    public init(
        sourceProjectID: String,
        name: String,
        repositoryPath: String,
        status: SupersetImportCandidateStatus,
        diagnostic: String? = nil,
        workspaces: [SupersetImportWorkspaceCandidate]
    ) {
        self.id = sourceProjectID
        self.sourceProjectID = sourceProjectID
        self.name = name
        self.repositoryPath = repositoryPath
        self.status = status
        self.diagnostic = diagnostic
        self.workspaces = workspaces
    }
}

public struct SupersetImportPreview: Codable, Hashable, Sendable, Identifiable {
    public let sourcePath: String
    public let schemaVersion: Int?
    public let projects: [SupersetImportProjectCandidate]

    public var id: String { sourcePath }

    public init(
        sourcePath: String,
        schemaVersion: Int?,
        projects: [SupersetImportProjectCandidate]
    ) {
        self.sourcePath = sourcePath
        self.schemaVersion = schemaVersion
        self.projects = projects
    }

    public var readyProjectCount: Int {
        projects.filter { $0.status == .ready }.count
    }

    public var readyWorkspaceCount: Int {
        projects.flatMap(\.workspaces).filter { $0.status == .ready }.count
    }

    public var readyProjectIDs: Set<String> {
        Set(projects.filter { $0.status == .ready }.map(\.id))
    }

    /// Returns a preview limited to the given project IDs. Workspace candidates
    /// are copied unchanged so later filtering still sees the full source
    /// metadata for each selected project.
    public func selectingProjects(_ ids: Set<String>) -> SupersetImportPreview {
        SupersetImportPreview(
            sourcePath: sourcePath,
            schemaVersion: schemaVersion,
            projects: projects.filter { ids.contains($0.id) }
        )
    }
}

public struct SupersetImportCommitResult: Codable, Hashable, Sendable {
    public let importedProjectIDs: [String]
    public let importedWorkspaceIDs: [String]
    public let skippedProjectCount: Int
    public let skippedWorkspaceCount: Int
    public let wasAlreadyImported: Bool

    public init(
        importedProjectIDs: [String],
        importedWorkspaceIDs: [String],
        skippedProjectCount: Int,
        skippedWorkspaceCount: Int,
        wasAlreadyImported: Bool
    ) {
        self.importedProjectIDs = importedProjectIDs
        self.importedWorkspaceIDs = importedWorkspaceIDs
        self.skippedProjectCount = skippedProjectCount
        self.skippedWorkspaceCount = skippedWorkspaceCount
        self.wasAlreadyImported = wasAlreadyImported
    }
}

public protocol SupersetImportCommitting: Sendable {
    func importSuperset(
        _ preview: SupersetImportPreview,
        into hostID: HostID
    ) async throws -> SupersetImportCommitResult

    func hasSupersetImportReceipt(sourceURL: URL) async throws -> Bool
}

public protocol SupersetImportPathInspecting: Sendable {
    func normalizedExistingDirectory(at path: String) -> String?
    func isGitWorktree(at path: String) -> Bool
}

public struct LocalSupersetImportPathInspector: SupersetImportPathInspecting {
    public init() {}

    public func normalizedExistingDirectory(at path: String) -> String? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url.resolvingSymlinksInPath().path
    }

    public func isGitWorktree(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path, "rev-parse", "--is-inside-work-tree"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

public enum SupersetImportSourceError: Error, Equatable, CustomStringConvertible {
    case sourceMissing(path: String)
    case sourceOpenFailed(path: String, reason: String)
    case incompatibleSchema(missing: [String])
    case readFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case let .sourceMissing(path):
            "Superset database does not exist at \(path)."
        case let .sourceOpenFailed(path, reason):
            "Could not open Superset database at \(path): \(reason)"
        case let .incompatibleSchema(missing):
            "Superset database is missing required schema: \(missing.joined(separator: ", "))."
        case let .readFailed(path, reason):
            "Could not read Superset database at \(path): \(reason)"
        }
    }
}
