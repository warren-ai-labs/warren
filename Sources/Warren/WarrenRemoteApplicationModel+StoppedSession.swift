import Foundation
import AppKit
import CryptoKit
import Network
import Combine
import Darwin
import UniformTypeIdentifiers
import GhosttyAdapter
import WarrenClientCore
import WarrenDesignSystem
import WarrenDesktop
import WarrenDomain
import WarrenProtocol
import WarrenClientCore
import WarrenTransport

extension WarrenRemoteApplicationModel {
    // MARK: Stopped Sessions

    /// Presents a stopped Session: no subscription, no control lease, no
    /// keyboard, and no resize. The pane shows what the Host kept of the last
    /// output and the single action that continues the Session.
    func presentStoppedSession(_ session: WarrenDesktopSession, activatingInput: Bool) {
        let sessionID = session.id
        // Give the keyboard up before the selection moves, so the blur reaches
        // the Session that actually held it.
        relinquishTerminalFocus()
        if activatingInput {
            surfaceManager.cancelPendingInputFocus()
        }
        cancelResizeRequests()
        inputRouter.discard(for: sessionID)
        attachedSessionID = nil
        focusedSessionID = nil
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        pendingFocusResizeSize = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        selectedSessionID = sessionID
        ensureStoppedSessionSurface(for: session)
        loadStoppedSessionHistory(sessionID)
        TerminalDiagnostics.log("present_stopped", [
            "session": sessionID.description,
            "reason": session.endReason?.rawValue ?? "unknown",
        ])
    }

    /// Mounts the read-only surface a stopped Session renders into. It is a real
    /// terminal surface because the Host's kept output is real terminal bytes:
    /// colors, cursor moves, and alternate screens all have to render the way
    /// they did when the program wrote them.
    func ensureStoppedSessionSurface(for session: WarrenDesktopSession) {
        if surfaceManager.surface(for: session.id) == nil {
            surfaceManager.insert(makeSurface(for: session, readOnly: true))
        }
        feedStoppedSessionHistory(session.id)
    }

    /// Feeds a stopped Session's kept output into its surface, once.
    func feedStoppedSessionHistory(_ sessionID: TerminalSessionID) {
        guard !stoppedSessionHistoryFed.contains(sessionID),
              let history = stoppedSessionHistory[sessionID],
              history.phase == .ready,
              !history.payload.isEmpty,
              surfaceManager.surface(for: sessionID) != nil else { return }
        stoppedSessionHistoryFed.insert(sessionID)
        surfaceManager.enqueueRawOutput(history.payload, for: sessionID)
        surfaceManager.requestPresent(sessionID)
    }

