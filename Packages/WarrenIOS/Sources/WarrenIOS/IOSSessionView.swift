import SwiftUI
import WarrenTransport

#if canImport(UIKit)
import UIKit
#endif

/// A focused workspace surface, modelled after Warren Web/Paseo's mobile
/// shell: compact chrome, a single context line, and a full-bleed body.
public struct SessionView: View {
    @ObservedObject private var model: IOSApplicationModel
    @ObservedObject private var terminalState: IOSTerminalState
    private let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var showingSessionSwitcher = false
    @State private var showingDeleteConfirmation = false
    @State private var showingNewSession = false
    /// Keep a very small renderer cache for quick back-and-forth terminal
    /// switching. Agent is the primary surface, so this is intentionally
    /// bounded: the model owns durable snapshots/output, while SwiftTerm
    /// instances are retained only for the current and two recent Sessions.
    @State private var terminalSurfaceCache: [String] = []

    private let terminalSurfaceCacheLimit = 3

    public init(model: IOSApplicationModel, sessionID: String) {
        self.model = model
        self._terminalState = ObservedObject(wrappedValue: model.terminalState)
        self.sessionID = sessionID
    }

    public var body: some View {
        let activeSessionID = model.currentSessionID ?? sessionID
        let session = model.activeSessions.first(where: { $0.id == activeSessionID })
        let siblings = sessionsInCurrentScope(for: activeSessionID)
        let terminalSessionPool = terminalSessions(
            activeSessionID: activeSessionID,
            currentSession: session,
            siblings: siblings
        )
        let terminalSurfaceIDs = cachedTerminalSurfaceIDs(
            activeSessionID: activeSessionID,
            sessions: terminalSessionPool,
            includeActive: model.displayMode == .terminal
        )

        VStack(spacing: 0) {
            SessionHeader(
                model: model,
                session: session,
                hasSiblings: siblings.count > 1,
                openSwitcher: { showingSessionSwitcher = true },
                openNewSession: { showingNewSession = true },
                deleteSession: { showingDeleteConfirmation = true },
                onBack: {
                    model.leaveSession(activeSessionID)
                    dismiss()
                }
            )
            if siblings.count > 1 {
                SessionTabRail(
                    model: model,
                    agentState: model.agentState,
                    activeSessionID: activeSessionID,
                    sessions: siblings,
                    showSwitcher: { showingSessionSwitcher = true }
                )
            }

            ZStack {
                // Agent is the primary mobile surface. Terminal renderers
                // stay mounted only for a small LRU set, so switching back to
                // a recently viewed shell reveals its cached grid immediately
                // while the new subscription finishes in the background.
                ForEach(terminalSurfaceIDs, id: \.self) { cachedSessionID in
                    if let cachedSession = terminalSessionPool.first(where: { $0.id == cachedSessionID }) {
                        let isActive = cachedSession.id == activeSessionID
                        SwiftTermTerminalSurface(
                            snapshot: terminalState.terminalSnapshotBySessionID[cachedSession.id] ?? Data(),
                            output: terminalState.terminalOutputBySessionID[cachedSession.id] ?? Data(),
                            outputRevision: terminalState.terminalOutputRevisionBySessionID[cachedSession.id] ?? 0,
                            isReady: terminalState.terminalReadyBySessionID[cachedSession.id] ?? false,
                            onInput: { model.sendTerminalInput($0) },
                            onTap: { model.focusTerminal() },
                            onResize: {
                                model.updateTerminalSize($0, for: cachedSession.id)
                                model.resizeTerminal($0)
                            }
                        )
                        .opacity(isActive && model.displayMode == .terminal ? 1 : 0)
                        .allowsHitTesting(isActive && model.displayMode == .terminal)
                        .accessibilityHidden(!isActive)
                    }
                }

                AgentChatView(model: model, sessionID: activeSessionID)
                    .opacity(model.displayMode == .agent ? 1 : 0)
                    .allowsHitTesting(model.displayMode == .agent)
            }
            .background(IOSTheme.background)
            .animation(.easeInOut(duration: 0.22), value: model.displayMode)
        }
        .background(IOSTheme.background.ignoresSafeArea())
        #if os(iOS) || os(visionOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.displayMode == .terminal {
                TerminalShortcutBar(model: model)
            }
        }
        .onAppear {
            if model.displayMode == .terminal {
                rememberTerminalSurface(sessionID)
            }
            model.selectSession(sessionID)
            // Terminal is an interactive surface, so entering it claims the
            // lease once the Host has registered the subscription. The focus
            // request is remote-only and does not present the keyboard.
            if model.displayMode == .terminal {
                Task { @MainActor in
                    await Task.yield()
                    model.focusTerminal()
                }
            }
        }
        .onChange(of: model.currentSessionID) { _, selectedSessionID in
            guard let selectedSessionID else { return }
            if model.displayMode == .terminal {
                rememberTerminalSurface(selectedSessionID)
                Task { @MainActor in
                    await Task.yield()
                    model.focusTerminal()
                }
            }
        }
        .onChange(of: model.displayMode) { _, mode in
            guard mode == .terminal else { return }
            rememberTerminalSurface(model.currentSessionID ?? sessionID)
            // Promote the remote control lease once per mode switch. The
            // request carries the last measured viewport, but never touches
            // SwiftTerm's first responder, so switching to Terminal cannot
            // unexpectedly present the system keyboard.
            Task { @MainActor in
                await Task.yield()
                model.focusTerminal()
            }
        }
        .onDisappear { model.leaveSession(model.currentSessionID ?? sessionID) }
        .sheet(isPresented: $showingNewSession) {
            IOSSessionCreationSheet(
                model: model,
                workspaceID: session?.workspaceID,
                terminalGroupID: session?.terminalGroupID,
                title: sessionTitle(for: session)
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingSessionSwitcher) {
            SessionSwitcherSheet(model: model, agentState: model.agentState, sessions: siblings)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete this session?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                model.deleteSession(activeSessionID)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Host process and its transcript will be removed.")
        }
    }

    private func sessionsInCurrentScope(for activeSessionID: String) -> [WarrenRemoteRoster.Session] {
        guard let session = model.activeSessions.first(where: { $0.id == activeSessionID }) else { return [] }
        if let workspaceID = session.workspaceID { return model.sessions(inWorkspace: workspaceID) }
        if let groupID = session.terminalGroupID { return model.sessions(inTerminalGroup: groupID) }
        return [session]
    }

    private func terminalSessions(
        activeSessionID: String,
        currentSession: WarrenRemoteRoster.Session?,
        siblings: [WarrenRemoteRoster.Session]
    ) -> [WarrenRemoteRoster.Session] {
        guard !siblings.isEmpty else {
            return currentSession.map { [$0] } ?? []
        }
        guard !siblings.contains(where: { $0.id == activeSessionID }),
              let currentSession else { return siblings }
        return siblings + [currentSession]
    }

    private func cachedTerminalSurfaceIDs(
        activeSessionID: String,
        sessions: [WarrenRemoteRoster.Session],
        includeActive: Bool
    ) -> [String] {
        let available = Set(sessions.map(\.id))
        var ids = terminalSurfaceCache.filter { available.contains($0) }
        if includeActive,
           !ids.contains(activeSessionID),
           available.contains(activeSessionID) {
            ids.insert(activeSessionID, at: 0)
        }
        return Array(ids.prefix(terminalSurfaceCacheLimit))
    }

    private func rememberTerminalSurface(_ sessionID: String) {
        guard !sessionID.isEmpty else { return }
        terminalSurfaceCache.removeAll { $0 == sessionID }
        terminalSurfaceCache.insert(sessionID, at: 0)
        if terminalSurfaceCache.count > terminalSurfaceCacheLimit {
            terminalSurfaceCache.removeLast(terminalSurfaceCache.count - terminalSurfaceCacheLimit)
        }
    }

    private func sessionTitle(for session: WarrenRemoteRoster.Session?) -> String {
        guard let session else { return "Session" }
        if !session.displayTitle.isEmpty { return session.displayTitle }
        if let process = session.process, !process.isEmpty { return process }
        return session.kind.capitalized
    }
}

