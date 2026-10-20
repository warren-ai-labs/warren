import Foundation
import WarrenDomain
import WarrenTransport

struct RemoteRoster: Decodable, Sendable, Equatable {
    struct Host: Decodable, Sendable, Equatable { let id: String; let name: String }
    struct Task: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let source: String?
        let externalID: String?
        let url: String?
        let pinned: Bool?
        let order: Int?
    }
    struct Project: Decodable, Sendable, Equatable {
        let id: String
        let name: String
        let path: String
        let setupScript: String?
        let autoImportGitWorktrees: Bool?
        let pinned: Bool?
        var activeSince: String? = nil
    }
    struct WorktreeCandidate: Decodable, Sendable {
        let path: String
        let name: String
        let branch: String?
        let locked: Bool?
        let imported: Bool
        let workspace: String?
    }
    struct Workspace: Decodable, Sendable, Equatable {
        let id: String
        let project: String
        let task: String?
        let name: String
        let path: String
        let branch: String?
        let managedWorktree: Bool?
        let worktreeLocked: Bool?
        let pinned: Bool?
        // Keep the wire value raw so a future Host state cannot invalidate
        // the entire roster; the projection maps known values below.
        let mergeState: String?
        var createdAt: String? = nil
        var lastActivityAt: String? = nil
    }
    /// The Host's pane tree. The wire shape is flat: a leaf carries pane and
    /// session identity, a split carries geometry. Recursion needs an indirect
    /// enum, and a leaf without a resolvable Session is dropped by the mapping
    /// into the projection rather than by the decoder.
    indirect enum PaneNode: Decodable, Sendable, Equatable {
        case leaf(paneID: String?, sessionID: String?)
        case split(axis: String, ratio: Double, first: PaneNode, second: PaneNode)

        private enum CodingKeys: String, CodingKey {
            case paneId, sessionId, axis, ratio, first, second
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let axis = try values.decodeIfPresent(String.self, forKey: .axis), !axis.isEmpty {
                self = .split(
                    axis: axis,
                    ratio: try values.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5,
                    first: try values.decode(PaneNode.self, forKey: .first),
                    second: try values.decode(PaneNode.self, forKey: .second)
                )
                return
            }
            self = .leaf(
                paneID: try values.decodeIfPresent(String.self, forKey: .paneId),
                sessionID: try values.decodeIfPresent(String.self, forKey: .sessionId)
            )
        }
    }

    struct PaneGroup: Decodable, Sendable, Equatable {
        let id: String
        let workspace: String?
        let name: String?
        let order: Int?
        let tree: PaneNode
        let revision: UInt64?
    }

    struct Session: Decodable, Sendable, Equatable {
        let id: String
        let workspace: String?
        let title: String
        let customTitle: String?
        /// The Host's one-line account of the last completed turn, when it
        /// asked a model for one. Absent on a Host that has no title endpoint
        /// configured, and then a row keeps its counts.
        let resultSentence: String?
        let kind: String
        /// The provider family the Host bound to a shell or custom Session.
        /// Dropping it made every Agent started inside a shell render as a
        /// plain terminal.
        var agentProvider: String? = nil
        let command: String?
        var process: String?
        var commandLine: String?
        var directory: String?
        let lifecycle: String
        let pinned: Bool?
        let agentStatus: AgentStatus?
        let agentTurn: AgentTurn?
        /// The shell's OSC 133 semantic prompt state. Nil when the shell
        /// never emitted a marker, so no part of the state is known.
        var shell: ShellMetadata? = nil
        var agentExecutionId: String? = nil
        /// `"acp"` marks a Session with no terminal: an Agent driven over the
        /// Agent Client Protocol, rendered by the Conversation surface.
        var runtimeKind: String? = nil
        var agentHandler: String? = nil
        /// The provider conversation a chat can hand off to its terminal UI.
        var agentSessionId: String? = nil
        var agentCapabilities: [String]? = nil
        /// When the Host created the Session, for the "nothing run yet"
        /// duration on a shell row.
        var createdAt: String? = nil
    }
    struct AgentTurn: Decodable, Sendable, Equatable {
        let id: UInt64
        let status: String
    }
    /// The OSC 133 semantic prompt state of a shell Session. Every field is
    /// live Host data; `ShellMetadata` absent means no marker was ever seen.
    struct ShellMetadata: Decodable, Sendable, Equatable {
        let atPrompt: Bool
        let runningCommand: String?
        let lastCommand: String?
        let lastExitCode: Int?
        let lastExitAt: String?

        init(
            atPrompt: Bool = false,
            runningCommand: String? = nil,
            lastCommand: String? = nil,
            lastExitCode: Int? = nil,
            lastExitAt: String? = nil
        ) {
            self.atPrompt = atPrompt
            self.runningCommand = runningCommand
            self.lastCommand = lastCommand
            self.lastExitCode = lastExitCode
            self.lastExitAt = lastExitAt
        }
    }
    struct AgentStatus: Decodable, Sendable, Equatable {
        let activity: String
        let attention: Attention?

        struct Attention: Decodable, Sendable, Equatable {
            let kind: String
            let reason: String
            let requestID: String?
            let since: String?

            private enum CodingKeys: String, CodingKey {
                case kind
                case reason
                case requestID = "requestId"
                case since
            }
        }
    }

    struct Delta: Decodable, Sendable {
        struct SessionMetadata: Decodable, Sendable, Equatable {
            let id: String
            let process: String?
            let commandLine: String?
            let directory: String?
            let shell: ShellMetadata?
        }

        struct SessionMetadataChanges: Decodable, Sendable {
            let upsert: [SessionMetadata]

            private enum CodingKeys: String, CodingKey {
                case upsert
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                upsert = try container.decodeIfPresent([SessionMetadata].self, forKey: .upsert) ?? []
            }
        }

        struct EntityChanges<Value: Decodable & Sendable>: Decodable, Sendable {
            let upsert: [Value]
            let remove: [String]
            let order: [String]?

            private enum CodingKeys: String, CodingKey {
                case upsert
                case remove
                case order
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                upsert = try container.decodeIfPresent([Value].self, forKey: .upsert) ?? []
                remove = try container.decodeIfPresent([String].self, forKey: .remove) ?? []
                order = try container.decodeIfPresent([String].self, forKey: .order)
            }
        }

        let baseRevision: UInt64
        let revision: UInt64
        let host: Host?
        let tasks: EntityChanges<Task>?
        let projects: EntityChanges<Project>?
        let workspaces: EntityChanges<Workspace>?
        let paneGroups: EntityChanges<PaneGroup>?
        let sessions: EntityChanges<Session>?
        let sessionMetadata: SessionMetadataChanges?
    }

    struct StreamMessage: Decodable, Sendable {
        let type: String
        let state: RemoteRoster?
        let delta: Delta?

        private enum CodingKeys: String, CodingKey {
            case type = "t"
            case state
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            state = try container.decodeIfPresent(RemoteRoster.self, forKey: .state)
            delta = type == "roster.delta" ? try Delta(from: decoder) : nil
        }
    }

    let revision: UInt64?
    let host: Host
    let tasks: [Task]
    let projects: [Project]
    let workspaces: [Workspace]
    let paneGroups: [PaneGroup]
    let sessions: [Session]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
        host = try container.decode(Host.self, forKey: .host)
        tasks = try container.decodeIfPresent([Task].self, forKey: .tasks) ?? []
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        paneGroups = try container.decodeIfPresent([PaneGroup].self, forKey: .paneGroups) ?? []
        sessions = try container.decodeIfPresent([Session].self, forKey: .sessions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case host
        case tasks
        case projects
        case workspaces
        case paneGroups
        case sessions
    }

    private init(
        revision: UInt64?,
        host: Host,
        tasks: [Task],
        projects: [Project],
        workspaces: [Workspace],
        paneGroups: [PaneGroup],
        sessions: [Session]
    ) {
        self.revision = revision
        self.host = host
        self.tasks = tasks
        self.projects = projects
        self.workspaces = workspaces
        self.paneGroups = paneGroups
        self.sessions = sessions
    }

    func applying(_ delta: Delta) -> RemoteRoster? {
        guard let revision,
              revision == delta.baseRevision,
              delta.revision >= delta.baseRevision else {
            return nil
        }
        return RemoteRoster(
            revision: delta.revision,
            host: delta.host ?? host,
            tasks: Self.applying(tasks, changes: delta.tasks, id: \.id),
            projects: Self.applying(projects, changes: delta.projects, id: \.id),
            workspaces: Self.applying(workspaces, changes: delta.workspaces, id: \.id),
            paneGroups: Self.applying(paneGroups, changes: delta.paneGroups, id: \.id),
            // Metadata travels separately from the Session entity, so apply it
            // first and let an entity upsert override it with the full record.
            sessions: Self.applying(
                Self.applyingMetadata(sessions, changes: delta.sessionMetadata),
                changes: delta.sessions,
                id: \.id
            )
        )
    }

    private static func applyingMetadata(
        _ current: [Session],
        changes: Delta.SessionMetadataChanges?
    ) -> [Session] {
        guard let changes, !changes.upsert.isEmpty else { return current }
        var byID: [String: Delta.SessionMetadata] = [:]
        for change in changes.upsert {
            byID[change.id] = change
        }
        return current.map { session in
            guard let change = byID[session.id] else { return session }
            var updated = session
            updated.process = change.process
            updated.commandLine = change.commandLine
            updated.directory = change.directory
            updated.shell = change.shell
            return updated
        }
    }

    private static func applying<Value: Decodable & Sendable>(
        _ current: [Value],
        changes: Delta.EntityChanges<Value>?,
        id: (Value) -> String
    ) -> [Value] {
        guard let changes else { return current }
        var valuesByID: [String: Value] = [:]
        for value in current {
            valuesByID[id(value)] = value
        }
        for value in changes.upsert {
            valuesByID[id(value)] = value
        }
        for value in changes.remove {
            valuesByID.removeValue(forKey: value)
        }

        var result: [Value] = []
        var emitted: Set<String> = []
        if let order = changes.order {
            for valueID in order {
                guard let value = valuesByID[valueID], emitted.insert(valueID).inserted else { continue }
                result.append(value)
            }
        }
        for value in current {
            let valueID = id(value)
            guard let latest = valuesByID[valueID], emitted.insert(valueID).inserted else { continue }
            result.append(latest)
        }
        for value in changes.upsert {
            let valueID = id(value)
            guard let latest = valuesByID[valueID], emitted.insert(valueID).inserted else { continue }
            result.append(latest)
        }
        return result
    }
}

