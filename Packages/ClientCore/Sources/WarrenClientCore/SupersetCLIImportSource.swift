import Foundation

/// Reads Superset's public CLI JSON interface instead of depending on its
/// private SQLite schema. Each project gets its own workspace query so the
/// preview follows the same data Superset currently exposes to users.
public actor SupersetCLIImportSource {
    private let executableURL: URL?
    private let pathInspector: any SupersetImportPathInspecting

    public init(
        executableURL: URL? = nil,
        pathInspector: any SupersetImportPathInspecting = LocalSupersetImportPathInspector()
    ) {
        self.executableURL = executableURL
        self.pathInspector = pathInspector
    }

    public func preview() async throws -> SupersetImportPreview {
        let executable = try resolveExecutable()
        let projectsData = try await run(executable, arguments: ["projects", "list", "--local", "--json"])
        let projects = try decode([CLIProject].self, from: projectsData)
        let workspacesByProject = try await loadWorkspaces(for: projects, executable: executable)
        var candidates: [SupersetImportProjectCandidate] = []

        for project in projects {
            let projectPath = pathInspector.normalizedExistingDirectory(at: project.path)
            let projectIsGit = projectPath.map(pathInspector.isGitWorktree(at:)) ?? false
            let projectStatus: SupersetImportCandidateStatus = projectPath == nil
                ? .missing
                : (projectIsGit ? .ready : .invalid)
            let projectDiagnostic: String? = switch projectStatus {
            case .ready: nil
            case .missing: "Repository directory does not exist."
            case .invalid: "Repository path is not a Git worktree."
            }

            let workspaces = workspacesByProject[project.id] ?? []
            let workspaceCandidates = workspaces.isEmpty
                ? [mainWorkspace(for: project, projectPath: projectPath)]
                : workspaces.map {
                    workspaceCandidate($0, project: project, projectPath: projectPath)
                }

            candidates.append(SupersetImportProjectCandidate(
                sourceProjectID: project.id,
                name: project.name,
                repositoryPath: projectPath ?? URL(fileURLWithPath: project.path).standardizedFileURL.path,
                status: projectStatus,
                diagnostic: projectDiagnostic,
                workspaces: workspaceCandidates
            ))
        }

        return SupersetImportPreview(sourcePath: "superset-cli", schemaVersion: nil, projects: candidates)
    }

    private func loadWorkspaces(
        for projects: [CLIProject],
        executable: URL
    ) async throws -> [String: [CLIWorkspace]] {
        try await withThrowingTaskGroup(of: (String, [CLIWorkspace]).self, returning: [String: [CLIWorkspace]].self) { group in
            for project in projects {
                group.addTask {
                    let data = try await self.run(executable, arguments: [
                        "workspaces", "list", "--local", "--project", project.id, "--json",
                    ])
                    return (project.id, try self.decode([CLIWorkspace].self, from: data))
                }
            }

            var result: [String: [CLIWorkspace]] = [:]
            for try await (projectID, workspaces) in group {
                result[projectID] = workspaces
            }
            return result
        }
    }

    private func workspaceCandidate(
        _ workspace: CLIWorkspace,
        project: CLIProject,
        projectPath: String?
    ) -> SupersetImportWorkspaceCandidate {
        let path = workspace.worktreePath ?? workspace.path ?? projectPath ?? project.path
        let normalized = pathInspector.normalizedExistingDirectory(at: path)
        let status: SupersetImportCandidateStatus
        let diagnostic: String?
        if let normalized {
            if pathInspector.isGitWorktree(at: normalized) {
                status = .ready
                diagnostic = nil
            } else {
                status = .invalid
                diagnostic = "Workspace path is not a Git worktree."
            }
        } else {
            status = .missing
            diagnostic = "Workspace directory does not exist."
        }

        let type = workspace.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = type?.isEmpty == false ? type! : "worktree"
        let branch = workspace.branch?.isEmpty == true ? nil : workspace.branch
        let name = workspace.name?.isEmpty == false
            ? workspace.name!
            : (branch ?? project.name)
        return SupersetImportWorkspaceCandidate(
            id: workspace.id ?? workspace.worktreePath ?? path,
            sourceWorkspaceID: workspace.id,
            sourceWorktreeID: workspace.worktreePath,
            sourceProjectID: project.id,
            name: name,
            path: normalized ?? URL(fileURLWithPath: path).standardizedFileURL.path,
            branch: branch,
            kind: kind,
            status: status,
            diagnostic: diagnostic
        )
    }

    private func mainWorkspace(for project: CLIProject, projectPath: String?) -> SupersetImportWorkspaceCandidate {
        let path = projectPath ?? project.path
        let status: SupersetImportCandidateStatus
        let diagnostic: String?
        if let projectPath {
            if pathInspector.isGitWorktree(at: projectPath) {
                status = .ready
                diagnostic = nil
            } else {
                status = .invalid
                diagnostic = "Repository path is not a Git worktree."
            }
        } else {
            status = .missing
            diagnostic = "Repository directory does not exist."
        }
        return SupersetImportWorkspaceCandidate(
            id: "main:\(project.id)",
            sourceWorkspaceID: nil,
            sourceWorktreeID: nil,
            sourceProjectID: project.id,
            name: project.name,
            path: path,
            branch: nil,
            kind: "main",
            status: status,
            diagnostic: diagnostic
        )
    }

    private func resolveExecutable() throws -> URL {
        if let executableURL {
            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                throw SupersetCLIImportError.executableUnavailable(executableURL.path)
            }
            return executableURL
        }
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["SUPERSET_CLI_PATH"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SupersetCLIImportError.executableUnavailable(url.path)
            }
            return url
        }
        var candidates: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".superset/bin/superset"),
            URL(fileURLWithPath: "/opt/homebrew/bin/superset"),
            URL(fileURLWithPath: "/usr/local/bin/superset"),
            URL(fileURLWithPath: "/usr/bin/superset"),
        ]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("superset")
            })
        }
        if let value = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return value
        }
        throw SupersetCLIImportError.executableUnavailable("superset")
    }

    private func run(_ executable: URL, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let error = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let diagnostics = String(
                    data: error.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: SupersetCLIImportError.commandFailed(
                        arguments.joined(separator: " "), diagnostics
                    ))
                    return
                }
                continuation.resume(returning: data)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SupersetCLIImportError.invalidJSON(String(describing: error))
        }
    }
}

private struct CLIProject: Decodable {
    let id: String
    let name: String
    let path: String
}

private struct CLIWorkspace: Decodable {
    let id: String?
    let name: String?
    let branch: String?
    let type: String?
    let path: String?
    let worktreePath: String?
}

public enum SupersetCLIImportError: Error, CustomStringConvertible, Sendable {
    case executableUnavailable(String)
    case commandFailed(String, String)
    case invalidJSON(String)

    public var description: String {
        switch self {
        case .executableUnavailable(let path):
            "Superset CLI is unavailable: \(path)"
        case .commandFailed(let command, let diagnostics):
            diagnostics.isEmpty ? "Superset CLI failed: \(command)" : "Superset CLI failed: \(diagnostics)"
        case .invalidJSON(let detail):
            "Superset CLI returned invalid JSON: \(detail)"
        }
    }
}
