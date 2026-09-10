import SwiftUI
import Combine
import WarrenDesignSystem
import WarrenDomain

/// A client-side reference to a Host-owned resource.
///
/// Endpoint scope is deliberately part of the value. Two Hosts may issue the
/// same UUID, and routing a later action by UUID alone would send the request
/// to whichever endpoint happens to be current at that moment.
public struct WarrenDesktopHostResourceRef<ID: Hashable & Sendable>: Hashable, Sendable {
    public let endpointID: String
    public let id: ID

    public init(endpointID: String, id: ID) {
        self.endpointID = endpointID
        self.id = id
    }

    public var navigationKey: String {
        "\(endpointID):\(id)"
    }
}

/// A resource selected from the aggregated Projects/Workspaces sidebar.
public enum WarrenDesktopSidebarResourceSelection: Hashable, Sendable {
    case project(WarrenDesktopHostResourceRef<ProjectID>)
    case workspace(WarrenDesktopHostResourceRef<WorkspaceID>)

    public var endpointID: String {
        switch self {
        case .project(let reference): reference.endpointID
        case .workspace(let reference): reference.endpointID
        }
    }
}

/// The value projection for one endpoint in the aggregated sidebar.
///
/// Only Projects and Workspaces are represented here. Tasks, terminal groups,
/// sessions, and the foreground terminal remain owned by the selected endpoint
/// in the existing single-host projection.
public struct WarrenDesktopSidebarHostProjection: Identifiable, Hashable, Sendable {
    public let endpointID: String
    public let endpointLabel: String
    public let host: WarrenDomain.Host?
    public let connectionState: WarrenDesktopConnectionState
    public let projectGroups: [WarrenDesktopProjectGroup]
    /// Host-local Tasks used to preserve task labels and attach/detach menus
    /// on the reused Workspace row. Tasks are not rendered as an aggregated
    /// section in v1.
    public let tasks: [WarrenTask]
    public let workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary]
    public let activeWorkspaceIDs: Set<WorkspaceID>
    public let lastError: String?

    public var id: String { endpointID }

    public var hostName: String? {
        host?.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public var title: String {
        guard let hostName else { return endpointLabel }
        if hostName.caseInsensitiveCompare(endpointLabel) == .orderedSame {
            return endpointLabel
        }
        return "\(endpointLabel) · \(hostName)"
    }

    public init(
        endpointID: String,
        endpointLabel: String,
        host: WarrenDomain.Host? = nil,
        connectionState: WarrenDesktopConnectionState,
        projectGroups: [WarrenDesktopProjectGroup] = [],
        tasks: [WarrenTask] = [],
        workspaceActivitySummaries: [WorkspaceID: WarrenDesktopWorkspaceActivitySummary] = [:],
        activeWorkspaceIDs: Set<WorkspaceID> = [],
        lastError: String? = nil
    ) {
        self.endpointID = endpointID
        self.endpointLabel = endpointLabel
        self.host = host
        self.connectionState = connectionState
        self.projectGroups = projectGroups
        self.tasks = tasks
        self.workspaceActivitySummaries = workspaceActivitySummaries
        self.activeWorkspaceIDs = activeWorkspaceIDs
        self.lastError = lastError
    }

    public func projectReference(_ projectID: ProjectID) -> WarrenDesktopHostResourceRef<ProjectID> {
        WarrenDesktopHostResourceRef(endpointID: endpointID, id: projectID)
    }

    public func workspaceReference(_ workspaceID: WorkspaceID) -> WarrenDesktopHostResourceRef<WorkspaceID> {
        WarrenDesktopHostResourceRef(endpointID: endpointID, id: workspaceID)
    }
}

/// Ordered, client-local read model consumed by the desktop sidebar.
public struct WarrenDesktopSidebarProjection: Equatable, Sendable {
    public let hosts: [WarrenDesktopSidebarHostProjection]
    public let currentEndpointID: String

    public init(
        hosts: [WarrenDesktopSidebarHostProjection] = [],
        currentEndpointID: String = "local"
    ) {
        self.hosts = hosts
        self.currentEndpointID = currentEndpointID
    }

