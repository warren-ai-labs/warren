import SwiftUI
import WarrenTransport

#if canImport(UIKit)
import UIKit
#endif

public enum IOSRoute: Hashable {
    case workspace(String)
    case terminalGroup(String)
    case session(String)
}

/// The compact home surface is Warren's mobile project rail. It keeps the
/// Web hierarchy (projects → workspaces → sessions) visible in one calm list,
/// and only pushes a detail route when the user actually needs a scope or a
/// terminal. There is no stock `List` chrome and no automatic shell creation.
public struct IOSRootView: View {
    @ObservedObject private var model: IOSApplicationModel
    @State private var navigationPath: [IOSRoute] = []
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var showingWorkspaceManager = false

    public init(model: IOSApplicationModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            HostDashboardView(
                model: model,
                collapsedSectionIDs: $collapsedSectionIDs,
                openWorkspace: { navigationPath.append(.workspace($0)) },
                openTerminalGroup: { navigationPath.append(.terminalGroup($0)) },
                openSession: { navigationPath.append(.session($0)) },
                openWorkspaceManager: { showingWorkspaceManager = true }
            )
            .navigationDestination(for: IOSRoute.self) { route in
                switch route {
                case .workspace(let id): WorkspaceView(model: model, workspaceID: id)
                case .terminalGroup(let id): TerminalGroupView(model: model, groupID: id)
                case .session(let id): SessionView(model: model, sessionID: id)
                }
            }
        }
        .tint(IOSTheme.accent)
        .preferredColorScheme(.dark)
        .background(IOSTheme.background.ignoresSafeArea())
        .sheet(isPresented: $showingWorkspaceManager) {
            IOSWorkspaceManagementSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: model.currentSessionID) { _, sessionID in
            guard let sessionID else {
                navigationPath.removeAll { route in
                    if case .session = route { return true }
                    return false
                }
                if let destination = model.consumeSessionDeletionDestination() {
                    switch destination {
                    case .workspace(let workspaceID):
                        guard !navigationPath.contains(.workspace(workspaceID)) else { return }
                        navigationPath.append(.workspace(workspaceID))
                    case .terminalGroup(let groupID):
                        guard !navigationPath.contains(.terminalGroup(groupID)) else { return }
                        navigationPath.append(.terminalGroup(groupID))
                    }
                }
                return
            }
            guard !navigationPath.contains(where: { route in
                if case .session = route { return true }
                return false
            }) else { return }
            navigationPath.append(.session(sessionID))
        }
    }
}

private struct HostDashboardView: View {
    @ObservedObject var model: IOSApplicationModel
    @Binding var collapsedSectionIDs: Set<String>
    let openWorkspace: (String) -> Void
    let openTerminalGroup: (String) -> Void
    let openSession: (String) -> Void
    let openWorkspaceManager: () -> Void

    private var projects: [WarrenRemoteRoster.Project] {
        (model.roster?.projects ?? []).sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var workspaces: [WarrenRemoteRoster.Workspace] {
        (model.roster?.workspaces ?? []).sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var sessionsByWorkspace: [String: [WarrenRemoteRoster.Session]] {
        (model.roster?.sessions ?? []).reduce(into: [:]) { result, session in
            guard session.isRunning else { return }
            guard let workspaceID = session.workspaceID else { return }
            result[workspaceID, default: []].append(session)
        }
    }

    /// Every directory-like section visible on the dashboard participates in
    /// the one-tap collapse action. Prefixes keep IDs from different scopes
    /// from colliding in the local view state.
    private var collapsibleSectionIDs: [String] {
        var ids = projects.map { sectionID(kind: "project", id: $0.id) }
        let assigned = Set(projects.map(\.id))
        if workspaces.contains(where: { !assigned.contains($0.projectID) }) {
            ids.append(sectionID(kind: "unassigned", id: "workspaces"))
        }
        if !(model.roster?.terminalGroups ?? []).isEmpty {
            ids.append(sectionID(kind: "groups", id: "terminal-groups"))
        }
        return ids
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HomeHeader(
                    model: model,
                    hasCollapsibleSections: !collapsibleSectionIDs.isEmpty,
                    isAllSectionsCollapsed: !collapsibleSectionIDs.isEmpty && collapsibleSectionIDs.allSatisfy { collapsedSectionIDs.contains($0) },
                    toggleAllSections: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            let shouldCollapse = !collapsibleSectionIDs.isEmpty && !collapsibleSectionIDs.allSatisfy { collapsedSectionIDs.contains($0) }
                            if shouldCollapse {
                                collapsedSectionIDs.formUnion(collapsibleSectionIDs)
                            } else {
                                collapsedSectionIDs.subtract(collapsibleSectionIDs)
                            }
                        }
                    },
                    openWorkspaceManager: openWorkspaceManager
                )

                if let message = model.maintenanceMessage {
                    IOSInlineNotice(
                        title: "Host updating",
                        message: message,
                        color: IOSTheme.amber,
                        symbol: "arrow.triangle.2.circlepath"
                    )
                    .padding(.top, 14)
                } else if let error = model.connectionError,
                          model.connectionState != .connected {
                    IOSInlineNotice(
                        title: connectionTitle,
                        message: error,
                        color: IOSTheme.red,
                        symbol: "wifi.exclamationmark"
                    )
                    .padding(.top, 14)
                }

                if model.roster == nil {
                    IOSLoadingRow(state: model.connectionState)
                        .padding(.top, 44)
                } else if projects.isEmpty && workspaces.isEmpty && (model.roster?.terminalGroups.isEmpty ?? true) {
                    IOSEmptyState(
                        symbol: "rectangle.stack",
                        title: "No sessions on this Host",
                        message: "Create a Session from Warren on the Host."
                    )
                    .padding(.top, 42)
                } else {
                    if !activeAgentSessions.isEmpty {
                        AgentActivitySummary(
                            sessions: activeAgentSessions,
                            workspaces: workspaces,
                            projects: projects,
                            agentStatusBySessionID: model.agentStatusBySessionID,
                            openSession: openSession
                        )
                    }
                    projectSections
                    unassignedWorkspaceSection
                    terminalGroupSection
                }

                if let error = model.mutationError {
                    IOSInlineNotice(
                        title: "Host action failed",
                        message: error,
                        color: IOSTheme.red,
                        symbol: "exclamationmark.triangle"
                    )
                    .padding(.top, 16)
                }
            }
            .padding(.horizontal, IOSTheme.pagePadding)
            .padding(.bottom, 22)
        }
        .background(IOSTheme.background.ignoresSafeArea())
        .scrollIndicators(.hidden)
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            IOSHostFooter(model: model)
        }
        .refreshable { model.reconnect() }
        .task { model.start() }
    }

    @ViewBuilder
    private var projectSections: some View {
        ForEach(projects) { project in
            let scopedWorkspaces = workspaces.filter { $0.projectID == project.id }
            ProjectSection(
                project: project,
                workspaces: scopedWorkspaces,
                sessionsByWorkspace: sessionsByWorkspace,
                agentStatusBySessionID: model.agentStatusBySessionID,
                isCollapsed: collapsedSectionIDs.contains(sectionID(kind: "project", id: project.id)),
                toggle: {
                    withAnimation(.easeOut(duration: 0.16)) {
                        let key = sectionID(kind: "project", id: project.id)
                        if collapsedSectionIDs.contains(key) {
                            collapsedSectionIDs.remove(key)
                        } else {
                            collapsedSectionIDs.insert(key)
                        }
                    }
                },
                openWorkspace: openWorkspace,
                openSession: openSession
            )
        }
    }

    @ViewBuilder
    private var unassignedWorkspaceSection: some View {
        let assigned = Set(projects.map(\.id))
        let unassigned = workspaces.filter { !assigned.contains($0.projectID) }
        if !unassigned.isEmpty {
            ScopeRailSection(
                title: "Workspaces",
                symbol: "folder",
                workspaces: unassigned,
                sessionsByWorkspace: sessionsByWorkspace,
                agentStatusBySessionID: model.agentStatusBySessionID,
                isCollapsed: collapsedSectionIDs.contains(sectionID(kind: "unassigned", id: "workspaces")),
                toggle: {
                    withAnimation(.easeOut(duration: 0.16)) {
                        toggleSection(kind: "unassigned", id: "workspaces")
                    }
                },
                openWorkspace: openWorkspace,
                openSession: openSession
            )
        }
    }

    @ViewBuilder
    private var terminalGroupSection: some View {
        let groups = (model.roster?.terminalGroups ?? []).sorted { lhs, rhs in
            lhs.order == rhs.order
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                : lhs.order < rhs.order
        }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                CollapsibleSectionHeader(
                    title: "Terminal groups",
                    count: groups.count,
                    symbol: "rectangle.split.3x1",
                    isCollapsed: collapsedSectionIDs.contains(sectionID(kind: "groups", id: "terminal-groups")),
                    toggle: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            toggleSection(kind: "groups", id: "terminal-groups")
                        }
                    }
                )
                if !collapsedSectionIDs.contains(sectionID(kind: "groups", id: "terminal-groups")) {
                    ForEach(groups) { group in
                        ScopeGroupRow(
                            group: group,
                            sessions: model.sessions(inTerminalGroup: group.id),
                            agentStatusBySessionID: model.agentStatusBySessionID,
                            openGroup: { openTerminalGroup(group.id) },
                            openSession: openSession
                        )
                    }
                }
            }
        }
    }

    private var connectionTitle: LocalizedStringKey {
        IOSCopy.connectionTitle(for: model.connectionState)
    }

    /// Keep the dashboard's high-signal area small: only live Agent-backed
    /// Sessions that are currently working or ready are promoted here. Shell
    /// Sessions and blocked/failed records remain in their normal scope rows.
    private var activeAgentSessions: [WarrenRemoteRoster.Session] {
        model.activeSessions
            .filter { session in
                guard session.isAgentBacked,
                      let status = model.agentStatusBySessionID[session.id] ?? session.agentStatus else {
                    return false
                }
                return status.activity == .working || status.activity == .ready
            }
            .sorted { lhs, rhs in
                let left = model.agentStatusBySessionID[lhs.id] ?? lhs.agentStatus
                let right = model.agentStatusBySessionID[rhs.id] ?? rhs.agentStatus
                let leftPriority = left?.activity == .working ? 0 : 1
                let rightPriority = right?.activity == .working ? 0 : 1
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                let leftTitle = lhs.displayTitle.isEmpty ? lhs.process ?? lhs.kind : lhs.displayTitle
                let rightTitle = rhs.displayTitle.isEmpty ? rhs.process ?? rhs.kind : rhs.displayTitle
                return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
            }
    }

    private func sectionID(kind: String, id: String) -> String {
        "\(kind):\(id)"
    }

    private func toggleSection(kind: String, id: String) {
        let key = sectionID(kind: kind, id: id)
        if collapsedSectionIDs.contains(key) {
            collapsedSectionIDs.remove(key)
        } else {
            collapsedSectionIDs.insert(key)
        }
    }
}

