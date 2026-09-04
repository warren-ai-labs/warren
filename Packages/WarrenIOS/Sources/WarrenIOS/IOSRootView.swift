import SwiftUI
import WarrenDesignSystem
import WarrenTransport

#if canImport(UIKit)
import UIKit
#endif

public enum IOSRoute: Hashable {
    case workspace(String)
    case terminalGroup(String)
    case session(String)
}

func sessionScopeID(kind: String, id: String) -> String {
    "\(kind):\(id)"
}

private func dashboardSectionID(kind: String, id: String) -> String {
    "\(kind):\(id)"
}

/// The compact home surface is Warren's mobile project rail. It keeps the
/// Web hierarchy (projects → workspaces → sessions) visible in one calm list,
/// and only pushes a detail route when the user actually needs a scope or a
/// terminal. There is no stock `List` chrome and no automatic shell creation.
public struct IOSRootView: View {
    @ObservedObject private var model: IOSApplicationModel
    @State private var navigationPath: [IOSRoute] = []
    @State private var collapsedCardIDs: Set<String> = []
    @State private var showingWorkspaceManager = false
    @State private var workspaceManagerProjectID: String?

    public init(model: IOSApplicationModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            HostDashboardView(
                model: model,
                collapsedCardIDs: $collapsedCardIDs,
                openWorkspace: { navigationPath.append(.workspace($0)) },
                openTerminalGroup: { navigationPath.append(.terminalGroup($0)) },
                openSession: { navigationPath.append(.session($0)) },
                openWorkspaceManager: { projectID in
                    workspaceManagerProjectID = projectID
                    showingWorkspaceManager = true
                }
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
        .onAppear {
            revealActiveSession(model.currentSessionID)
        }
        .sheet(isPresented: $showingWorkspaceManager) {
            IOSWorkspaceManagementSheet(model: model, projectID: workspaceManagerProjectID)
                .iosSheetPresentation(.medium, .large)
        }
        .onOpenURL { url in
            if let sessionID = model.parseSessionDeepLink(url) {
                model.selectSession(sessionID)
                navigateToSession(sessionID)
            }
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
            navigateToSession(sessionID)
        }
    }

    private func navigateToSession(_ sessionID: String) {
        revealActiveSession(sessionID)
        if let routeIndex = navigationPath.firstIndex(where: { route in
            if case .session = route { return true }
            return false
        }) {
            // SessionView can switch siblings without changing the
            // NavigationStack depth. Keep the path's identity in lockstep
            // with the model so dismissal never returns to a deleted tab.
            navigationPath[routeIndex] = .session(sessionID)
            if routeIndex + 1 < navigationPath.count {
                navigationPath.removeSubrange((routeIndex + 1)..<navigationPath.count)
            }
            return
        }
        navigationPath.append(.session(sessionID))
    }

    private func revealActiveSession(_ sessionID: String?) {
        guard let sessionID,
              let session = model.activeSessions.first(where: { $0.id == sessionID }) else {
            return
        }

        if let workspaceID = session.workspaceID {
            collapsedCardIDs.remove(sessionScopeID(kind: "workspace", id: workspaceID))
        }
        if let groupID = session.terminalGroupID {
            collapsedCardIDs.remove(sessionScopeID(kind: "group", id: groupID))
        }
    }
}

private enum IOSSessionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case agents = "Agents"
    case terminals = "Terminals"
    case active = "Active"

    var id: String { rawValue }
}

private struct SessionFilterBar: View {
    @Binding var selected: IOSSessionFilter