private struct SessionHeader: View {
    @ObservedObject var model: IOSApplicationModel
    let session: WarrenRemoteRoster.Session?
    let hasSiblings: Bool
    let openSwitcher: () -> Void
    let openNewSession: () -> Void
    let deleteSession: () -> Void
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            IOSIconButton("line.3.horizontal", label: "Open sessions", action: onBack)
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionTitle)
                    .font(IOSTypography.sessionBarTitle)
                    .foregroundStyle(IOSTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .iosMachineText()
                    .layoutPriority(1)
                HStack(spacing: 5) {
                    IOSStatusDot(color: connectionColor, size: 6)
                    Text(connectionTitle)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                    if let scopeTitle {
                        Text("·")
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Text(scopeTitle)
                            .font(IOSTypography.status)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .iosMachineText()
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IOSModeToggle(selection: Binding(
                get: { model.displayMode },
                set: { model.setDisplayMode($0) }
            ))
            Menu {
                if hasSiblings {
                    Button("Switch session", systemImage: "rectangle.stack") { openSwitcher() }
                }
                Button("New session", systemImage: "plus") {
                    openNewSession()
                }
                Button("Delete session", role: .destructive) {
                    deleteSession()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 42, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.automatic)
            .accessibilityLabel("Session actions")
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 56)
        .background(IOSTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
    }

    private var sessionTitle: String {
        if let title = session?.displayTitle, !title.isEmpty { return title }
        if let process = session?.process, !process.isEmpty { return process }
        return "Session"
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

    private var scopeTitle: String? {
        guard let session else { return nil }
        if let workspaceID = session.workspaceID,
           let workspace = model.roster?.workspaces.first(where: { $0.id == workspaceID }) {
            if let branch = workspace.branch?.trimmingCharacters(in: .whitespacesAndNewlines),
               !branch.isEmpty {
                return branch
            }
            if !workspace.name.isEmpty { return workspace.name }
            let leaf = pathLeaf(workspace.path)
            return leaf.isEmpty ? nil : leaf
        }
        if let groupID = session.terminalGroupID,
           let group = model.roster?.terminalGroups.first(where: { $0.id == groupID }) {
            return group.name
        }
        return nil
    }
}

/// Provider marks are intentionally shared by the pane bar and switcher. A
/// shell remains a branch/workspace resource; only an Agent-backed
/// Session gets an AI provider mark. A shell that Warren later binds to an
/// Agent can still resolve its provider from the newest normalized event.
private func sessionProviderID(
    for session: WarrenRemoteRoster.Session,
    events: [WarrenRemoteAgentEvent]? = nil
) -> String {
    let kind = session.kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let provider = (kind == "shell" || kind == "custom")
        ? events?.reversed().compactMap { event -> String? in
            let value = event.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return value.isEmpty ? nil : value
        }.first ?? kind
        : kind
    switch provider {
    case "claude", "claude-code": return "claude"
    case "codex": return "codex"
    case "opencode", "open-code": return "opencode"
    default: return "shell"
    }
}

private struct SessionProviderMark: View {
    @ObservedObject var model: IOSApplicationModel
    @ObservedObject var agentState: IOSAgentLiveState
    let session: WarrenRemoteRoster.Session
    let slotSize: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            IOSPresetIcon(
                presetID: sessionProviderID(
                    for: session,
                    events: agentState.agentEventsBySessionID[session.id]
                ),
                size: min(18, slotSize * 0.78)
            )
            .frame(width: slotSize, height: slotSize)

            if let status = model.agentStatusBySessionID[session.id] ?? session.agentStatus,
               session.isAgentBacked {
                // Keep the provider mark as the primary glyph while reusing
                // the same pulse used by workspace/session activity rows.
                // Scaling the marker down makes the animation legible without
                // competing with the provider silhouette on a narrow rail.
                IOSAgentActivityMark(
                    activity: status.activity,
                    attention: status.attention,
                    slotSize: 12
                )
                .scaleEffect(0.58)
                .offset(x: 1, y: 1)
                .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch sessionProviderID(
            for: session,
            events: agentState.agentEventsBySessionID[session.id]
        ) {
        case "claude": return "Claude session"
        case "codex": return "Codex session"
        case "opencode": return "OpenCode session"
        default: return "Shell session"
        }
    }
}

private struct SessionTabRail: View {
    @ObservedObject var model: IOSApplicationModel
    @ObservedObject var agentState: IOSAgentLiveState
    let activeSessionID: String
    let sessions: [WarrenRemoteRoster.Session]
    let showSwitcher: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if sessions.count <= 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(sessions) { session in
                            Button {
                                model.selectSession(session.id)
                            } label: {
                                HStack(spacing: 6) {
                                    SessionProviderMark(model: model, agentState: agentState, session: session, slotSize: 20)
                                    Text(session.displayTitle.isEmpty ? "Untitled" : session.displayTitle)
                                        .font(IOSTypography.label)
                                        .foregroundStyle(session.id == activeSessionID ? IOSTheme.text : IOSTheme.secondaryText)
                                        // Tabs are a deliberate compact contract;
                                        // the switcher sheet exposes the full
                                        // title when it cannot fit here.
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .padding(.horizontal, 12)
                                .frame(minHeight: 38)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(session.id == activeSessionID ? IOSTheme.accent : .clear)
                                        .frame(height: 2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Session \(session.displayTitle)")
                            .accessibilityAddTraits(session.id == activeSessionID ? .isSelected : [])
                        }
                    }
                }
            } else {
                Button(action: showSwitcher) {
                    HStack(spacing: 7) {
                        Image(systemName: "rectangle.stack")
                        Text("\(sessions.count)")
                            .font(IOSTypography.metric)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(IOSTypography.label)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 13)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .background(IOSTheme.raised, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous)
                            .stroke(IOSTheme.ring.opacity(0.8), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .accessibilityLabel("Switch session")
                .accessibilityValue("\(sessions.count) sessions")
            }
        }
        .background(IOSTheme.chrome)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
    }
}

private struct SessionSwitcherSheet: View {
    @ObservedObject var model: IOSApplicationModel
    @ObservedObject var agentState: IOSAgentLiveState
    let sessions: [WarrenRemoteRoster.Session]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("Sessions")
                        .font(IOSTypography.pageTitle)
                        .foregroundStyle(IOSTheme.text)
                        .padding(.horizontal, 16)
                        .padding(.top, 22)
                        .padding(.bottom, 12)
                    ForEach(sessions) { session in
                        Button {
                            model.selectSession(session.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                SessionProviderMark(model: model, agentState: agentState, session: session, slotSize: 23)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.displayTitle.isEmpty ? "Untitled session" : session.displayTitle)
                                        .font(model.currentSessionID == session.id ? IOSTypography.bodyEmphasis : IOSTypography.body)
                                        .foregroundStyle(IOSTheme.text)
                                        .lineLimit(2)
                                        .iosNaturalWrap()
                                        .layoutPriority(1)
                                    Text(session.process ?? session.kind.capitalized)
                                        .font(IOSTypography.metadata)
                                        .foregroundStyle(IOSTheme.secondaryText)
                                }
                                Spacer(minLength: 8)
                                if model.currentSessionID == session.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(IOSTheme.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(IOSTheme.separator.opacity(0.54))
                                .frame(height: 1)
                                .padding(.leading, 34)
                        }
                    }
                }
            }
            .background(IOSTheme.background.ignoresSafeArea())
            .scrollIndicators(.hidden)
            #if os(iOS) || os(visionOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .preferredColorScheme(.dark)
    }
}

