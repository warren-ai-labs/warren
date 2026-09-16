import Foundation

/// Which way a split divides its container.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Left and right columns.
    case horizontal
    /// Top and bottom rows.
    case vertical
}

/// One node of a Pane Group's tree.
///
/// A leaf carries the identity of its pane and of the Session it shows; a split
/// carries geometry only. Pane identity belongs to the Host, so a leaf a client
/// is creating arrives without one and is filled in by the Host.
public indirect enum PaneNode: Hashable, Sendable {
    case leaf(paneID: PaneID?, sessionID: TerminalSessionID)
    case split(axis: SplitAxis, ratio: Double, first: PaneNode, second: PaneNode)

    public static func leaf(sessionID: TerminalSessionID) -> PaneNode {
        .leaf(paneID: nil, sessionID: sessionID)
    }

    public var paneID: PaneID? {
        switch self {
        case .leaf(let paneID, _): return paneID
        case .split: return nil
        }
    }

    public var sessionID: TerminalSessionID? {
        switch self {
        case .leaf(_, let sessionID): return sessionID
        case .split: return nil
        }
    }

    public var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }

    /// Leaves in preorder: the order a client renders and numbers panes in.
    public var leaves: [PaneNode] {
        switch self {
        case .leaf: return [self]
        case .split(_, _, let first, let second): return first.leaves + second.leaves
        }
    }

    public var paneCount: Int { leaves.count }

    public var sessionIDs: [TerminalSessionID] { leaves.compactMap(\.sessionID) }

    public func paneIndex(forSession sessionID: TerminalSessionID) -> Int? {
        leaves.firstIndex { $0.sessionID == sessionID }.map { $0 + 1 }
    }

    /// Rebuilds the tree with one leaf's Session replaced, keeping pane identity
    /// and geometry. Returns nil when the Session is not in the tree.
    public func replacingSession(
        _ sessionID: TerminalSessionID,
        with replacement: TerminalSessionID
    ) -> PaneNode? {
        switch self {
        case .leaf(let paneID, let existing):
            guard existing == sessionID else { return nil }
            return .leaf(paneID: paneID, sessionID: replacement)
        case .split(let axis, let ratio, let first, let second):
            if let updated = first.replacingSession(sessionID, with: replacement) {
                return .split(axis: axis, ratio: ratio, first: updated, second: second)
            }
            if let updated = second.replacingSession(sessionID, with: replacement) {
                return .split(axis: axis, ratio: ratio, first: first, second: updated)
            }
            return nil
        }
    }

    /// Rebuilds the tree with one leaf's ratio replaced, addressed by the child
    /// path a divider drag owns: false descends to first, true to second.
    public func replacingRatio(_ ratio: Double, at path: [Bool]) -> PaneNode? {
        guard case .split(let axis, let existing, let first, let second) = self else { return nil }
        guard let firstStep = path.first else {
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }
        if firstStep {
            guard let updated = second.replacingRatio(ratio, at: Array(path.dropFirst())) else { return nil }
            return .split(axis: axis, ratio: existing, first: first, second: updated)
        }
        guard let updated = first.replacingRatio(ratio, at: Array(path.dropFirst())) else { return nil }
        return .split(axis: axis, ratio: existing, first: updated, second: second)
    }
}

extension PaneNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case paneId, sessionId, axis, ratio, first, second
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let axis = try values.decodeIfPresent(SplitAxis.self, forKey: .axis) {
            self = .split(
                axis: axis,
                ratio: try values.decodeIfPresent(Double.self, forKey: .ratio) ?? 0.5,
                first: try values.decode(PaneNode.self, forKey: .first),
                second: try values.decode(PaneNode.self, forKey: .second)
            )
            return
        }
        let rawSession = try values.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        guard let sessionID = TerminalSessionID(uuidString: rawSession) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sessionId,
                in: values,
                debugDescription: "A pane leaf needs a Session ID."
            )
        }
        let rawPane = try values.decodeIfPresent(String.self, forKey: .paneId)
        self = .leaf(paneID: rawPane.flatMap(PaneID.init(uuidString:)), sessionID: sessionID)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let paneID, let sessionID):
            try values.encodeIfPresent(paneID?.description, forKey: .paneId)
            try values.encode(sessionID.description, forKey: .sessionId)
        case .split(let axis, let ratio, let firstChild, let secondChild):
            try values.encode(axis, forKey: .axis)
            try values.encode(ratio, forKey: .ratio)
            try values.encode(firstChild, forKey: .first)
            try values.encode(secondChild, forKey: .second)
        }
    }
}

/// One whole-screen arrangement of running Sessions, owned by the Host.
///
/// A Pane Group is durable Host state: the Host stores the tree, so any client
/// reads the same shape without a reporting peer, and several arrangements can
/// coexist in one Workspace or Terminal Group.
public struct PaneGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: PaneGroupID
    public let hostID: HostID
    /// Workspace and Terminal Group ownership are mutually exclusive, exactly as
    /// they are for a Session.
    public let workspaceID: WorkspaceID?
    public let terminalGroupID: TerminalGroupID?
    public var name: String?
    public var order: Int
    public var tree: PaneNode
    /// The compare-and-swap token for a tree update. A rename or a reorder is
    /// not a tree change and leaves it alone.
    public var revision: UInt64
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: PaneGroupID = PaneGroupID(),
        hostID: HostID,
        workspaceID: WorkspaceID? = nil,
        terminalGroupID: TerminalGroupID? = nil,
        name: String? = nil,
        order: Int = 0,
        tree: PaneNode,
        revision: UInt64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.workspaceID = workspaceID
        self.terminalGroupID = terminalGroupID
        self.name = name
        self.order = order
        self.tree = tree
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var paneCount: Int { tree.paneCount }

    /// The Workspace or Terminal Group that owns the arrangement.
    public var ownerID: String { workspaceID?.description ?? terminalGroupID?.description ?? "" }

    /// A group is drawn as a group only once it holds more than one pane: a
    /// single pane has nothing to bind it to.
    public var isSplit: Bool { tree.paneCount > 1 }

    public func paneIndex(forSession sessionID: TerminalSessionID) -> Int? {
        tree.paneIndex(forSession: sessionID)
    }
}