/// A compact cross-scope index for the sessions that are most likely to need
/// attention. It deliberately uses value snapshots instead of observing the
/// application model so terminal frames do not invalidate every row.
private struct AgentActivitySummary: View {
    let sessions: [WarrenRemoteRoster.Session]
    let workspaces: [WarrenRemoteRoster.Workspace]
    let projects: [WarrenRemoteRoster.Project]
    let agentStatusBySessionID: [String: WarrenRemoteAgentStatus]
    let openSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            IOSSectionLabel("Agent activity", count: sessions.count)
                .padding(.top, 20)
                .padding(.bottom, 5)
            ForEach(sessions) { session in
                Button { openSession(session.id) } label: {
                    AgentActivitySummaryRow(
                        session: session,
                        subtitle: subtitle(for: session),
                        status: agentStatusBySessionID[session.id] ?? session.agentStatus
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func subtitle(for session: WarrenRemoteRoster.Session) -> String {
        if let workspaceID = session.workspaceID,
           let workspace = workspaces.first(where: { $0.id == workspaceID }) {
            let workspaceName = workspace.branch?.isEmpty == false
                ? workspace.branch!
                : (workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name)
            if let project = projects.first(where: { $0.id == workspace.projectID }),
               !project.name.isEmpty,
               !workspaceName.isEmpty {
                return "\(project.name) · \(workspaceName)"
            }
            return workspaceName.isEmpty ? "Workspace" : workspaceName
        }
        if let groupID = session.terminalGroupID {
            return "Terminal group · \(groupID)"
        }
        return session.directory ?? "Host session"
    }
}

private struct AgentActivitySummaryRow: View {
    let session: WarrenRemoteRoster.Session
    let subtitle: String
    let status: WarrenRemoteAgentStatus?

    var body: some View {
        HStack(spacing: 10) {
            if let status {
                IOSAgentActivityMark(
                    activity: status.activity,
                    attention: status.attention,
                    slotSize: 22
                )
            } else {
                IOSStatusDot(color: IOSTheme.secondaryText, size: 7)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle.isEmpty ? (session.process ?? session.kind.capitalized) : session.displayTitle)
                    .font(IOSTypography.bodyEmphasis)
                    .foregroundStyle(IOSTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(status?.activity == .working ? "Working" : "Ready")
                .font(IOSTypography.status)
                .foregroundStyle(status?.activity == .working ? IOSTheme.amber : IOSTheme.secondaryText)
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.42))
                .frame(height: 1)
                .padding(.leading, 32)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.displayTitle.isEmpty ? "Agent session" : session.displayTitle)
        .accessibilityValue("\(subtitle), \(status?.activity == .working ? "Working" : "Ready")")
    }
}

private struct HomeHeader: View {
    @ObservedObject var model: IOSApplicationModel
    let hasCollapsibleSections: Bool
    let isAllSectionsCollapsed: Bool
    let toggleAllSections: () -> Void
    let openWorkspaceManager: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            IOSBrandMark(size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sessions")
                    .font(IOSTypography.pageTitle)
                    .foregroundStyle(IOSTheme.text)
                HStack(spacing: 6) {
                    IOSStatusDot(color: connectionColor, size: 6)
                    Text(connectionTitle)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                    if model.roster != nil {
                        Text("·")
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Text("\(model.activeSessions.count) active")
                            .font(IOSTypography.metric)
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                }
            }
            Spacer(minLength: 0)
            if model.roster != nil && hasCollapsibleSections {
                Button(action: toggleAllSections) {
                    Image(systemName: isAllSectionsCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 38, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isAllSectionsCollapsed ? "Expand all sections" : "Collapse all sections")
            }
            Menu {
                Button("Manage workspaces", systemImage: "folder") {
                    openWorkspaceManager()
                }
                if model.connectionState != .connected {
                    Button("Reconnect", systemImage: "arrow.clockwise") { model.reconnect() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 42, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.automatic)
            .accessibilityLabel("Host actions")
        }
        .frame(minHeight: 76)
        .padding(.top, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
    }

    private var connectionTitle: LocalizedStringKey {
        IOSCopy.connectionTitle(for: model.connectionState)
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return IOSTheme.green
        case .connecting, .reconnecting: return IOSTheme.amber
        case .disconnected: return IOSTheme.red
        case .stopped: return IOSTheme.secondaryText
        }
    }
}

private struct ProjectSection: View {
    let project: WarrenRemoteRoster.Project
    let workspaces: [WarrenRemoteRoster.Workspace]
    let sessionsByWorkspace: [String: [WarrenRemoteRoster.Session]]
    let agentStatusBySessionID: [String: WarrenRemoteAgentStatus]
    let isCollapsed: Bool
    let toggle: () -> Void
    let openWorkspace: (String) -> Void
    let openSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    IOSProjectIcon(name: project.name.isEmpty ? pathLeaf(project.path) : project.name, size: 25)
                    Text(project.name.isEmpty ? pathLeaf(project.path) : project.name)
                        .font(IOSTypography.sectionTitle)
                        .foregroundStyle(IOSTheme.text)
                        .lineLimit(2)
                        .iosNaturalWrap()
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if !workspaces.isEmpty {
                        Text("\(workspaces.count)")
                            .font(IOSTypography.metric)
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                    Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IOSTheme.tertiaryText)
                        .frame(width: 24, height: 24)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "Expand \(project.name)" : "Collapse \(project.name)")

            if !isCollapsed {
                ForEach(workspaces) { workspace in
                    WorkspaceRailRow(
                        workspace: workspace,
                        sessions: sessionsByWorkspace[workspace.id] ?? [],
                        agentStatusBySessionID: agentStatusBySessionID,
                        openWorkspace: { openWorkspace(workspace.id) },
                        openSession: openSession
                    )
                }
                if workspaces.isEmpty {
                    Text("No workspaces")
                        .font(IOSTypography.secondaryBody)
                        .foregroundStyle(IOSTheme.tertiaryText)
                        .padding(.leading, 39)
                        .padding(.bottom, 8)
                }
            }
        }
        .padding(.top, 22)
    }
}

private struct ScopeRailSection: View {
    let title: String
    let symbol: String
    let workspaces: [WarrenRemoteRoster.Workspace]
    let sessionsByWorkspace: [String: [WarrenRemoteRoster.Session]]
    let agentStatusBySessionID: [String: WarrenRemoteAgentStatus]
    let isCollapsed: Bool
    let toggle: () -> Void
    let openWorkspace: (String) -> Void
    let openSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleSectionHeader(
                title: title,
                count: workspaces.count,
                symbol: symbol,
                isCollapsed: isCollapsed,
                toggle: toggle
            )
            if !isCollapsed {
                ForEach(workspaces) { workspace in
                    WorkspaceRailRow(
                        workspace: workspace,
                        sessions: sessionsByWorkspace[workspace.id] ?? [],
                        agentStatusBySessionID: agentStatusBySessionID,
                        openWorkspace: { openWorkspace(workspace.id) },
                        openSession: openSession
                    )
                }
            }
        }
    }
}