private struct TerminalShortcutBar: View {
    @ObservedObject var model: IOSApplicationModel
    @State private var showingControlKeys = false
    @State private var altArmed = false

    var body: some View {
        VStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    IOSKeyboardDismissButton {
                        model.dismissKeyboard()
                    }
                    shortcut("Esc", [0x1B])
                    shortcut("Tab", [0x09])
                    shortcut("Home", [0x1B, 0x5B, 0x48])
                    shortcut("End", [0x1B, 0x5B, 0x46])
                    shortcut("↑", [0x1B, 0x5B, 0x41])
                    shortcut("↓", [0x1B, 0x5B, 0x42])
                    shortcut("←", [0x1B, 0x5B, 0x44])
                    shortcut("→", [0x1B, 0x5B, 0x43])
                    IOSKeyCap(title: "Ctrl", isEnabled: model.hasControlLease, isSelected: showingControlKeys) {
                        showingControlKeys.toggle()
                    }
                    IOSKeyCap(title: "Alt", isEnabled: model.hasControlLease, isSelected: altArmed) {
                        altArmed.toggle()
                    }
                    #if canImport(UIKit)
                    IOSKeyCap(title: "Copy", symbol: "doc.on.doc", isEnabled: true) {
                        UIPasteboard.general.string = currentTerminalText
                    }
                    IOSKeyCap(title: "Paste", symbol: "doc.on.clipboard", isEnabled: model.hasControlLease) {
                        if let text = UIPasteboard.general.string {
                            sendShortcut(Data(text.utf8))
                        }
                    }
                    #endif
                }
                .padding(.horizontal, 8)
            }
            if showingControlKeys {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        controlKey("Ctrl-C", 0x03)
                        controlKey("Ctrl-D", 0x04)
                        controlKey("Ctrl-A", 0x01)
                        controlKey("Ctrl-E", 0x05)
                        controlKey("Ctrl-U", 0x15)
                        controlKey("Ctrl-K", 0x0B)
                        controlKey("Ctrl-L", 0x0C)
                    }
                .padding(.horizontal, 8)
            }
        }
        }
        .padding(.vertical, 5)
        .background(IOSTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func shortcut(_ title: String, _ bytes: [UInt8]) -> some View {
        IOSKeyCap(title: title, isEnabled: model.hasControlLease) {
            sendShortcut(Data(bytes))
        }
    }

    private func controlKey(_ title: String, _ byte: UInt8) -> some View {
        IOSKeyCap(title: title, isEnabled: model.hasControlLease) {
            sendShortcut(Data([byte]))
        }
    }

    private func sendShortcut(_ data: Data) {
        guard model.hasControlLease, !data.isEmpty else { return }
        var payload = Data()
        if altArmed { payload.append(0x1B) }
        payload.append(data)
        model.sendTerminalInput(payload)
        altArmed = false
    }

    private var currentTerminalText: String {
        guard let sessionID = model.currentSessionID else { return "" }
        let snapshot = model.terminalState.terminalSnapshotBySessionID[sessionID] ?? Data()
        let output = model.terminalState.terminalOutputBySessionID[sessionID] ?? Data()
        return String(decoding: snapshot + output, as: UTF8.self)
    }
}

private func pathLeaf(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