    /// Loads what the Host kept of a stopped Session's last output, or retries
    /// after a failed read.
    func loadStoppedSessionHistory(_ sessionID: TerminalSessionID) {
        guard let wire, stoppedSessionHistory[sessionID]?.isLoading != true else { return }
        stoppedSessionHistory[sessionID] = .loading
        Task { @MainActor [weak self] in
            do {
                let data = try await wire.request(
                    "session.history",
                    params: ["session": sessionID.description]
                )
                let payload = try JSONDecoder().decode(WarrenStoppedSessionHistoryPayload.self, from: data)
                guard let self, self.wire === wire else { return }
                let bytes = payload.payload.flatMap { Data(base64Encoded: $0) } ?? Data()
                self.stoppedSessionHistory[sessionID] = .ready(bytes)
                self.feedStoppedSessionHistory(sessionID)
            } catch {
                guard let self else { return }
                if Self.isTransportFailure(error as NSError) {
                    self.stoppedSessionHistory.removeValue(forKey: sessionID)
                    return
                }
                if self.wire === wire {
                    self.stoppedSessionHistory[sessionID] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Continues a stopped Agent Session's conversation in a new Session. The
    /// Host owns the resume command; this only names the Session to continue.
    func resumeStoppedSession(_ sessionID: TerminalSessionID) {
        guard let wire, beginStoppedResume(sessionID) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error = await self.performStoppedResume(sessionID, using: wire, selectsResult: true) {
                self.present(error)
            }
        }
    }

    /// The other stopped Sessions Resume All would continue from `sessionID`'s
    /// banner.
    func resumeAllTargets(besides sessionID: TerminalSessionID) -> [TerminalSessionID] {
        WarrenDesktopStoppedSessionRoster
            .resumeAllTargets(stoppedResumeCandidates, besides: sessionID.description)
            .compactMap(TerminalSessionID.init(uuidString:))
    }

    /// Resumes `sessionID` when it offers Resume, and every other stopped
    /// conversation with it.
    ///
    /// The Session on screen goes first and is selected, so the pane in front
    /// of the person comes back while the rest follow. The others resume one
    /// at a time in place and leave the selection alone; a failure stays on its
    /// own banner, and the batch reports once rather than once per Session.
    func resumeAllStoppedSessions(from sessionID: TerminalSessionID) {
        guard let wire else { return }
        let resumesCurrent = projection.session(id: sessionID)?.stoppedAction == .resume
            && beginStoppedResume(sessionID)
        let others = resumeAllTargets(besides: sessionID).filter(beginStoppedResume)
        guard resumesCurrent || !others.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [Error] = []
            if resumesCurrent,
               let error = await self.performStoppedResume(sessionID, using: wire, selectsResult: true) {
                failures.append(error)
            }
            for other in others {
                if let error = await self.performStoppedResume(other, using: wire, selectsResult: false) {
                    failures.append(error)
                }
            }
            if failures.count == 1 {
                self.present(failures[0])
            } else if failures.count > 1 {
                self.present(NSError(domain: "WarrenRemote", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(failures.count) Sessions could not be resumed.",
                ]))
            }
        }
    }

    /// Marks one stopped Session's resume as started, or refuses when it is not
    /// stopped or already starting.
    func beginStoppedResume(_ sessionID: TerminalSessionID) -> Bool {
        guard projection.session(id: sessionID)?.isStopped == true,
              stoppedSessionActionInFlight.insert(sessionID).inserted else { return false }
        stoppedSessionActionFailure.removeValue(forKey: sessionID)
        return true
    }

    /// Asks the Host to resume one stopped Session begun with
    /// `beginStoppedResume`, and answers the error a failure produced.
    func performStoppedResume(
        _ sessionID: TerminalSessionID,
        using wire: WarrenRemoteClient,
        selectsResult: Bool
    ) async -> Error? {
        defer { stoppedSessionActionInFlight.remove(sessionID) }
        do {
            let data = try await wire.request(
                "session.resume",
                params: ["session": sessionID.description]
            )
            let created = try JSONDecoder().decode(CreatedSession.self, from: data)
            guard self.wire === wire,
                  let createdID = TerminalSessionID(uuidString: created.id) else { return nil }
            try? await refreshRoster(using: wire)
            guard selectsResult else { return nil }
            publishNavigationIfChanged(
                WarrenDesktopNavigationReducer.reduce(
                    navigation,
                    action: .selectTab(Self.tabID(createdID)),
                    in: projection
                )
            )
            await presentSelectedSession(activatingInput: true)
            return nil
        } catch {
            if self.wire === wire {
                stoppedSessionActionFailure[sessionID] = error.localizedDescription
            }
            return error
        }
    }

    /// Starts the same shell or custom command again in the stopped Session's
    /// own workspace directory. The Host launches it as a new Session; nothing
    /// of the stopped one is replayed or re-run automatically.
    func restartStoppedSession(_ sessionID: TerminalSessionID) {
        // The in-flight guard belongs to `createSession`, which marks the
        // workspace before it starts and clears it when the launch finishes; the
        // stopped pane reads that mark for its busy state rather than keeping a
        // second one of its own.
        guard let session = projection.session(id: sessionID),
              session.isStopped,
              let workspaceID = session.workspaceID else { return }
        let launch = TerminalSessionLaunchRequest(
            kind: session.kind,
            command: session.runtimeProcess
        )
        createSession(workspaceID: workspaceID, request: launch)
    }

    func attachSelectedSession(
        preservingExistingSurface: Bool = false
    ) async {
        guard let tabID = navigation.selectedTabID,
              let sessionID = projection.tabs.first(where: { $0.id == tabID })?.sessionID,
              let session = projection.sessions.first(where: { $0.id == sessionID }),
              let wire else { return }

        // A tab can send the same selection more than once while SwiftUI is
        // reconciling the tab rail (and a roster update can schedule another
        // presentation at the same time). Do not start a second daemon attach
        // for the same session: the second request cancels the first attach
        // preparation, then its failure tears down the only mounted surface.
        guard attachingSessionID != sessionID else {
            TerminalDiagnostics.logVerbose("attach_deduplicated", [
                "session": sessionID.description,
            ])
            return
        }

        // Mount before awaiting the attach response. The daemon may legally
        // produce the first recovery snapshot immediately after it accepts the
        // attach request; feeding that snapshot into an already-created surface
        // prevents the initial prompt from disappearing in the network race.
        let existingSurface = surfaceManager.surface(for: sessionID)
        guard existingSurface == nil || selectedSessionID != sessionID || attachedSessionID != sessionID else {
            return
        }
        TerminalDiagnostics.log("attach_start", [
            "session": sessionID.description,
            "existing": existingSurface != nil ? "true" : "false",
        ])
        inputRouter.prepare(for: sessionID)
        if let previousSessionID = selectedSessionID, previousSessionID != sessionID {
            blur(sessionID: previousSessionID)
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            cancelResizeRequests()
        }
        attachGeneration &+= 1
        let generation = attachGeneration
        attachingSessionID = sessionID
        defer {
            if generation == attachGeneration, attachingSessionID == sessionID {
                attachingSessionID = nil
            }
        }
        attachedSessionID = nil
        focusedSessionID = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        let surface: GhosttySurface
        if let existingSurface {
            surface = existingSurface
            surface.onOpenURL = { [weak self] url, kind, workingDirectory in
                guard let self else { return false }
                return self.onOpenTerminalURL?(sessionID, url, kind, workingDirectory ?? session.workingDirectory) ?? false
            }
        } else {
            // Defensive fallback: the authoritative cleanup runs in
            // TerminalSurfaceManager.dispose, but never attach a brand-new
            // surface with an anchor from an older surface instance.
            outputAnchors.removeValue(forKey: sessionID)
            suppressFramedAnchorUpdates.remove(sessionID)
            surface = makeSurface(for: session)
            surfaceManager.insert(surface, recoveryGated: true)
        }
        selectedSessionID = sessionID
        // Keep a retained surface's last completed frame visible during a
        // transient reconnect. A cold attach still uses the neutral
        // placeholder gate so an empty native surface can never flash.
        surfaceManager.beginRecovery(
            for: sessionID,
            preservingDisplay: preservingExistingSurface
                && reconnectPreservedSessions.contains(sessionID)
        )

        // The roster can select a tab before SwiftUI has committed the
        // terminal host (notably after a daemon/app restart). Do not ask the
        // daemon for a checkpoint while the surface is still inactive, while
        // its native surface is missing, or while its grid is zero-sized. In
        // each of those states the only correct visible result is the neutral
        // placeholder; sending the snapshot request early is what used to
        // produce a permanent black pane until the user resized it.
        guard let size = await waitForSurfaceReady(
            sessionID,
            surface: surface,
            generation: generation
        ) else { return }
        TerminalDiagnostics.log("attach_size", [
            "session": sessionID.description,
            "size": "\(size.columns)x\(size.rows)",
        ])
        guard generation == attachGeneration,
              selectedSessionID == sessionID,
              surfaceManager.surface(for: sessionID) === surface else { return }
        do {
            initialRefreshPending = true
            // Only a view that is actually focused in the key window may
            // claim the shared runtime geometry before the checkpoint. A
            // background endpoint still receives an atomic state, but its
            // measured size is intentionally not allowed to trigger SIGWINCH
            // in another client's TUI.
            let claimControl = surfaceManager.ownsTerminalFocus(sessionID)
            try await seedSessionSubscription(
                using: wire,
                sessionID: sessionID,
                size: claimControl ? size : nil,
                claimControl: claimControl
            )
            guard generation == attachGeneration,
                  selectedSessionID == sessionID,
                  self.wire === wire else { return }
            noteOutputSubscriptionAdded(sessionID, reason: "attachSelectedSession")
            attachedSessionID = sessionID
            TerminalDiagnostics.log("attach_complete", [
                "session": sessionID.description,
            ])
            inputRouter.activate(for: sessionID) { [wire] data in
                try? await wire.sendInput(sessionID: sessionID.description, payload: data)
            }
            if pendingFocusSessionID == sessionID {
                let pendingSize = pendingFocusSize ?? size
                pendingFocusSessionID = nil
                pendingFocusSize = nil
                sendFocus(
                    sessionID: sessionID,
                    focused: true,
                    size: pendingSize,
                    reason: "attach"
                )
            }
        } catch {
            if generation == attachGeneration, selectedSessionID == sessionID {
                if preservingExistingSurface, Self.isTransportFailure(error as NSError) {
                    selectedSessionID = nil
                    attachedSessionID = nil
                    focusedSessionID = nil
                    inputRouter.discard(for: sessionID)
                    noteOutputSubscriptionDropped(
                        sessionID,
                        reason: "attachTransportFailure"
                    )
                    surfaceManager.cancelRecovery(
                        for: sessionID,
                        preservingDisplay: true
                    )
                    pendingRetainedSurfaceRebinds.insert(sessionID)
                    TerminalDiagnostics.log("reconnect_surface_rebind_deferred", [
                        "session": sessionID.description,
                        "error": error.localizedDescription,
                    ])
                    return
                }
                TerminalDiagnostics.log("attach_failed", [
                    "session": sessionID.description,
                    "error": String(describing: error),
                    "generation": String(generation),
                ])
                selectedSessionID = nil
                attachedSessionID = nil
                focusedSessionID = nil
                inputRouter.discard(for: sessionID)
                surfaceManager.endRecovery(for: sessionID)
                removeMountedSurface(sessionID: sessionID)
                // Only a failure for the currently selected session belongs in
                // the notice center. A stale attach can be cancelled by a
                // rapid close of the very tab it was connecting; reporting
                // that would create noise during normal tab churn.
                present(error)
            }
        }
    }

    func waitForSurfaceReady(
        _ sessionID: TerminalSessionID,
        surface: GhosttySurface,
        generation: UInt64
    ) async -> TerminalSize? {
        var loggedWaiting = false
        while true {
            guard generation == attachGeneration else { return nil }
            guard selectedSessionID == sessionID,
                  surfaceManager.surface(for: sessionID) === surface else { return nil }
            _ = surfaceManager.prepareForRecovery(sessionID)
            guard surfaceManager.isReadyForRecovery(sessionID) else {
                if !loggedWaiting {
                    loggedWaiting = true
                    TerminalDiagnostics.log("attach_waiting_for_surface", [
                        "session": sessionID.description,
                        "surface": surface.terminalSurfaceIsReady ? "ready" : "missing",
                        "viewport": surface.terminalViewportIsValid ? "valid" : "pending",
                    ])
                }
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return nil
                }
                continue
            }
            if let size = surfaceManager.viewportGrid(for: sessionID) {
                return size
            }
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return nil
            }
        }
    }

    /// Subscribes the daemon-side output stream and records the attachment
    /// identity required for every subsequent DENB input frame.
    func seedSessionSubscription(
        using wire: WarrenRemoteClient,
        sessionID: TerminalSessionID,
        size: TerminalSize?,
        claimControl: Bool
    ) async throws {
        let anchor = outputAnchors[sessionID].map {
            WarrenRemoteRecoveryAnchor(epoch: $0.epoch, sequence: $0.sequence)
        }
        let result = try await wire.subscribe(
            sessionID: sessionID.description,
            size: size,
            anchor: anchor,
            claimControl: claimControl
        )
        guard result.subscribed, !result.attachmentID.isEmpty else {
            throw WarrenRemoteClientError.requestFailed("Host did not return a terminal attachment")
        }
    }

    func selectSession(_ id: TerminalSessionID) {
        guard let session = projection.sessions.first(where: { $0.id == id }) else { return }
        guard session.workspaceID != nil else { return }
        TerminalDiagnostics.log("select_session", [
            "session": id.description,
            "workspace": session.workspaceID?.description ?? "nil",
        ])
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(
                navigation,
                action: .openSession(id),
                in: projection
            )
        )
        Task { await presentSelectedSession(activatingInput: true) }
    }

    func moveTab(_ tabID: String, before destinationTabID: String?) {
        guard let workspaceID = projection.workspaceID(forTabID: tabID),
              destinationTabID == nil
                || projection.workspaceID(forTabID: destinationTabID!) == workspaceID else { return }
        let currentOrder = projection.tabs(in: workspaceID).map(\.id)
        let nextOrder = WarrenRemoteTabOrdering.moving(
            tabID,
            before: destinationTabID,
            in: currentOrder
        )
        guard nextOrder != currentOrder else { return }
        tabOrderByWorkspaceID[workspaceID] = nextOrder
        persistTabOrders()
        publishProjectionIfChanged(
            projection.reorderingTabs(
                tabID: tabID,
                accordingTo: nextOrder
            )
        )
    }

    func applyingLocalTabOrder(
        _ tabs: [ClientTab],
        sessionWorkspaces: [TerminalSessionID: WorkspaceID],
        successors: [String: String] = [:]
    ) -> [ClientTab] {
        let tabWorkspaceIDs = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            tab.sessionID.flatMap { sessionWorkspaces[$0] }.map { (tab.id, $0) }
        })
        let liveWorkspaceIDs = Set(tabWorkspaceIDs.values)
        tabOrderByWorkspaceID = tabOrderByWorkspaceID.filter {
            liveWorkspaceIDs.contains($0.key)
        }

        var result = tabs
        for workspaceID in liveWorkspaceIDs {
            let availableIDs = tabs.compactMap { tab in
                tabWorkspaceIDs[tab.id] == workspaceID ? tab.id : nil
            }
            let preferredOrder = tabOrderByWorkspaceID[workspaceID] ?? availableIDs
            let reconciledOrder = WarrenRemoteTabOrdering.reconciling(
                preferredOrder: preferredOrder,
                availableTabIDs: availableIDs,
                successors: successors
            )
            tabOrderByWorkspaceID[workspaceID] = reconciledOrder
            let tabsByID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            var orderedTabs = reconciledOrder.compactMap { tabsByID[$0] }.makeIterator()
            result = result.map { tab in
                tabWorkspaceIDs[tab.id] == workspaceID ? (orderedTabs.next() ?? tab) : tab
            }
        }
        return result
    }

    /// Schedules the explicit rebind required after a transient transport
    /// reconnect. Roster contents can be byte-for-byte identical to the
    /// previous connection, so the normal tab-change heuristic is not enough
    /// to restore daemon-side subscriptions.
    func scheduleRetainedSurfaceRebind() {
        guard !pendingRetainedSurfaceRebinds.isEmpty,
              retainedSurfaceRebindTask == nil else { return }
        retainedSurfaceRebindTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rebindRetainedSurfaces()
        }
    }

    func rebindRetainedSurfaces() async {
        defer { retainedSurfaceRebindTask = nil }
        guard let wire else { return }
        let candidates = pendingRetainedSurfaceRebinds
        pendingRetainedSurfaceRebinds.removeAll()
        let liveSessionIDs = Set(projection.tabs.compactMap(\.sessionID))
        let eligible = candidates.filter { sessionID in
            liveSessionIDs.contains(sessionID)
                && surfaceManager.surface(for: sessionID) != nil
        }
        guard !eligible.isEmpty else {
            reconnectPreservedSessions.subtract(candidates)
            return
        }

        let selectedID = navigation.selectedTabID.flatMap { tabID in
            projection.tabs.first(where: { $0.id == tabID })?.sessionID
        }
        if let selectedID, eligible.contains(selectedID) {
            await attachSelectedSession(preservingExistingSurface: true)
        }

        for sessionID in eligible where sessionID != selectedID {
            guard !Task.isCancelled, self.wire === wire else {
                pendingRetainedSurfaceRebinds.insert(sessionID)
                return
            }
            guard !outputSubscriptions.contains(sessionID) else {
                continue
            }
            do {
                try await seedSessionSubscription(
                    using: wire,
                    sessionID: sessionID,
                    size: nil,
                    claimControl: false
                )
                guard self.wire === wire else {
                    pendingRetainedSurfaceRebinds.insert(sessionID)
                    return
                }
                noteOutputSubscriptionAdded(sessionID, reason: "rebindRetainedSurfaces")
                TerminalDiagnostics.log("reconnect_surface_rebound", [
                    "session": sessionID.description,
                    "selected": "false",
                ])
            } catch {
                if Self.isTransportFailure(error as NSError) {
                    pendingRetainedSurfaceRebinds.insert(sessionID)
                    TerminalDiagnostics.log("reconnect_surface_rebind_deferred", [
                        "session": sessionID.description,
                        "error": error.localizedDescription,
                    ])
                } else {
                    reconnectPreservedSessions.remove(sessionID)
                    TerminalDiagnostics.log("reconnect_surface_rebind_failed", [
                        "session": sessionID.description,
                        "error": error.localizedDescription,
                    ])
                }
            }
        }
    }

    var selectedWorkspaceID: WorkspaceID? {
        switch navigation.selection {
        case .workspace(let id): id
        case .project(let id): projection.firstWorkspace(in: id)?.id
        case nil: nil
        }
    }

    var selectedContextTabs: [ClientTab] {
        switch navigation.selection {
        case .workspace(let id):
            return projection.tabs(in: id)
        case .project(let id):
            guard let workspaceID = projection.firstWorkspace(in: id)?.id else { return [] }
            return projection.tabs(in: workspaceID)
        case nil:
            return []
        }
    }

    func present(_ error: Error) {
        if Self.isRemoteRequestOutcomeUnknown(error), endpointConfiguration != nil {
            scheduleTransientConnectionIssue(error)
            return
        }
        presentDiagnostic(error)
    }

    func presentDiagnostic(_ error: Error) {
        let detail = Self.diagnosticText(
            error: error,
            endpoint: endpointConfiguration?.ssh ?? endpointConfiguration?.url,
            selectedSessionID: selectedSessionID,
            attachedSessionID: attachedSessionID,
            focusedSessionID: focusedSessionID
        )
        addNotice(
            title: "Warren error",
            message: error.localizedDescription,
            detail: detail,
            kind: .error
        )
    }

    func scheduleTransientConnectionIssue(_ error: Error) {
        guard let expectedConfiguration = endpointConfiguration,
              connectionIssueTask == nil else { return }
        connectionIssueTask = Task { @MainActor [weak self] in
            defer { self?.connectionIssueTask = nil }
            do {
                try await Task.sleep(for: Self.transientConnectionIssueDelay)
            } catch {
                return
            }
            guard let self,
                  self.endpointConfiguration?.hasSameRoute(as: expectedConfiguration) == true,
                  self.maintenanceMessage == nil else { return }
            self.presentDiagnostic(error)
        }
    }

    func cancelTransientConnectionIssue() {
        connectionIssueTask?.cancel()
        connectionIssueTask = nil
    }

    @discardableResult
    @MainActor
    func publishProjectionIfChanged(_ nextProjection: WarrenDesktopProjection) -> Bool {
        guard projection != nextProjection else { return false }
        projection = nextProjection
        projectionPublicationCount &+= 1
        return true
    }

    nonisolated static func shouldApplyRoster(_ roster: RemoteRoster, after previous: RemoteRoster?) -> Bool {
        previous != roster
    }

    /// The daemon roster is the durable snapshot. A live event is only a
    /// fallback for sessions whose snapshot has not exposed activity yet.
    nonisolated static func resolvedAgentStatus(
        rosterStatus: RemoteRoster.AgentStatus?,
        liveStatus: AgentStatus?
    ) -> AgentStatus? {
        if let rosterStatus,
           let activity = AgentActivityState(rawValue: rosterStatus.activity) {
            let attention = rosterStatus.attention.flatMap { value -> AgentAttention? in
                guard let kind = AgentAttentionKind(rawValue: value.kind) else { return nil }
                return AgentAttention(
                    kind: kind,
                    reason: value.reason,
                    requestID: value.requestID,
                    since: value.since
                )
            }
            return AgentStatus(activity: activity, attention: attention)
        }
        return liveStatus
    }

    func publishNavigationIfChanged(_ nextNavigation: WarrenDesktopNavigationState) {
        guard navigation != nextNavigation else { return }
        navigation = nextNavigation
        // Selection is the acknowledgment. Hooking it here rather than in
        // `selectSession` covers the sidebar leaf, the Tab strip, the command
        // palette, and the keyboard with one rule.
        acknowledgeSelectedActivity()
    }

    func switchNavigationScope(to rawScope: String) {
        let scope = rawScope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "local"
            : rawScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard navigationScope != scope else {
            restorePersistedTabOrders(scope: scope)
            return
        }
        // Persist the old Host before replacing the in-memory state. This is
        // intentionally synchronous because endpoint switches can happen
        // while the normal 50ms navigation debounce is pending.
        flushNavigationPersistence()
        navigationScope = scope
        navigation = WarrenDesktopNavigationPersistence.restore(scope: scope)
            ?? WarrenDesktopNavigationState(selection: nil, selectedTabID: nil)
        restorePersistedTabOrders(scope: scope)
    }

    func restorePersistedTabOrders(scope: String) {
        // Acknowledgments ride along with Tab order because they answer the same
        // kind of question — what did this device look like last time — and are
        // keyed to the same Host. Restoring them is what makes "does not expire"
        // true across a relaunch: the roster carries no transition history, so a
        // client with no record would have to guess, and `hadPreviousObservation`
        // makes it guess "nothing is new".
        activityAcknowledgments = WarrenDesktopActivityAcknowledgmentStore.restore(scope: scope)
        let orders = WarrenDesktopNavigationPersistence.restoreTabOrders(scope: scope)
        tabOrderByWorkspaceID = orders.workspace.reduce(into: [:]) { result, entry in
            guard let id = WorkspaceID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    /// Records that this person has now seen whatever the Session was reporting.
    ///
    /// Called from every path that puts a Session on screen, because the answer
    /// to "have I seen this" cannot depend on which door was used.
    func acknowledgeActivity(for session: WarrenDesktopSession) {
        guard activityAcknowledgments.acknowledge(session) else { return }
        persistActivityAcknowledgments()
        publishProjectionIfChanged(
            projection.withSessionAcknowledgedActivity(
                activityAcknowledgments[session.id],
                for: session.id
            )
        )
    }

    func acknowledgeSelectedActivity() {
        guard let tabID = navigation.selectedTabID,
              let session = projection.sessions.first(where: { $0.tabID == tabID })
        else { return }
        acknowledgeActivity(for: session)
    }

    func persistActivityAcknowledgments() {
        WarrenDesktopActivityAcknowledgmentStore.save(
            activityAcknowledgments,
            scope: navigationScope
        )
    }

    func persistTabOrders() {
        WarrenDesktopNavigationPersistence.saveTabOrders(WarrenDesktopTabOrders(
            workspace: Dictionary(uniqueKeysWithValues: tabOrderByWorkspaceID.map {
                ($0.key.description, $0.value)
            })
        ), scope: navigationScope)
    }
    static func tabID(_ id: TerminalSessionID) -> String { "remote-\(id.description)" }

    /// Maps the Host's pane tree into the domain tree. A leaf whose Session ID
    /// does not parse is dropped together with the split that only held it, so a
    /// roster that raced a Session transition can never produce an empty pane.
    static func paneTree(_ node: RemoteRoster.PaneNode) -> WarrenDomain.PaneNode? {
        switch node {
        case .leaf(let paneID, let rawSession):
            guard let rawSession, let session = TerminalSessionID(uuidString: rawSession) else { return nil }
            return WarrenDomain.PaneNode.leaf(
                paneID: paneID.flatMap(PaneID.init(uuidString:)),
                sessionID: session
            )
        case .split(let rawAxis, let ratio, let first, let second):
            guard let axis = WarrenDomain.SplitAxis(rawValue: rawAxis) else { return nil }
            switch (paneTree(first), paneTree(second)) {
            case (nil, nil):
                return nil
            case (let only?, nil), (nil, let only?):
                // Collapsing here mirrors the Host's own reconcile, so the
                // renderer never sees a split with one child.
                return only
            case (let firstChild?, let secondChild?):
                return .split(axis: axis, ratio: ratio, first: firstChild, second: secondChild)
            }
        }
    }
}