private struct CollapsibleSectionHeader: View {
    let title: String
    let count: Int
    let symbol: String
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IOSTheme.secondaryText.opacity(0.78))
                    .frame(width: 16)
                Text(title)
                    .font(IOSTypography.eyebrow)
                    .foregroundStyle(IOSTheme.secondaryText.opacity(0.74))
                    .lineLimit(2)
                    .iosNaturalWrap()
                    .layoutPriority(1)
                Text("\(count)")
                    .font(IOSTypography.metric)
                    .foregroundStyle(IOSTheme.tertiaryText)
                Rectangle()
                    .fill(IOSTheme.separator.opacity(0.72))
                    .frame(height: 1)
                Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .frame(width: 24, height: 24)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
        .padding(.top, 20)
        .padding(.bottom, 4)
    }
}

private struct WorkspaceRailRow: View {
    let workspace: WarrenRemoteRoster.Workspace
    let sessions: [WarrenRemoteRoster.Session]
    let agentStatusBySessionID: [String: WarrenRemoteAgentStatus]
    let openWorkspace: () -> Void
    let openSession: (String) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: openWorkspace) {
                HStack(spacing: 11) {
                    WorkspaceGlyph(workspace: workspace, agentStatus: agentStatus)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(workspace.branch ?? (workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name))
                            .font(IOSTypography.body)
                            .foregroundStyle(IOSTheme.text)
                            .lineLimit(2)
                            .iosNaturalWrap()
                            .iosMachineText()
                            .layoutPriority(1)
                        Text(workspaceSubtitle)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(2)
                            .iosNaturalWrap()
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: IOSTheme.workspaceRowHeight)

            Menu {
                Button("Open workspace", systemImage: "rectangle.split.2x1") { openWorkspace() }
                if sessions.count == 1, let session = sessions.first {
                    Button("Open session", systemImage: "terminal") { openSession(session.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.automatic)
            .accessibilityLabel("Actions for \(workspace.name)")
        }
        .padding(.leading, 29)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.42))
                .frame(height: 1)
                .padding(.leading, 40)
        }
    }

    private var sessionSummary: String {
        guard !sessions.isEmpty else { return "No sessions" }
        return "\(sessions.count) session\(sessions.count == 1 ? "" : "s")"
    }

    /// Keep the secondary rail as one natural-language string so it can wrap
    /// at meaningful boundaries in German, CJK, or a translated Host label.
    /// An HStack of individually constrained fragments cannot wrap as a unit.
    private var workspaceSubtitle: String {
        var parts: [String] = []
        if let branch = workspace.branch, !branch.isEmpty, !workspace.name.isEmpty {
            parts.append(workspace.name)
        } else if !workspace.path.isEmpty {
            parts.append(pathLeaf(workspace.path))
        }
        parts.append(sessions.isEmpty ? "Open workspace" : sessionSummary)
        return parts.joined(separator: " · ")
    }

    private var agentStatus: WarrenRemoteAgentStatus? {
        highestAgentStatus(sessions: sessions, statuses: agentStatusBySessionID)
    }
}

