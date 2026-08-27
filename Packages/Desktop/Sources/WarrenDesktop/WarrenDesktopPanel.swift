import SwiftUI
import WarrenDomain

/// The intentionally small context shared by every desktop Panel module.
public struct WarrenDesktopPanelContext: Hashable, Sendable {
    public let endpointID: String
    public let workspaceID: WorkspaceID?
    public let workspaceName: String

    public init(endpointID: String, workspaceID: WorkspaceID? = nil, workspaceName: String = "") {
        self.endpointID = endpointID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
    }
}

public struct WarrenDesktopPanelDescriptor: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String?
    public var icon: String? { systemImage }

    public init(id: String, title: String, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
    }
}

/// A module owns its lifecycle and transport-facing invalidation callback;
/// the registry only coordinates those boundaries and never owns module data.
@MainActor
public final class WarrenDesktopPanelContribution {
    public typealias Availability = @MainActor (WarrenDesktopPanelContext) -> Bool
    public typealias Activation = @MainActor (WarrenDesktopPanelContext) -> Void
    public typealias Lifecycle = @MainActor () -> Void
    public typealias ContentBuilder = @MainActor (WarrenDesktopPanelContext) -> AnyView
    public typealias ConnectionGenerationCallback = @MainActor (String, UInt64) -> Void

    public let descriptor: WarrenDesktopPanelDescriptor
    private let availability: Availability
    private let activateHandler: Activation
    private let deactivateHandler: Lifecycle
    private let refreshHandler: Lifecycle
    private let closeDetailHandler: Lifecycle
    private let rightContentHandler: ContentBuilder
    private let centerDetailHandler: ContentBuilder?
    private let connectionGenerationHandler: ConnectionGenerationCallback

    public init(
        descriptor: WarrenDesktopPanelDescriptor,
        availability: @escaping Availability = { _ in true },
        activate: @escaping Activation = { _ in },
        deactivate: @escaping Lifecycle = {},
        refresh: @escaping Lifecycle = {},
        closeDetail: @escaping Lifecycle = {},
        rightContent: @escaping ContentBuilder = { _ in AnyView(EmptyView()) },
        centerDetail: ContentBuilder? = nil,
        connectionGenerationWillChange: @escaping ConnectionGenerationCallback = { _, _ in }
    ) {
        self.descriptor = descriptor
        self.availability = availability
        self.activateHandler = activate
        self.deactivateHandler = deactivate
        self.refreshHandler = refresh
        self.closeDetailHandler = closeDetail
        self.rightContentHandler = rightContent
        self.centerDetailHandler = centerDetail
        self.connectionGenerationHandler = connectionGenerationWillChange
    }

    public var id: String { descriptor.id }

    public func isAvailable(in context: WarrenDesktopPanelContext) -> Bool {
        availability(context)
    }

    public func availability(in context: WarrenDesktopPanelContext) -> Bool {
        isAvailable(in: context)
    }

    public func activate(in context: WarrenDesktopPanelContext) {
        activateHandler(context)
    }

    public func activate(context: WarrenDesktopPanelContext) {
        activate(in: context)
    }

    public func deactivate(in context: WarrenDesktopPanelContext) {
        deactivateHandler()
    }

    public func deactivate() {
        deactivateHandler()
    }

    public func refresh(in context: WarrenDesktopPanelContext) {
        refreshHandler()
    }

    public func refresh() {
        refreshHandler()
    }

    public func closeDetail(in context: WarrenDesktopPanelContext) {
        closeDetailHandler()
    }

    public func closeDetail() {
        closeDetailHandler()
    }

    public func rightContent(in context: WarrenDesktopPanelContext) -> AnyView {
        rightContentHandler(context)
    }

    public func rightPanelContent(in context: WarrenDesktopPanelContext) -> AnyView {
        rightContent(in: context)
    }

    public func centerDetail(in context: WarrenDesktopPanelContext) -> AnyView? {
        centerDetailHandler?(context)
    }

    public func centerDetailContent(in context: WarrenDesktopPanelContext) -> AnyView? {
        centerDetail(in: context)
    }

    public func connectionWillChange(endpointID: String, generation: UInt64) {
        connectionGenerationHandler(endpointID, generation)
    }

    public func invalidateConnectionGeneration(endpointID: String, generation: UInt64) {
        connectionWillChange(endpointID: endpointID, generation: generation)
    }
}

@MainActor
public final class WarrenDesktopPanelRegistry {
    private var contributionsByID: [String: WarrenDesktopPanelContribution] = [:]
    private var orderedIDs: [String] = []

    public init() {}

    @discardableResult
    public func register(_ contribution: WarrenDesktopPanelContribution) -> String {
        let id = contribution.id
        if contributionsByID[id] == nil {
            orderedIDs.append(id)
        }
        contributionsByID[id] = contribution
        return id
    }

    @discardableResult
    public func unregister(panelID: String) -> WarrenDesktopPanelContribution? {
        orderedIDs.removeAll { $0 == panelID }
        return contributionsByID.removeValue(forKey: panelID)
    }

    public var panelIDs: [String] { orderedIDs }

    public func contribution(panelID: String) -> WarrenDesktopPanelContribution? {
        contributionsByID[panelID]
    }

    public func isAvailable(panelID: String, in context: WarrenDesktopPanelContext) -> Bool {
        contributionsByID[panelID]?.isAvailable(in: context) ?? false
    }

    public func availablePanelIDs(in context: WarrenDesktopPanelContext) -> [String] {
        orderedIDs.filter { isAvailable(panelID: $0, in: context) }
    }

    public func availableContributions(in context: WarrenDesktopPanelContext) -> [WarrenDesktopPanelContribution] {
        availablePanelIDs(in: context).compactMap { contributionsByID[$0] }
    }

    /// Availability affects presentation only. A retained active ID is kept
    /// until its contribution is removed, so a Workspace switch cannot invoke
    /// an unexpected module replacement.
    public func retainedActivePanelID(_ panelID: String?) -> String? {
        guard let panelID, contributionsByID[panelID] != nil else { return nil }
        return panelID
    }

    public func broadcastConnectionWillChange(endpointID: String, generation: UInt64) {
        for id in orderedIDs {
            contributionsByID[id]?.connectionWillChange(endpointID: endpointID, generation: generation)
        }
    }

    public func broadcastConnectionGeneration(endpointID: String, generation: UInt64) {
        broadcastConnectionWillChange(endpointID: endpointID, generation: generation)
    }

    /// The lifecycle owner can retain this callback without retaining the
    /// registry, preventing a registry → module → transport cycle.
    public func makeConnectionLifecycleCallback() -> @MainActor (String, UInt64) -> Void {
        { [weak self] endpointID, generation in
            self?.broadcastConnectionWillChange(endpointID: endpointID, generation: generation)
        }
    }
}