    var body: some View {
        HStack(spacing: 6) {
            ForEach(IOSSessionFilter.allCases) { filter in
                Button {
                    selected = filter
                } label: {
                    Text(filter.rawValue)
                        .font(IOSTypography.status)
                        .fontWeight(selected == filter ? .semibold : .regular)
                        .foregroundStyle(selected == filter ? IOSTheme.text : IOSTheme.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            selected == filter
                                ? IOSTheme.muted.opacity(0.55)
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

private struct SessionCreationTarget: Identifiable {
    let id: String
    let workspaceID: String?
    let terminalGroupID: String?
    let title: String
}

private struct HostDashboardView: View {
    @ObservedObject var model: IOSApplicationModel
    @Binding var collapsedCardIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openWorkspace: (String) -> Void
    let openTerminalGroup: (String) -> Void
    let openSession: (String) -> Void
    let openWorkspaceManager: (String) -> Void

    @State private var selectedFilter: IOSSessionFilter = .all
    @State private var creationTarget: SessionCreationTarget?

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

    private var allCardIDs: Set<String> {
        var ids = Set<String>()
        for ws in workspaces {
            ids.insert(sessionScopeID(kind: "workspace", id: ws.id))
        }
        for grp in model.roster?.terminalGroups ?? [] {
            ids.insert(sessionScopeID(kind: "group", id: grp.id))
        }
        return ids
    }

    private var isAllCollapsed: Bool {
        let ids = allCardIDs
        return !ids.isEmpty && ids.isSubset(of: collapsedCardIDs)
    }

    private func toggleCollapseAll() {
        IOSHaptics.selection()
        withAnimation(reduceMotion ? nil : IOSMotion.spring) {
            if isAllCollapsed {
                collapsedCardIDs.removeAll()
            } else {
                collapsedCardIDs.formUnion(allCardIDs)
            }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HomeHeader(
                    model: model,
                    onNewSession: {
                        creationTarget = SessionCreationTarget(
                            id: "global",
                            workspaceID: nil,
                            terminalGroupID: nil,
                            title: ""
                        )
                    }
                )

                if let message = model.maintenanceMessage {
                    IOSInlineNotice(
                        title: "Host updating",
                        message: message,
                        color: IOSTheme.amber,
                        symbol: "arrow.triangle.2.circlepath"
                    )
                    .padding(.top, 10)
                } else if let error = model.connectionError,
                          model.connectionState != .connected {
                    IOSInlineNotice(
                        title: connectionTitle,
                        message: error,
                        color: IOSTheme.red,
                        symbol: "wifi.exclamationmark"
                    )
                    .padding(.top, 10)
                }

                if model.roster == nil {
                    IOSLoadingRow(state: model.connectionState)
                        .padding(.top, 44)
                } else if projects.isEmpty && workspaces.isEmpty && (model.roster?.terminalGroups.isEmpty ?? true) {
                    IOSEmptyState(
                        symbol: "terminal",
                        title: "No sessions",
                        message: "Create a session to get started."
                    )
                    .padding(.top, 42)
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        SessionFilterBar(selected: $selectedFilter)
                        if !allCardIDs.isEmpty {
                            Button(action: toggleCollapseAll) {
                                Image(systemName: isAllCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(isAllCollapsed ? IOSTheme.accent : IOSTheme.secondaryText)
                                    .frame(width: 32, height: 32)
                                    .background(IOSTheme.raised, in: Circle())
                                    .overlay(
                                        Circle().stroke(IOSTheme.separator.opacity(0.35), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isAllCollapsed ? "Expand all workspaces" : "Collapse all workspaces")
                        }
                    }
                    .padding(.top, 4)

                    if hasMatchingSessions {
                        projectSections
                        unassignedWorkspaceSection
                        terminalGroupSection
                    } else {
                        IOSEmptyState(
                            symbol: "line.3.horizontal.decrease",
                            title: "No matches",
                            message: "No \(selectedFilter.rawValue.lowercased()) sessions found."
                        )
                        .padding(.top, 36)
                    }
                }

                if let error = model.mutationError {
                    IOSInlineNotice(
                        title: "Action failed",
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
        .sheet(item: $creationTarget) { target in
            IOSSessionCreationSheet(
                model: model,
                workspaceID: target.workspaceID,
                terminalGroupID: target.terminalGroupID,
                title: target.title
            )
            .iosSheetPresentation(.medium, .large)
        }
    }

    private var hasMatchingSessions: Bool {
        if selectedFilter == .all { return true }
        let hasWs = workspaces.contains { ws in
            !filter(sessions: sessionsByWorkspace[ws.id] ?? []).isEmpty
        }
        if hasWs { return true }
        let hasTg = (model.roster?.terminalGroups ?? []).contains { grp in
            !filter(sessions: model.sessions(inTerminalGroup: grp.id)).isEmpty
        }
        return hasTg
    }

    private func filter(sessions: [WarrenRemoteRoster.Session]) -> [WarrenRemoteRoster.Session] {
        switch selectedFilter {
        case .all:
            return sessions
        case .agents:
            return sessions.filter { $0.isAgentBacked }
        case .terminals:
            return sessions.filter { !$0.isAgentBacked }
        case .active:
            return sessions.filter { session in
                if session.isAgentBacked {
                    let status = model.agentStatusBySessionID[session.id] ?? session.agentStatus
                    return status?.activity == .working || status?.activity == .ready
                }
                return session.isRunning
            }
        }
    }

    @ViewBuilder
    private var projectSections: some View {
        ForEach(projects) { project in
            let scopedWorkspaces = workspaces.filter { $0.projectID == project.id }
            let matchingWorkspaces = scopedWorkspaces.filter { ws in
                if selectedFilter == .all { return true }
                let sess = filter(sessions: sessionsByWorkspace[ws.id] ?? [])
                return !sess.isEmpty
            }
            if !matchingWorkspaces.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(project.name.isEmpty ? pathLeaf(project.path) : project.name)
                            .font(IOSTypography.sectionTitle)
                            .foregroundStyle(IOSTheme.text)
                        Spacer()
                        Menu {
                            Button("Manage workspaces", systemImage: "slider.horizontal.3") {
                                openWorkspaceManager(project.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(IOSTheme.tertiaryText)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 12)

                    ForEach(matchingWorkspaces) { workspace in
                        let cardID = sessionScopeID(kind: "workspace", id: workspace.id)
                        let sess = filter(sessions: sessionsByWorkspace[workspace.id] ?? [])
                        WorkspaceCard(
                            model: model,
                            workspace: workspace,
                            projectName: nil,
                            sessions: sess,
                            activeSessionID: model.currentSessionID,
                            isCollapsed: collapsedCardIDs.contains(cardID),
                            toggle: { toggleCard(cardID) },
                            openWorkspace: { openWorkspace(workspace.id) },
                            openSession: openSession,
                            openNewSession: {
                                creationTarget = SessionCreationTarget(
                                    id: "ws-\(workspace.id)",
                                    workspaceID: workspace.id,
                                    terminalGroupID: nil,
                                    title: workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name
                                )
                            }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var unassignedWorkspaceSection: some View {
        let assigned = Set(projects.map(\.id))
        let unassigned = workspaces.filter { !assigned.contains($0.projectID) }
        let matchingWorkspaces = unassigned.filter { ws in
            if selectedFilter == .all { return true }
            let sess = filter(sessions: sessionsByWorkspace[ws.id] ?? [])
            return !sess.isEmpty
        }
        if !matchingWorkspaces.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspaces")
                    .font(IOSTypography.sectionTitle)
                    .foregroundStyle(IOSTheme.text)
                    .padding(.horizontal, 2)
                    .padding(.top, 12)

                ForEach(matchingWorkspaces) { workspace in
                    let cardID = sessionScopeID(kind: "workspace", id: workspace.id)
                    let sess = filter(sessions: sessionsByWorkspace[workspace.id] ?? [])
                    WorkspaceCard(
                        model: model,
                        workspace: workspace,
                        projectName: nil,
                        sessions: sess,
                        activeSessionID: model.currentSessionID,
                        isCollapsed: collapsedCardIDs.contains(cardID),
                        toggle: { toggleCard(cardID) },
                        openWorkspace: { openWorkspace(workspace.id) },
                        openSession: openSession,
                        openNewSession: {
                            creationTarget = SessionCreationTarget(
                                id: "ws-\(workspace.id)",
                                workspaceID: workspace.id,
                                terminalGroupID: nil,
                                title: workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name
                            )
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var terminalGroupSection: some View {
        let groups = (model.roster?.terminalGroups ?? []).sorted { lhs, rhs in
            lhs.order == rhs.order
                ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                : lhs.order < rhs.order
        }
        let matchingGroups = groups.filter { group in
            if selectedFilter == .all { return true }
            let sess = filter(sessions: model.sessions(inTerminalGroup: group.id))
            return !sess.isEmpty
        }
        if !matchingGroups.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Terminal Groups")
                    .font(IOSTypography.sectionTitle)
                    .foregroundStyle(IOSTheme.text)
                    .padding(.horizontal, 2)
                    .padding(.top, 12)

                ForEach(matchingGroups) { group in
                    let cardID = sessionScopeID(kind: "group", id: group.id)
                    let sess = filter(sessions: model.sessions(inTerminalGroup: group.id))
                    TerminalGroupCard(
                        model: model,
                        group: group,
                        sessions: sess,
                        activeSessionID: model.currentSessionID,
                        isCollapsed: collapsedCardIDs.contains(cardID),
                        toggle: { toggleCard(cardID) },
                        openSession: openSession,
                        openNewSession: {
                            creationTarget = SessionCreationTarget(
                                id: "tg-\(group.id)",
                                workspaceID: nil,
                                terminalGroupID: group.id,
                                title: group.name.isEmpty ? "Terminal Group" : group.name
                            )
                        }
                    )
                }
            }
        }
    }

    private var connectionTitle: LocalizedStringKey {
        IOSCopy.connectionTitle(for: model.connectionState)
    }

    private func toggleCard(_ cardID: String) {
        withAnimation(reduceMotion ? nil : IOSMotion.spring) {
            if collapsedCardIDs.contains(cardID) {
                collapsedCardIDs.remove(cardID)
            } else {
                collapsedCardIDs.insert(cardID)
            }
        }
    }
}

private struct HomeHeader: View {
    @ObservedObject var model: IOSApplicationModel
    let onNewSession: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IOSBrandMark(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Warren")
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

            Button(action: onNewSession) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(IOSTheme.text)
                    .frame(width: 34, height: 34)
                    .background(IOSTheme.muted.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New session")

            if model.connectionState != .connected {
                Menu {
                    Button("Reconnect", systemImage: "arrow.clockwise") { model.reconnect() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 34, height: 34)
                        .background(IOSTheme.muted.opacity(0.3), in: Circle())
                }
                .menuStyle(.automatic)
                .accessibilityLabel("Host actions")
            }
        }
        .frame(minHeight: 64)
        .padding(.top, 8)
        .padding(.bottom, 6)
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


private struct WorkspaceCard: View {
    @ObservedObject var model: IOSApplicationModel
    let workspace: WarrenRemoteRoster.Workspace
    let projectName: String?
    let sessions: [WarrenRemoteRoster.Session]
    let activeSessionID: String?
    let isCollapsed: Bool
    let toggle: () -> Void
    let openWorkspace: () -> Void
    let openSession: (String) -> Void
    let openNewSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            if let projectName, !projectName.isEmpty {
                                Text(projectName)
                                    .font(IOSTypography.eyebrow)
                                    .foregroundStyle(IOSTheme.tertiaryText)
                                    .lineLimit(1)
                            }
                            Text(workspaceTitle)
                                .font(IOSTypography.bodyEmphasis)
                                .foregroundStyle(IOSTheme.text)
                                .lineLimit(1)
                                .iosMachineText()
                        }
                        Spacer(minLength: 8)
                        if !sessions.isEmpty {
                            Text("\(sessions.count)")
                                .font(IOSTypography.metric)
                                .foregroundStyle(IOSTheme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(IOSTheme.muted.opacity(0.35), in: Capsule())
                        }
                        Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .frame(width: 20, height: 20)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: openNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(IOSTheme.muted.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New session in \(workspaceTitle)")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)

            if !isCollapsed {
                if !sessions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            Rectangle()
                                .fill(IOSTheme.separator.opacity(0.22))
                                .frame(height: 0.5)
                                .padding(.leading, 42)

                            SessionCardRow(
                                model: model,
                                session: session,
                                agentStatus: model.agentStatusBySessionID[session.id] ?? session.agentStatus,
                                isActive: activeSessionID == session.id,
                                onSelect: { openSession(session.id) }
                            )
                        }
                    }
                } else {
                    Rectangle()
                        .fill(IOSTheme.separator.opacity(0.22))
                        .frame(height: 0.5)
                    HStack {
                        Text("No sessions")
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Spacer()
                        Button("New session", action: openNewSession)
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.accent)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                }
            }
        }
        .background(IOSTheme.cardBackground, in: RoundedRectangle(cornerRadius: IOSTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IOSTheme.cardRadius, style: .continuous)
                .stroke(IOSTheme.cardBorder, lineWidth: 0.5)
        }
        .padding(.bottom, 10)
    }

    private var workspaceTitle: String {
        workspace.branch ?? (workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name)
    }
}

private struct TerminalGroupCard: View {
    @ObservedObject var model: IOSApplicationModel
    let group: WarrenRemoteRoster.TerminalGroup
    let sessions: [WarrenRemoteRoster.Session]
    let activeSessionID: String?
    let isCollapsed: Bool
    let toggle: () -> Void
    let openSession: (String) -> Void
    let openNewSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Text(group.name.isEmpty ? "Terminal Group" : group.name)
                            .font(IOSTypography.bodyEmphasis)
                            .foregroundStyle(IOSTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !sessions.isEmpty {
                            Text("\(sessions.count)")
                                .font(IOSTypography.metric)
                                .foregroundStyle(IOSTheme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(IOSTheme.muted.opacity(0.35), in: Capsule())
                        }
                        Image(systemName: isCollapsed ? "chevron.forward" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .frame(width: 20, height: 20)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button(action: openNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(IOSTheme.muted.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New session in \(group.name)")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)

            if !isCollapsed {
                if !sessions.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            Rectangle()
                                .fill(IOSTheme.separator.opacity(0.22))
                                .frame(height: 0.5)
                                .padding(.leading, 42)

                            SessionCardRow(
                                model: model,
                                session: session,
                                agentStatus: model.agentStatusBySessionID[session.id] ?? session.agentStatus,
                                isActive: activeSessionID == session.id,
                                onSelect: { openSession(session.id) }
                            )
                        }
                    }
                } else {
                    Rectangle()
                        .fill(IOSTheme.separator.opacity(0.22))
                        .frame(height: 0.5)
                    HStack {
                        Text("No sessions")
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Spacer()
                        Button("New session", action: openNewSession)
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.accent)
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                }
            }
        }
        .background(IOSTheme.cardBackground, in: RoundedRectangle(cornerRadius: IOSTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IOSTheme.cardRadius, style: .continuous)
                .stroke(IOSTheme.cardBorder, lineWidth: 0.5)
        }
        .padding(.bottom, 10)
    }
}

private struct SessionCardRow: View {
    @ObservedObject var model: IOSApplicationModel
    let session: WarrenRemoteRoster.Session
    let agentStatus: WarrenRemoteAgentStatus?
    let isActive: Bool
    let onSelect: () -> Void

    private var isAgent: Bool {
        if session.isAgentBacked { return true }
        let provider = sessionProviderID(
            for: session,
            events: model.agentState.agentEventsBySessionID[session.id]
        )
        return provider != "shell"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 11) {
                if isAgent {
                    SessionProviderMark(
                        model: model,
                        agentState: model.agentState,
                        session: session,
                        slotSize: 20
                    )
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 20, height: 20)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle.isEmpty ? (session.process ?? session.kind.capitalized) : session.displayTitle)
                        .font(IOSTypography.bodyEmphasis)
                        .foregroundStyle(isActive ? IOSTheme.accent : IOSTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .iosMachineText()

                    statusSubtitle
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    Circle()
                        .fill(IOSTheme.accent)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusSubtitle: some View {
        if session.isAgentBacked {
            if let status = agentStatus {
                if status.activity == .working {
                    Text("Working")
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.amber)
                } else if status.attention != nil {
                    Text("Action needed")
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.yellow)
                } else if status.activity == .failed {
                    Text("Failed")
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.red)
                } else {
                    Text("Ready")
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
            } else {
                Text("Ready")
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
            }
        } else {
            Text(session.process ?? "Shell")
                .font(IOSTypography.status)
                .foregroundStyle(IOSTheme.tertiaryText)
        }
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
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
            }
        }
        .frame(width: 23)
        .accessibilityHidden(true)
    }
}

/// Shared bottom Host rail. The selected Host name opens the same explicit
/// picker from the dashboard and from a live Session surface.
struct IOSHostFooter: View {
    @ObservedObject var model: IOSApplicationModel
    @State private var showingHostPicker = false

    var body: some View {
        HStack(spacing: 12) {
            Button { showingHostPicker = true } label: {
                HStack(spacing: 8) {
                    IOSStatusDot(color: connectionColor, size: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.endpointMetadata.name)
                            .font(IOSTypography.bodyEmphasis)
                            .foregroundStyle(IOSTheme.text)
                            .lineLimit(1)
                        Text(model.endpointMetadata.isRelay ? "Relay" : "Direct Host")
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch Host")

            Spacer()

            Button(action: model.reconnect) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reconnect to Host")

            NavigationLink {
                IOSEndpointConfigurationView(model: model)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Host settings")
        }
        .padding(.horizontal, IOSTheme.pagePadding)
        .frame(minHeight: 56)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.35))
                .frame(height: 0.5)
        }
        .sheet(isPresented: $showingHostPicker) {
            IOSEndpointPickerSheet(
                model: model,
                hosts: hosts,
                title: "Switch Host"
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
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

/// A calm, explicit Host switcher without clutter or extraneous text.
private struct IOSEndpointPickerSheet: View {
    @ObservedObject var model: IOSApplicationModel
    let hosts: [IOSEndpointMetadata]
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(displayHosts.enumerated()), id: \.element.name) { index, host in
                        if index > 0 {
                            Divider()
                                .background(IOSTheme.separator.opacity(0.3))
                                .padding(.leading, 56)
                        }
                        Button {
                            IOSHaptics.selection()
                            model.selectEndpoint(named: host.name)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ZStack(alignment: .bottomTrailing) {
                                    Circle()
                                        .fill(host.name == model.endpointMetadata.name ? IOSTheme.accent.opacity(0.15) : IOSTheme.muted.opacity(0.4))
                                        .frame(width: 38, height: 38)
                                        .overlay(
                                            Image(systemName: host.isRelay ? "point.3.connected.trianglepath.dotted" : "server.rack")
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundStyle(host.name == model.endpointMetadata.name ? IOSTheme.accent : IOSTheme.secondaryText)
                                        )
                                    if host.name == model.endpointMetadata.name {
                                        Circle()
                                            .fill(connectionColor)
                                            .frame(width: 8, height: 8)
                                            .overlay(Circle().stroke(IOSTheme.cardBackground, lineWidth: 1.5))
                                    }
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.name)
                                        .font(IOSTypography.bodyEmphasis)
                                        .foregroundStyle(IOSTheme.text)
                                        .lineLimit(1)
                                    Text(host.isRelay ? "Relay" : host.url)
                                        .font(IOSTypography.metadata)
                                        .foregroundStyle(IOSTheme.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer(minLength: 8)

                                if host.name == model.endpointMetadata.name {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(IOSTheme.green)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .iosCardSurface()
                .padding(.horizontal, IOSTheme.pagePadding)
                .padding(.top, 16)

                Spacer(minLength: 0)
            }
            .background(IOSTheme.background.ignoresSafeArea())
            .navigationTitle(title)
#if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(IOSTypography.bodyEmphasis)
                        .foregroundStyle(IOSTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var displayHosts: [IOSEndpointMetadata] {
        let values = hosts.isEmpty ? [model.endpointMetadata] : hosts
        return values.sorted { lhs, rhs in
            let lhsCurrent = lhs.name == model.endpointMetadata.name
            let rhsCurrent = rhs.name == model.endpointMetadata.name
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
    @State private var pendingSessionID: String?
    @State private var actionFeedback: String?
    @State private var actionFeedbackGeneration = 0

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
                                        guard pendingSessionID == nil, !model.isMutating else { return }
                                        pendingSessionID = session.id
                                        showActionFeedback("Deleting…", duration: 0)
                                        onDeleteSession(session.id)
                                    }
                                    .disabled(pendingSessionID != nil || model.isMutating)
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
        .overlay(alignment: .top) {
            if let actionFeedback {
                Text(actionFeedback)
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(IOSTheme.chrome, in: Capsule())
                    .overlay(Capsule().stroke(IOSTheme.separator, lineWidth: 1))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear(perform: onAppear)
        .onChange(of: model.isMutating) { wasMutating, isMutating in
            guard pendingSessionID != nil, wasMutating, !isMutating else { return }
            let message: String
            if let error = model.mutationError, !error.isEmpty {
                message = "Session delete failed: \(error)"
            } else {
                message = "Session deleted"
            }
            pendingSessionID = nil
            showActionFeedback(message)
        }
    }

    private func showActionFeedback(_ message: String, duration: TimeInterval = 1.6) {
        actionFeedbackGeneration &+= 1
        let generation = actionFeedbackGeneration
        actionFeedback = message
        guard duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if actionFeedbackGeneration == generation { actionFeedback = nil }
        }
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
                    .frame(width: 44, height: 44)
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
    let symbol: String?
    let actions: AnyView?
    let onBack: () -> Void

    init(
        title: String,
        subtitle: String,
        symbol: String? = nil,
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
        HStack(spacing: 8) {
            IOSIconButton("chevron.backward", label: "Back", action: onBack)
            if let symbol, !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
            }
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
    @State private var renamePending = false
    @State private var deletePending = false
    @State private var actionFeedback: String?
    @State private var actionFeedbackGeneration = 0

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
                .iosSheetPresentation(.medium, .large)
        }
        .overlay(alignment: .top) {
            if let actionFeedback {
                Text(actionFeedback)
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(IOSTheme.chrome, in: Capsule())
                    .overlay(Capsule().stroke(IOSTheme.separator, lineWidth: 1))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .alert("Rename workspace", isPresented: $showingRename) {
            TextField("Workspace name", text: $workspaceName)
            Button(renamePending ? "Saving…" : "Save") {
                guard !renamePending,
                      !model.isMutating,
                      !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                renamePending = true
                showActionFeedback("Saving…", duration: 0)
                model.renameWorkspace(workspaceID, name: workspaceName)
            }
            .disabled(
                renamePending
                    || model.isMutating
                    || workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            Button("Cancel", role: .cancel) {}
                .disabled(renamePending)
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive) {
                guard !deletePending, !model.isMutating else { return }
                deletePending = true
                showActionFeedback("Deleting…", duration: 0)
                model.deleteWorkspace(workspaceID)
            }
            .disabled(deletePending || model.isMutating)
            Button("Cancel", role: .cancel) {}
                .disabled(deletePending)
        } message: {
            Text("The workspace record will be removed. Running sessions must be deleted first.")
        }
        .onChange(of: model.isMutating) { wasMutating, isMutating in
            guard wasMutating, !isMutating else { return }
            if renamePending {
                renamePending = false
                if let error = model.mutationError, !error.isEmpty {
                    showActionFeedback("Workspace rename failed: \(error)")
                } else {
                    showActionFeedback("Workspace renamed")
                }
            }
            if deletePending {
                deletePending = false
                if let error = model.mutationError, !error.isEmpty {
                    showActionFeedback("Workspace delete failed: \(error)")
                } else {
                    showActionFeedback("Workspace deleted")
                }
            }
        }
    }

    private func showActionFeedback(_ message: String, duration: TimeInterval = 1.6) {
        actionFeedbackGeneration &+= 1
        let generation = actionFeedbackGeneration
        actionFeedback = message
        guard duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if actionFeedbackGeneration == generation { actionFeedback = nil }
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
                .iosSheetPresentation(.medium, .large)
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
    case claude
    case codex
    case antigravity
    case opencode
    case pi
    case qoder
    case trae
    case shell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .opencode: return "OpenCode"
        case .pi: return "Pi"
        case .qoder: return "Qoder"
        case .trae: return "Trae"
        case .shell: return "Shell"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "curlybraces"
        case .antigravity: return "arrow.up.circle"
        case .opencode: return "terminal.fill"
        case .pi: return "function"
        case .qoder: return "sparkle"
        case .trae: return "sparkle.magnifyingglass"
        case .shell: return "terminal"
        }
    }

    var defaultCommand: String? {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex --dangerously-bypass-hook-trust"
        case .antigravity: return "agy"
        case .opencode: return "opencode"
        case .pi: return "pi"
        case .qoder: return "qoder"
        case .trae: return "trae-cli interactive"
        case .shell: return nil
        }
    }
}

private enum IOSSessionCreationWorkspaceMode: String, CaseIterable, Identifiable {
    case existing = "Existing"
    case new = "New"
    var id: String { rawValue }
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
    @State private var didSubmit = false

    @State private var selectedProjectID: String
    @State private var workspaceMode: IOSSessionCreationWorkspaceMode
    @State private var selectedWorkspaceID: String
    @State private var newWorkspaceBranch: String = ""
    @State private var newWorkspaceName: String = ""

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
        let remembered = IOSSessionCreationKind(rawValue: model.localStore.lastSessionKind) ?? .claude
        _selectedKind = State(initialValue: remembered)
        _command = State(initialValue: remembered.defaultCommand ?? "")

        let rosterProjects = (model.roster?.projects ?? []).sorted { lhs, rhs in
            lhs.order < rhs.order
        }
        let rosterWorkspaces = model.roster?.workspaces ?? []

        if let wsID = workspaceID, let ws = rosterWorkspaces.first(where: { $0.id == wsID }) {
            _selectedProjectID = State(initialValue: ws.projectID)
            _selectedWorkspaceID = State(initialValue: wsID)
            _workspaceMode = State(initialValue: .existing)
        } else if let firstProject = rosterProjects.first {
            _selectedProjectID = State(initialValue: firstProject.id)
            let matchingWs = rosterWorkspaces.filter { $0.projectID == firstProject.id }
            if let firstWs = matchingWs.first {
                _selectedWorkspaceID = State(initialValue: firstWs.id)
                _workspaceMode = State(initialValue: .existing)
            } else {
                _selectedWorkspaceID = State(initialValue: "")
                _workspaceMode = State(initialValue: .new)
            }
        } else {
            _selectedProjectID = State(initialValue: "")
            _selectedWorkspaceID = State(initialValue: workspaceID ?? "")
            _workspaceMode = State(initialValue: .existing)
        }
    }

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

    private var projectWorkspaces: [WarrenRemoteRoster.Workspace] {
        workspaces.filter { $0.projectID == selectedProjectID }
    }

    private var isDestinationSelectable: Bool {
        workspaceID == nil && terminalGroupID == nil && !projects.isEmpty
    }

    private var currentWorkspace: WarrenRemoteRoster.Workspace? {
        guard let workspaceID else { return nil }
        return model.roster?.workspaces.first(where: { $0.id == workspaceID })
    }

    private var currentProject: WarrenRemoteRoster.Project? {
        guard let projectID = currentWorkspace?.projectID else { return nil }
        return model.roster?.projects.first(where: { $0.id == projectID })
    }

    private var currentTerminalGroup: WarrenRemoteRoster.TerminalGroup? {
        guard let terminalGroupID else { return nil }
        return model.roster?.terminalGroups.first(where: { $0.id == terminalGroupID })
    }

    private var displayProjectName: String {
        if let currentProject {
            return currentProject.name.isEmpty ? pathLeaf(currentProject.path) : currentProject.name
        }
        if title.contains(" · ") {
            return title.components(separatedBy: " · ").first ?? "Scope"
        }
        return "Scope"
    }

    private var displayTargetName: String {
        if let currentWorkspace {
            return currentWorkspace.name.isEmpty ? (currentWorkspace.branch ?? "Workspace") : currentWorkspace.name
        }
        if let currentTerminalGroup {
            return currentTerminalGroup.name.isEmpty ? "Terminal Group" : currentTerminalGroup.name
        }
        if title.contains(" · ") {
            return title.components(separatedBy: " · ").last ?? title
        }
        return title.isEmpty ? "Workspace" : title
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isDestinationSelectable {
                        destinationSection
                    } else {
                        fixedScopeCard
                    }

                    sessionTypeSection

                    optionsSection

                    if let error = model.mutationError {
                        IOSInlineNotice(
                            title: "Session not created",
                            message: error,
                            color: IOSTheme.red,
                            symbol: "exclamationmark.triangle"
                        )
                    }

                    submitButton
                }
                .padding(.horizontal, IOSTheme.pagePadding)
                .padding(.vertical, 16)
            }
            .background(IOSTheme.background.ignoresSafeArea())
            .navigationTitle("New Session")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(IOSTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedKind) { oldKind, newKind in
            let currentCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let oldDefault = oldKind.defaultCommand ?? ""
            if currentCommand.isEmpty || currentCommand == oldDefault {
                command = newKind.defaultCommand ?? ""
            }
        }
        .onChange(of: selectedProjectID) { _, newProjectID in
            let matching = workspaces.filter { $0.projectID == newProjectID }
            if let firstWs = matching.first {
                selectedWorkspaceID = firstWs.id
            } else {
                selectedWorkspaceID = ""
                workspaceMode = .new
            }
        }
        .onChange(of: model.isMutating) { wasMutating, isMutating in
            guard didSubmit, wasMutating, !isMutating else { return }
            if model.mutationError == nil {
                dismiss()
            } else {
                didSubmit = false
            }
        }
    }

    @ViewBuilder
    private var fixedScopeCard: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(IOSTheme.accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: terminalGroupID != nil ? "terminal.fill" : "folder.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSTheme.accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayProjectName)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(1)

                    if let branch = currentWorkspace?.branch, !branch.isEmpty {
                        Text("•")
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.tertiaryText)
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10, weight: .bold))
                            Text(branch)
                                .font(IOSTypography.metadata)
                        }
                        .foregroundStyle(IOSTheme.tertiaryText)
                        .lineLimit(1)
                    }
                }

                Text(displayTargetName)
                    .font(IOSTypography.bodyEmphasis)
                    .foregroundStyle(IOSTheme.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            HStack(spacing: 5) {
                Circle()
                    .fill(IOSTheme.green)
                    .frame(width: 6, height: 6)
                Text("Target")
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(IOSTheme.muted.opacity(0.35), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .iosCardSurface()
    }

    @ViewBuilder
    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DESTINATION")
                .font(IOSTypography.eyebrow)
                .foregroundStyle(IOSTheme.secondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                // Project Row
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(IOSTheme.accent)
                        .frame(width: 24)

                    Text("Project")
                        .font(IOSTypography.bodyEmphasis)
                        .foregroundStyle(IOSTheme.text)

                    Spacer(minLength: 8)

                    Picker("Project", selection: $selectedProjectID) {
                        ForEach(projects) { proj in
                            Text(proj.name.isEmpty ? pathLeaf(proj.path) : proj.name)
                                .tag(proj.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(IOSTheme.accent)
                    .accessibilityLabel("Project")
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)

                Divider()
                    .background(IOSTheme.separator.opacity(0.35))
                    .padding(.leading, 50)

                // Workspace Mode Selector
                VStack(spacing: 10) {
                    Picker("Workspace Mode", selection: $workspaceMode) {
                        ForEach(IOSSessionCreationWorkspaceMode.allCases) { mode in
                            Text(mode == .existing ? "Existing Workspace" : "New Workspace")
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                    if workspaceMode == .existing {
                        if projectWorkspaces.isEmpty {
                            HStack(spacing: 8) {
                                Text("No existing workspaces in this project")
                                    .font(IOSTypography.status)
                                    .foregroundStyle(IOSTheme.secondaryText)
                                Spacer()
                                Button("Create One") {
                                    withAnimation(IOSMotion.quick) {
                                        workspaceMode = .new
                                    }
                                }
                                .font(IOSTypography.status)
                                .foregroundStyle(IOSTheme.accent)
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        } else {
                            HStack(spacing: 12) {
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(IOSTheme.secondaryText)
                                    .frame(width: 24)

                                Text("Target")
                                    .font(IOSTypography.bodyEmphasis)
                                    .foregroundStyle(IOSTheme.text)

                                Spacer(minLength: 8)

                                Picker("Workspace Target", selection: $selectedWorkspaceID) {
                                    ForEach(projectWorkspaces) { ws in
                                        Text(ws.name.isEmpty ? (ws.branch ?? ws.id) : ws.name)
                                            .tag(ws.id)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(IOSTheme.accent)
                                .accessibilityLabel("Workspace target")
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 10)
                        }
                    } else {
                        VStack(spacing: 0) {
                            Divider()
                                .background(IOSTheme.separator.opacity(0.35))
                                .padding(.leading, 50)

                            HStack(spacing: 12) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(IOSTheme.accent)
                                    .frame(width: 24)

                                TextField("Branch (e.g. main, feat-ui)", text: $newWorkspaceBranch)
                                    .font(IOSTypography.body)
                                    #if os(iOS)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    #endif
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 46)

                            Divider()
                                .background(IOSTheme.separator.opacity(0.35))
                                .padding(.leading, 50)

                            HStack(spacing: 12) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(IOSTheme.secondaryText)
                                    .frame(width: 24)

                                TextField("Workspace name (optional)", text: $newWorkspaceName)
                                    .font(IOSTypography.body)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 46)
                        }
                    }
                }
                .padding(.bottom, workspaceMode == .existing && !projectWorkspaces.isEmpty ? 0 : (workspaceMode == .new ? 4 : 0))
            }
            .iosCardSurface()
        }
    }

    private var sessionTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSION TYPE")
                .font(IOSTypography.eyebrow)
                .foregroundStyle(IOSTheme.secondaryText)
                .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(IOSSessionCreationKind.allCases) { kind in
                        sessionKindCard(kind)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func sessionKindCard(_ kind: IOSSessionCreationKind) -> some View {
        let isSelected = selectedKind == kind
        Button {
            IOSHaptics.selection()
            withAnimation(IOSMotion.quick) {
                selectedKind = kind
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? IOSTheme.accent.opacity(0.18) : IOSTheme.muted.opacity(0.35))
                        .frame(width: 44, height: 44)

                    IOSPresetIcon(presetID: kind.rawValue, size: 24)
                }

                Text(kind.displayName)
                    .font(isSelected ? IOSTypography.bodyEmphasis : IOSTypography.secondaryBody)
                    .foregroundStyle(isSelected ? IOSTheme.text : IOSTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(width: 82, height: 86)
            .background(
                isSelected ? IOSTheme.accent.opacity(0.10) : IOSTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? IOSTheme.accent : IOSTheme.cardBorder,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONFIGURATION")
                .font(IOSTypography.eyebrow)
                .foregroundStyle(IOSTheme.secondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 24)

                    TextField("Session title (optional)", text: $sessionTitle)
                        .font(IOSTypography.body)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)

                Divider()
                    .background(IOSTheme.separator.opacity(0.35))
                    .padding(.leading, 50)

                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 24)

                    TextField(commandPlaceholder, text: $command)
                        .font(IOSTypography.code)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
            }
            .iosCardSurface()
        }
    }

    private var submitButton: some View {
        Button {
            IOSHaptics.light()
            submit()
        } label: {
            HStack(spacing: 8) {
                if model.isMutating || didSubmit {
                    ProgressView()
                        .tint(IOSTheme.background)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                }
                Text(submitButtonText)
                    .font(IOSTypography.bodyEmphasis)
            }
            .foregroundStyle(IOSTheme.background)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                canSubmit ? IOSTheme.accent : IOSTheme.accent.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .padding(.top, 4)
    }

    private var canSubmit: Bool {
        guard !didSubmit, !model.isMutating else { return false }
        if isDestinationSelectable {
            if workspaceMode == .new {
                return !selectedProjectID.isEmpty && !newWorkspaceBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } else {
                return !selectedWorkspaceID.isEmpty
            }
        }
        return true
    }

    private var submitButtonText: String {
        if model.isMutating || didSubmit { return "Creating…" }
        if isDestinationSelectable && workspaceMode == .new {
            return "Create workspace & session"
        }
        return "Create session"
    }

    private func submit() {
        guard canSubmit else { return }
        didSubmit = true
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : command
        let trimmedTitle = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sessionTitle

        if isDestinationSelectable {
            if workspaceMode == .new {
                let branch = newWorkspaceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newWorkspaceName
                model.createWorkspaceAndSession(
                    projectID: selectedProjectID,
                    branch: branch,
                    workspaceName: name,
                    command: trimmedCmd,
                    kind: selectedKind.rawValue,
                    title: trimmedTitle
                )
            } else {
                model.createSession(
                    workspaceID: selectedWorkspaceID,
                    terminalGroupID: nil,
                    command: trimmedCmd,
                    kind: selectedKind.rawValue,
                    title: trimmedTitle
                )
            }
        } else {
            model.createSession(
                workspaceID: workspaceID,
                terminalGroupID: terminalGroupID,
                command: trimmedCmd,
                kind: selectedKind.rawValue,
                title: trimmedTitle
            )
        }
        model.localStore.lastSessionKind = selectedKind.rawValue
    }

    private var commandPlaceholder: String {
        selectedKind == .shell
            ? "Command (optional; Host shell default)"
            : "Command (optional; \(selectedKind.displayName) default)"
    }
}

private struct IOSWorkspaceManagementSheet: View {
    @ObservedObject var model: IOSApplicationModel
    let projectID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var renameWorkspaceID: String?
    @State private var renameName = ""
    @State private var deleteWorkspaceID: String?
    @State private var renamePending = false
    @State private var deletePending = false
    @State private var actionFeedback: String?
    @State private var actionFeedbackGeneration = 0

    private var workspaces: [WarrenRemoteRoster.Workspace] {
        (model.roster?.workspaces ?? [])
            .filter { projectID == nil || $0.projectID == projectID }
            .sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var projectTitle: String? {
        guard let projectID else { return nil }
        return model.roster?.projects.first(where: { $0.id == projectID }).map {
            $0.name.isEmpty ? pathLeaf($0.path) : $0.name
        }
    }

    private var headingTitle: String {
        if let projectTitle, !projectTitle.isEmpty { return "Workspaces · \(projectTitle)" }
        return "Workspaces"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        IOSScreenHeading(title: headingTitle, symbol: "folder")
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
                            let sessions = model.sessions(inWorkspace: workspace.id)
                            HStack(spacing: 10) {
                                WorkspaceGlyph(
                                    workspace: workspace,
                                    agentStatus: highestAgentStatus(
                                        sessions: model.sessions(inWorkspace: workspace.id),
                                        statuses: model.agentStatusBySessionID
                                    )
                                )
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 5) {
                                        Text(workspace.name.isEmpty ? pathLeaf(workspace.path) : workspace.name)
                                            .font(IOSTypography.rowTitle)
                                            .foregroundStyle(IOSTheme.text)
                                            .lineLimit(2)
                                            .iosNaturalWrap()
                                            .layoutPriority(1)
                                        if !sessions.isEmpty {
                                            Text("\(sessions.count)")
                                                .font(IOSTypography.metric)
                                                .foregroundStyle(IOSTheme.tertiaryText)
                                                .accessibilityLabel("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                                        }
                                    }
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
                                        .frame(width: 44, height: 44)
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
        .overlay(alignment: .top) {
            if let actionFeedback {
                Text(actionFeedback)
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(IOSTheme.chrome, in: Capsule())
                    .overlay(Capsule().stroke(IOSTheme.separator, lineWidth: 1))
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $showingCreate) {
            IOSWorkspaceCreationSheet(model: model, initialProjectID: projectID)
                .iosSheetPresentation(.medium, .large)
        }
        .alert("Rename workspace", isPresented: Binding(
            get: { renameWorkspaceID != nil },
            // SwiftUI dismisses the alert immediately after Save. Keep the
            // mutation guard independent from presentation state so the
            // dismissed alert cannot be re-presented while the Host responds.
            set: { if !$0 { renameWorkspaceID = nil } }
        )) {
            TextField("Workspace name", text: $renameName)
            Button(renamePending ? "Saving…" : "Save") {
                guard !renamePending, !model.isMutating,
                      !renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let id = renameWorkspaceID else { return }
                renamePending = true
                showActionFeedback("Saving…", duration: 0)
                model.renameWorkspace(id, name: renameName)
            }
            .disabled(
                renamePending
                    || model.isMutating
                    || renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            Button("Cancel", role: .cancel) {
                guard !renamePending else { return }
                renameWorkspaceID = nil
            }
            .disabled(renamePending)
        }
        .confirmationDialog(
            "Delete workspace?",
            isPresented: Binding(
                get: { deleteWorkspaceID != nil },
                // The confirmation dialog is dismissed before the delete
                // response arrives; pending state still disables duplicate
                // actions without pinning the dialog on screen.
                set: { if !$0 { deleteWorkspaceID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletePending ? "Deleting…" : "Delete Workspace", role: .destructive) {
                guard !deletePending, !model.isMutating,
                      let id = deleteWorkspaceID else { return }
                deletePending = true
                showActionFeedback("Deleting…", duration: 0)
                model.deleteWorkspace(id)
            }
            .disabled(deletePending || model.isMutating)
            Button("Cancel", role: .cancel) {
                guard !deletePending else { return }
                deleteWorkspaceID = nil
            }
            .disabled(deletePending)
        } message: {
            Text("Running sessions must be deleted before the workspace can be removed.")
        }
        .onChange(of: model.isMutating) { wasMutating, isMutating in
            guard wasMutating, !isMutating else { return }
            if renamePending {
                renamePending = false
                renameWorkspaceID = nil
                showActionFeedback(model.mutationError == nil ? "Workspace renamed" : "Workspace rename failed")
            }
            if deletePending {
                deletePending = false
                deleteWorkspaceID = nil
                showActionFeedback(model.mutationError == nil ? "Workspace deleted" : "Workspace delete failed")
            }
        }
    }

    private func showActionFeedback(_ message: String, duration: TimeInterval = 1.6) {
        actionFeedbackGeneration &+= 1
        let generation = actionFeedbackGeneration
        actionFeedback = message
        guard duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if actionFeedbackGeneration == generation { actionFeedback = nil }
        }
    }
}

private struct IOSWorkspaceCreationSheet: View {
    @ObservedObject var model: IOSApplicationModel
    private let initialProjectID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var projectID = ""
    @State private var branch = ""
    @State private var name = ""
    @State private var path = ""
    @State private var didSubmit = false

    init(model: IOSApplicationModel, initialProjectID: String? = nil) {
        self.model = model
        self.initialProjectID = initialProjectID
        _projectID = State(initialValue: initialProjectID ?? "")
    }

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
                            guard !didSubmit, !model.isMutating else { return }
                            didSubmit = true
                            model.createWorkspace(
                                projectID: projectID,
                                branch: branch,
                                name: name.isEmpty ? nil : name,
                                path: path.isEmpty ? nil : path
                            )
                        } label: {
                            Text(model.isMutating || didSubmit ? "Creating…" : "Create workspace")
                                .font(IOSTypography.button)
                                .foregroundStyle(IOSTheme.background)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(IOSTheme.accent, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(projectID.isEmpty || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isMutating || didSubmit)
                        .opacity(projectID.isEmpty || branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isMutating || didSubmit ? 0.45 : 1)
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
            if projectID.isEmpty { projectID = initialProjectID ?? projects.first?.id ?? "" }
        }
        .onChange(of: model.isMutating) { wasMutating, isMutating in
            guard didSubmit, wasMutating, !isMutating else { return }
            if model.mutationError == nil {
                dismiss()
            } else {
                didSubmit = false
            }
        }
    }
}

/// Lists the Hosts saved on this device. Each row is independently selectable
/// and editable; credentials stay in the Keychain behind the model.
public struct IOSEndpointConfigurationView: View {
    @ObservedObject private var model: IOSApplicationModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingRelayScanner = false

    public init(model: IOSApplicationModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            IOSBackHeader(
                title: "Hosts",
                subtitle: "Connections"
            ) {
                dismiss()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    IOSSectionLabel("Hosts", count: hosts.isEmpty ? nil : hosts.count)
                        .padding(.top, 22)
                        .padding(.bottom, 8)

                    if hosts.isEmpty {
                        IOSEmptyState(
                            symbol: "server.rack",
                            title: "No saved Hosts",
                            message: "Add a Warren Host to connect from this device."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(hosts.enumerated()), id: \.element.name) { index, host in
                                let isCurrent = host.name == model.endpointMetadata.name
                                if index > 0 {
                                    Rectangle()
                                        .fill(IOSTheme.separator.opacity(0.35))
                                        .frame(height: 0.5)
                                        .padding(.leading, 48)
                                }
                                HStack(spacing: 0) {
                                    if isCurrent {
                                        NavigationLink {
                                            IOSEndpointDetailView(model: model, endpoint: host)
                                        } label: {
                                            hostRowContent(host: host, isCurrent: true)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Current Host, \(host.name)")
                                    } else {
                                        Button {
                                            IOSHaptics.selection()
                                            model.selectEndpoint(named: host.name)
                                        } label: {
                                            hostRowContent(host: host, isCurrent: false)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Switch to Host \(host.name)")
                                    }

                                    NavigationLink {
                                        IOSEndpointDetailView(model: model, endpoint: host)
                                    } label: {
                                        Image(systemName: "chevron.forward")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(IOSTheme.tertiaryText)
                                            .frame(width: 44, height: 60)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Details for \(host.name)")
                                }
                            }
                        }
                        .iosCardSurface()
                    }

                    IOSSectionLabel("Add a Host")
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        Button {
                            showingRelayScanner = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "qrcode.viewfinder")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(IOSTheme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Scan Relay QR")
                                        .font(IOSTypography.bodyEmphasis)
                                        .foregroundStyle(IOSTheme.text)
                                    Text("Pair from a shareable link or QR code")
                                        .font(IOSTypography.metadata)
                                        .foregroundStyle(IOSTheme.secondaryText)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IOSTheme.tertiaryText)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Scan Relay QR to add a Host")
                        .disabled(model.isPairingRelay)

                        Rectangle()
                            .fill(IOSTheme.separator.opacity(0.35))
                            .frame(height: 0.5)
                            .padding(.leading, 50)

                        NavigationLink {
                            IOSEndpointEditorView(model: model, endpoint: nil)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "server.rack")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(IOSTheme.accent)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add direct Host")
                                        .font(IOSTypography.bodyEmphasis)
                                        .foregroundStyle(IOSTheme.text)
                                    Text("Connect with a local or remote URL")
                                        .font(IOSTypography.metadata)
                                        .foregroundStyle(IOSTheme.secondaryText)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.forward")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(IOSTheme.tertiaryText)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add a direct Host")
                    }
                    .iosCardSurface()

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
        .sheet(isPresented: $showingRelayScanner) {
            IOSRelayPairingScannerView(
                onCode: { code in
                    showingRelayScanner = false
                    model.pairRelay(from: code)
                },
                onPaste: {
                    showingRelayScanner = false
                    #if canImport(UIKit)
                    model.pairRelayLink(UIPasteboard.general.string ?? "")
                    #else
                    model.pairRelayLink("")
                    #endif
                },
                onCancel: { showingRelayScanner = false }
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func hostRowContent(host: IOSEndpointMetadata, isCurrent: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: host.isRelay ? "point.3.connected.trianglepath.dotted" : "server.rack")
                .font(.system(size: 16, weight: isCurrent ? .medium : .regular))
                .foregroundStyle(isCurrent ? IOSTheme.accent : IOSTheme.secondaryText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(host.name)
                        .font(isCurrent ? IOSTypography.bodyEmphasis : IOSTypography.body)
                        .foregroundStyle(IOSTheme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isCurrent {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IOSTheme.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(IOSTheme.green.opacity(0.12), in: Capsule())
                    }

                    if host.hasToken {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                }

                if isCurrent {
                    HStack(spacing: 5) {
                        IOSStatusDot(color: connectionColor, size: 5)
                        Text(IOSCopy.connectionTitle(for: model.connectionState))
                            .font(IOSTypography.metadata)
                            .foregroundStyle(connectionColor)
                        Text("·")
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Text(host.isRelay ? "Relay" : host.url)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text(host.isRelay ? "Relay" : host.url)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var hosts: [IOSEndpointMetadata] {
        let values = model.endpointMetadataList
        return values.sorted { lhs, rhs in
            let lhsCurrent = lhs.name == model.endpointMetadata.name
            let rhsCurrent = rhs.name == model.endpointMetadata.name
            if lhsCurrent != rhsCurrent { return lhsCurrent }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
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
                actions: AnyView(
                    NavigationLink {
                        IOSEndpointEditorView(model: model, endpoint: endpoint)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(IOSTheme.secondaryText)
                            .frame(width: 44, height: 44)
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
                    VStack(spacing: 0) {
                        if endpoint.isRelay {
                            endpointDetailRow("Type", value: "Relay")
                            Rectangle()
                                .fill(IOSTheme.separator.opacity(0.35))
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                            endpointDetailRow(
                                "Access",
                                value: endpoint.hasToken ? "Saved in Keychain" : "Needs pairing"
                            )
                        } else {
                            endpointDetailRow("Address", value: endpoint.url, machineText: true)
                            Rectangle()
                                .fill(IOSTheme.separator.opacity(0.35))
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                            endpointDetailRow("Type", value: "Direct Host")
                            Rectangle()
                                .fill(IOSTheme.separator.opacity(0.35))
                                .frame(height: 0.5)
                                .padding(.leading, 14)
                            endpointDetailRow(
                                "Token",
                                value: endpoint.hasToken ? "Saved in Keychain" : "Not saved"
                            )
                        }
                    }
                    .iosCardSurface()

                    Button {
                        model.selectEndpoint(named: endpoint.name)
                    } label: {
                        Text(isActive ? "Current Host" : "Use this Host")
                            .font(IOSTypography.button)
                            .foregroundStyle(isActive ? IOSTheme.secondaryText : IOSTheme.background)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                isActive ? IOSTheme.muted : IOSTheme.accent,
                                in: RoundedRectangle(cornerRadius: IOSTheme.cardRadius, style: .continuous)
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
                        ? "Relay routes this Host through the configured control-plane connection."
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
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, token }

    var body: some View {
        VStack(spacing: 0) {
            IOSBackHeader(
                title: endpoint == nil ? "Add Host" : "Edit Host",
                subtitle: "Connection"
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
                    VStack(spacing: 0) {
                        endpointField("Name", placeholder: "Warren Host", text: $name, field: .name)
                        Rectangle()
                            .fill(IOSTheme.separator.opacity(0.35))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                        endpointField("URL", placeholder: IOSDevelopmentEndpoint.url, text: $url, field: .url)
                        Rectangle()
                            .fill(IOSTheme.separator.opacity(0.35))
                            .frame(height: 0.5)
                            .padding(.leading, 14)
                        endpointSecureField("Token", placeholder: "Host token", text: $token, field: .token)
                    }
                    .iosCardSurface()

                    Text(hasToken
                        ? "Token saved in Keychain. Leave it blank to keep it."
                        : "No token saved on this device.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .padding(.top, 10)

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
                            .background(IOSTheme.accent, in: RoundedRectangle(cornerRadius: IOSTheme.cardRadius, style: .continuous))
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
                        ? "Relay routes this Host through the configured control-plane connection."
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