private struct WorkspaceGlyph: View {
    let workspace: WarrenRemoteRoster.Workspace
    let agentStatus: WarrenRemoteAgentStatus?

    var body: some View {
        Group {
            if workspace.mergeState == "merged" {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(IOSTheme.green.opacity(0.85))
            } else if let agentStatus {
                IOSAgentActivityMark(
                    activity: agentStatus.activity,
                    attention: agentStatus.attention,
                    slotSize: 23
                )
            } else {
                // Desktop uses the activity dot for live Agent work and a
                // branch mark for an otherwise quiet workspace. Never use a
                // computer glyph here: the row represents a branch scope,
                // not the device running Warren.
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
            }
        }
        .frame(width: 23)
        .accessibilityHidden(true)
    }
}

private struct ScopeGroupRow: View {
    let group: WarrenRemoteRoster.TerminalGroup
    let sessions: [WarrenRemoteRoster.Session]
    let agentStatusBySessionID: [String: WarrenRemoteAgentStatus]
    let openGroup: () -> Void
    let openSession: (String) -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button(action: openGroup) {
                HStack(spacing: 11) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 23)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.name)
                            .font(IOSTypography.body)
                            .foregroundStyle(IOSTheme.text)
                            .lineLimit(2)
                            .iosNaturalWrap()
                            .layoutPriority(1)
                        Text(group.home ?? "Standalone sessions")
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(2)
                            .iosNaturalWrap()
                            .iosMachineText()
                            .layoutPriority(1)
                    }
                    if let status = highestAgentStatus(sessions: sessions, statuses: agentStatusBySessionID) {
                        IOSAgentActivityMark(
                            activity: status.activity,
                            attention: status.attention,
                            slotSize: 22
                        )
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: IOSTheme.workspaceRowHeight)
            Menu {
                Button("Open group", systemImage: "rectangle.split.3x1") { openGroup() }
                if sessions.count == 1, let session = sessions.first {
                    Button("Open session", systemImage: "terminal") { openSession(session.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .frame(width: 32, height: 44)
            }
            .menuStyle(.automatic)
        }
        .padding(.leading, 29)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.42))
                .frame(height: 1)
                .padding(.leading, 40)
        }
    }
}

/// Shared bottom Host rail. The selected Host name is a menu so the same
/// affordance works from the dashboard and from a live Session surface.
struct IOSHostFooter: View {
    @ObservedObject var model: IOSApplicationModel