    public var isMultiHost: Bool { hosts.count > 1 }

    public func host(for endpointID: String) -> WarrenDesktopSidebarHostProjection? {
        hosts.first { $0.endpointID == endpointID }
    }

    public func project(
        _ reference: WarrenDesktopHostResourceRef<ProjectID>
    ) -> Project? {
        host(for: reference.endpointID)?.projectGroups
            .first { $0.project.id == reference.id }?.project
    }

    public func workspace(
        _ reference: WarrenDesktopHostResourceRef<WorkspaceID>
    ) -> Workspace? {
        host(for: reference.endpointID)?.projectGroups
            .flatMap(\.workspaces)
            .first { $0.id == reference.id }
    }
}

/// Stable presentation-only Host tint assignment.
///
/// The assignment is keyed by endpoint alias, never by array position. The
/// palette is intentionally low-saturation and is applied by the sidebar as a
/// four-percent wash; it is not persisted in the endpoint catalog.
public enum WarrenDesktopHostTint {
    public static let maximumOpacity = 0.08
    public static let targetOpacity = 0.04

    public static func color(
        for endpointID: String,
        tokens: WarrenColorTokens
    ) -> Color {
        let palette = tokens.hostSectionTints
        guard !palette.isEmpty else { return .clear }
        return palette[index(for: endpointID, count: palette.count)]
    }

    /// Resolves palette collisions for one visible sidebar roster. Sorting the
    /// aliases makes the result independent of CLI order; callers that need
    /// to preserve assignments while aliases are added should retain the
    /// returned map and allocate only new aliases.
    public static func indices(
        for endpointIDs: [String],
        count: Int
    ) -> [String: Int] {
        indices(for: endpointIDs, count: count, preserving: [:])
    }

    /// Allocates new aliases without changing slots already assigned to a
    /// visible alias. This keeps a Host's wash stable when the CLI adds an
    /// alias whose hash collides with an existing one.
    public static func indices(
        for endpointIDs: [String],
        count: Int,
        preserving existing: [String: Int]
    ) -> [String: Int] {
        guard count > 0 else { return [:] }
        let uniqueIDs = Set(endpointIDs)
        var result: [String: Int] = existing.reduce(into: [:]) { result, entry in
            guard uniqueIDs.contains(entry.key), (0..<count).contains(entry.value) else { return }
            result[entry.key] = entry.value
        }
        var used: Set<Int> = Set(result.values)
        for endpointID in uniqueIDs.sorted() where result[endpointID] == nil {
            var candidate = index(for: endpointID, count: count)
            if used.count < count {
                while used.contains(candidate) {
                    candidate = (candidate + 1) % count
                }
                used.insert(candidate)
            }
            result[endpointID] = candidate
        }
        return result
    }

    public static func color(
        for endpointID: String,
        among endpointIDs: [String],
        tokens: WarrenColorTokens
    ) -> Color {
        let palette = tokens.hostSectionTints
        guard !palette.isEmpty else { return .clear }
        let assignments = indices(for: endpointIDs, count: palette.count)
        let slot = assignments[endpointID] ?? index(for: endpointID, count: palette.count)
        return palette[slot]
    }

    public static func index(for endpointID: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        // FNV-1a keeps the result deterministic across launches and processes;
        // Swift's Hasher is deliberately randomized and is not suitable here.
        var hash: UInt64 = 14695981039346656037
        for byte in endpointID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return Int(hash % UInt64(count))
    }
}

/// Main-actor-owned presentation state for Host tint slots. It deliberately
/// retains assignments across roster/configuration updates instead of
/// deriving them from the current array order.
@MainActor
public final class WarrenDesktopHostTintAllocator: ObservableObject {
    @Published public private(set) var assignments: [String: Int] = [:]

    public init() {}

    public func update(endpointIDs: [String], paletteCount: Int) {
        let next = WarrenDesktopHostTint.indices(
            for: endpointIDs,
            count: paletteCount,
            preserving: assignments
        )
        guard next != assignments else { return }
        assignments = next
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