extension RemoteRoster.AgentStatus {
    /// Reads a status straight from an Agent event's JSON under the decoder's
    /// own rules, without coding it through `Data` on the main actor:
    /// `activity` is required; `attention` may be absent or null, but one that
    /// is present and malformed rejects the whole status.
    init?(json value: WarrenRemoteJSONValue) {
        guard case .object(let fields) = value,
              case .string(let activity)? = fields["activity"] else { return nil }
        switch fields["attention"] {
        case nil, .null?:
            self.init(activity: activity, attention: nil)
        case .object(let raw)?:
            guard case .string(let kind)? = raw["kind"],
                  case .string(let reason)? = raw["reason"],
                  let requestID = Self.optionalString(raw["requestId"]),
                  let since = Self.optionalString(raw["since"]) else { return nil }
            self.init(
                activity: activity,
                attention: Attention(kind: kind, reason: reason, requestID: requestID, since: since)
            )
        default:
            return nil
        }
    }

    /// An optional string field: `.some(nil)` when absent or null, nil when it
    /// holds anything other than a string.
    private static func optionalString(_ value: WarrenRemoteJSONValue?) -> String?? {
        switch value {
        case nil, .null?: return .some(nil)
        case .string(let string)?: return .some(string)
        default: return nil
        }
    }
}