    var body: some View {
        HStack(spacing: 10) {
            IOSStatusDot(color: connectionColor, size: 8)
            Menu {
                ForEach(hosts, id: \.name) { host in
                    Button {
                        model.selectEndpoint(named: host.name)
                    } label: {
                        Label(
                            host.name,
                            systemImage: host.name == model.endpointMetadata.name
                                ? "checkmark.circle.fill"
                                : "server.rack"
                        )
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.endpointMetadata.name)
                            .font(IOSTypography.bodyEmphasis)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(2)
                            .iosNaturalWrap()
                            .layoutPriority(1)
                        Text(model.endpointMetadata.isRelay ? "Relay" : "Direct Host")
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IOSTheme.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.automatic)
            .accessibilityLabel("Switch Host")

            Button(action: model.reconnect) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reconnect to Host")

            NavigationLink {
                IOSEndpointConfigurationView(model: model)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Host settings")
        }
        .padding(.horizontal, IOSTheme.pagePadding)
        .frame(minHeight: 62)
        .background(IOSTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
    }

    private var hosts: [IOSEndpointMetadata] {
        model.endpointMetadataList.isEmpty
            ? [model.endpointMetadata]
            : model.endpointMetadataList
    }

    private var connectionColor: Color {
        switch model.connectionState {
        case .connected: return IOSTheme.green
        case .connecting, .reconnecting: return IOSTheme.amber
        case .disconnected: return IOSTheme.red
        case .stopped: return IOSTheme.secondaryText
        }
    }
}

private struct ScopeDetailView: View {
    @ObservedObject var model: IOSApplicationModel
    let title: String
    let subtitle: String
    let symbol: String
    let sessions: [WarrenRemoteRoster.Session]
    let onAppear: () -> Void
    let onNewSession: (() -> Void)?
    let onRenameWorkspace: (() -> Void)?
    let onDeleteWorkspace: (() -> Void)?
    let onDeleteSession: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            IOSBackHeader(
                title: title,
                subtitle: subtitle,
                symbol: symbol,
                actions: managementActions
            ) {
                dismiss()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    IOSSectionLabel("Sessions", count: sessions.count)
                        .padding(.top, 24)
                        .padding(.bottom, 8)
                    if sessions.isEmpty {
                        IOSEmptyState(
                            symbol: "terminal",
                            title: "No sessions in this scope",
                            message: "Sessions created on the Host will appear here."
                        )
                        .padding(.top, 24)
                    } else {
                        ForEach(sessions) { session in
                            NavigationLink(value: IOSRoute.session(session.id)) {
                                ScopeSessionRow(
                                    session: session,
                                    agentStatus: model.agentStatusBySessionID[session.id] ?? session.agentStatus
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let onDeleteSession {
                                    Button("Delete session", role: .destructive) {
                                        onDeleteSession(session.id)
                                    }
                                }
                            }
                        }
                    }
                    if let error = model.mutationError {
                        IOSInlineNotice(
                            title: "Host action failed",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                        .padding(.top, 16)
                    }
                }
                .padding(.horizontal, IOSTheme.pagePadding)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .background(IOSTheme.background.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear(perform: onAppear)
    }

    private var managementActions: AnyView? {
        guard onNewSession != nil || onRenameWorkspace != nil || onDeleteWorkspace != nil else {
            return nil
        }
        return AnyView(
            Menu {
                if let onNewSession {
                    Button("New session", systemImage: "plus") { onNewSession() }
                }
                if let onRenameWorkspace {
                    Button("Rename workspace", systemImage: "pencil") { onRenameWorkspace() }
                }
                if let onDeleteWorkspace {
                    Button("Delete workspace", role: .destructive) { onDeleteWorkspace() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 42, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.automatic)
            .accessibilityLabel("Scope actions")
        )
    }
}

private struct IOSBackHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    let actions: AnyView?
    let onBack: () -> Void

    init(
        title: String,
        subtitle: String,
        symbol: String,
        actions: AnyView? = nil,
        onBack: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.actions = actions
        self.onBack = onBack
    }

    var body: some View {
        HStack(spacing: 7) {
            IOSIconButton("chevron.backward", label: "Back", action: onBack)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(IOSTheme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IOSTypography.navigationTitle)
                    .foregroundStyle(IOSTheme.text)
                    .lineLimit(2)
                    .iosNaturalWrap()
                    .layoutPriority(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(2)
                        .iosNaturalWrap()
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 0)
            if let actions {
                actions
            }
        }
        .padding(.horizontal, 4)
        // A fixed height clips translated titles. The toolbar stays compact
        // for common labels but grows when a real scope name needs a second
        // line.
        .frame(minHeight: IOSTheme.toolbarHeight)
        .padding(.vertical, 5)
        .background(IOSTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
    }
}

private struct ScopeSessionRow: View {
    let session: WarrenRemoteRoster.Session
    let agentStatus: WarrenRemoteAgentStatus?

    var body: some View {
        HStack(spacing: 11) {
            if session.isAgentBacked, let activity = agentStatus?.activity {
                IOSAgentActivityMark(activity: activity, attention: agentStatus?.attention)
            } else {
                IOSStatusDot(color: activityColor, size: 8)
                    .frame(width: 23)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle.isEmpty ? "Untitled session" : session.displayTitle)
                    .font(IOSTypography.body)
                    .foregroundStyle(IOSTheme.text)
                    .lineLimit(2)
                    .iosNaturalWrap()
                    .layoutPriority(1)
                HStack(spacing: 6) {
                    Text(session.process ?? session.kind.capitalized)
                }
                .font(IOSTypography.metadata)
                .foregroundStyle(IOSTheme.secondaryText)
                .lineLimit(2)
                .iosNaturalWrap()
                .iosMachineText()
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IOSTheme.tertiaryText)
        }
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.48))
                .frame(height: 1)
                .padding(.leading, 34)
        }
    }

    private var activityColor: Color {
        if session.isAgentBacked, let status = agentStatus {
            return IOSTheme.statusColor(status)
        }
        return session.isRunning ? IOSTheme.green : IOSTheme.secondaryText
    }
}

private struct WorkspaceView: View {
    @ObservedObject var model: IOSApplicationModel
    let workspaceID: String
    @State private var showingNewSession = false
    @State private var showingRename = false
    @State private var showingDelete = false
    @State private var workspaceName = ""

    var body: some View {
        let workspace = model.roster?.workspaces.first(where: { $0.id == workspaceID })
        ScopeDetailView(
            model: model,
            title: workspace?.branch ?? workspace?.name ?? "Workspace",
            subtitle: workspace?.name ?? workspace?.path ?? "",
            symbol: workspaceSymbol(workspace),
            sessions: model.sessions(inWorkspace: workspaceID),
            onAppear: { model.selectWorkspace(workspaceID) },
            onNewSession: { showingNewSession = true },
            onRenameWorkspace: {
                workspaceName = workspace?.name ?? ""
                showingRename = true
            },
            onDeleteWorkspace: { showingDelete = true },
            onDeleteSession: { model.deleteSession($0) }
        )
        .sheet(isPresented: $showingNewSession) {
            IOSSessionCreationSheet(model: model, workspaceID: workspaceID, title: workspace?.name ?? "Workspace")
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("Rename workspace", isPresented: $showingRename) {
            TextField("Workspace name", text: $workspaceName)
            Button("Save") { model.renameWorkspace(workspaceID, name: workspaceName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                model.deleteWorkspace(workspaceID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The workspace record will be removed. Running sessions must be deleted first.")
        }
    }
}

private struct TerminalGroupView: View {
    @ObservedObject var model: IOSApplicationModel
    let groupID: String
    @State private var showingNewSession = false

    var body: some View {
        let group = model.roster?.terminalGroups.first(where: { $0.id == groupID })
        ScopeDetailView(
            model: model,
            title: group?.name ?? "Terminal group",
            subtitle: group?.home ?? "Standalone sessions",
            symbol: "rectangle.split.3x1",
            sessions: model.sessions(inTerminalGroup: groupID),
            onAppear: { model.selectTerminalGroup(groupID) },
            onNewSession: { showingNewSession = true },
            onRenameWorkspace: nil,
            onDeleteWorkspace: nil,
            onDeleteSession: { model.deleteSession($0) }
        )
        .sheet(isPresented: $showingNewSession) {
            IOSSessionCreationSheet(model: model, terminalGroupID: groupID, title: group?.name ?? "Terminal group")
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct IOSInlineNotice: View {
    let title: LocalizedStringKey
    let message: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IOSTypography.label)
                    .foregroundStyle(IOSTheme.text)
                Text(message)
                    .font(IOSTypography.secondaryBody)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .iosNaturalWrap()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 11)
        .background(IOSTheme.accentSubtle, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
    }
}

private struct IOSLoadingRow: View {
    let state: WarrenRemoteConnectionState

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(IOSTheme.accent)
            Text(state == .stopped ? LocalizedStringKey("Connect to a Warren Host") : LocalizedStringKey("Loading sessions"))
                .font(IOSTypography.secondaryBody)
                .foregroundStyle(IOSTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
    }
}

private struct IOSEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(IOSTheme.secondaryText)
            Text(title)
                .font(IOSTypography.screenTitle)
                .foregroundStyle(IOSTheme.text)
            Text(message)
                .font(IOSTypography.body)
                .foregroundStyle(IOSTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

private func pathLeaf(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}

private func workspaceSymbol(_ workspace: WarrenRemoteRoster.Workspace?) -> String {
    guard let workspace else { return "arrow.triangle.branch" }
    if workspace.mergeState == "merged" { return "arrow.triangle.merge" }
    return "arrow.triangle.branch"
}

/// Collapses the activity of every Agent-backed Session in a scope into one
/// marker. Shell Sessions never contribute a status, even if a stale Host
/// roster happens to carry agent metadata for them.
private func highestAgentStatus(
    sessions: [WarrenRemoteRoster.Session],
    statuses: [String: WarrenRemoteAgentStatus]
) -> WarrenRemoteAgentStatus? {
    sessions
        .filter(\.isAgentBacked)
        .compactMap { statuses[$0.id] ?? $0.agentStatus }
        .max { lhs, rhs in
            agentStatusPriority(lhs) < agentStatusPriority(rhs)
        }
}

private func agentStatusPriority(_ status: WarrenRemoteAgentStatus) -> Int {
    switch status.activity {
    case .failed: return 6
    case .blocked: return 5
    case .stalled: return 4
    case .working: return status.attention == nil ? 3 : 5
    case .ready: return 2
    case .exited: return 1
    case .unknown: return 0
    }
}

/// The small, intentionally finite set of launch types exposed by the mobile
/// creation flow. Unknown Host kinds remain visible in the roster but are not
/// manufactured by this first-party shortcut.
private enum IOSSessionCreationKind: String, CaseIterable, Identifiable {
    case shell
    case codex
    case claude
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shell: return "Shell"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .opencode: return "OpenCode"
        }
    }

    var symbol: String {
        switch self {
        case .shell: return "terminal"
        case .codex: return "curlybraces"
        case .claude: return "sparkles"
        case .opencode: return "terminal.fill"
        }
    }

    var defaultCommand: String? {
        switch self {
        case .shell: return nil
        case .codex: return "codex --dangerously-bypass-hook-trust"
        case .claude: return "claude"
        case .opencode: return "opencode"
        }
    }
}

/// Secondary session-management entry point. The dashboard stays focused on
/// opening existing work; creation is deliberately behind the scope action
/// menu so a one-tap visit never creates a shell by accident.
struct IOSSessionCreationSheet: View {
    @ObservedObject var model: IOSApplicationModel
    let workspaceID: String?
    let terminalGroupID: String?
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: IOSSessionCreationKind
    @State private var command = ""
    @State private var sessionTitle = ""

    init(
        model: IOSApplicationModel,
        workspaceID: String? = nil,
        terminalGroupID: String? = nil,
        title: String
    ) {
        self.model = model
        self.workspaceID = workspaceID
        self.terminalGroupID = terminalGroupID
        self.title = title
        let remembered = IOSSessionCreationKind(rawValue: model.localStore.lastSessionKind) ?? .shell
        _selectedKind = State(initialValue: remembered)
        _command = State(initialValue: remembered.defaultCommand ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    IOSScreenHeading(title: "New session", symbol: "plus", subtitle: title)
                    VStack(spacing: 1) {
                        HStack(spacing: 10) {
                            Image(systemName: selectedKind.symbol)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(IOSTheme.secondaryText)
                                .frame(width: 23)
                            Text("Type")
                                .font(IOSTypography.body)
                                .foregroundStyle(IOSTheme.text)
                            Spacer(minLength: 0)
                            Picker("Session type", selection: $selectedKind) {
                                ForEach(IOSSessionCreationKind.allCases) { kind in
                                    Text(kind.displayName).tag(kind)
                                }
                            }
                            .font(IOSTypography.body)
                            .tint(IOSTheme.accent)
                            .accessibilityLabel("Session type")
                        }
                        .frame(minHeight: 44)
                        TextField("Title (optional)", text: $sessionTitle)
                        TextField(commandPlaceholder, text: $command)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            #endif
                    }
                    .padding(.horizontal, 12)
                    .iosSurface(color: IOSTheme.chrome)

                    if let error = model.mutationError {
                        IOSInlineNotice(
                            title: "Session not created",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                    }

                    Button {
                        model.createSession(
                            workspaceID: workspaceID,
                            terminalGroupID: terminalGroupID,
                            command: command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command,
                            kind: selectedKind.rawValue,
                            title: sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sessionTitle
                        )
                        model.localStore.lastSessionKind = selectedKind.rawValue
                        dismiss()
                    } label: {
                        Text(model.isMutating ? "Creating…" : "Create session")
                            .font(IOSTypography.button)
                            .foregroundStyle(IOSTheme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(IOSTheme.accent, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isMutating)
                    .opacity(model.isMutating ? 0.5 : 1)
                }
                .padding(16)
            }
            .background(IOSTheme.background.ignoresSafeArea())
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedKind) { oldKind, newKind in
            let currentCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldDefault = oldKind.defaultCommand ?? ""
            if currentCommand.isEmpty || currentCommand == oldDefault {
                command = newKind.defaultCommand ?? ""
            }
        }
    }

    private var commandPlaceholder: String {
        selectedKind == .shell
            ? "Command (optional; Host shell default)"
            : "Command (optional; \(selectedKind.displayName) default)"
    }
}

private struct IOSWorkspaceManagementSheet: View {
    @ObservedObject var model: IOSApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var renameWorkspaceID: String?
    @State private var renameName = ""
    @State private var deleteWorkspaceID: String?

    private var workspaces: [WarrenRemoteRoster.Workspace] {
        (model.roster?.workspaces ?? []).sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        IOSScreenHeading(title: "Workspaces", symbol: "folder")
                        Button {
                            showingCreate = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(IOSTheme.accent)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Create workspace")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 10)

                    if workspaces.isEmpty {
                        IOSEmptyState(
                            symbol: "folder",
                            title: "No workspaces",
                            message: "Create one from a Host project."
                        )
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                    } else {
                        ForEach(workspaces) { workspace in
                            HStack(spacing: 10) {
                                WorkspaceGlyph(
                                    workspace: workspace,
                                    agentStatus: highestAgentStatus(
                                        sessions: model.sessions(inWorkspace: workspace.id),
                                        statuses: model.agentStatusBySessionID
                                    )
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name)
                                        .font(IOSTypography.rowTitle)
                                        .foregroundStyle(IOSTheme.text)
                                        .lineLimit(2)
                                        .iosNaturalWrap()
                                        .layoutPriority(1)
                                    Text(workspace.branch ?? workspace.path)
                                        .font(IOSTypography.metadata)
                                        .foregroundStyle(IOSTheme.secondaryText)
                                        .lineLimit(2)
                                        .iosNaturalWrap()
                                        .iosMachineText()
                                        .layoutPriority(1)
                                }
                                Spacer(minLength: 8)
                                Menu {
                                    Button("Rename workspace", systemImage: "pencil") {
                                        renameWorkspaceID = workspace.id
                                        renameName = workspace.name
                                    }
                                    Button("Delete workspace", role: .destructive) {
                                        deleteWorkspaceID = workspace.id
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(IOSTheme.tertiaryText)
                                        .frame(width: 36, height: 44)
                                }
                                .menuStyle(.automatic)
                                .accessibilityLabel("Actions for workspace")
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 62)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(IOSTheme.separator.opacity(0.48))
                                    .frame(height: 1)
                                    .padding(.leading, 40)
                            }
                        }
                    }

                    if let error = model.mutationError {
                        IOSInlineNotice(
                            title: "Workspace action failed",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                        .padding(16)
                    }
                }
                .padding(.bottom, 20)
            }
            .background(IOSTheme.background.ignoresSafeArea())
            .scrollIndicators(.hidden)
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingCreate) {
            IOSWorkspaceCreationSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Rename workspace", isPresented: Binding(
            get: { renameWorkspaceID != nil },
            set: { if !$0 { renameWorkspaceID = nil } }
        )) {
            TextField("Workspace name", text: $renameName)
            Button("Save") {
                if let id = renameWorkspaceID { model.renameWorkspace(id, name: renameName) }
                renameWorkspaceID = nil
            }
            Button("Cancel", role: .cancel) { renameWorkspaceID = nil }
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: Binding(
                get: { deleteWorkspaceID != nil },
                set: { if !$0 { deleteWorkspaceID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                if let id = deleteWorkspaceID { model.deleteWorkspace(id) }
                deleteWorkspaceID = nil
            }
            Button("Cancel", role: .cancel) { deleteWorkspaceID = nil }
        } message: {
            Text("Running sessions must be deleted before the workspace can be removed.")
        }
    }
}

private struct IOSWorkspaceCreationSheet: View {
    @ObservedObject var model: IOSApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var branch = ""
    @State private var name = ""
    @State private var path = ""

    private var projects: [WarrenRemoteRoster.Project] { model.roster?.projects ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    IOSScreenHeading(title: "New workspace", symbol: "folder.badge.plus")
                    if projects.isEmpty {
                        IOSEmptyState(
                            symbol: "folder",
                            title: "No Host projects",
                            message: "Add a project on the Host before creating a workspace."
                        )
                    } else {
                        Picker("Project", selection: $projectID) {
                            ForEach(projects) { project in
                                Text(project.name.isEmpty ? pathLeaf(project.path) : project.name)
                                    .tag(project.id)
                            }
                        }
                        .pickerStyle(.menu)
                        VStack(spacing: 1) {
                            TextField("Branch", text: $branch)
                            TextField("Name (optional)", text: $name)
                            TextField("Path (optional)", text: $path)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                #endif
                        }
                        .padding(.horizontal, 12)
                        .iosSurface(color: IOSTheme.chrome)

                        if let error = model.mutationError {
                            IOSInlineNotice(
                                title: "Workspace not created",
                                message: error,
                                color: IOSTheme.red,
                                symbol: "exclamationmark.triangle"
                            )
                        }

                        Button {
                            model.createWorkspace(
                                projectID: projectID,
                                branch: branch,
                                name: name.isEmpty ? nil : name,
                                path: path.isEmpty ? nil : path
                            )
                            dismiss()
                        } label: {
                            Text(model.isMutating ? "Creating…" : "Create workspace")
                                .font(IOSTypography.button)
                                .foregroundStyle(IOSTheme.background)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(IOSTheme.accent, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(projectID.isEmpty || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isMutating)
                        .opacity(projectID.isEmpty || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isMutating ? 0.45 : 1)
                    }
                }
                .padding(16)
            }
            .background(IOSTheme.background.ignoresSafeArea())
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if projectID.isEmpty { projectID = projects.first?.id ?? "" }
        }
    }
}

/// Lists the Hosts saved on this device. Each row is independently selectable
/// and editable; credentials stay in the Keychain behind the model.
public struct IOSEndpointConfigurationView: View {
    @ObservedObject private var model: IOSApplicationModel
    @Environment(\.dismiss) private var dismiss

    public init(model: IOSApplicationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            IOSBackHeader(
                title: "Hosts",
                subtitle: "Connections",
                symbol: "server.rack",
                actions: AnyView(
                    NavigationLink {
                        IOSEndpointEditorView(model: model, endpoint: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(IOSTheme.secondaryText)
                            .frame(width: 42, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Host")
                )
            ) {
                dismiss()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Saved Hosts")
                        .font(IOSTypography.sectionTitle)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .padding(.top, 25)
                        .padding(.bottom, 9)
                    if hosts.isEmpty {
                        IOSEmptyState(
                            symbol: "server.rack",
                            title: "No saved Hosts",
                            message: "Add a Warren Host to connect from this device."
                        )
                    } else {
                        VStack(spacing: 1) {
                            ForEach(hosts, id: \.name) { host in
                                NavigationLink {
                                    IOSEndpointDetailView(model: model, endpoint: host)
                                } label: {
                                    HStack(spacing: 11) {
                                        IOSStatusDot(
                                            color: host.name == model.endpointMetadata.name
                                                ? IOSTheme.accent
                                                : IOSTheme.tertiaryText,
                                            size: 8
                                        )
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(host.name)
                                                .font(host.name == model.endpointMetadata.name
                                                    ? IOSTypography.bodyEmphasis
                                                    : IOSTypography.body)
                                                .foregroundStyle(IOSTheme.text)
                                                .lineLimit(2)
                                                .iosNaturalWrap()
                                                .layoutPriority(1)
                                            Text(host.url)
                                                .font(IOSTypography.metadata)
                                                .foregroundStyle(IOSTheme.secondaryText)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                                .iosMachineText()
                                        }
                                        Spacer(minLength: 8)
                                        if host.hasToken {
                                            Image(systemName: "lock.fill")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(IOSTheme.tertiaryText)
                                        }
                                        Image(systemName: "chevron.forward")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(IOSTheme.tertiaryText)
                                    }
                                    .padding(.horizontal, 13)
                                    .frame(minHeight: 62)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Details for \(host.name)")
                                .background(IOSTheme.chrome)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous)
                                .stroke(IOSTheme.ring.opacity(0.72), lineWidth: 1)
                        }
                    }

                    if let error = model.endpointError {
                        IOSInlineNotice(
                            title: "Host action failed",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                        .padding(.top, 16)
                    }

                    Text("Tokens are stored in the device Keychain. Select a Host here or from the Session footer to switch connections.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
                .padding(.horizontal, IOSTheme.pagePadding)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(IOSTheme.background.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var hosts: [IOSEndpointMetadata] {
        model.endpointMetadataList
    }
}

/// Read-only details for one Host. Configuration edits stay behind the pencil
/// action so opening an item never changes fields or starts a connection.
private struct IOSEndpointDetailView: View {
    @ObservedObject var model: IOSApplicationModel
    let endpoint: IOSEndpointMetadata
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            IOSBackHeader(
                title: endpoint.name,
                subtitle: "Host details",
                symbol: "server.rack",
                actions: AnyView(
                    NavigationLink {
                        IOSEndpointEditorView(model: model, endpoint: endpoint)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(IOSTheme.secondaryText)
                            .frame(width: 42, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit \(endpoint.name)")
                )
            ) {
                dismiss()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    IOSSectionLabel("Connection")
                        .padding(.top, 25)
                        .padding(.bottom, 9)
                    VStack(spacing: 1) {
                        endpointDetailRow("Address", value: endpoint.url, machineText: true)
                        endpointDetailRow(
                            "Type",
                            value: endpoint.isRelay ? "Relay" : "Direct Host"
                        )
                        endpointDetailRow(
                            "Token",
                            value: endpoint.hasToken ? "Saved in Keychain" : "Not saved"
                        )
                    }
                    .iosSurface(color: IOSTheme.chrome)

                    if endpoint.isRelay {
                        relayDetails
                    }

                    Button {
                        model.selectEndpoint(named: endpoint.name)
                    } label: {
                        Text(isActive ? "Current Host" : "Use this Host")
                            .font(IOSTypography.button)
                            .foregroundStyle(isActive ? IOSTheme.secondaryText : IOSTheme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                isActive ? IOSTheme.muted : IOSTheme.accent,
                                in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isActive)
                    .padding(.top, 22)

                    if let error = model.endpointError {
                        IOSInlineNotice(
                            title: "Host action failed",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                        .padding(.top, 16)
                    }

                    Text(endpoint.isRelay
                        ? "Relay routes this Host through an encrypted control-plane tunnel."
                        : "Warren connects to /v1/ws. Use HTTPS/WSS outside your local network.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
                .padding(.horizontal, IOSTheme.pagePadding)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(IOSTheme.background.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
    }

    private var isActive: Bool {
        endpoint.name == model.endpointMetadata.name
    }

    @ViewBuilder
    private var relayDetails: some View {
        IOSSectionLabel("Relay")
            .padding(.top, 25)
            .padding(.bottom, 9)
        VStack(spacing: 1) {
            endpointDetailRow("Status", value: "Connected")
            if let hostID = endpoint.hostID, !hostID.isEmpty {
                endpointDetailRow("Host ID", value: hostID, machineText: true)
            }
            if let routeID = endpoint.routeID, !routeID.isEmpty {
                endpointDetailRow("Route ID", value: routeID, machineText: true)
            }
        }
        .iosSurface(color: IOSTheme.chrome)
    }

    private func endpointDetailRow(
        _ label: String,
        value: String,
        machineText: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(IOSTypography.label)
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(machineText ? IOSTypography.metadata : IOSTypography.body)
                .foregroundStyle(IOSTheme.text)
                .lineLimit(3)
                .iosNaturalWrap()
                .iosMachineText()
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(IOSTheme.input)
    }
}

/// Edits one list item. Passing `nil` creates a new Host; an existing item is
/// replaced by its original name so editing a non-active row cannot overwrite
/// the currently selected Host by accident.
private struct IOSEndpointEditorView: View {
    @ObservedObject var model: IOSApplicationModel
    let endpoint: IOSEndpointMetadata?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var didLoad = false
    @State private var showingRelayScanner = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, token }

    var body: some View {
        VStack(spacing: 0) {
            IOSBackHeader(
                title: endpoint == nil ? "Add Host" : "Edit Host",
                subtitle: "Connection",
                symbol: "server.rack"
            ) {
                dismiss()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Connection")
                        .font(IOSTypography.sectionTitle)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .padding(.top, 25)
                        .padding(.bottom, 9)
                    VStack(spacing: 1) {
                        endpointField("Name", placeholder: "Warren Host", text: $name, field: .name)
                        endpointField("URL", placeholder: IOSDevelopmentEndpoint.url, text: $url, field: .url)
                        endpointSecureField("Token", placeholder: "Host token", text: $token, field: .token)
                    }
                    .iosSurface(color: IOSTheme.chrome)

                    Text(hasToken
                        ? "Token saved in Keychain. Leave it blank to keep it."
                        : "No token saved on this device.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .padding(.top, 10)

                    relayPairingSection

                    if let error = model.endpointError {
                        IOSInlineNotice(
                            title: "Host not saved",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                        .padding(.top, 16)
                    }

                    Button {
                        let replacementToken = token.isEmpty ? nil : token
                        let saved: Bool
                        if let endpoint {
                            saved = model.saveEndpoint(
                                name: name,
                                url: url,
                                token: replacementToken,
                                replacingEndpointName: endpoint.name
                            )
                        } else {
                            saved = model.saveNewEndpoint(
                                name: name,
                                url: url,
                                token: replacementToken
                            )
                        }
                        if saved {
                            focusedField = nil
                            dismiss()
                        }
                    } label: {
                        Text("Save & connect")
                            .font(IOSTypography.button)
                            .foregroundStyle(IOSTheme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(IOSTheme.accent, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    .padding(.top, 22)

                    if hasToken {
                        Button(role: .destructive) {
                            model.clearEndpointToken(named: endpoint?.name)
                            token = ""
                        } label: {
                            Text("Clear saved token")
                                .font(IOSTypography.button)
                                .foregroundStyle(IOSTheme.red)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }

                    Text(isRelay
                        ? "Relay routes this Host through an encrypted control-plane tunnel."
                        : "Warren connects to /v1/ws. Use HTTPS/WSS outside your local network.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText.opacity(0.84))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                }
                .padding(.horizontal, IOSTheme.pagePadding)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(IOSTheme.background.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            guard !didLoad else { return }
            name = endpoint?.name ?? ""
            url = endpoint?.url ?? ""
            didLoad = true
        }
        .sheet(isPresented: $showingRelayScanner) {
            IOSRelayPairingScannerView(
                onCode: { code in
                    showingRelayScanner = false
                    model.pairRelay(from: code, replacingEndpointName: endpoint?.name)
                },
                onPaste: {
                    showingRelayScanner = false
                    #if canImport(UIKit)
                    model.pairRelayLink(
                        UIPasteboard.general.string ?? "",
                        replacingEndpointName: endpoint?.name
                    )
                    #else
                    model.pairRelayLink("", replacingEndpointName: endpoint?.name)
                    #endif
                },
                onCancel: { showingRelayScanner = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: model.endpointMetadata) { _, metadata in
            guard model.isPairingRelay || metadata.isRelay else { return }
            name = metadata.name
            url = metadata.url
        }
    }

    private var savedMetadata: IOSEndpointMetadata? {
        let targetName = endpoint?.name ?? name
        if model.endpointMetadata.name == targetName || model.endpointMetadata.name == name {
            return model.endpointMetadata
        }
        return model.endpointMetadataList.first(where: { $0.name == targetName })
    }

    private var hasToken: Bool {
        savedMetadata?.hasToken ?? false
    }

    private var isRelay: Bool {
        savedMetadata?.isRelay ?? false
    }

    @ViewBuilder
    private var relayPairingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Relay")
                    .font(IOSTypography.sectionTitle)
                    .foregroundStyle(IOSTheme.text)
                if isRelay {
                    Text("CONNECTED")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.green)
                }
            }

            Button {
                showingRelayScanner = true
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(IOSTheme.accent)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isPairingRelay ? "Pairing Relay…" : "Scan Relay QR")
                            .font(IOSTypography.bodyEmphasis)
                            .foregroundStyle(IOSTheme.text)
                        Text("Use the one-time link shown by Warren Relay.")
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if model.isPairingRelay {
                        ProgressView()
                            .controlSize(.small)
                            .tint(IOSTheme.accent)
                    } else {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                }
                .padding(.horizontal, 13)
                .frame(minHeight: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isPairingRelay)
            .iosSurface(color: IOSTheme.chrome, radius: IOSTheme.smallRadius)

            #if canImport(UIKit)
            Button {
                guard let link = UIPasteboard.general.string else {
                    model.pairRelayLink("", replacingEndpointName: endpoint?.name)
                    return
                }
                model.pairRelayLink(link, replacingEndpointName: endpoint?.name)
            } label: {
                Label("Paste Relay link", systemImage: "doc.on.clipboard")
                    .font(IOSTypography.label)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isPairingRelay)
            #endif

            if isRelay, let hostID = savedMetadata?.hostID {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("Host \(hostID.prefix(8))")
                }
                .font(IOSTypography.metadata)
                .foregroundStyle(IOSTheme.secondaryText)
            }
        }
        .padding(.top, 25)
    }

    private func endpointField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(IOSTypography.label)
                .foregroundStyle(IOSTheme.secondaryText)
                // The label width is content-driven rather than calibrated
                // to the English strings. Localized labels may grow without
                // stealing a fixed character-sized slot from the field.
                .lineLimit(2)
                .iosNaturalWrap()
                .layoutPriority(1)
            TextField(placeholder, text: text)
                .font(IOSTypography.body)
                .foregroundStyle(IOSTheme.text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(field == .url ? .URL : .default)
                #endif
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 50)
        .background(IOSTheme.input)
    }

    private func endpointSecureField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(IOSTypography.label)
                .foregroundStyle(IOSTheme.secondaryText)
                .lineLimit(2)
                .iosNaturalWrap()
                .layoutPriority(1)
            SecureField(placeholder, text: text)
                .font(IOSTypography.body)
                .foregroundStyle(IOSTheme.text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: field)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                #endif
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 50)
        .background(IOSTheme.input)
    }
}
