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
    /// person opened is still open when they come back.
    func inspector(for workspace: Workspace) -> WarrenInspectorModel {
        if let inspector = inspectors[workspace.id] {
            inspector.path = workspace.path
            return inspector
        }
        let inspector = WarrenInspectorModel(
            workspaceID: workspace.id.description,
            path: workspace.path,
            client: { [weak self] in
                guard let wire = self?.wire else { throw WarrenRemoteClientError.notConnected }
                return wire
            }
        )
        inspectors[workspace.id] = inspector
        return inspector
    }

    /// Files are read from disk, so the Files tab needs the Workspace's
    /// checkout on this Mac.
    var inspectorReadsLocalFiles: Bool { isLocalEndpoint }

    // MARK: Conversation (RFC 0023)

    /// Folds the Lead flags the client reads from each conversation into the
    /// projection's Session rows. The Host has no parent/child records
    /// (RFC 0024 §8), so this is presentation state rebuilt from messages.
    func refreshLeadMarks() {
        var leadIDs: Set<TerminalSessionID> = []
        var signatures: [TerminalSessionID: String] = [:]
        for (sessionID, feed) in conversationFeeds {
            let lead = WarrenLeadConversation.derive(from: feed.conversation) { id in
                guard let sessionID = TerminalSessionID(uuidString: id) else { return false }
                return projection.session(id: sessionID) != nil
            }
            if lead.isLead { leadIDs.insert(sessionID) }
            if let decision = lead.pendingDecision {
                signatures[sessionID] = "ask|\(decision.id)|\(decision.question)"
            } else if let checks = lead.pendingChecks {
                signatures[sessionID] = "checks|\(checks.id)|\(checks.checks.count)"
            }
        }
        if signatures != leadAttentionSignatures {
            leadAttentionSignatures = signatures
            leadAttentionRevision &+= 1
        }
        let attentionIDs = Set(signatures.keys)
        let currentLeadIDs = Set(projection.sessions.filter(\.isLead).map(\.id))
        let currentAttentionIDs = Set(projection.sessions.filter(\.leadNeedsAttention).map(\.id))
        guard leadIDs != currentLeadIDs || attentionIDs != currentAttentionIDs else { return }
        let sessions = projection.sessions.map { session in
            session.withLead(
                isLead: leadIDs.contains(session.id),
                needsAttention: attentionIDs.contains(session.id)
            )
        }
        _ = publishProjectionIfChanged(projection.replacingSessions(sessions))
    }

    /// The system notifications a Lead's text markers ask for. They join the
    /// existing attention alerts, so a decision or checklist notifies through
    /// the same path as a provider permission.
    func leadAttentionAlerts() -> [WarrenDesktopAttentionAlert] {
        projection.sessions.compactMap { session -> WarrenDesktopAttentionAlert? in
            guard session.leadNeedsAttention,
                  let feed = conversationFeeds[session.id] else { return nil }
            let lead = WarrenLeadConversation.derive(from: feed.conversation) { id in
                guard let sessionID = TerminalSessionID(uuidString: id) else { return false }
                return projection.session(id: sessionID) != nil
            }
            let workspace = session.workspaceID.flatMap { projection.workspace(id: $0) }
            let project = workspace.flatMap { projection.projectGroup(id: $0.projectID)?.project.name }
            let branch = workspace.flatMap { value in
                value.branch?.isEmpty == false ? value.branch : value.name
            }
            let title = session.displayTitle
            let body: String
            let key: String
            if let decision = lead.pendingDecision {
                body = decision.question
                key = "lead-ask|\(decision.id)"
            } else if let checks = lead.pendingChecks {
                body = "Check \(checks.checks.count) things on main"
                key = "lead-checks|\(checks.id)"
            } else {
                return nil
            }
            return WarrenDesktopAttentionAlert(
                sessionID: session.id,
                key: "\(session.id.description)|\(key)",
                title: title,
                location: [project, branch].compactMap { $0 }.joined(separator: " \u{00B7} "),
                body: body,
                quickAnswer: nil
            )
        }
    }

    /// The feed a Conversation surface renders. It is seeded from the local
    /// replica, then kept current by the same batches that drive activity.
    func conversationFeed(for sessionID: TerminalSessionID) -> WarrenConversationFeed {
        if let feed = conversationFeeds[sessionID] { return feed }
        let feed = WarrenConversationFeed(sessionID: sessionID)
        feed.status = projection.session(id: sessionID)?.agentStatus
        conversationFeeds[sessionID] = feed
        seedConversationFeed(feed)
        return feed
    }

    /// Moves the Session's activation token so its composer claims the
    /// keyboard.
    ///
    /// The composer is an AppKit text view inside the pane, so the token is
    /// the only delivery mechanism that survives SwiftUI re-creating the
    /// surface, and it keeps a remount from stealing focus on its own.
    func requestConversationFocus(_ sessionID: TerminalSessionID) {
        nextConversationFocusToken &+= 1
        conversationFocusTokens[sessionID] = nextConversationFocusToken
        TerminalDiagnostics.log("conversation_focus_request", [
            "session": sessionID.description,
            "token": String(nextConversationFocusToken),
        ])
    }

    /// Loads a feed's history from the local replica once its stream is known.
    /// A feed created before the roster names its stream is seeded again when
    /// the stream appears; merging is idempotent by sequence.
    func seedConversationFeed(_ feed: WarrenConversationFeed) {
        guard let namespace = agentNamespace,
              let streamID = conversationStreamID(feed.sessionID),
              feed.seededStreamID != streamID else { return }
        feed.seededStreamID = streamID
        Task { @MainActor [weak feed] in
            let cached = await WarrenAgentEventStore.shared.loadRecentEvents(
                namespace: namespace,
                streamID: streamID,
                limit: 2000
            )
            feed?.merge(cached, streamID: streamID)
            if let state = self.conversationStateEventsByStreamID[streamID] {
                feed?.merge(state, streamID: streamID)
            }
            feed?.markLoaded()
            refreshLeadMarks()
        }
    }

    func conversationStreamID(_ sessionID: TerminalSessionID) -> String? {
        agentSessionByStreamID.first { $0.value == sessionID }?.key
    }

    func conversationCommandContext(_ sessionID: TerminalSessionID) throws -> (WarrenRemoteClient, String) {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        guard let executionID = conversationStreamID(sessionID) else {
            throw WarrenRemoteClientError.requestFailed("This Agent's conversation is not available yet.")
        }
        return (wire, executionID)
    }

    /// Starts a turn. The command ID doubles as the causation the Host echoes
    /// on the user message, so the surface can retire its pending prompt.
    /// Sends a prompt now, showing it as pending until the Host echoes it.
    func submitConversationPrompt(
        _ text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        in feed: WarrenConversationFeed
    ) {
        let placeholderID = "local-\(UUID().uuidString)"
        let names = attachments.compactMap { reference -> String? in
            guard let name = reference.name, !name.isEmpty else { return nil }
            return name
        }
        feed.pendingPrompts.append(.init(id: placeholderID, text: text, attachments: names))
        Task { @MainActor in
            do {
                let commandID = try await self.sendConversationMessage(text, attachments: attachments, to: feed.sessionID)
                if let index = feed.pendingPrompts.firstIndex(where: { $0.id == placeholderID }) {
                    // Re-key the placeholder by the command so the echo retires it.
                    feed.pendingPrompts[index] = .init(id: commandID, text: text, attachments: names)
                    if feed.conversation.turns.contains(where: { $0.promptCausedBy == commandID }) {
                        feed.pendingPrompts.remove(at: index)
                    }
                }
            } catch {
                if let index = feed.pendingPrompts.firstIndex(where: { $0.id == placeholderID }) {
                    feed.pendingPrompts[index].failure = "Not sent: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Holds a prompt until the Agent is ready for it (after Synara's queued
    /// follow-ups). The queue lives with the feed, not the view, so it keeps
    /// draining while another Session is on screen.
    func queueConversationPrompt(
        _ text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        in feed: WarrenConversationFeed
    ) {
        feed.queuedPrompts.append(.init(id: "queued-\(UUID().uuidString)", text: text, attachments: attachments))
        drainConversationQueue(feed.sessionID)
    }

    /// Sends the next queued prompt once the Agent is ready, no decision is
    /// waiting, and the previous prompt has been echoed.
    func drainConversationQueue(_ sessionID: TerminalSessionID) {
        guard let feed = conversationFeeds[sessionID],
              !feed.queuedPrompts.isEmpty,
              feed.status?.activity == .ready,
              feed.conversation.decisions.isEmpty,
              feed.pendingPrompts.allSatisfy({ $0.failure != nil }) else { return }
        let next = feed.queuedPrompts.removeFirst()
        submitConversationPrompt(next.text, attachments: next.attachments, in: feed)
    }

    func sendConversationMessage(
        _ text: String,
        attachments: [WarrenRemoteAgentAttachmentRef] = [],
        to sessionID: TerminalSessionID
    ) async throws -> String {
        let (wire, executionID) = try conversationCommandContext(sessionID)
        let commandID = "desktop-\(UUID().uuidString.lowercased())"
        let receipt = try await wire.startAgentTurn(
            executionID: executionID,
            commandID: commandID,
            text: text,
            attachments: attachments
        )
        guard receipt.accepted else {
            throw WarrenRemoteClientError.requestFailed("The Host did not accept the message.")
        }
        return commandID
    }

    // MARK: Conversation attachments

    /// Reads one local file, uploads it through the Host's
    /// prepare/chunk/complete lifecycle, and leaves the Host-issued reference
    /// on the feed's chip. The bytes never leave this Mac except as upload
    /// chunks; only the returned id travels on the next turn.
    func addConversationAttachment(_ url: URL, in feed: WarrenConversationFeed) {
        let id = "attach-\(UUID().uuidString)"
        let name = url.lastPathComponent
        guard supportsConversationAttachments(feed.sessionID) else {
            feed.pendingAttachments.append(.init(
                id: id,
                name: name,
                failure: "This Host does not support attachments."
            ))
            return
        }
        feed.pendingAttachments.append(.init(id: id, name: name))
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Data(contentsOf: url)
                }.value
                self.updateConversationAttachment(id, in: feed) { $0.size = Int64(data.count) }
                let reference = try await self.uploadAgentAttachment(
                    data: data,
                    name: name,
                    mime: Self.attachmentMimeType(for: url),
                    sessionID: feed.sessionID
                ) { [weak self] progress in
                    self?.updateConversationAttachment(id, in: feed) { $0.progress = progress }
                }
                self.updateConversationAttachment(id, in: feed) {
                    $0.reference = reference
                    $0.progress = 1
                }
            } catch {
                self.updateConversationAttachment(id, in: feed) {
                    $0.failure = error.localizedDescription
                }
            }
        }
    }

    func updateConversationAttachment(
        _ id: String,
        in feed: WarrenConversationFeed,
        _ change: (inout WarrenConversationFeed.PendingAttachment) -> Void
    ) {
        guard let index = feed.pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
        change(&feed.pendingAttachments[index])
    }

    /// Uploads one file as opaque chunks. Progress is reported in whole-percent
    /// steps so a large file does not invalidate the composer per chunk.
    func uploadAgentAttachment(
        data: Data,
        name: String,
        mime: String,
        sessionID: TerminalSessionID,
        progress: @escaping @MainActor (Double) -> Void = { _ in }
    ) async throws -> WarrenRemoteAgentAttachmentRef {
        let (wire, executionID) = try conversationCommandContext(sessionID)
        let sharedBytes = data
        let digest = await Task.detached(priority: .utility) {
            Self.sha256Hex(sharedBytes)
        }.value
        let prepared = try await wire.prepareAgentAttachment(
            executionID: executionID,
            commandID: "attachment-\(UUID().uuidString.lowercased())",
            name: name,
            mime: mime,
            size: Int64(data.count),
            sha256: digest
        )
        let chunkSize = max(1, prepared.chunkSize)
        var offset = 0
        var sequence: UInt64 = 0
        var lastReported = -1.0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let slice = Data(data[offset..<end])
            let chunkDigest = await Task.detached(priority: .utility) {
                Self.sha256Hex(slice)
            }.value
            let result = try await wire.uploadAgentAttachmentChunk(
                executionID: executionID,
                commandID: "\(prepared.uploadID)-chunk-\(sequence)",
                uploadID: prepared.uploadID,
                chunk: sequence,
                length: slice.count,
                sha256: chunkDigest,
                data: slice.base64EncodedString()
            )
            guard result.accepted else {
                throw WarrenRemoteClientError.requestFailed(result.error ?? "The Host rejected an attachment chunk.")
            }
            offset = end
            sequence &+= 1
            let value = Double(offset) / Double(max(data.count, 1))
            if value - lastReported >= 0.01 || value >= 1 {
                lastReported = value
                progress(value)
            }
        }
        let completed = try await wire.completeAgentAttachment(
            executionID: executionID,
            commandID: "\(prepared.uploadID)-complete",
            uploadID: prepared.uploadID,
            length: Int64(data.count),
            sha256: digest
        )
        guard completed.accepted,
              let attachmentID = completed.attachmentID,
              !attachmentID.isEmpty else {
            throw WarrenRemoteClientError.requestFailed(completed.error ?? "The Host rejected the attachment.")
        }
        progress(1)
        return WarrenRemoteAgentAttachmentRef(
            attachmentID: attachmentID,
            name: name,
            mime: mime,
            size: Int64(data.count)
        )
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func attachmentMimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    func cancelConversationTurn(_ sessionID: TerminalSessionID, turnID: String) async throws {
        let (wire, executionID) = try conversationCommandContext(sessionID)
        _ = try await wire.cancelAgentTurn(
            executionID: executionID,
            commandID: "cancel-\(executionID)-\(turnID)",
            turnID: turnID,
            reason: "cancel"
        )
    }

    func resolveConversationDecision(
        _ decision: WarrenConversation.Decision,
        optionID: String,
        in sessionID: TerminalSessionID
    ) async throws {
        try await resolveConversationDecision(
            decision,
            resolution: ["decision": .string(optionID)],
            in: sessionID
        )
    }

    /// Resolves a decision with the wire's own resolution shape: an option id
    /// for a choice, `text` for a question, or `cancelled` to dismiss.
    func resolveConversationDecision(
        _ decision: WarrenConversation.Decision,
        resolution: [String: WarrenRemoteJSONValue],
        in sessionID: TerminalSessionID
    ) async throws {
        let (wire, executionID) = try conversationCommandContext(sessionID)
        _ = try await wire.resolveAgentInteraction(
            executionID: executionID,
            commandID: "resolve-\(executionID)-\(decision.id)-\(decision.version)",
            interactionID: decision.id,
            version: decision.version,
            resolution: resolution
        )
    }

    /// Answers the decision the approval tray shows for `sessionID`, through
    /// the same request the Conversation's dock sends. The tray names the
    /// decision it drew, so an answer to a request that has since moved on is
    /// refused rather than applied to its successor.
    func resolvePendingDecision(
        _ decisionID: String,
        optionID: String,
        in sessionID: TerminalSessionID
    ) async throws {
        guard let streamID = conversationStreamID(sessionID),
              let decision = agentOpenDecisionByStreamID[streamID],
              decision.id == decisionID else {
            throw WarrenRemoteClientError.requestFailed("This request was already answered.")
        }
        try await resolveConversationDecision(decision, optionID: optionID, in: sessionID)
    }

    /// Folds a batch's interaction events into the stream's open decision.
    /// The Conversation projection is the rule for what is still pending, so
    /// the tray and the dock cannot disagree about it.
    func foldOpenDecision(_ events: [WarrenRemoteAgentEvent], streamID: String) {
        let interactions = events.filter { $0.type.lowercased().hasPrefix("interaction.") }
        guard !interactions.isEmpty else { return }
        var held = agentInteractionEventsByStreamID[streamID] ?? [:]
        for event in interactions where held[event.sequence] == nil {
            held[event.sequence] = event
        }
        agentInteractionEventsByStreamID[streamID] = held
        let open = WarrenConversation.project(Array(held.values)).decisions.first
        guard agentOpenDecisionByStreamID[streamID] != open else { return }
        agentOpenDecisionByStreamID[streamID] = open
        publishPendingDecisions()
    }

    /// Publishes the open decisions of the Sessions whose decisions the
    /// Desktop can answer: Conversation Sessions, the only ones the dock
    /// answers today. A terminal Agent's request is answered in its own TUI,
    /// so the tray offers only Open for it.
    func publishPendingDecisions() {
        var next: [TerminalSessionID: WarrenDesktopPendingDecision] = [:]
        for (streamID, decision) in agentOpenDecisionByStreamID where !decision.options.isEmpty {
            guard let sessionID = agentSessionByStreamID[streamID],
                  conversationSessionIDs.contains(sessionID) else { continue }
            let session = projection.session(id: sessionID)
            let providerName = (session?.agentProvider ?? session?.kind)?.displayName ?? "Agent"
            let target = decision.detail.isEmpty ? (decision.diff?.file ?? "") : decision.detail
            next[sessionID] = WarrenDesktopPendingDecision(
                id: decision.id,
                ask: decision.ask(providerName: providerName),
                detail: WarrenConversation.displayTarget(target, root: session?.workingDirectory),
                options: decision.options.map {
                    WarrenDesktopPendingDecision.Option(id: $0.id, label: $0.label, isReject: $0.isReject)
                }
            )
        }
        if pendingDecisions != next {
            pendingDecisions = next
        }
    }

    /// Changes one agent selector (model, mode) of a chat Session
    /// (RFC 0023 §6.11). The agent's answer arrives as the next config.updated.
    func setConversationConfig(_ configID: String, value: String, in sessionID: TerminalSessionID) async throws {
        let (wire, executionID) = try conversationCommandContext(sessionID)
        _ = try await wire.setAgentConfig(
            executionID: executionID,
            commandID: "desktop-config-\(UUID().uuidString.lowercased())",
            configID: configID,
            value: value
        )
    }

    /// Replaces a chat Session with a terminal Session that resumes the same
    /// provider conversation (RFC 0023 §6.12), launched with this Mac's
    /// terminal preset for the provider, and selects it.
    func handoffConversation(_ sessionID: TerminalSessionID) async throws {
        guard let wire else { throw URLError(.notConnectedToInternet) }
        let session = projection.session(id: sessionID)
        let kind = (session?.agentProvider ?? session?.kind)?.rawValue ?? ""
        let created = try await wire.handoffSession(sessionID: sessionID.description, command: Self.terminalPresetCommand(for: kind))
        try await refreshRoster(using: wire)
        guard let replacement = TerminalSessionID(uuidString: created.id) else { return }
        selectSession(replacement)
    }

    /// The terminal preset command Settings holds for a provider.
    static func terminalPresetCommand(for kind: String) -> String? {
        let key: String
        switch kind {
        case "claude": key = WarrenPreferenceKey.presetCommandClaude
        case "codex": key = WarrenPreferenceKey.presetCommandCodex
        case "opencode": key = WarrenPreferenceKey.presetCommandOpenCode
        default: return nil
        }
        let stored = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty { return stored }
        return kind == "codex" ? "codex --dangerously-bypass-hook-trust" : kind
    }

    func supportsConversationConfig(_ sessionID: TerminalSessionID) -> Bool {
        conversationConfigSessionIDs.contains(sessionID)
    }

    func supportsConversationAttachments(_ sessionID: TerminalSessionID) -> Bool {
        conversationAttachmentSessionIDs.contains(sessionID)
    }

    func conversationHasConversation(_ sessionID: TerminalSessionID) -> Bool {
        conversationHandoffSessionIDs.contains(sessionID)
    }

    /// Opens a Session named by an event payload, such as an agent terminal.
    func openSession(named id: String) {
        guard let sessionID = TerminalSessionID(uuidString: id) else { return }
        selectSession(sessionID)
    }

    func sessionIsOpen(named id: String) -> Bool {
        guard let sessionID = TerminalSessionID(uuidString: id) else { return false }
        return projection.session(id: sessionID)?.state.isActive == true
    }

    func createSession(
        workspaceID: WorkspaceID,
        request launch: TerminalSessionLaunchRequest,
        token: UUID? = nil
    ) {
        guard let wire,
              let workspace = projection.workspace(id: workspaceID),
              !creatingSessionWorkspaceIDs.contains(workspaceID),
              !deletingWorkspaceIDs.contains(workspaceID),
              !deletingProjectIDs.contains(workspace.projectID) else { return }
        creatingSessionWorkspaceIDs.insert(workspaceID)
        Task { @MainActor [weak self] in
            defer { self?.finishCreatingSession(in: workspaceID) }
            do {
                let call = Self.createSessionCall(
                    workspaceID: workspaceID.description,
                    request: launch
                )
                let data = try await wire.request(call.method, params: call.params)
                let created = try JSONDecoder().decode(CreatedSession.self, from: data)
                guard let sessionID = TerminalSessionID(uuidString: created.id) else {
                    throw NSError(domain: "WarrenRemote", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: "The daemon returned an invalid Session ID.",
                    ])
                }
                // Published before the roster refresh so the requester can match
                // the Session whichever of the two reaches it first.
                if let token {
                    self?.createdSessionIDsByToken[token] = sessionID
                }

                // The create response is authoritative, but the projection is
                // roster-backed. Refresh it before selecting the new tab so the
                // terminal surface can be mounted against a real tab instead of
                // waiting for an arbitrary roster tick.
                try await self?.refreshRoster(using: wire)
                guard let self,
                      self.selectedWorkspaceID == workspaceID else { return }
                // Creating and attaching are separate waits. End the create
                // indication before the terminal attach indication begins so
                // one user action never displays two spinners at once.
                self.finishCreatingSession(in: workspaceID)
                self.publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        self.navigation,
                        action: .selectTab(Self.tabID(sessionID)),
                        in: self.projection
                    )
                )
                await self.presentSelectedSession(activatingInput: true)
            } catch {
                self?.present(error)
            }
        }
    }

    /// Resolves a launcher link and opens its requested resource. The request
    /// is retained until the local/remote roster is ready so a Raycast
    /// invocation can arrive during Warren's first connection attempt.
    func openTerminal(_ request: WarrenTerminalOpenRequest) {
        pendingTerminalOpenRequest = request
        fulfillPendingTerminalOpenRequest()
    }

    func fulfillPendingTerminalOpenRequest() {
        guard let request = pendingTerminalOpenRequest,
              wire != nil else { return }

        if request.hasResourceTarget {
            fulfillResourceOpenRequest(request)
            return
        }

        // A bare terminal link opens a shell where ⌘T would: in the selected
        // Workspace. With no Workspace selected there is nowhere to put one.
        pendingTerminalOpenRequest = nil
        guard let workspaceID = selectedWorkspaceID else {
            present(NSError(domain: "WarrenRemote", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Select a workspace before opening a Warren terminal.",
            ]))
            return
        }
        createSession(workspaceID: workspaceID, request: .shell)
    }

    func fulfillResourceOpenRequest(_ request: WarrenTerminalOpenRequest) {
        let project: Project?
        if let selector = request.project {
            guard let resolved = resolveSelector(
                selector,
                in: projection.groups.map(\.project),
                name: { $0.name },
                id: { $0.id.description }
            ) else {
                failResourceOpenRequest(resource: "project", selector: selector)
                return
            }
            project = resolved
        } else {
            project = nil
        }

        let explicitlySelectedWorkspace: Workspace?
        if let selector = request.workspace {
            let candidates = projection.groups
                .filter { project == nil || $0.project.id == project?.id }
                .flatMap(\.workspaces)
            guard let resolved = resolveSelector(
                selector,
                in: candidates,
                name: { $0.name },
                id: { $0.id.description }
            ) else {
                failResourceOpenRequest(resource: "workspace", selector: selector)
                return
            }
            explicitlySelectedWorkspace = resolved
        } else {
            explicitlySelectedWorkspace = nil
        }

        if let project, let workspace = explicitlySelectedWorkspace, workspace.projectID != project.id {
            failResourceOpenRequest(resource: "workspace", selector: request.workspace ?? workspace.name)
            return
        }

        if let selector = request.session {
            let candidates = projection.sessions.filter { session in
                if let workspace = explicitlySelectedWorkspace {
                    return session.workspaceID == workspace.id && session.tabID != nil
                }
                if let project {
                    return session.workspaceID.flatMap(projection.workspace(id:))?.projectID == project.id
                        && session.tabID != nil
                }
                return session.tabID != nil
            }
            guard let session = resolveSelector(
                selector,
                in: candidates,
                name: { $0.displayTitle },
                id: { $0.id.description }
            ) else {
                failResourceOpenRequest(resource: "session", selector: selector)
                return
            }
            pendingTerminalOpenRequest = nil
            publishNavigationIfChanged(
                WarrenDesktopNavigationReducer.reduce(
                    navigation,
                    action: .openSession(session.id),
                    in: projection
                )
            )
            Task { await presentSelectedSession(activatingInput: true) }
            return
        }

        let workspace = explicitlySelectedWorkspace
            ?? project.flatMap { projection.firstWorkspace(in: $0.id) }
        guard let workspace else {
            // A project can exist without a workspace. Selecting it is still
            // useful, but there is no terminal to create until one is added.
            if let project {
                pendingTerminalOpenRequest = nil
                publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        navigation,
                        action: .selectProject(project.id),
                        in: projection
                    )
                )
                return
            }
            failResourceOpenRequest(resource: "workspace", selector: request.workspace ?? "")
            return
        }

        pendingTerminalOpenRequest = nil
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(
                navigation,
                action: .selectWorkspace(workspace.id),
                in: projection
            )
        )
        if projection.tabs(in: workspace.id).isEmpty {
            createSession(workspaceID: workspace.id, request: .shell)
        } else {
            Task { await presentSelectedSession(activatingInput: true) }
        }
    }

    func failResourceOpenRequest(resource: String, selector: String) {
        pendingTerminalOpenRequest = nil
        let target = selector.isEmpty ? resource : "\(resource) ‘\(selector)’"
        present(NSError(domain: "WarrenRemote", code: 31, userInfo: [
            NSLocalizedDescriptionKey: "The Warren link target \(target) does not exist or is ambiguous.",
        ]))
    }

    func resolveSelector<Value>(
        _ selector: String,
        in values: [Value],
        name: (Value) -> String,
        id: (Value) -> String
    ) -> Value? {
        let normalized = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = values.filter { value in
            id(value).caseInsensitiveCompare(normalized) == .orderedSame
                || name(value).caseInsensitiveCompare(normalized) == .orderedSame
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func finishCreatingSession(in workspaceID: WorkspaceID) {
        guard creatingSessionWorkspaceIDs.contains(workspaceID) else { return }
        creatingSessionWorkspaceIDs.remove(workspaceID)
    }

    func addProject(_ folder: URL) async {
        guard let wire else { return }
        do {
            _ = try await wire.request("project.add", params: [
                "path": folder.path,
                "name": folder.lastPathComponent,
            ])
            try await refreshRoster(using: wire)
        } catch {
            present(error)
        }
    }

    func updateTerminalFont(_ preference: TerminalFontPreference) {
        guard preference != terminalFont else { return }
        terminalFont = preference
        surfaceManager.apply(font: preference)
    }

    func updateTerminalBackgroundOpacity(_ opacity: Double) {
        guard opacity != terminalBackgroundOpacity else { return }
        terminalBackgroundOpacity = opacity
        surfaceManager.apply(backgroundOpacity: opacity)
    }
    func startWebFromUI() {
        controlPublicAccess(.enable)
    }
    func stopWeb() {
        controlPublicAccess(.disable)
    }

    func enablePublicAccess(publicHostname: String = "", pathPrefix: String = "") {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(
                    .enable,
                    publicHostname: publicHostname,
                    pathPrefix: pathPrefix
                )
            } catch {
                webStatus.publicAccessError = error.localizedDescription
                present(error)
            }
        }
    }

    /// Persists the non-secret Relay route configuration and verifies the
    /// route without changing its enabled intent.
    func testPublicAccess(publicHostname: String, pathPrefix: String) {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        webStatus.publicAccessAuthenticated = false
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(
                    .test,
                    publicHostname: publicHostname,
                    pathPrefix: pathPrefix
                )
            } catch {
                webStatus.publicAccessError = error.localizedDescription
                present(error)
            }
        }
    }

    /// Disables the Relay route and clears Warren's local route metadata.
    func resetPublicAccess() {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(.reset)
                webStatus.publicAccessError = nil
            } catch {
                webStatus.publicAccessError = error.localizedDescription
                present(error)
            }
        }
    }

    enum PublicAccessAction: String {
        case enable
        case test
        case disable
        case reset
        case restart
    }

    func controlPublicAccess(_ action: PublicAccessAction) {
        webStatus.publicAccessBusy = true
        webStatus.publicAccessError = nil
        Task {
            defer { webStatus.publicAccessBusy = false }
            do {
                try await publicAccessRequest(action)
            } catch {
                webStatus.publicAccessError = error.localizedDescription
                present(error)
            }
        }
    }
    func browserURL(for url: URL) -> URL {
        Self.browserURL(
            for: url,
            localURL: webStatus.localURL,
            lanURL: webStatus.lanURL,
            secureURL: webStatus.secureURL,
            daemonToken: webAuthToken
        )
    }

    func openWebURL(_ url: URL) {
        let browserURL = browserURL(for: url)
        NSWorkspace.shared.open(browserURL)
    }
    func copyWebURL(_ url: URL) {
        WarrenCopyFeedback.shared.copy(browserURL(for: url).absoluteString, announcing: "Copied link")
    }
    func copyLocalWebURL() {
        if let url = webStatus.localURL { copyWebURL(url) }
    }
    func copySecureWebURL() {
        Task {
            await refreshTunnelStatus()
            guard let url = webStatus.secureURL else {
                present(NSError(domain: "WarrenRemote", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Public Access is not ready. Configure the Relay route in Settings → Public Access, then use Save & Test.",
                ]))
                return
            }
            WarrenCopyFeedback.shared.copy(browserURL(for: url).absoluteString, announcing: "Copied public link")
        }
    }

    /// Relay endpoints authenticate the control WebSocket with a short-lived
    /// capability; that value must never be copied into a public URL fragment.
    /// Only the local daemon path needs a token fragment when explicitly
    /// opening a protected Web URL. Relay capabilities stay in memory.
    var webAuthToken: String {
        guard endpointConfiguration?.type.lowercased() != "relay" else { return "" }
        return endpointConfiguration?.token ?? ""
    }

    /// The viewer page URL for one Warren Browser Session (RFC 0022 §8.2).
    ///
    /// `nil` until an Endpoint is selected, which is the honest answer: a viewer
    /// page is served by the Host that owns the browser, so with no Host there is
    /// nothing to load and the region shows its empty state instead of a web view
    /// pointed at nowhere.
    func browserViewerURL(sessionID: String) -> URL? {
        liveEndpointConfiguration?.browserViewerURL(sessionID: sessionID)
    }

    /// Resolves the browser-open or clipboard URL for a Web address. Local
    /// and LAN daemon endpoints attach the local daemon authentication fragment.
    /// Remote public access endpoints attach credentials only when permitted.
    static func browserURL(
        for url: URL,
        localURL: URL?,
        lanURL: URL?,
        secureURL: URL?,
        daemonToken: String
    ) -> URL {
        if let localURL, canonicalWebURL(url) == canonicalWebURL(localURL) {
            return authenticatedWebURL(url, daemonToken: daemonToken)
        }
        if let lanURL, canonicalWebURL(url) == canonicalWebURL(lanURL) {
            return authenticatedWebURL(url, daemonToken: daemonToken)
        }
        return publicAccessBrowserURL(
            url,
            currentEndpoint: secureURL,
            daemonToken: daemonToken
        )
    }

    /// Returns the URL used only for an explicit browser-open action. Public
    /// Public Access responses stay canonical and credential-free; explicit
    /// browser and clipboard actions add the existing Warren fragment at the
    /// last possible moment so the protected WebSocket can authenticate. This
    /// Local daemon authentication remains a residual browser-history risk and
    /// is never persisted or sent through analytics.
    static func publicAccessBrowserURL(
        _ url: URL,
        currentEndpoint: URL?,
        daemonToken: String
    ) -> URL {
        guard !daemonToken.isEmpty,
              let currentEndpoint,
              canonicalWebURL(url) == canonicalWebURL(currentEndpoint) else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return authenticatedWebURL(components.url ?? url, daemonToken: daemonToken)
    }

    /// Adds the local daemon authentication fragment only to a URL being
    /// opened in a browser. The value is encoded as an RFC3986 fragment field
    /// so base64 tokens containing `+`, `/`, or `=` survive URLSearchParams.
    static func authenticatedWebURL(_ url: URL, daemonToken: String) -> URL {
        guard !daemonToken.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.percentEncodedFragment = "t=\(percentEncodeFragmentValue(daemonToken))"
        return components.url ?? url
    }

    static func percentEncodeFragmentValue(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func normalizeAuthenticatedWebURL(_ url: URL) -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              fragment.hasPrefix("t=") else {
            return url
        }
        let token = String(fragment.dropFirst(2))
        var canonical = components
        canonical.fragment = nil
        return authenticatedWebURL(canonical.url ?? url, daemonToken: token)
    }

    static func canonicalWebURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    func refreshTunnelStatus() async {
        guard let configuration = liveEndpointConfiguration else { return }
        _ = await refreshPublicAccessStatus(configuration: configuration)
    }

    func publicAccessRequest(
        _ action: PublicAccessAction,
        publicHostname: String = "",
        pathPrefix: String = ""
    ) async throws {
        guard let configuration = liveEndpointConfiguration else {
            throw NSError(domain: "WarrenRemote", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "The selected SSH endpoint is still connecting.",
            ])
        }
        if configuration.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "relay" {
            guard let wire else { throw URLError(.notConnectedToInternet) }
            var params: [String: String] = [:]
            if action == .enable || action == .test {
                if !publicHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    params["publicHostname"] = publicHostname
                }
                if !pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    params["pathPrefix"] = pathPrefix
                }
            }
            let data = try await wire.request("public-access.\(action.rawValue)", params: params)
            applyPublicAccessStatus(from: data)
            return
        }
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/public-access/" + action.rawValue) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if action == .enable || action == .test {
            let body = PublicAccessRouteRequest(
                publicHostname: publicHostname.isEmpty ? nil : publicHostname,
                pathPrefix: pathPrefix.isEmpty ? nil : pathPrefix
            )
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(PublicAccessStatus.self, from: data).error)
                .flatMap { $0 }
                ?? String(data: data, encoding: .utf8)
                ?? "Public Access request failed."
            throw NSError(domain: "WarrenRemote", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
        applyPublicAccessStatus(from: data)
    }

    func refreshPublicAccessStatus(configuration: WarrenRemoteEndpointConfiguration) async -> Bool {
        if configuration.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "relay" {
            guard let wire else { return false }
            do {
                let data = try await wire.request("public-access.status")
                applyPublicAccessStatus(from: data)
                return true
            } catch {
                return false
            }
        }
        let base = configuration.url.hasSuffix("/")
            ? String(configuration.url.dropLast())
            : configuration.url
        guard let url = URL(string: base + "/v1/public-access") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            applyPublicAccessStatus(from: data)
            return true
        } catch {
            return false
        }
    }

    struct PublicAccessRouteRequest: Encodable {
        let publicHostname: String?
        let pathPrefix: String?

        enum CodingKeys: String, CodingKey {
            case publicHostname
            case pathPrefix
        }
    }

    struct PublicAccessStatus: Decodable {
        let relayURL: String?
        let hostID: String?
        let routeID: String?
        let publicHostname: String?
        let pathPrefix: String?
        let authMode: String?
        let enabled: Bool
        let authenticated: Bool?
        let running: Bool
        let publicEndpoint: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case relayURL = "relayUrl"
            case hostID = "hostId"
            case routeID = "routeId"
            case publicHostname
            case pathPrefix
            case authMode
            case enabled
            case authenticated
            case running
            case publicEndpoint
            case error
        }
    }

    func applyPublicAccessStatus(from data: Data) {
        guard let response = try? JSONDecoder().decode(PublicAccessStatus.self, from: data) else {
            webStatus.secureURL = nil
            webStatus.tunnelRunning = false
            webStatus.relayURL = nil
            webStatus.relayHostID = nil
            webStatus.routeID = nil
            webStatus.publicHostname = nil
            webStatus.pathPrefix = nil
            webStatus.authMode = nil
            webStatus.publicAccessEnabled = false
            webStatus.publicAccessAuthenticated = false
            return
        }
        webStatus.relayURL = response.relayURL.flatMap(URL.init(string:))
        webStatus.relayHostID = response.hostID
        webStatus.routeID = response.routeID
        webStatus.publicHostname = response.publicHostname
        webStatus.pathPrefix = response.pathPrefix
        webStatus.authMode = response.authMode
        webStatus.publicAccessEnabled = response.enabled
        webStatus.publicAccessAuthenticated = response.authenticated ?? false
        webStatus.publicAccessError = response.error.flatMap { error in
            error.isEmpty ? nil : error
        }
        guard response.running,
              let endpoint = response.publicEndpoint,
              let url = URL(string: endpoint) else {
            webStatus.secureURL = nil
            webStatus.tunnelRunning = false
            return
        }
        webStatus.secureURL = url
        webStatus.tunnelRunning = true
        webStatus.publicAccessAuthenticated = true
    }

    func previewSupersetImport() async throws -> SupersetImportPreview {
        try await SupersetCLIImportSource().preview()
    }

    func commitSupersetImport(_ preview: SupersetImportPreview) async {
        guard let wire else { return }
        do {
            for project in preview.projects where project.status == .ready {
                let id: String
                do {
                    let data = try await wire.request("project.add", params: [
                        "path": project.repositoryPath,
                        "name": project.name,
                    ])
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let createdID = object["id"] as? String else { continue }
                    id = createdID
                } catch {
                    // The user may have added this project just before importing.
                    // The local projection can still be one roster tick behind,
                    // so ask the daemon for an authoritative snapshot instead of
                    // treating its duplicate-path response as a fatal import error.
                    try await refreshRoster(using: wire)
                    guard let existing = findProject(path: project.repositoryPath) else {
                        throw error
                    }
                    id = existing.id
                }
                // project.add may have imported every Git worktree when the
                // host setting is enabled. Refresh before issuing explicit
                // workspace.create requests so this manual import remains
                // idempotent across both settings modes.
                try await refreshRoster(using: wire)
                for workspace in project.workspaces where workspace.status == .ready {
                    if normalizedPath(workspace.path) == normalizedPath(project.repositoryPath) {
                        continue
                    }
                    if hasWorkspace(path: workspace.path, projectID: id) {
                        continue
                    }
                    _ = try await wire.request("workspace.create", params: [
                        "project": id,
                        "branch": workspace.branch ?? "main",
                        "name": workspace.name,
                        "path": workspace.path,
                    ])
                }
            }
            try await refreshRoster(using: wire)
        } catch {
            present(error)
        }
    }

    func refreshRoster(using wire: WarrenRemoteClient) async throws {
        let generation = rosterApplicationGeneration
        let data = try await wire.request("roster")
        let roster = try JSONDecoder().decode(RemoteRoster.self, from: data)
        // A refresh may race with a stream roster or another refresh. Only
        // apply a response if this wire is still active and no newer roster
        // has already been applied while the request was in flight.
        guard self.wire === wire,
              Self.shouldApplyRoster(
                  startedAt: generation,
                  currentGeneration: rosterApplicationGeneration
              ) else { return }
        guard Self.shouldApplyRoster(roster, after: currentRoster) else {
            clearMaintenance()
            cancelTransientConnectionIssue()
            return
        }
        currentRoster = roster
        apply(roster)
    }

    func refreshRosterAfterDeltaMismatch(using wire: WarrenRemoteClient) async {
        do {
            try await refreshRoster(using: wire)
        } catch {
            present(error)
        }
    }

    func findProject(path: String) -> (id: String, path: String)? {
        guard let project = currentRoster?.projects.first(where: {
            normalizedPath($0.path) == normalizedPath(path)
        }) else { return nil }
        return (project.id, project.path)
    }

    func hasWorkspace(path: String, projectID: String) -> Bool {
        currentRoster?.workspaces.contains(where: {
            $0.project == projectID && normalizedPath($0.path) == normalizedPath(path)
        }) == true
    }

    func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    func perform(_ action: WarrenDesktopAction) {
        TerminalDiagnostics.log("action", [
            "action": String(String(describing: action).prefix(160)),
        ])
        publishNavigationIfChanged(
            WarrenDesktopNavigationReducer.reduce(navigation, action: action, in: projection)
        )
        switch action {
        case .selectProject, .selectWorkspace, .openWorkspace, .selectTab, .restoreNavigation:
            // Every one of these is the user entering a Session or the
            // Workspace that holds it, including the Settings window closing
            // on to the Session it was opened over.
            Task { await presentSelectedSession(activatingInput: true) }
        case .openSession(let id):
            selectSession(id)
        case .deleteSession(let id):
            closeSession(id)
        case .clearSelectedTab:
            // Nothing is attached, so nothing needs presenting. The Sessions
            // stay running on the Host; only this client stopped showing one.
            break
        case .launchSession(let workspaceID, let launch):
            createSession(workspaceID: workspaceID, request: launch)
        case .addProject:
            present(NSError(domain: "WarrenRemote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Remote projects must use remote paths. "
                    + "Run `warren --endpoint <server> project add /path`.",
            ]))
        case .renameProject(let id, let name):
            request("project.rename", params: ["id": id.description, "name": name])
        case .renameTask(let id, let name):
            request("task.rename", params: ["id": id.description, "name": name])
        case .renameWorkspace(let id, let name):
            request("workspace.rename", params: ["id": id.description, "name": name])
        case .attachWorkspaceToTask(let taskID, let workspaceID):
            request("task.attach", params: [
                "id": taskID.description,
                "workspace": workspaceID.description,
            ])
        case .detachWorkspaceFromTask(let taskID, let workspaceID):
            request("task.detach", params: [
                "id": taskID.description,
                "workspace": workspaceID.description,
            ])
        case .deleteTask(let id):
            request("task.remove", params: ["id": id.description])
        case .deleteProject(let id):
            deleteProject(id)
        case .deleteWorkspace(let id, let removeLocalWorktree):
            deleteWorkspace(id, removeLocalWorktree: removeLocalWorktree)
        case .renameSession(let id, let title):
            request("session.rename", params: ["id": id.description, "title": title])
        case .regenerateSessionTitle(let id):
            // The Host writes the name as a rename, so the new title arrives
            // with the roster; only a failure has anything to say here.
            request("session.title.regenerate", params: ["id": id.description])
        case .setTaskPinned(let id, let pinned):
            request("task.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .setProjectPinned(let id, let pinned):
            request("project.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .setWorkspacePinned(let id, let pinned):
            request("workspace.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .setSessionPinned(let id, let pinned):
            request("session.pin", params: ["id": id.description, "pinned": String(pinned)])
        case .dismissActivity(let id, let expectedActivity):
            // Records that the notice was read rather than erasing the status.
            // Nil-ing the status also dropped `agentStatus`, which made a shell
            // the Host had promoted to an Agent read as a plain shell again —
            // tolerable for a rarely-used menu item, wrong now that visiting a
            // row does this.
            guard let session = projection.session(id: id),
                  WarrenActivityDismissal.canDismiss(
                      candidate: session.activity,
                      expected: expectedActivity
                  ) else { return }
            acknowledgeActivity(for: session)
        case .moveProject(let projectID, let before):
            guard !deletingProjectIDs.contains(projectID),
                  let group = projection.groups.first(where: { $0.project.id == projectID }),
                  !group.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) })
            else { return }
            var params = ["id": projectID.description]
            if let before { params["before"] = before.description }
            request("project.move", params: params)
        case .moveWorkspace(let workspaceID, let before):
            guard let workspace = projection.workspace(id: workspaceID),
                  let group = projection.groups.first(where: { $0.project.id == workspace.projectID }),
                  !deletingProjectIDs.contains(workspace.projectID),
                  !deletingWorkspaceIDs.contains(workspaceID),
                  !group.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) })
            else { return }
            var params = ["id": workspaceID.description]
            if let before { params["before"] = before.description }
            request("workspace.move", params: params)
        case .moveTab(let tabID, let before):
            moveTab(tabID, before: before)
        case .moveSession(let id, let destination):
            moveSession(id, to: destination)
        case .importSuperset, .requestNewWorkspace, .requestProjectWorktreeImport,
             .requestProjectSetupScript,
             .setProjectAutoImportGitWorktrees, .requestNewSession,
             .toggleSidebar, .openNotifications:
            break
        }
    }

    func resize(
        sessionID: TerminalSessionID,
        columns: Int,
        rows: Int
    ) {
        // A surface reports a grid whenever Ghostty recomputes metrics,
        // including the default surface it is created with before the view has
        // driven a real size. That report arrives asynchronously, so by now the
        // view already matches its pane and only a grid comparison can tell it
        // apart from a real resize. Forwarding it would reflow the running
        // program at the wrong width, which reads as a history replay.
        guard surfaceManager.acceptsReportedGrid(
            sessionID,
            columns: columns,
            rows: rows
        ) else { return }
        guard let size = TerminalSize(columns: columns, rows: rows) else { return }
        requestViewportSize(sessionID: sessionID, size: size)
    }

    /// Asks the Host to size a Session's PTY for its pane.
    func requestViewportSize(sessionID: TerminalSessionID, size: TerminalSize) {
        let columns = size.columns
        let rows = size.rows
        // The selected pane's size belongs to its focus claim while that claim
        // is being established. Routing it through the viewport-only path
        // would race the attach and can queue a bare `session.resize` ahead of
        // `session.subscribe` on the daemon's reader. Only a real sibling pane
        // — never the pane that is about to own focus — uses that path.
        let focusPending = focusClaimInFlight
            || pendingFocusSessionID == sessionID
            || attachedSessionID != sessionID
        if sessionID == selectedSessionID,
           focusedSessionID == sessionID || focusPending {
            resize(columns: columns, rows: rows)
        } else {
            resizePassive(sessionID: sessionID, columns: columns, rows: rows)
        }
    }

    /// Sizes a visible pane that does not own the keyboard lease.
    ///
    /// A split pane has to follow its own viewport even while another pane
    /// holds the input lease. The daemon arbitrates the shared runtime size
    /// independently of input control, so this is safe to send; it is ignored
    /// when another client currently owns the size. A pane must already be
    /// subscribed: a resize before `session.subscribe` is either rejected or
    /// queued ahead of the attach, which is how a slow PTY resize used to leave
    /// the terminal black.
    func resizePassive(
        sessionID: TerminalSessionID,
        columns: Int,
        rows: Int
    ) {
        guard visibleSessionIDs.contains(sessionID),
              outputSubscriptions.contains(sessionID),
              focusedSessionID != sessionID,
              let size = TerminalSize(columns: columns, rows: rows) else { return }
        var buffer = passiveResizeBuffers[sessionID] ?? WarrenResizeRequestBuffer()
        let shouldStart = buffer.offer(size)
        passiveResizeBuffers[sessionID] = buffer
        guard shouldStart, passiveResizeTasks[sessionID] == nil else { return }
        passiveResizeTasks[sessionID] = Task { @MainActor [weak self] in
            await self?.drainPassiveResizeRequests(sessionID: sessionID)
        }
    }

    func drainPassiveResizeRequests(sessionID: TerminalSessionID) async {
        defer { passiveResizeTasks[sessionID] = nil }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(24))
            } catch {
                return
            }
            guard var buffer = passiveResizeBuffers[sessionID],
                  let size = buffer.take(),
                  let wire,
                  visibleSessionIDs.contains(sessionID),
                  outputSubscriptions.contains(sessionID),
                  focusedSessionID != sessionID else {
                return
            }
            buffer.markSent(size)
            passiveResizeBuffers[sessionID] = buffer
            TerminalDiagnostics.log("resize_request", [
                "session": sessionID.description,
                "cols": String(size.columns),
                "rows": String(size.rows),
            ])
            do {
                _ = try await wire.resize(
                    sessionID: sessionID.description,
                    size: size
                )
            } catch is CancellationError {
                return
            } catch {
                // A passive pane's viewport is best-effort: another client may
                // own the shared size, and a failed background resize must not
                // surface as a terminal error over the selected pane.
                return
            }
        }
    }

    func cancelPassiveResizeRequests() {
        for task in passiveResizeTasks.values {
            task.cancel()
        }
        passiveResizeTasks.removeAll()
        passiveResizeBuffers.removeAll()
    }

    func resize(columns: Int, rows: Int) {
        guard let sessionID = selectedSessionID else { return }
        guard let size = TerminalSize(columns: columns, rows: rows) else { return }
        guard attachedSessionID == sessionID, focusedSessionID == sessionID else {
            // The selected pane's size belongs to its focus claim. The very
            // first Ghostty metric can arrive before the attach and while the
            // claim is still in flight, so remember the latest size and let
            // `sendFocus` carry it once ownership is confirmed; sending a bare
            // `session.resize` here would race the attach and can block the
            // daemon's reader behind a slow PTY resize.
            if attachedSessionID != sessionID
                || focusClaimInFlight
                || pendingFocusSessionID == sessionID {
                pendingFocusResizeSize = size
            }
            return
        }
        pendingFocusResizeSize = nil
        guard resizeBuffer.offer(size) else { return }
        guard resizeTask == nil else { return }
        resizeTask = Task { @MainActor [weak self] in
            await self?.drainResizeRequests()
        }
    }

    func drainResizeRequests() async {
        defer { resizeTask = nil }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(24))
            } catch {
                return
            }

            guard let size = resizeBuffer.take(),
                  let wire,
                  let sessionID = selectedSessionID,
                  attachedSessionID == sessionID,
                  focusedSessionID == sessionID else {
                return
            }
            resizeBuffer.markSent(size)
            TerminalDiagnostics.log("resize_request", [
                "session": sessionID.description,
                "cols": String(size.columns),
                "rows": String(size.rows),
            ])
            do {
                _ = try await wire.resize(
                    sessionID: sessionID.description,
                    size: size
                )
            } catch {
                guard !Task.isCancelled,
                      selectedSessionID == sessionID,
                      attachedSessionID == sessionID,
                      focusedSessionID == sessionID else { return }
                present(error)
                return
            }
        }
    }

    func cancelResizeRequests() {
        resizeTask?.cancel()
        resizeTask = nil
        resizeBuffer.reset()
    }

    func focus(sessionID: TerminalSessionID, size: TerminalSize?) {
        guard selectedSessionID == sessionID else { return }
        let measuredSize = size ?? surfaceManager.viewportGrid(for: sessionID)
        guard attachedSessionID == sessionID else {
            pendingFocusSessionID = sessionID
            pendingFocusSize = measuredSize
            return
        }
        sendFocus(
            sessionID: sessionID,
            focused: true,
            size: measuredSize,
            reason: "surfaceFocus"
        )
    }

    /// Reports that the keyboard moved to a surface in this window that is not a
    /// terminal — today the embedded editor region.
    ///
    /// The surface manager reports blur when a pane is parked or its host goes
    /// away, neither of which happens here: the pane stays mounted and attached,
    /// only the keyboard left. Without this the Session is still told it has
    /// focus, so a program that tracks focus keeps drawing an active cursor
    /// while the user types into a document.
    ///
    /// Focus returns on its own. Clicking back into the terminal makes it first
    /// responder, and the manager reports that as a focus claim.
    func relinquishTerminalFocus() {
        guard let sessionID = selectedSessionID else { return }
        blur(sessionID: sessionID)
    }

    func blur(sessionID: TerminalSessionID) {
        // TerminalSurfaceManager reports blur for every pane that is parked
        // or whose host disappears. In a split window a passive sibling must
        // not cancel the selected pane's resize buffer or invalidate its
        // focus-claim generation; those pieces of state belong exclusively
        // to the selected control target.
        guard selectedSessionID == sessionID else {
            if pendingFocusSessionID == sessionID {
                pendingFocusSessionID = nil
                pendingFocusSize = nil
            }
            return
        }
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        pendingFocusResizeSize = nil
        cancelResizeRequests()
        focusClaimInFlight = false
        focusClaimGeneration += 1
        focusTask?.cancel()
        focusedSessionID = nil
        guard attachedSessionID == sessionID else { return }
        sendFocus(sessionID: sessionID, focused: false, size: nil, reason: "surfaceBlur")
    }

    /// Sends the keyboard focus this pane holds to the daemon.
    ///
    /// A terminal application sees these as focus-in/focus-out, and a
    /// full-screen TUI is entitled to repaint its whole interface for one — pi
    /// does, which is why a repaint nobody asked for has to be attributable to a
    /// focus change before it is blamed on rendering. `reason` names the path
    /// that decided the pane holds focus.
    func sendFocus(
        sessionID: TerminalSessionID,
        focused: Bool,
        size: TerminalSize?,
        reason: String
    ) {
        guard let wire,
              selectedSessionID == sessionID,
              attachedSessionID == sessionID else {
            // The report never left. The pane may own the keyboard, but the
            // Host was told nothing, so the latch must not stay closed.
            if focused {
                surfaceManager.noteFocusReportOutcome(sessionID, accepted: false)
            }
            return
        }
        let sizeLabel = focused
            ? size.map { "\($0.columns)x\($0.rows)" } ?? "nil"
            : "nil"
        TerminalDiagnostics.log("terminal_focus_send", [
            "session": sessionID.description,
            "focused": focused ? "true" : "false",
            "size": sizeLabel,
            "reason": reason,
        ])
        focusTask?.cancel()
        focusClaimGeneration += 1
        let generation = focusClaimGeneration
        focusClaimInFlight = focused
        focusTask = Task { @MainActor [weak self, generation] in
            guard let self else { return }
            do {
                // A passive subscription does not populate the daemon's
                // legacy attached pointer. Always include the target session
                // when promoting or releasing its control lease.
                let result = try await wire.focus(
                    sessionID: sessionID.description,
                    focused: focused,
                    size: focused ? size : nil
                )
                guard self.focusClaimGeneration == generation,
                      self.selectedSessionID == sessionID,
                      self.attachedSessionID == sessionID else { return }
                TerminalDiagnostics.log("terminal_focus_sent", [
                    "session": sessionID.description,
                    "focused": focused ? "true" : "false",
                    "reason": reason,
                    "accepted": result.focused ? "true" : "false",
                ])
                self.focusClaimInFlight = false
                if focused {
                    // Only the Host's answer closes the latch. AppKit gave the
                    // pane the keyboard; the Host decides whether a keystroke
                    // is accepted from this client.
                    self.surfaceManager.noteFocusReportOutcome(
                        sessionID,
                        accepted: result.focused
                    )
                    self.focusedSessionID = result.focused ? sessionID : nil
                    if let pending = self.pendingFocusResizeSize {
                        self.pendingFocusResizeSize = nil
                        self.resize(columns: pending.columns, rows: pending.rows)
                    }
                } else if self.focusedSessionID == sessionID {
                    self.focusedSessionID = nil
                }
            } catch is CancellationError {
                // A newer report owns the latch and will record its own answer.
                return
            } catch {
                guard self.focusClaimGeneration == generation,
                      self.selectedSessionID == sessionID,
                      self.attachedSessionID == sessionID else { return }
                self.focusClaimInFlight = false
                if focused {
                    self.surfaceManager.noteFocusReportOutcome(sessionID, accepted: false)
                }
                self.present(error)
            }
        }
    }

    func report(_ error: Error) { present(error) }

    /// Writes one local arrangement back to the Host.
    ///
    /// The Host owns the shape, so this is a request rather than a store: a
    /// scope the Host has no group for is created around the tree's first
    /// Session, and every later edit is one tree replacement under the revision
    /// the roster reported. A rejected edit is not fatal: the roster's answer
    /// replaces the optimistic local value on the next update.
    func commitPaneTree(
        owner: WarrenDesktopPaneOwner,
        tree: PaneNode,
        target: WarrenDesktopPaneGroupTarget
    ) {
        guard let wire else { return }
        guard let workspaceID = owner.workspaceID?.description else { return }
        Task { @MainActor [weak self, wire] in
            guard let self, self.wire === wire else { return }
            // A Host that does not advertise the capability owns no
            // arrangements, so a write would be an unknown method rather than a
            // rejected tree. The read side needs no gate: an old Host has no
            // groups to project, and the scope renders its selected Tab alone.
            guard await wire.supportsCapability("pane-groups-v1") else {
                TerminalDiagnostics.log("pane_update_skipped", ["reason": "noCapability"])
                return
            }
            do {
                let groupID: String
                let revision: UInt64
                switch target {
                case .group(let id):
                    // A scope can hold several arrangements, so the window names
                    // the one it renders. Reaching for the scope's first group
                    // here would edit an arrangement that is not on screen.
                    guard let existing = self.projection.paneGroups.first(where: { $0.id == id }) else {
                        TerminalDiagnostics.log("pane_update_skipped", ["reason": "groupGone"])
                        await self.refreshRosterAfterDeltaMismatch(using: wire)
                        return
                    }
                    groupID = existing.id.description
                    revision = existing.revision
                case .newGroup:
                    // A new arrangement is opened around the tree's first
                    // Session, then given its full shape in one follow-up write
                    // under the revision create returned. Naming the revision
                    // here keeps the two writes off each other's CAS token,
                    // which two updates of one group could not do.
                    guard let sessionID = tree.sessionIDs.first else { return }
                    TerminalDiagnostics.log("pane_group_create", ["panes": String(tree.paneCount)])
                    let params: [String: Any] = [
                        "session": sessionID.description,
                        "workspace": workspaceID,
                    ]
                    let created: RemoteRoster.PaneGroup = try await wire.request(
                        "pane-group.create",
                        jsonParams: params,
                        decoding: RemoteRoster.PaneGroup.self
                    )
                    groupID = created.id
                    revision = created.revision ?? 0
                }
                let encoded = try JSONEncoder().encode(tree)
                let treeObject = try JSONSerialization.jsonObject(with: encoded)
                _ = try await wire.request(
                    "pane-group.update",
                    jsonParams: [
                        "id": groupID,
                        "tree": treeObject,
                        "expectedRevision": revision,
                    ]
                )
                TerminalDiagnostics.log("pane_update_accepted", [
                    "group": String(groupID.prefix(8)),
                    "expectedRevision": String(revision),
                    "panes": String(tree.paneCount),
                ])
                // The mutation is accepted, so the next roster delta carries the
                // Host's version of the tree. Nothing is cached locally.
            } catch {
                // A rejected write was invisible before this: the roster simply
                // kept the old arrangement and the split read as a no-op.
                TerminalDiagnostics.log("pane_update_rejected", [
                    "panes": String(tree.paneCount),
                    "error": String(error.localizedDescription.prefix(200)),
                ])
                // A revision conflict means another client shaped the same
                // arrangement first. Re-reading the roster is the whole
                // recovery: the Host's version is already authoritative.
                await self.refreshRosterAfterDeltaMismatch(using: wire)
            }
        }
    }

    func reportActiveScreenSessions(_ sessions: Set<TerminalSessionID>) {
        // The Desktop callback intentionally exposes a Set, so sort before
        // sending it to keep `session.current` and CLI output stable across
        // Swift hash-seed changes.
        let joined = sessions
            .sorted { $0.description < $1.description }
            .map(\.rawValue.uuidString)
            .joined(separator: ",")
        lastReportedScreenSessions = sessions
        guard let wire else { return }
        sendScreenReport(sessions, joined: joined, using: wire)
    }

    func sendScreenReport(
        _ sessions: Set<TerminalSessionID>,
        using wire: WarrenRemoteClient
    ) {
        let joined = sessions
            .sorted { $0.description < $1.description }
            .map(\.rawValue.uuidString)
            .joined(separator: ",")
        sendScreenReport(sessions, joined: joined, using: wire)
    }

    func sendScreenReport(
        _ sessions: Set<TerminalSessionID>,
        joined: String,
        using wire: WarrenRemoteClient
    ) {
        Task { @MainActor [weak self, wire] in
            guard let self, self.wire === wire,
                  self.lastReportedScreenSessions == sessions else { return }
            do {
                _ = try await wire.request("screen.report", params: ["sessions": joined])
            } catch {
                // Background report; fail silently
            }
        }
    }

    func addNotice(
        title: String,
        message: String,
        detail: String? = nil,
        kind: WarrenDesktopNotice.Kind = .info
    ) {
        notices.insert(
            WarrenDesktopNotice(
                kind: kind,
                title: title,
                message: message,
                detail: detail
            ),
            at: 0
        )
        if notices.count > 50 {
            notices.removeLast(notices.count - 50)
        }
    }

    func markNoticeRead(_ id: WarrenDesktopNotice.ID) {
        guard let index = notices.firstIndex(where: { $0.id == id }) else { return }
        guard notices[index].isUnread else { return }
        notices[index].isUnread = false
    }

    func dismissNotice(_ id: WarrenDesktopNotice.ID) {
        notices.removeAll { $0.id == id }
    }

    nonisolated static func diagnosticText(
        error: Error,
        endpoint: String? = nil,
        selectedSessionID: TerminalSessionID? = nil,
        attachedSessionID: TerminalSessionID? = nil,
        focusedSessionID: TerminalSessionID? = nil,
        now: Date = Date()
    ) -> String {
        WarrenRemoteDiagnostics.text(
            error: error,
            endpoint: endpoint,
            selectedSessionID: selectedSessionID,
            attachedSessionID: attachedSessionID,
            focusedSessionID: focusedSessionID,
            now: now
        )
    }

    func request(
        _ method: String,
        params: [String: String] = [:],
        onError: (@MainActor (Error) -> Void)? = nil
    ) {
        guard let wire else {
            let error = NSError(
                domain: "WarrenRemote",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected to the Warren daemon. Check the menu bar status and try again."]
            )
            if let onError {
                onError(error)
            } else {
                present(error)
            }
            return
        }
        Task { @MainActor [weak self] in
            do { _ = try await wire.request(method, params: params) }
            catch {
                if let onError {
                    onError(error)
                } else {
                    self?.present(error)
                }
            }
        }
    }

    func deleteProject(_ id: ProjectID) {
        guard let wire,
              let group = projection.groups.first(where: { $0.project.id == id }),
              !group.workspaces.contains(where: { deletingWorkspaceIDs.contains($0.id) }),
              deletingProjectIDs.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("project.remove", params: [
                    "id": id.description,
                    "force": "true",
                ])
            } catch {
                guard let self else { return }
                if Self.isRemoteRequestOutcomeUnknown(error) {
                    if self.wire === wire {
                        self.ensureDeletionReconciliation(using: wire)
                    }
                } else {
                    self.deletingProjectIDs.remove(id)
                    if self.wire === wire {
                        self.present(error)
                    }
                }
                return
            }
            // Keep the row busy until an authoritative roster confirms that
            // the project is gone. The helper also retries when the refresh
            // itself times out.
            guard let self, self.wire === wire else { return }
            self.ensureDeletionReconciliation(using: wire)
        }
    }

    func deleteWorkspace(_ id: WorkspaceID, removeLocalWorktree: Bool) {
        guard let wire,
              let workspace = projection.workspace(id: id),
              !deletingProjectIDs.contains(workspace.projectID),
              deletingWorkspaceIDs.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("workspace.remove", params: [
                    "id": id.description,
                    "force": "true",
                    "remove_worktree": String(removeLocalWorktree),
                ])
            } catch {
                guard let self else { return }
                if Self.isRemoteRequestOutcomeUnknown(error) {
                    if self.wire === wire {
                        self.ensureDeletionReconciliation(using: wire)
                    }
                } else {
                    self.deletingWorkspaceIDs.remove(id)
                    if self.wire === wire {
                        self.present(error)
                    }
                }
                return
            }
            // Keep the row busy until an authoritative roster confirms that
            // the workspace is gone. The helper also retries when the refresh
            // itself times out.
            guard let self, self.wire === wire else { return }
            self.ensureDeletionReconciliation(using: wire)
        }
    }

    func closeSession(_ id: TerminalSessionID) {
        detachSessionBeingClosed(id)
        request("session.delete", params: ["id": id.description]) { [weak self] error in
            guard let self else { return }
            if Self.isSessionAlreadyClosed(error, sessionID: id) {
                // The tab may already have been closed by a previous action or
                // another client before its roster update arrived. A stale
                // close is a successful no-op, matching the local model's
                // closeTabIfPresent behavior; it must not create a notice.
                Task { await self.refreshRosterIfConnected() }
            } else {
                self.present(error)
            }
        }
    }

    func moveSession(
        _ id: TerminalSessionID,
        to destination: WarrenDesktopSessionMoveDestination
    ) {
        guard let wire else { return }
        let wasSelected = navigation.selectedTabID == Self.tabID(id)
        var params = ["id": id.description]
        switch destination {
        case .workspace(let workspaceID):
            params["workspace"] = workspaceID.description
        }
        Task { @MainActor [weak self] in
            do {
                _ = try await wire.request("session.move", params: params)
                guard let self else { return }
                try await self.refreshRoster(using: wire)
                guard wasSelected else { return }
                // The roster has already moved the tab into the destination
                // context; selecting the same tab now transfers navigation
                // (sidebar selection and active tab) with the UI.
                self.publishNavigationIfChanged(
                    WarrenDesktopNavigationReducer.reduce(
                        self.navigation,
                        action: .selectTab(Self.tabID(id)),
                        in: self.projection
                    )
                )
                await self.presentSelectedSession()
            } catch {
                self?.present(error)
            }
        }
    }

    /// Releases the local attachment as soon as a session is being closed.
    ///
    /// SwiftUI can demote the terminal view while the delete request is still
    /// in flight, which makes the host call `blur` for the same session. If the
    /// daemon has already removed the session by then, that stale focus request
    /// fails with "no attached session" and would create a notice during
    /// normal tab churn. Clearing attachment state first
    /// keeps the blur, attach, resize, and focus paths inert for the closed
    /// session; the roster still owns the durable cleanup.
    func detachSessionBeingClosed(_ id: TerminalSessionID) {
        guard selectedSessionID == id else { return }
        attachingSessionID = nil
        selectedSessionID = nil
        attachedSessionID = nil
        focusedSessionID = nil
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        pendingFocusResizeSize = nil
        focusClaimInFlight = false
        focusClaimGeneration += 1
        attachGeneration &+= 1
        inputRouter.discard(for: id)
        cancelResizeRequests()
        focusTask?.cancel()
        focusTask = nil
    }

    func refreshRosterIfConnected() async {
        guard let wire else { return }
        try? await refreshRoster(using: wire)
    }

    func clearDeletionState() {
        stopDeletionReconciliation()
        deletingProjectIDs.removeAll()
        deletingWorkspaceIDs.removeAll()
    }

    func stopDeletionReconciliation() {
        deletionReconciliationTask?.cancel()
        deletionReconciliationTask = nil
        deletionReconciliationWire = nil
    }

    var hasPendingDeletion: Bool {
        !deletingProjectIDs.isEmpty || !deletingWorkspaceIDs.isEmpty
    }

    func ensureDeletionReconciliation(using wire: WarrenRemoteClient) {
        guard self.wire === wire, hasPendingDeletion else { return }
        if deletionReconciliationWire === wire, deletionReconciliationTask != nil {
            return
        }
        deletionReconciliationTask?.cancel()
        deletionReconciliationWire = wire
        deletionReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconcilePendingDeletions(using: wire)
            guard self.deletionReconciliationWire === wire else { return }
            self.deletionReconciliationTask = nil
            self.deletionReconciliationWire = nil
        }
    }

    func reconcilePendingDeletions(using wire: WarrenRemoteClient) async {
        let deadline = ContinuousClock.now.advanced(by: Self.deletionReconciliationTimeout)
        var delayMilliseconds = 500
        while !Task.isCancelled,
              self.wire === wire,
              hasPendingDeletion {
            guard ContinuousClock.now < deadline else {
                deletingProjectIDs.removeAll()
                deletingWorkspaceIDs.removeAll()
                present(NSError(domain: "WarrenRemote", code: 14, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Deletion did not finish within 30 seconds. Refresh the roster and try again.",
                ]))
                return
            }
            do {
                try await refreshRoster(using: wire)
            } catch is CancellationError {
                return
            } catch {
                // A timeout here does not prove that the deletion failed. Keep
                // the row unavailable and retry the read-only reconciliation.
            }
            guard !Task.isCancelled,
                  self.wire === wire,
                  hasPendingDeletion else { return }
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            delayMilliseconds = min(delayMilliseconds * 2, 15_000)
        }
    }

    nonisolated static func isSessionAlreadyClosed(
        _ error: Error,
        sessionID: TerminalSessionID
    ) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "WarrenRemote"
            && nsError.code == 1
            && nsError.localizedDescription == "session not found: \(sessionID)"
    }

    nonisolated static func reconcileDeletionIDs<T: Hashable>(
        _ pending: Set<T>,
        against live: Set<T>
    ) -> Set<T> {
        pending.intersection(live)
    }

    nonisolated static func shouldApplyRoster(
        startedAt generation: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        generation == currentGeneration
    }

    nonisolated static func isRemoteRequestOutcomeUnknown(_ error: Error) -> Bool {
        isTransportFailure(error as NSError)
    }

    nonisolated static func isTransportFailure(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain {
            // URLSession occasionally surfaces a dropped WebSocket as a raw
            // POSIX error instead of an NSURLError. These are all expected
            // while the daemon is restarting or the client is reconnecting.
            switch error.code {
            case 32, 50, 51, 54, 57, 60, 61, 65:
                return true
            default:
                break
            }
        }
        switch URLError.Code(rawValue: error.code) {
        case .cancelled,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .resourceUnavailable,
             .secureConnectionFailed,
             .timedOut:
            return true
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
                return false
            }
            return isTransportFailure(underlying)
        }
    }

    /// Writes a rejected atomic snapshot next to the terminal diagnostics log.
    /// The daemon only serves the current terminal state, so without this file
    /// the exact failing bytes are unrecoverable after a reconnect re-captures
    /// a new boundary. Bounded so a failing session cannot fill the disk.
    func persistRejectedSnapshot(
        sessionID: TerminalSessionID,
        payload: Data
    ) {
        let directory = URL(
            fileURLWithPath: NSHomeDirectory()
                .appending("/Library/Logs/Warren/failed-snapshots")
        )
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter {
                $0.lastPathComponent.hasSuffix(".bin")
            }
            if existing.count >= 10 {
                for file in existing.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                .prefix(existing.count - 9) {
                    try? fm.removeItem(at: file)
                }
            }
            let name = "\(Int(Date().timeIntervalSince1970))-\(sessionID.description).bin"
            try payload.write(to: directory.appendingPathComponent(name), options: .atomic)
            TerminalDiagnostics.log("atomic_rejected_snapshot_dumped", [
                "session": sessionID.description,
                "bytes": String(payload.count),
                "file": name,
            ])
        } catch {
            TerminalDiagnostics.log("atomic_rejected_snapshot_dump_failed", [
                "session": sessionID.description,
                "error": String(describing: error),
            ])
        }
    }

    func failAtomicRecovery(
        sessionID: TerminalSessionID,
        reason: String,
        closeWire: Bool = false
    ) {
        TerminalDiagnostics.log("atomic_recovery_failed", [
            "session": sessionID.description,
            "reason": reason,
        ])
        clearAtomicRecoveryState(for: sessionID)
        installedAtomicStateAnchors.removeValue(forKey: sessionID)
        failedAtomicRecoverySessions.insert(sessionID)
        reconnectPreservedSessions.remove(sessionID)
        guard closeWire else { return }
        Task { [wire] in await wire?.stop() }
    }

    func scheduleAtomicRecoveryRetry(for sessionID: TerminalSessionID) {
        recoveryRetryTasks[sessionID]?.cancel()
        let generation = recoveryRetryGenerations[sessionID, default: 0] &+ 1
        recoveryRetryGenerations[sessionID] = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryRetryGenerations[sessionID] == generation {
                    self.recoveryRetryTasks.removeValue(forKey: sessionID)
                }
            }

            while !Task.isCancelled,
                  self.recoveryRetryGenerations[sessionID] == generation {
                guard let pending = self.pendingAtomicRecoveries[sessionID] else {
                    return
                }
                if self.surfaceManager.isActive(sessionID) {
                    // The selected surface follows the cold-attach path: fit
                    // the view and wait for full presentability before
                    // installing so the snapshot lands into a sized grid.
                    guard self.surfaceManager.prepareForRecovery(sessionID) else {
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return
                        }
                        continue
                    }
                    guard self.surfaceManager.isReadyForRecovery(sessionID) else {
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return
                        }
                        continue
                    }
                } else {
                    // The user switched away before this snapshot could be
                    // installed. The warm surface keeps its native Ghostty
                    // surface ready off-screen (and its output subscription
                    // live), so install the bytes now without requiring the
                    // tab to be active — otherwise the retry loop spins until
                    // the user switches back, leaving the tab black on the
                    // next visit. Pixel presentation is still gated by
                    // schedulePresent on the next activation.
                    guard self.surfaceManager.isReadyToInstallRecovery(sessionID) else {
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return
                        }
                        continue
                    }
                }

                let restoreResult = self.surfaceManager.restoreSnapshotResult(
                    pending.payload,
                    for: sessionID,
                    epoch: pending.epoch,
                    sequence: pending.sequence
                )
                guard restoreResult == .restored else {
                    if restoreResult == .feedBusy {
                        do {
                            try await Task.sleep(for: .milliseconds(16))
                        } catch {
                            return
                        }
                        continue
                    }
                    guard restoreResult == .rejected else {
                        // The snapshot is valid; only the runtime config could
                        // not be reapplied. Retry config until it lands or the
                        // generation changes. A successful later install must
                        // still be recorded, but never treat this as a bad
                        // snapshot.
                        if self.recoveryRetryGenerations[sessionID] == generation {
                            try? await Task.sleep(for: .milliseconds(50))
                            continue
                        }
                        return
                    }
                    // At this point all lifecycle prerequisites are true, so
                    // a failure means the Ghostline payload itself is invalid
                    // rather than a cold-mount race. Persist the exact payload
                    // before reconnecting so a later recurrence can be
                    // reproduced offline against the same bytes.
                    self.persistRejectedSnapshot(
                        sessionID: sessionID,
                        payload: pending.payload
                    )
                    self.failAtomicRecovery(
                        sessionID: sessionID,
                        reason: "native snapshot rejected after surface became ready",
                        closeWire: true
                    )
                    return
                }

                // The readiness waits above let a newer install for this
                // Session run; the payload captured at the top of the loop is
                // then stale and must not replace the grid a second time.
                guard self.pendingAtomicRecoveries[sessionID]?.epoch == pending.epoch,
                      self.pendingAtomicRecoveries[sessionID]?.sequence == pending.sequence else {
                    return
                }

                let anchor = TerminalOutputAnchor(
                    epoch: pending.epoch,
                    sequence: pending.sequence
                )
                self.pendingAtomicRecoveries.removeValue(forKey: sessionID)
                self.installedAtomicStateAnchors[sessionID] = anchor
                self.noteRecoveryPayloadInstalled(sessionID)
                TerminalDiagnostics.log("atomic_recovery_installed", [
                    "session": sessionID.description,
                    "epoch": String(pending.epoch),
                    "sequence": String(pending.sequence),
                    "bytes": String(pending.payload.count),
                    "retry": "true",
                ])
                self.finishAtomicRecoveryIfSynced(sessionID: sessionID, anchor: anchor)
                return
            }
        }
        recoveryRetryTasks[sessionID] = task
    }

    func installAtomicRecovery(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        format: String,
        payload: Data
    ) -> Bool {
        guard format == "ghostty-vt-snapshot-v1" else {
            failAtomicRecovery(
                sessionID: sessionID,
                reason: "unsupported format \(format)"
            )
            return false
        }
        supersedePendingAtomicRecovery(sessionID: sessionID, epoch: epoch, sequence: sequence)
        guard surfaceManager.restoreSnapshot(
            payload,
            for: sessionID,
            epoch: epoch,
            sequence: sequence
        ) else {
            pendingAtomicRecoveries[sessionID] = PendingAtomicRecovery(
                epoch: epoch,
                sequence: sequence,
                format: format,
                payload: payload
            )
            if surfaceManager.surface(for: sessionID) != nil {
                surfaceManager.beginRecovery(
                    for: sessionID,
                    preservingDisplay: reconnectPreservedSessions.contains(sessionID)
                )
            }
            TerminalDiagnostics.log("atomic_recovery_deferred", [
                "session": sessionID.description,
                "epoch": String(epoch),
                "sequence": String(sequence),
                "bytes": String(payload.count),
                "surfaceReady": surfaceManager.isReadyForRecovery(sessionID) ? "true" : "false",
            ])
            scheduleAtomicRecoveryRetry(for: sessionID)
            return false
        }
        let anchor = TerminalOutputAnchor(epoch: epoch, sequence: sequence)
        pendingAtomicRecoveries.removeValue(forKey: sessionID)
        installedAtomicStateAnchors[sessionID] = anchor
        noteRecoveryPayloadInstalled(sessionID)
        TerminalDiagnostics.log("atomic_recovery_installed", [
            "session": sessionID.description,
            "epoch": String(epoch),
            "sequence": String(sequence),
            "bytes": String(payload.count),
        ])
        finishAtomicRecoveryIfSynced(sessionID: sessionID, anchor: anchor)
        return true
    }

    /// Drops a deferred install for this Session that a newer state replaces.
    ///
    /// A background seed installs no snapshot while its pane is unmounted, so
    /// the payload waits in `pendingAtomicRecoveries` for a retry. When the user
    /// then selects that Session, the attach delivers the same state again and
    /// the retry would install the earlier copy too, replacing the grid twice
    /// and repainting the whole pane twice for one state. Anything the retry
    /// still holds is redundant once the same or a newer state installs, so
    /// cancel it.
    func supersedePendingAtomicRecovery(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64
    ) {
        guard let pending = pendingAtomicRecoveries[sessionID] else { return }
        let superseded = pending.epoch < epoch
            || (pending.epoch == epoch && pending.sequence <= sequence)
        guard superseded else { return }
        pendingAtomicRecoveries.removeValue(forKey: sessionID)
        recoveryRetryGenerations[sessionID, default: 0] &+= 1
        recoveryRetryTasks.removeValue(forKey: sessionID)?.cancel()
        TerminalDiagnostics.log("atomic_recovery_superseded", [
            "session": sessionID.description,
            "pendingEpoch": String(pending.epoch),
            "pendingSequence": String(pending.sequence),
            "epoch": String(epoch),
            "sequence": String(sequence),
        ])
    }

    @discardableResult
    func finishAtomicRecoveryIfSynced(
        sessionID: TerminalSessionID,
        anchor: TerminalOutputAnchor
    ) -> Bool {
        guard let synced = pendingSyncedAnchors.removeValue(forKey: sessionID) else {
            return false
        }
        guard synced == anchor else {
            failAtomicRecovery(
                sessionID: sessionID,
                reason: "synced marker did not match delayed snapshot"
            )
            return false
        }
        installedAtomicStateAnchors.removeValue(forKey: sessionID)
        surfaceManager.endRecovery(for: sessionID)
        reconnectPreservedSessions.remove(sessionID)
        if selectedSessionID == sessionID {
            initialRefreshPending = false
        }
        return true
    }

    @MainActor
    func consume(_ event: WarrenRemoteEvent) async {
        switch event {
        case .connection(let state):
            switch state {
            case .connected:
                connectionError = nil
                isMigratingRuntimeSessions = false
                cancelTransientConnectionIssue()
                clearMaintenance()
                // The handshake comes before the roster, and a Host that has
                // just started can take seconds to build its first one. Until
                // that roster lands the empty projection is not a fact: calling
                // it attached drew "Add Project" over a Host full of projects.
                // A reconnect already holds the last roster, so it attaches now.
                if currentRoster != nil {
                    publishProjectionIfChanged(projection.withConnectionState(.attached))
                }
            case .reconnecting, .connecting:
                if isLocalEndpoint {
                    refreshLocalRuntimeMigrationStatus()
                } else {
                    isMigratingRuntimeSessions = false
                }
                publishProjectionIfChanged(projection.withConnectionState(.reconnecting))
            case .disconnected:
                publishProjectionIfChanged(projection.withConnectionState(.disconnected))
            case .stopped:
                break
            }
        case .welcome:
            break
        case .roster(let remoteRoster):
            guard let roster = decodeApplicationRoster(remoteRoster) else { return }
            guard let wire else { return }
            cancelTransientConnectionIssue()
            clearMaintenance()
            guard Self.shouldApplyRoster(roster, after: currentRoster) else {
                ensureDeletionReconciliation(using: wire)
                publishProjectionIfChanged(projection.withConnectionState(.attached))
                scheduleRetainedSurfaceRebind()
                return
            }
            currentRoster = roster
            await syncAgentSubscriptions(using: wire, roster: roster)
            apply(roster)
            ensureDeletionReconciliation(using: wire)
            scheduleRetainedSurfaceRebind()
        case .rosterDelta(let remoteDelta):
            guard let delta = decodeApplicationRosterDelta(remoteDelta) else { return }
            guard let wire else { return }
            guard let current = currentRoster else {
                await refreshRosterAfterDeltaMismatch(using: wire)
                return
            }
            if let revision = current.revision, delta.baseRevision < revision {
                scheduleRetainedSurfaceRebind()
                return
            }
            guard let roster = current.applying(delta) else {
                await refreshRosterAfterDeltaMismatch(using: wire)
                return
            }
            cancelTransientConnectionIssue()
            clearMaintenance()
            guard Self.shouldApplyRoster(roster, after: currentRoster) else { return }
            currentRoster = roster
            await syncAgentSubscriptions(using: wire, roster: roster)
            apply(roster)
            ensureDeletionReconciliation(using: wire)
            scheduleRetainedSurfaceRebind()
        case .agentEvents(let streamID, _, let events):
            await receiveAgentEvents(events, streamID: streamID, using: wire)
        case .output(let frame):
            guard let sessionID = TerminalSessionID(uuidString: frame.sessionID) else { return }
            await consumeOutput(
                sessionID: sessionID,
                epoch: frame.epoch,
                sequence: frame.sequence,
                payload: frame.payload
            )
        case .atomicState(let state):
            guard let sessionID = TerminalSessionID(uuidString: state.sessionID) else { return }
            consumeAtomicState(
                sessionID: sessionID,
                epoch: state.epoch,
                sequence: state.sequence,
                format: state.format,
                payload: state.payload
            )
        case .browserFrame(let frame):
            guard let sessionID = TerminalSessionID(uuidString: frame.sessionID) else { return }
            consumeBrowserFrame(
                sessionID: sessionID,
                epoch: frame.epoch,
                sequence: frame.sequence,
                payload: frame.payload
            )
        case .anchor(let anchor):
            guard let sessionID = TerminalSessionID(uuidString: anchor.sessionID) else { return }
            if !anchor.synced {
                // The size at a new anchor must be in place before its
                // snapshot installs. An attachment without one returns the grid
                // to the pane.
                surfaceManager.setHostGrid(
                    anchor.grid.flatMap { TerminalSize(columns: $0.columns, rows: $0.rows) },
                    for: sessionID
                )
            }
            consumeAnchor(
                sessionID: sessionID,
                epoch: anchor.epoch,
                sequence: anchor.sequence,
                reanchor: anchor.reanchor,
                synced: anchor.synced
            )
        case .terminalResized(let resize):
            guard let sessionID = TerminalSessionID(uuidString: resize.sessionID),
                  let grid = TerminalSize(columns: resize.grid.columns, rows: resize.grid.rows)
            else { return }
            surfaceManager.enqueueGridChange(
                grid,
                for: sessionID,
                epoch: resize.epoch,
                sequence: resize.sequence
            )
        case .recoveryFailed(let sessionIDString, let reason):
            guard let sessionID = TerminalSessionID(uuidString: sessionIDString) else { return }
            handleRecoveryFailed(sessionID, reason: reason)
        case .focusTaken(let sessionIDString, _):
            guard let sessionID = TerminalSessionID(uuidString: sessionIDString) else { return }
            TerminalDiagnostics.log("focus_taken", [
                "session": sessionID.description,
                "selected": selectedSessionID == sessionID ? "true" : "false",
            ])
            surfaceManager.noteFocusLeaseTaken(sessionID)
            if focusedSessionID == sessionID {
                // The Host says another peer holds the lease. Keep the resize
                // routing honest until either the re-claim lands or the event
                // for a hand-back arrives.
                focusedSessionID = nil
            }
        case .focusGranted(let sessionIDString, _):
            guard let sessionID = TerminalSessionID(uuidString: sessionIDString) else { return }
            TerminalDiagnostics.log("focus_granted", [
                "session": sessionID.description,
                "selected": selectedSessionID == sessionID ? "true" : "false",
            ])
            surfaceManager.noteFocusLeaseGranted(sessionID)
            if selectedSessionID == sessionID, attachedSessionID == sessionID {
                focusedSessionID = sessionID
                if let pending = pendingFocusResizeSize {
                    pendingFocusResizeSize = nil
                    resize(columns: pending.columns, rows: pending.rows)
                }
            }
        case .inputRejected(let sessionIDString, let attachmentID, let message):
            // The Host refused a keystroke. Until we claimed it silently
            // vanished; make it traceable and attribute it to its Session.
            TerminalDiagnostics.log("input_rejected", [
                "session": sessionIDString ?? "nil",
                "attachment": attachmentID ?? "nil",
                "error": message,
                "selected": sessionIDString == selectedSessionID?.description ? "true" : "false",
            ])
        case .maintenance(let message):
            consumeMaintenance(message)
        case .disconnected(let reason):
            connectionError = reason
            scheduleTransientConnectionIssue(NSError(
                domain: "WarrenRemote",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: reason]
            ))
        case .hostAbsent(let detail):
            // Relay already waited for the Host before telling us it is absent,
            // so this is a confirmed absence rather than a flap: say it now
            // instead of sitting through the transient-issue delay.
            connectionError = detail
            cancelTransientConnectionIssue()
            presentDiagnostic(NSError(
                domain: "WarrenRemote",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            ))
        case .credentialsRejected(let detail):
            // The connection loop has already failed the connection; keep the
            // reason for the Host popover.
            connectionError = detail
        }
    }

    func applyAgentProjection(_ status: AgentStatus, for sessionID: TerminalSessionID) {
            conversationFeeds[sessionID]?.status = status
            drainConversationQueue(sessionID)
            let previousActivity = lastObservedActivityBySessionID[sessionID]
            lastObservedActivityBySessionID[sessionID] = status.activity
            if status.activity == .ready, previousActivity != .ready {
                activityUpdatedAtBySessionID[sessionID] = Date()
            }
            agentStatusBySessionID[sessionID] = status
            // The Agent moved, so any completion notice this person read is now
            // about a previous state. Dropping it here is what lets a second
            // completion light up instead of being swallowed by the first one's
            // acknowledgment.
            if activityAcknowledgments.invalidate(
                sessionID: sessionID,
                currentActivity: status.activity
            ) {
                persistActivityAcknowledgments()
            }
            // Activity events are live updates and should not wait for the
            // next roster tick. The roster remains authoritative when it is
            // applied, so a stale event cache cannot overwrite a newer
            // server snapshot later.
            publishProjectionIfChanged(
                projection.withSessionAgentStatus(
                    status,
                    activityUpdatedAt: activityUpdatedAtBySessionID[sessionID],
                    acknowledgedActivity: activityAcknowledgments[sessionID],
                    for: sessionID
                )
            )
    }

    func consumeMaintenance(_ message: String?) {
            maintenanceMessage = message?.isEmpty == false ? message : "Warren is updating"
            maintenanceResetTask?.cancel()
            // Safety net for an announcement without a restart: the banner
            // clears on the next roster once the daemon is back, and after a
            // bounded timeout so an aborted update cannot linger forever.
            maintenanceResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.clearMaintenance()
            }
    }

    func consumeOutput(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        payload: Data
    ) async {
            if !suppressFramedAnchorUpdates.contains(sessionID) {
                let endSequence = sequence + UInt64(payload.count)
                if let current = outputAnchors[sessionID] {
                    if epoch > current.epoch
                        || (epoch == current.epoch && endSequence > current.sequence) {
                        outputAnchors[sessionID] = TerminalOutputAnchor(
                            epoch: epoch,
                            sequence: endSequence
                        )
                    }
                } else {
                    outputAnchors[sessionID] = TerminalOutputAnchor(
                        epoch: epoch,
                        sequence: endSequence
                    )
                }
            }
            await feedOutput(
                payload,
                sessionID: sessionID,
                epoch: epoch,
                sequence: sequence
            )
    }

    func consumeBrowserFrame(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        payload: Data
    ) {
        browserFrameStore.install(
            sessionID: sessionID,
            frame: WarrenBrowserFrame(
                epoch: epoch,
                sequence: sequence,
                format: WarrenRemoteClient.browserFrameFormat,
                payload: payload
            )
        )
    }

    func consumeAtomicState(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        format: String,
        payload: Data
    ) {
        _ = installAtomicRecovery(
                sessionID: sessionID,
                epoch: epoch,
                sequence: sequence,
                format: format,
                payload: payload
            )
    }

    func consumeAnchor(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        reanchor: Bool,
        synced: Bool
    ) {
            TerminalDiagnostics.log("recovery_anchor", [
                "session": sessionID.description,
                "reanchor": reanchor ? "true" : "false",
                "epoch": String(epoch),
                "sequence": String(sequence),
                "surface": surfaceManager.surface(for: sessionID) != nil ? "retained" : "absent",
            ])
            if !synced {
                failedAtomicRecoverySessions.remove(sessionID)
                clearAtomicRecoveryState(for: sessionID)
                installedAtomicStateAnchors.removeValue(forKey: sessionID)
                suppressFramedAnchorUpdates.insert(sessionID)
                if surfaceManager.surface(for: sessionID) != nil {
                    surfaceManager.beginRecovery(
                        for: sessionID,
                        preservingDisplay: reconnectPreservedSessions.contains(sessionID)
                    )
                    TerminalDiagnostics.log("recovery_stage_start", [
                        "session": sessionID.description,
                        "mode": "atomic",
                    ])
                }
            } else {
                suppressFramedAnchorUpdates.remove(sessionID)
                guard !failedAtomicRecoverySessions.contains(sessionID) else {
                    TerminalDiagnostics.log("atomic_recovery_marker_ignored", [
                        "session": sessionID.description,
                        "epoch": String(epoch),
                        "sequence": String(sequence),
                    ])
                    return
                }
                let syncedAnchor = TerminalOutputAnchor(epoch: epoch, sequence: sequence)
                if let pending = pendingAtomicRecoveries[sessionID] {
                    // A direct reader may emit the synced marker before the
                    // native surface has finished attaching. Keep both
                    // pieces until the retry installs the matching snapshot;
                    // presenting now would reveal an empty/black surface.
                    guard pending.epoch == epoch, pending.sequence == sequence else {
                        failAtomicRecovery(
                            sessionID: sessionID,
                            reason: "synced marker did not match pending snapshot"
                        )
                        return
                    }
                    pendingSyncedAnchors[sessionID] = syncedAnchor
                    scheduleAtomicRecoveryRetry(for: sessionID)
                    return
                }
                guard let installedAnchor = installedAtomicStateAnchors.removeValue(forKey: sessionID) else {
                    failAtomicRecovery(
                        sessionID: sessionID,
                        reason: "recovery marker arrived without an installed snapshot"
                    )
                    return
                }
                if installedAnchor != syncedAnchor {
                    TerminalDiagnostics.log("atomic_recovery_marker_mismatch", [
                        "session": sessionID.description,
                        "installed": "\(installedAnchor.epoch):\(installedAnchor.sequence)",
                        "synced": "\(epoch):\(sequence)",
                    ])
                    failAtomicRecovery(sessionID: sessionID, reason: "synced marker did not match installed snapshot")
                    return
                }
                surfaceManager.endRecovery(for: sessionID)
                reconnectPreservedSessions.remove(sessionID)
                if selectedSessionID == sessionID { initialRefreshPending = false }
            }
            if let current = outputAnchors[sessionID] {
                if epoch > current.epoch
                    || (epoch == current.epoch && sequence > current.sequence) {
                    outputAnchors[sessionID] = TerminalOutputAnchor(
                        epoch: epoch,
                        sequence: sequence
                    )
                }
            } else {
                outputAnchors[sessionID] = TerminalOutputAnchor(
                    epoch: epoch,
                    sequence: sequence
                )
            }
    }

    func syncAgentSubscriptions(using wire: WarrenRemoteClient, roster: RemoteRoster) async {
        guard let identity = await wire.replicaNamespace() else { return }
        let namespace = WarrenAgentEventStore.Namespace(
            hostID: identity.hostID,
            accessScopeID: identity.accessScopeID
        )
        agentNamespace = namespace
        agentSessionByStreamID = Dictionary(uniqueKeysWithValues: roster.sessions.compactMap { session in
            guard let streamID = session.agentExecutionId?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !streamID.isEmpty,
                  let sessionID = TerminalSessionID(uuidString: session.id) else { return nil }
            return (streamID, sessionID)
        })
        for feed in conversationFeeds.values { seedConversationFeed(feed) }
        let activeStreamIDs = Set(agentSessionByStreamID.keys)
        agentCurrentStepByStreamID = agentCurrentStepByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentTurnByStreamID = agentTurnByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentTurnStepsByStreamID = agentTurnStepsByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentPlanByStreamID = agentPlanByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentContextByStreamID = agentContextByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentSubagentsByStreamID = agentSubagentsByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentInteractionEventsByStreamID = agentInteractionEventsByStreamID.filter { activeStreamIDs.contains($0.key) }
        agentOpenDecisionByStreamID = agentOpenDecisionByStreamID.filter { activeStreamIDs.contains($0.key) }
        publishPendingDecisions()
        await WarrenAgentEventStore.shared.purgeOrphanStreams(
            namespace: namespace,
            activeStreamIDs: activeStreamIDs
        )
        for streamID in activeStreamIDs
            where !agentSubscribedStreamIDs.contains(streamID)
                && !agentQuarantinedStreamIDs.contains(streamID) {
            agentSubscribedStreamIDs.insert(streamID)
            let task = Task { @MainActor [weak self] in
                defer { self?.agentSubscriptionTasks.removeValue(forKey: streamID) }
                await self?.bootstrapAgentStream(
                    streamID: streamID,
                    namespace: namespace,
                    wire: wire
                )
            }
            agentSubscriptionTasks[streamID] = task
        }
    }

    /// Maps the wire roster into the application's own shape through JSON,
    /// which keeps one set of decoding rules (raw values, defaults, tolerated
    /// unknowns) for both. The round trip is a full encode and decode on the
    /// main actor, so an unchanged roster reuses the previous result; comparing
    /// two rosters costs far less than re-coding one.
    func decodeApplicationRoster(_ roster: WarrenRemoteRoster) -> RemoteRoster? {
        if let cached = decodedRosterCache, cached.source == roster { return cached.roster }
        guard let data = try? JSONEncoder().encode(roster),
              let decoded = try? JSONDecoder().decode(RemoteRoster.self, from: data) else { return nil }
        decodedRosterCache = (roster, decoded)
        return decoded
    }

    func decodeApplicationRosterDelta(_ delta: WarrenRemoteRoster.Delta) -> RemoteRoster.Delta? {
        guard let data = try? JSONEncoder().encode(delta) else { return nil }
        return try? JSONDecoder().decode(RemoteRoster.Delta.self, from: data)
    }

    nonisolated static func agentStatus(from value: RemoteRoster.AgentStatus) -> AgentStatus? {
        guard let activity = AgentActivityState(rawValue: value.activity) else { return nil }
        let attention = value.attention.flatMap { raw -> AgentAttention? in
            guard let kind = AgentAttentionKind(rawValue: raw.kind) else { return nil }
            return AgentAttention(
                kind: kind,
                reason: raw.reason,
                requestID: raw.requestID,
                since: raw.since
            )
        }
        return AgentStatus(activity: activity, attention: attention)
    }

    func receiveAgentEvents(
        _ events: [WarrenRemoteAgentEvent],
        streamID: String,
        using wire: WarrenRemoteClient?
    ) async {
        guard let namespace = agentNamespace,
              let wire,
              agentSessionByStreamID[streamID] != nil,
              !agentQuarantinedStreamIDs.contains(streamID) else { return }
        do {
            _ = try await WarrenAgentEventStore.shared.saveEvents(
                events,
                namespace: namespace,
                streamID: streamID
            )
            await projectAgentEvents(events, streamID: streamID)
            await recoverAgentGapIfNeeded(streamID: streamID, namespace: namespace, wire: wire)
        } catch {
            quarantineAgentStream(streamID: streamID, error: error)
        }
    }

    func bootstrapAgentStream(
        streamID: String,
        namespace: WarrenAgentEventStore.Namespace,
        wire: WarrenRemoteClient
    ) async {
        guard agentNamespace == namespace,
              agentSessionByStreamID[streamID] != nil else { return }
        do {
            var state = await WarrenAgentEventStore.shared.syncState(
                namespace: namespace,
                streamID: streamID
            )
            let cached = await WarrenAgentEventStore.shared.loadRecentEvents(
                namespace: namespace,
                streamID: streamID,
                limit: 100
            )
            if let retained = state?.retainedFromSequence {
                seedAgentProjectionBoundary(streamID: streamID, retainedFromSequence: retained)
            }
            await projectAgentEvents(cached, streamID: streamID)
            if let checkpoint = state?.checkpoint {
                applyAgentCheckpoint(
                    sequence: state?.checkpointSequence ?? 0,
                    state: checkpoint,
                    streamID: streamID
                )
            }

            var result: WarrenRemoteAgentEventsSubscriptionResult
            do {
                result = try await wire.subscribeAgentEvents(
                    streamID: streamID,
                    afterSequence: state?.contiguousThrough ?? 0,
                    limit: 500
                )
            } catch {
                guard let boundary = agentHistoryBoundary(from: error) else { throw error }
                state = try await installAgentHistoryBoundary(
                    boundary,
                    namespace: namespace,
                    streamID: streamID
                )
                applyAgentCheckpoint(
                    sequence: boundary.checkpoint,
                    state: boundary.state,
                    streamID: streamID
                )
                result = try await wire.subscribeAgentEvents(
                    streamID: streamID,
                    afterSequence: state?.contiguousThrough ?? 0,
                    limit: 500
                )
            }
            _ = try await WarrenAgentEventStore.shared.saveEvents(
                result.events,
                namespace: namespace,
                streamID: streamID,
                checkpointSequence: result.checkpoint.sequence,
                checkpoint: result.checkpoint.state,
                retainedFromSequence: result.retainedFromSequence
            )
            await projectAgentEvents(result.events, streamID: streamID)
            // State older than the replica's window: the selectors, plan,
            // and context the Conversation shows however far back they were set.
            conversationStateEventsByStreamID[streamID] = result.stateEvents
            if let sessionID = agentSessionByStreamID[streamID] {
                // The plan and context live in the state events, which are older
                // than the replica window; fold them so a Session that has not
                // moved since it was opened still shows them.
                if foldSessionSummary(result.stateEvents, streamID: streamID, includingTurnSteps: false) {
                    publishSessionSummary(streamID: streamID, sessionID: sessionID)
                }
                conversationFeeds[sessionID]?.merge(result.stateEvents, streamID: streamID)
                refreshLeadMarks()
                drainConversationQueue(sessionID)
            }
            applyAgentCheckpoint(
                sequence: result.checkpoint.sequence,
                state: result.checkpoint.state,
                streamID: streamID
            )
            await recoverAgentGapIfNeeded(streamID: streamID, namespace: namespace, wire: wire)
        } catch {
            quarantineAgentStream(streamID: streamID, error: error)
        }
    }

    func recoverAgentGapIfNeeded(
        streamID: String,
        namespace: WarrenAgentEventStore.Namespace,
        wire: WarrenRemoteClient
    ) async {
        guard let state = await WarrenAgentEventStore.shared.syncState(
            namespace: namespace,
            streamID: streamID
        ), state.contiguousThrough < state.headSequence else { return }
        var after = state.contiguousThrough
        var boundaryBefore: UInt64 = 0
        while !Task.isCancelled {
            do {
                let page = try await wire.agentEventsHistory(
                    streamID: streamID,
                    afterSequence: after,
                    beforeSequence: boundaryBefore == 0 ? nil : boundaryBefore,
                    limit: 500
                )
                guard !page.events.isEmpty else {
                    throw WarrenRemoteClientError.requestFailed("Host returned an empty Agent history page while a gap remained.")
                }
                _ = try await WarrenAgentEventStore.shared.saveEvents(
                    page.events,
                    namespace: namespace,
                    streamID: streamID,
                    retainedFromSequence: page.retainedFromSequence
                )
                await projectAgentEvents(page.events, streamID: streamID)
                guard let last = page.events.map(\.sequence).max(), last > after else { break }
                after = last
                if !page.hasMore { break }
                boundaryBefore = 0
            } catch {
                if let boundary = agentHistoryBoundary(from: error) {
                    do {
                        _ = try await installAgentHistoryBoundary(
                            boundary,
                            namespace: namespace,
                            streamID: streamID
                        )
                        applyAgentCheckpoint(
                            sequence: boundary.checkpoint,
                            state: boundary.state,
                            streamID: streamID
                        )
                        after = boundary.retainedFrom > 0
                            ? boundary.retainedFrom - 1
                            : boundary.checkpoint
                        boundaryBefore = 0
                        continue
                    } catch {
                        quarantineAgentStream(streamID: streamID, error: error)
                    }
                } else {
                    quarantineAgentStream(streamID: streamID, error: error)
                }
                return
            }
        }
    }

    func projectAgentEvents(
        _ events: [WarrenRemoteAgentEvent],
        streamID: String
    ) async {
        guard let projectedSessionID = agentSessionByStreamID[streamID] else { return }
        conversationFeeds[projectedSessionID]?.merge(events, streamID: streamID)
        refreshLeadMarks()
        drainConversationQueue(projectedSessionID)
        foldCurrentStep(events, streamID: streamID, sessionID: projectedSessionID)
        foldOpenDecision(events, streamID: streamID)
        let baseline = agentProjectionSequenceByStreamID[streamID] ?? 0
        let statusEvents = events.filter {
            $0.type == "status.changed" && $0.sequence > baseline
        }
        for event in events where event.sequence > baseline && event.type != "status.changed" {
            agentPendingProjectionByStreamID[streamID, default: [:]][event.sequence] = event
        }
        if let latest = statusEvents.max(by: { $0.sequence < $1.sequence }) {
            agentProjectionSequenceByStreamID[streamID] = latest.sequence
            agentPendingProjectionByStreamID[streamID]?.removeAll()
            let payload = latest.payload?["status"] ?? .object(latest.payload ?? [:])
            if let remote = RemoteRoster.AgentStatus(json: payload),
               let sessionID = agentSessionByStreamID[streamID],
               let status = Self.agentStatus(from: remote) {
                applyAgentProjection(status, for: sessionID)
            }
        } else {
            var cursor = agentProjectionSequenceByStreamID[streamID] ?? 0
            while let event = agentPendingProjectionByStreamID[streamID]?.removeValue(forKey: cursor + 1) {
                cursor = event.sequence
            }
            agentProjectionSequenceByStreamID[streamID] = cursor
        }
    }

    func foldCurrentStep(
        _ events: [WarrenRemoteAgentEvent],
        streamID: String,
        sessionID: TerminalSessionID
    ) {
        let folded = agentCurrentStepByStreamID[streamID]
        let fresh = events.filter { $0.sequence > (folded?.sequence ?? 0) }
        guard let last = fresh.map(\.sequence).max() else { return }
        let step = WarrenConversation.currentStep(after: folded?.step, applying: fresh)
        agentCurrentStepByStreamID[streamID] = (step, last)
        var turn = agentTurnByStreamID[streamID] ?? WarrenAgentTurnFold()
        guard let session = projection.session(id: sessionID) else { return }
        // Most tool events leave the line as it was (an update or a result for
        // the step already shown); only a changed line republishes the tree.
        let line = Self.stepLine(step, root: session.workingDirectory)
        let lastActivity = Self.lastActivity(
            after: session.lastActivity,
            applying: fresh,
            from: folded?.step,
            root: session.workingDirectory,
            turn: &turn
        )
        agentTurnByStreamID[streamID] = turn
        let summaryChanged = foldSessionSummary(fresh, streamID: streamID)
        // A resting row's age is measured from the turn's own end, which the
        // replayed history carries too. Without it, a Session that was already
        // idle when this client connected has no age until its next turn ends.
        var settledAt: Date?
        if let ended = Self.lastSettledDate(in: fresh),
           ended > (activityUpdatedAtBySessionID[sessionID] ?? .distantPast) {
            activityUpdatedAtBySessionID[sessionID] = ended
            settledAt = ended
        }
        // The secondary line holds the last primary fact it showed. A tool step
        // wins, then the plan entry being advanced, then whatever was shown
        // before, so a gap between steps never swaps the subject.
        let primaryLine = line
            ?? agentPlanByStreamID[streamID]?.currentStep
            ?? lastPrimaryLineBySessionID[sessionID]
        let linesChanged = line != session.currentStep
            || primaryLine != session.primaryLine
            || lastActivity != session.lastActivity
        guard linesChanged || summaryChanged || settledAt != nil else { return }
        if let lastActivity { lastActivityBySessionID[sessionID] = lastActivity }
        if let primaryLine { lastPrimaryLineBySessionID[sessionID] = primaryLine }
        var next = projection
        if linesChanged {
            next = next.withSessionActivityLines(
                currentStep: line,
                primaryLine: primaryLine,
                lastActivity: lastActivity,
                for: sessionID
            )
        }
        if summaryChanged {
            next = next.withSessionSummary(
                plan: agentPlanByStreamID[streamID],
                context: agentContextByStreamID[streamID],
                turnCounts: Self.turnCounts(agentTurnStepsByStreamID[streamID] ?? []),
                turnStartedAt: agentTurnByStreamID[streamID]?.startedAt,
                subagents: agentSubagentsByStreamID[streamID] ?? [],
                for: sessionID
            )
        }
        if let settledAt {
            next = next.withSessionAgentStatus(
                session.agentStatus,
                activityUpdatedAt: settledAt,
                acknowledgedActivity: session.acknowledgedActivity,
                for: sessionID
            )
        }
        publishProjectionIfChanged(next)
    }

    /// When the last turn in a batch of events ended, by the Host's stamp.
    nonisolated static func lastSettledDate(in events: [WarrenRemoteAgentEvent]) -> Date? {
        events
            .filter { turnEndingEventTypes.contains($0.type.lowercased()) }
            .compactMap { eventDate($0) }
            .max()
    }

    nonisolated static let turnEndingEventTypes: Set<String> = [
        "turn.completed", "turn.failed", "turn.cancelled", "turn.interrupted", "turn.aborted",
    ]

    /// What a Session last did, folded forward over a batch of events.
    ///
    /// A settled tool call is what a resting row reports: the last thing the
    /// Session did, in the past tense, and nothing in a turn's ending replaces
    /// it. A turn that settled no call at all still has to say something about
    /// itself, and the honest thing Warren holds is how long it ran.
    ///
    /// A step still in flight moves nothing, so a half-done action never gets
    /// frozen in the past tense; the previous line stands until the call it
    /// belongs to settles.
    nonisolated static func lastActivity(
        after current: String?,
        applying events: [WarrenRemoteAgentEvent],
        from start: WarrenConversation.Step?,
        root: String?,
        turn: inout WarrenAgentTurnFold
    ) -> String? {
        var step = start
        var line = current
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            step = WarrenConversation.currentStep(after: step, applying: [event])
            switch event.type.lowercased() {
            case "turn.started":
                turn = WarrenAgentTurnFold(startedAt: eventDate(event))
            case let type where turnEndingEventTypes.contains(type):
                line = turn.settledLine(replacing: line, at: eventDate(event))
            case "tool.completed", "tool.failed":
                guard let step, step.status == .completed || step.status == .failed else { break }
                line = stepLine(step, root: root) ?? line
                turn.settledCalls += 1
            default:
                break
            }
        }
        return line
    }

    /// When an event says it happened. The Host stamps both fields; a client
    /// that has neither has no duration to report.
    nonisolated static func eventDate(_ event: WarrenRemoteAgentEvent) -> Date? {
        [event.occurredAt, event.recordedAt, event.timestamp]
            .compactMap { $0 }
            .compactMap { parseISO8601Date($0) }
            .first
    }

    /// One sidebar line for a step, e.g. "Running git status".
    nonisolated static func stepLine(_ step: WarrenConversation.Step?, root: String?) -> String? {
        guard let step else { return nil }
        let line = step.line(relativeTo: root)
        let text = [line.verb, line.target]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// Maps the Host's OSC 133 prompt state onto the Desktop read model. A nil
    /// input stays nil so a shell that never emitted a marker stays unknown,
    /// which is not the same as sitting at an empty prompt.
    ///
    /// Two facts outlive one snapshot and are carried forward from `previous`:
    /// the shell's own name, captured while the foreground process named it,
    /// and when the running command began. The Host reports a foreground
    /// process, not a command start time, so this client records the prompt
    /// transition it observed.
    nonisolated static func shellState(
        from shell: RemoteRoster.ShellMetadata?,
        previous: WarrenDesktopShellState?,
        foregroundProcess: String,
        now: Date
    ) -> WarrenDesktopShellState? {
        guard let shell else { return nil }
        let shellName = TerminalSessionPresentation.shellName(process: foregroundProcess)
            ?? previous?.shellName
            ?? ""
        let lastExitAt = parseISO8601Date(shell.lastExitAt)
        let commandStartedAt: Date?
        if shell.atPrompt {
            commandStartedAt = nil
        } else if previous?.isRunningCommand == true {
            commandStartedAt = previous?.commandStartedAt ?? lastExitAt ?? now
        } else {
            // A fresh client meets a command already running. The previous
            // command's end is a closer start than this observation, so prefer
            // it when it is the only thing known.
            commandStartedAt = lastExitAt ?? now
        }
        return WarrenDesktopShellState(
            atPrompt: shell.atPrompt,
            runningCommand: shell.runningCommand ?? "",
            lastCommand: shell.lastCommand ?? "",
            lastExitCode: shell.lastExitCode,
            lastExitAt: lastExitAt,
            shellName: shellName,
            commandStartedAt: commandStartedAt
        )
    }

    /// Folds a batch of events into the values the sidebar's second line reads
    /// from a Session: this turn's steps, the plan, the context, and the
    /// subagents. Returns whether anything changed, so a caller can avoid
    /// republishing a tree that did not move.
    @discardableResult
    func foldSessionSummary(
        _ events: [WarrenRemoteAgentEvent],
        streamID: String,
        includingTurnSteps: Bool = true
    ) -> Bool {
        var changed = false
        if includingTurnSteps {
            let before = agentTurnStepsByStreamID[streamID] ?? []
            let after = WarrenConversation.steps(after: before, applying: events)
            if after != before {
                agentTurnStepsByStreamID[streamID] = after
                changed = true
            }
        }
        var subagents = agentSubagentsByStreamID[streamID] ?? []
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            let type = event.type.lowercased()
            let payload = event.payload ?? [:]
            switch type {
            case "plan.updated":
                guard let plan = Self.planProgress(from: payload) else { break }
                if agentPlanByStreamID[streamID] != plan {
                    agentPlanByStreamID[streamID] = plan
                    changed = true
                }
            case "context.updated":
                let usage = WarrenDesktopContextUsage(
                    used: payload.int("used"),
                    size: payload.int("size")
                )
                guard usage.size > 0 else { break }
                if agentContextByStreamID[streamID] != usage {
                    agentContextByStreamID[streamID] = usage
                    changed = true
                }
            case "subagent", "subagent.updated":
                guard let id = payload.string("subagentId"), !id.isEmpty else { break }
                let state: WarrenDesktopSubagent.State =
                    payload.string("state") == "completed" ? .completed : .running
                if let index = subagents.firstIndex(where: { $0.id == id }) {
                    let existing = subagents[index]
                    let next = WarrenDesktopSubagent(
                        id: id,
                        parentCallID: payload.string("parentCallId") ?? existing.parentCallID,
                        title: payload.string("title") ?? payload.string("label") ?? existing.title,
                        summary: payload.string("summary") ?? existing.summary,
                        // A later row without a state leaves the previous one
                        // standing; a completed child never goes back to running.
                        state: payload.string("state") == nil ? existing.state : state,
                        lastActivity: existing.lastActivity,
                        isWaiting: existing.isWaiting
                    )
                    if next != existing {
                        subagents[index] = next
                        changed = true
                    }
                } else {
                    subagents.append(WarrenDesktopSubagent(
                        id: id,
                        parentCallID: payload.string("parentCallId"),
                        title: payload.string("title") ?? payload.string("label") ?? "Subagent",
                        summary: payload.string("summary") ?? "",
                        state: state,
                        lastActivity: nil
                    ))
                    changed = true
                }
            case "tool.started", "tool.updated", "tool.completed", "tool.failed":
                // A child's tool call rides the parent stream tagged with the
                // child's id; only that child's activity moves.
                guard event.sidechain,
                      let id = payload.string("subagentId"),
                      !id.isEmpty,
                      let index = subagents.firstIndex(where: { $0.id == id })
                else { break }
                let line = Self.subagentActivityLine(type: type, payload: payload)
                if subagents[index].lastActivity != line {
                    let existing = subagents[index]
                    subagents[index] = WarrenDesktopSubagent(
                        id: existing.id,
                        parentCallID: existing.parentCallID,
                        title: existing.title,
                        summary: existing.summary,
                        state: existing.state,
                        lastActivity: line,
                        isWaiting: existing.isWaiting
                    )
                    changed = true
                }
            case "interaction.requested", "interaction.resolved", "interaction.expired":
                // A child's pending question or approval rides the same
                // sidechain stream. The Host lifts it to the parent's
                // attention; folding it here is what lets the row name which
                // child is asking and reveal only that row.
                guard event.sidechain,
                      let id = payload.string("subagentId"),
                      !id.isEmpty,
                      let index = subagents.firstIndex(where: { $0.id == id })
                else { break }
                let state = payload.string("state") ?? ""
                guard let waiting = Self.subagentWaiting(type: type, state: state) else { break }
                if subagents[index].isWaiting != waiting {
                    let existing = subagents[index]
                    subagents[index] = WarrenDesktopSubagent(
                        id: existing.id,
                        parentCallID: existing.parentCallID,
                        title: existing.title,
                        summary: existing.summary,
                        state: existing.state,
                        lastActivity: existing.lastActivity,
                        isWaiting: waiting
                    )
                    changed = true
                }
            default:
                break
            }
        }
        if changed {
            agentSubagentsByStreamID[streamID] = subagents
        }
        return changed
    }

    /// Publishes one Session's summary values after a fold changed them.
    func publishSessionSummary(streamID: String, sessionID: TerminalSessionID) {
        publishProjectionIfChanged(projection.withSessionSummary(
            plan: agentPlanByStreamID[streamID],
            context: agentContextByStreamID[streamID],
            turnCounts: Self.turnCounts(agentTurnStepsByStreamID[streamID] ?? []),
            turnStartedAt: agentTurnByStreamID[streamID]?.startedAt,
            subagents: agentSubagentsByStreamID[streamID] ?? [],
            for: sessionID
        ))
    }

    /// The sidebar's count order, heaviest first, and the wording each kind
    /// uses. It is data, not a switch inside the function, so the priority can
    /// be read and changed in one place.
    nonisolated static let turnCountOrder: [WarrenConversation.TurnSummaryItem.Kind] = [
        .edited,
        .gitWrite,
        .ran,
        .fetched,
        .searched,
        .read,
        .other,
        .decision,
    ]

    /// This turn's counts, heaviest first. The sidebar's priority differs from
    /// `summarize`'s stable order: an edit outranks a Git write, which outranks
    /// a command, which outranks fetching, searching, and reading, because that
    /// is the order a person would name what a turn did.
    nonisolated static func turnCounts(_ steps: [WarrenConversation.Step]) -> [String] {
        let rank = Dictionary(
            uniqueKeysWithValues: turnCountOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return WarrenConversation.summaryItems(steps)
            .sorted { (rank[$0.kind] ?? 99) < (rank[$1.kind] ?? 99) }
            .map(\.label)
    }

    /// The plan `plan.updated` reports, in the sidebar's shape.
    nonisolated static func planProgress(
        from payload: [String: WarrenRemoteJSONValue]
    ) -> WarrenDesktopPlanProgress? {
        guard case let .array(items)? = payload["items"] else { return nil }
        var entries: [(title: String, state: String)] = []
        for item in items {
            guard case let .object(value) = item else { continue }
            let title = value.string("title") ?? value.string("label") ?? ""
            if title.isEmpty { continue }
            entries.append((title, value.string("state") ?? "pending"))
        }
        guard !entries.isEmpty else { return nil }
        let done = entries.filter { $0.state == "completed" }.count
        let current = (entries.first { $0.state == "in_progress" }
            ?? entries.first { $0.state == "pending" })?.title ?? ""
        return WarrenDesktopPlanProgress(done: done, total: entries.count, currentStep: current)
    }

    /// Whether one interaction event leaves a child waiting on a person. A
    /// pending request asks; a resolved or expired one settles it. A type that
    /// is not an interaction returns nil so the caller leaves the state alone.
    nonisolated static func subagentWaiting(type: String, state: String) -> Bool? {
        switch type.lowercased() {
        case "interaction.requested":
            return state.isEmpty || state == "pending"
        case "interaction.resolved", "interaction.expired":
            return false
        default:
            return nil
        }
    }

    /// One child tool call as a line, built from the same step vocabulary the
    /// parent's activity line uses.
    nonisolated static func subagentActivityLine(
        type: String,
        payload: [String: WarrenRemoteJSONValue]
    ) -> String? {
        var step = WarrenConversation.Step(id: payload.string("callId") ?? "", kind: .tool)
        step.toolKind = payload.string("toolKind") ?? ""
        step.title = payload.string("toolName") ?? ""
        step.detail = payload.string("toolDetail") ?? ""
        step.status = type == "tool.completed"
            ? .completed
            : type == "tool.failed"
                ? .failed
                : (payload.string("toolStatus") == "in_progress" ? .running : .pending)
        return stepLine(step, root: nil)
    }

    func applyAgentCheckpoint(
        sequence: UInt64,
        state: [String: WarrenRemoteJSONValue],
        streamID: String
    ) {
        guard sequence >= (agentProjectionSequenceByStreamID[streamID] ?? 0) else { return }
        agentProjectionSequenceByStreamID[streamID] = sequence
        agentPendingProjectionByStreamID[streamID] = agentPendingProjectionByStreamID[streamID]?.filter {
            $0.key > sequence
        }
        guard let rawStatus = state["status"],
              let remote = RemoteRoster.AgentStatus(json: rawStatus),
              let sessionID = agentSessionByStreamID[streamID],
              let status = Self.agentStatus(from: remote) else { return }
        applyAgentProjection(status, for: sessionID)
    }

    func seedAgentProjectionBoundary(streamID: String, retainedFromSequence: UInt64) {
        guard retainedFromSequence > 0 else { return }
        let baseline = retainedFromSequence - 1
        guard baseline > (agentProjectionSequenceByStreamID[streamID] ?? 0) else { return }
        agentProjectionSequenceByStreamID[streamID] = baseline
        agentPendingProjectionByStreamID[streamID] = agentPendingProjectionByStreamID[streamID]?.filter {
            $0.key > baseline
        }
    }

    func quarantineAgentStream(streamID: String, error: Error) {
        agentQuarantinedStreamIDs.insert(streamID)
        agentSubscribedStreamIDs.remove(streamID)
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        addNotice(
            title: "Agent stream paused",
            message: detail.isEmpty ? "Agent stream (streamID) failed its integrity check." : detail
        )
    }

    func agentHistoryBoundary(from error: Error) -> (
        retainedFrom: UInt64,
        head: UInt64,
        checkpoint: UInt64,
        state: [String: WarrenRemoteJSONValue]
    )? {
        guard case let WarrenRemoteClientError.requestFailedWithCode(code, _, details) = error,
              code == "history_boundary",
              let details else { return nil }
        func number(_ value: WarrenRemoteJSONValue?) -> UInt64 {
            switch value {
            case .number(let value) where value >= 0: return UInt64(value)
            case .string(let value): return UInt64(value) ?? 0
            default: return 0
            }
        }
        let checkpoint: [String: WarrenRemoteJSONValue] = {
            guard case let .object(value) = details["checkpoint"] else { return [:] }
            return value
        }()
        let retained = number(details["retainedFromSequence"])
        let head = number(details["headSequence"])
        let sequence = number(details["checkpointSequence"])
        guard retained > 0 || head > 0 || sequence > 0 else { return nil }
        return (retained, head, sequence, checkpoint)
    }

    func installAgentHistoryBoundary(
        _ boundary: (retainedFrom: UInt64, head: UInt64, checkpoint: UInt64, state: [String: WarrenRemoteJSONValue]),
        namespace: WarrenAgentEventStore.Namespace,
        streamID: String
    ) async throws -> WarrenAgentEventStore.SyncState {
        try await WarrenAgentEventStore.shared.installHistoryBoundary(
            namespace: namespace,
            streamID: streamID,
            retainedFromSequence: boundary.retainedFrom,
            headSequence: boundary.head,
            checkpointSequence: boundary.checkpoint,
            checkpoint: boundary.state
        )
    }

    func feedOutput(
        _ data: Data,
        sessionID: TerminalSessionID? = nil,
        epoch: UInt64? = nil,
        sequence: UInt64? = nil
    ) async {
        guard !data.isEmpty,
              let targetSessionID = sessionID ?? selectedSessionID,
              surfaceManager.surface(for: targetSessionID) != nil else { return }
        let nudge = initialRefreshPending && targetSessionID == selectedSessionID
        if nudge {
            TerminalDiagnostics.log("feed_output", [
                "session": targetSessionID.description,
                "bytes": String(data.count),
                "nudge": "true",
            ])
        } else {
            TerminalDiagnostics.logVerbose("feed_output", [
                "session": targetSessionID.description,
                "bytes": String(data.count),
                "nudge": "false",
            ])
        }
        if let epoch, let sequence {
            surfaceManager.enqueueOutput(
                data,
                for: targetSessionID,
                epoch: epoch,
                sequence: sequence
            )
        } else {
            surfaceManager.enqueueRawOutput(data, for: targetSessionID)
        }
        if nudge {
            initialRefreshPending = false
            surfaceManager.requestPresent(targetSessionID)
        }
    }

    func apply(
        _ roster: RemoteRoster,
        advancesGeneration: Bool = true
    ) {
        if advancesGeneration {
            rosterApplicationGeneration &+= 1
        }
        loadSettings()
        clearMaintenance()
        guard let hostID = HostID(uuidString: roster.host.id) else { return }
        let host = WarrenDomain.Host(id: hostID, name: roster.host.name)
        let tasks = roster.tasks.enumerated().compactMap { index, value -> WarrenDomain.WarrenTask? in
            guard let id = TaskID(uuidString: value.id) else { return nil }
            return WarrenDomain.WarrenTask(
                id: id,
                hostID: hostID,
                name: value.name,
                source: value.source,
                externalID: value.externalID,
                url: value.url.flatMap(URL.init(string:)),
                pinned: value.pinned ?? false,
                order: value.order ?? index
            )
        }
        let projects = roster.projects.compactMap { value -> Project? in
            guard let id = ProjectID(uuidString: value.id) else { return nil }
            return Project(
                id: id,
                hostID: hostID,
                name: value.name,
                rootPath: value.path,
                setupScript: value.setupScript,
                autoImportGitWorktrees: value.autoImportGitWorktrees ?? false,
                pinned: value.pinned ?? false,
                activeSince: Self.parseISO8601Date(value.activeSince)
            )
        }
        let workspaces = roster.workspaces.compactMap { value -> Workspace? in
            guard let id = WorkspaceID(uuidString: value.id),
                  let projectID = ProjectID(uuidString: value.project) else { return nil }
            return Workspace(
                id: id,
                projectID: projectID,
                taskID: value.task.flatMap(TaskID.init(uuidString:)),
                name: value.name,
                path: value.path,
                branch: value.branch,
                pinned: value.pinned ?? false,
                mergeState: value.mergeState.flatMap(WorkspaceMergeState.init(rawValue:)),
                managedWorktree: value.managedWorktree ?? false,
                worktreeLocked: value.worktreeLocked ?? false,
                createdAt: Self.parseISO8601Date(value.createdAt),
                lastActivityAt: Self.parseISO8601Date(value.lastActivityAt)
            )
        }
        let liveProjectIDs = Set(projects.map(\.id))
        let liveWorkspaceIDs = Set(workspaces.map(\.id))
        deletingProjectIDs = Self.reconcileDeletionIDs(
            deletingProjectIDs,
            against: liveProjectIDs
        )
        deletingWorkspaceIDs = Self.reconcileDeletionIDs(
            deletingWorkspaceIDs,
            against: liveWorkspaceIDs
        )
        // Pane groups are Host state, so the projection carries them verbatim:
        // the client renders the arrangement the Host owns instead of keeping a
        // device-local copy that no other client can see.
        let paneGroups = roster.paneGroups.enumerated().compactMap { index, value -> PaneGroup? in
            guard let id = PaneGroupID(uuidString: value.id),
                  let tree = Self.paneTree(value.tree) else { return nil }
            guard let workspaceID = value.workspace.flatMap(WorkspaceID.init(uuidString:)) else {
                return nil
            }
            return PaneGroup(
                id: id,
                hostID: hostID,
                workspaceID: workspaceID,
                name: value.name,
                order: value.order ?? index,
                tree: tree,
                revision: value.revision ?? 0
            )
        }
        let workspacePaths = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.path) })
        // Every Session belongs to a Workspace; one the Host reports without
        // a resolvable Workspace has nowhere to be shown.
        let remoteSessions = roster.sessions.compactMap {
            value -> (RemoteRoster.Session, TerminalSessionID, WorkspaceID)? in
            guard let id = TerminalSessionID(uuidString: value.id),
                  let workspaceID = value.workspace.flatMap(WorkspaceID.init(uuidString:)) else {
                return nil
            }
            return (value, id, workspaceID)
        }
        conversationSessionIDs = Set(remoteSessions.compactMap { value, id, _ in
            value.lifecycle == "running" && value.runtimeKind == "acp" ? id : nil
        })
        conversationConfigSessionIDs = Set(remoteSessions.compactMap { value, id, _ in
            value.agentCapabilities?.contains(WarrenRemoteAgentCapability.config) == true ? id : nil
        })
        conversationAttachmentSessionIDs = Set(remoteSessions.compactMap { value, id, _ in
            value.agentCapabilities?.contains(WarrenRemoteAgentCapability.attachments) == true ? id : nil
        })
        conversationHandoffSessionIDs = Set(remoteSessions.compactMap { value, id, _ in
            value.agentSessionId?.isEmpty == false ? id : nil
        })
        conversationFeeds = conversationFeeds.filter { conversationSessionIDs.contains($0.key) }
        // A Lead is read from its own conversation, so every Conversation
        // Session needs a feed even while its pane is closed: the sidebar mark
        // and the system notification are decided before anyone opens it.
        for sessionID in conversationSessionIDs {
            _ = conversationFeed(for: sessionID)
        }
        let agentTurns = Dictionary(uniqueKeysWithValues: remoteSessions.compactMap {
            value, sessionID, _ in
            value.agentTurn.map { (sessionID, $0) }
        })
        let completedAgentSessions = agentCompletionTracker.observe(
            sessions: Set(remoteSessions.map { $0.1 }),
            turns: agentTurns
        )
        let previousProjectionSessions = Dictionary(
            uniqueKeysWithValues: projection.sessions.map { ($0.id, $0) }
        )
        let rosterObservationDate = Date()
        var nextLastObservedActivityBySessionID = lastObservedActivityBySessionID
        var nextActivityUpdatedAtBySessionID = activityUpdatedAtBySessionID
        var nextAcknowledgments = activityAcknowledgments
        var acknowledgmentsChanged = false
        let sessions = remoteSessions.map { value, id, workspaceID in
            let candidateStatus = Self.resolvedAgentStatus(
                rosterStatus: value.agentStatus,
                liveStatus: agentStatusBySessionID[id]
            )
            let candidateActivity = candidateStatus?.activity
            let previousActivity = nextLastObservedActivityBySessionID[id]
                ?? previousProjectionSessions[id]?.activity
            let hadPreviousObservation = nextLastObservedActivityBySessionID[id] != nil
                || previousProjectionSessions[id] != nil
            if candidateActivity == .ready,
               previousActivity != .ready,
               hadPreviousObservation {
                nextActivityUpdatedAtBySessionID[id] = rosterObservationDate
            }
            if let candidateActivity {
                nextLastObservedActivityBySessionID[id] = candidateActivity
            } else {
                nextLastObservedActivityBySessionID.removeValue(forKey: id)
            }
            if nextAcknowledgments.invalidate(sessionID: id, currentActivity: candidateActivity) {
                acknowledgmentsChanged = true
            }
            let workingDirectory = value.directory
                ?? workspacePaths[workspaceID]
                ?? ""
            let previousShell = previousProjectionSessions[id]?.shellState
            let streamID = value.agentExecutionId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let currentStep = streamID
                .flatMap { agentCurrentStepByStreamID[$0]?.step }
            let stepLine = Self.stepLine(currentStep, root: workingDirectory)
            let plan = streamID.flatMap { agentPlanByStreamID[$0] }
            let primaryLine = stepLine
                ?? plan?.currentStep
                ?? lastPrimaryLineBySessionID[id]
            if let primaryLine { lastPrimaryLineBySessionID[id] = primaryLine }
            let stopped = value.lifecycle == "ended"
            return WarrenDesktopSession(
                id: id,
                workspaceID: workspaceID,
                tabID: Self.tabID(id),
                title: value.title,
                customTitle: value.customTitle,
                pinned: value.pinned ?? false,
                kind: TerminalSessionKind(rawValue: value.kind) ?? .custom,
                agentProvider: value.agentProvider.flatMap(TerminalSessionKind.init(rawValue:)),
                state: value.lifecycle == "running" ? .attached : .exited,
                agentStatus: candidateStatus,
                activityUpdatedAt: nextActivityUpdatedAtBySessionID[id],
                createdAt: Self.parseISO8601Date(value.createdAt),
                runtimeProcess: value.process ?? value.command ?? "",
                runtimeCommandLine: value.commandLine ?? "",
                workingDirectory: workingDirectory,
                shellState: Self.shellState(
                    from: value.shell,
                    previous: previousShell,
                    foregroundProcess: value.process ?? "",
                    now: rosterObservationDate
                ),
                acknowledgedActivity: nextAcknowledgments[id],
                currentStep: stepLine,
                resultSentence: value.resultSentence,
                titleRegeneratable: value.titleRegeneratable ?? false,
                primaryLine: primaryLine,
                lastActivity: lastActivityBySessionID[id],
                plan: plan,
                context: streamID.flatMap { agentContextByStreamID[$0] },
                turnCounts: streamID.map { Self.turnCounts(agentTurnStepsByStreamID[$0] ?? []) } ?? [],
                turnStartedAt: streamID.flatMap { agentTurnByStreamID[$0]?.startedAt },
                subagents: streamID.flatMap { agentSubagentsByStreamID[$0] } ?? [],
                endReason: stopped ? WarrenDesktopEndReason(wire: value.endReason) : nil,
                stoppedAction: stopped
                    ? WarrenDesktopStoppedSessionRoster.action(
                        kind: value.kind,
                        agentProvider: value.agentProvider,
                        agentSessionID: value.agentSessionId
                    )
                    : nil
            )
        }
        let liveSessionIDs = Set(remoteSessions.map(\.1))
        lastObservedActivityBySessionID = nextLastObservedActivityBySessionID.filter {
            liveSessionIDs.contains($0.key)
        }
        activityUpdatedAtBySessionID = nextActivityUpdatedAtBySessionID.filter {
            liveSessionIDs.contains($0.key)
        }
        lastActivityBySessionID = lastActivityBySessionID.filter {
            liveSessionIDs.contains($0.key)
        }
        lastPrimaryLineBySessionID = lastPrimaryLineBySessionID.filter {
            liveSessionIDs.contains($0.key)
        }
        nextAcknowledgments.retain(sessionIDs: liveSessionIDs)
        if acknowledgmentsChanged || nextAcknowledgments != activityAcknowledgments {
            activityAcknowledgments = nextAcknowledgments
            persistActivityAcknowledgments()
        }
        let activeStatusSessionIDs = Set(
            remoteSessions.compactMap { value, id, _ in
                value.agentStatus == nil ? nil : id
            }
        )
        agentStatusBySessionID = agentStatusBySessionID.filter {
            liveSessionIDs.contains($0.key) && activeStatusSessionIDs.contains($0.key)
        }
        // A Session whose runtime ended without the user closing it keeps its
        // Tab as a stopped one: the pane shows the output the Host kept and
        // offers the single action that continues it. Everything else that ended
        // stays in the projection as history but has no Tab to open.
        let stoppedSessionIDs = Set(
            WarrenDesktopStoppedSessionRoster.stoppedSessionIDs(
                remoteSessions.map { value, id, _ in
                    WarrenDesktopStoppedSessionInput(
                        sessionID: id.description,
                        lifecycle: value.lifecycle,
                        kind: value.kind,
                        runtimeKind: value.runtimeKind,
                        endReason: value.endReason,
                        resumedFrom: value.resumedFrom
                    )
                }
            ).compactMap(TerminalSessionID.init(uuidString:))
        )
        // Forget stopped Sessions whose Tab is gone: a resumed or removed
        // Session must not keep its kept output in memory.
        stoppedSessionHistory = stoppedSessionHistory.filter { stoppedSessionIDs.contains($0.key) }
        stoppedSessionHistoryFed.formIntersection(stoppedSessionIDs)
        stoppedSessionActionInFlight.formIntersection(stoppedSessionIDs)
        stoppedSessionActionFailure = stoppedSessionActionFailure.filter { stoppedSessionIDs.contains($0.key) }
        // What Resume All may continue, read once here so the stopped banner
        // only filters a short list.
        let conversationsBySessionID = Dictionary(
            remoteSessions.compactMap { value, id, _ -> (TerminalSessionID, String)? in
                guard stoppedSessionIDs.contains(id),
                      let conversation = value.agentSessionId?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !conversation.isEmpty else { return nil }
                return (id, conversation)
            },
            uniquingKeysWith: { first, _ in first }
        )
        stoppedResumeCandidates = sessions.compactMap { session in
            guard session.stoppedAction == .resume,
                  let conversation = conversationsBySessionID[session.id] else { return nil }
            return WarrenDesktopResumeCandidate(
                sessionID: session.id.description,
                conversationID: conversation,
                createdAt: session.createdAt
            )
        }
        let unorderedTabs = remoteSessions.compactMap { value, id, _ -> ClientTab? in
            guard value.lifecycle == "running" || stoppedSessionIDs.contains(id) else {
                return nil
            }
            return ClientTab(
                id: Self.tabID(id),
                title: value.title,
                sessionID: id,
                // A Tab is a presentation entry, so it follows the bound
                // provider rather than the durable launch kind.
                kind: value.agentProvider.flatMap(TerminalSessionKind.init(rawValue:))
                    ?? TerminalSessionKind(rawValue: value.kind)
                    ?? .custom
            )
        }
        let sessionWorkspaces = Dictionary(uniqueKeysWithValues: remoteSessions.map { value in
            (value.1, value.2)
        })
        // A running Session that resumed a stopped one takes over that
        // stopped Tab's place in the strip.
        let tabSuccessors = Dictionary(
            remoteSessions.compactMap { value, id, _ -> (String, String)? in
                guard value.lifecycle == "running",
                      let resumedFrom = value.resumedFrom.flatMap(TerminalSessionID.init(uuidString:))
                else { return nil }
                return (Self.tabID(resumedFrom), Self.tabID(id))
            },
            uniquingKeysWith: { first, _ in first }
        )
        let tabs = applyingLocalTabOrder(
            unorderedTabs,
            sessionWorkspaces: sessionWorkspaces,
            successors: tabSuccessors
        )
        let nextProjection = WarrenDesktopProjection(
            host: host,
            tasks: tasks,
            projects: projects,
            workspaces: workspaces,
            sessions: sessions,
            tabs: tabs,
            sessionWorkspaceIDs: sessionWorkspaces,
            connectionState: .attached,
            paneGroups: paneGroups
        )
        publishProjectionIfChanged(nextProjection)
        refreshLeadMarks()
        // Which Sessions are Conversations, and their names, came with this
        // roster; the tray's decisions are filtered and worded by both.
        publishPendingDecisions()
        TerminalDiagnostics.log("roster_apply", [
            "tabs": String(tabs.count),
            "selectedTab": navigation.selectedTabID ?? "nil",
            "mounted": String(surfaceManager.retainedSurfaceCount),
            "paneGroups": String(paneGroups.count),
        ])
        let liveTabSessionIDs = Set(tabs.compactMap(\.sessionID))
        for sessionID in Array(outputAnchors.keys) where !liveTabSessionIDs.contains(sessionID) {
            outputAnchors.removeValue(forKey: sessionID)
            suppressFramedAnchorUpdates.remove(sessionID)
        }
        // Surface cleanup is only needed when the set of live tabs changes;
        // repeatedly scanning every mounted terminal makes roster bursts
        // compete with input and rendering on the main actor.
        if appliedLiveTabSessionIDs != liveTabSessionIDs {
            let pruned = appliedLiveTabSessionIDs.subtracting(liveTabSessionIDs)
            if !pruned.isEmpty {
                // Disposing a surface also drops its output subscription, so a
                // transiently narrow live tab set is what turns the next
                // visibility update into a burst of full snapshot installs.
                TerminalDiagnostics.log("mounted_surfaces_pruned", [
                    "pruned": String(pruned.count),
                    "sessions": pruned.map(\.description).sorted().joined(separator: ","),
                ])
            }
            surfaceManager.removeAll(except: liveTabSessionIDs)
            appliedLiveTabSessionIDs = liveTabSessionIDs
        }
        cancelTransientConnectionIssue()
        let previousTabID = navigation.selectedTabID
        let nextNavigation = WarrenDesktopNavigationReducer.reconcile(navigation, with: projection)
        if nextNavigation != navigation {
            navigation = nextNavigation
        }
        if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
            attachedSessionID = nil
            focusedSessionID = nil
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            focusClaimInFlight = false
            focusClaimGeneration += 1
            inputRouter.discard(for: selectedSessionID)
            cancelResizeRequests()
        }
        if navigation.selectedTabID == nil {
            let previousSessionID = selectedSessionID
            selectedSessionID = nil
            attachedSessionID = nil
            focusedSessionID = nil
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            focusClaimInFlight = false
            focusClaimGeneration += 1
            if let previousSessionID {
                inputRouter.discard(for: previousSessionID)
            }
            cancelResizeRequests()
        } else if WarrenRemoteTerminalProtocol.shouldAttach(
            previousTabID: previousTabID,
            nextTabID: navigation.selectedTabID,
            mountedSurfaceCount: surfaceManager.retainedSurfaceCount
        ) {
            // The first roster is also the desktop's restore point. Without
            // this explicit attach, the tab bar appears populated while the
            // pane remains empty until the user clicks the tab.
            Task { @MainActor [weak self] in
                await self?.presentSelectedSession()
            }
        }
        fulfillPendingTerminalOpenRequest()
        for sessionID in completedAgentSessions {
            guard let turn = agentTurns[sessionID] else { continue }
            agentCompletionSubject.send(WarrenAgentCompletionEvent(
                sessionID: sessionID,
                turnID: turn.id
            ))
        }
    }

    /// Entry point for every navigation that makes a session visible.
    ///
    /// A retained surface with a live output subscription is promoted
    /// locally: its grid already holds the current screen, so presentation
    /// is a reparent plus a control-lease swap and performs zero replay,
    /// snapshot, or clear. Everything else takes the cold seeding path.
    func makeSurface(
        for session: WarrenDesktopSession,
        readOnly: Bool = false
    ) -> GhosttySurface {
        let sessionID = session.id
        let inputRouter = self.inputRouter
        let inputBridge = WarrenOrderedInputBridge { [inputRouter, sessionID] data in
            inputRouter.enqueue(data, for: sessionID)
        }
        return GhosttySurface(
            id: sessionID,
            attachmentID: TerminalAttachmentID(),
            workingDirectory: session.workingDirectory,
            font: terminalFont,
            backgroundOpacity: terminalBackgroundOpacity,
            onInput: { data in
                // A stopped Session has no runtime, so its surface is a picture:
                // keystrokes belong to nothing and must never be queued for a
                // Session that no longer exists.
                guard !readOnly else { return }
                inputBridge.send(data)
            },
            onResize: { [weak self] columns, rows in
                Task { @MainActor in
                    // Every visible pane owns a native surface and therefore
                    // emits its own geometry callbacks. Only the selected
                    // surface may resize the shared PTY/control lease; a
                    // passive sibling must never resize whichever pane
                    // happens to be selected at the time its view lays out.
                    self?.resize(
                        sessionID: sessionID,
                        columns: columns,
                        rows: rows
                    )
                }
            },
            onOpenURL: { [weak self] url, kind, workingDirectory in
                guard let self else { return false }
                return self.onOpenTerminalURL?(
                    sessionID,
                    url,
                    kind,
                    workingDirectory ?? session.workingDirectory
                ) ?? false
            }
        )
    }

    /// Ensures every leaf currently rendered by the split window has a live
    /// output subscription. The selected leaf additionally owns the control
    /// lease; sibling subscriptions are passive and failures stay isolated to
    /// that pane.
    /// Selects the Tab that renders `sessionID`. Used when AppKit, not the UI,
    /// decides which split pane owns keyboard focus.
    func selectTab(forSessionID sessionID: TerminalSessionID) {
        let tabID = Self.tabID(sessionID)
        guard navigation.selectedTabID != tabID,
              projection.tabs.contains(where: { $0.id == tabID && $0.sessionID == sessionID }) else {
            return
        }
        perform(.selectTab(tabID))
    }

    func ensureVisibleSessions(_ sessionIDs: Set<TerminalSessionID>) {
        // A browser Session has no PTY: it is not a terminal screen to seed,
        // subscribe, or resize. Only the browser region renders it (RFC 0022 §3).
        let live = Set(
            projection.sessions
                .filter { $0.state.isActive && $0.kind != .browser && !conversationSessionIDs.contains($0.id) }
                .map(\.id)
        )
        let visible = sessionIDs.intersection(live)
        let departed = visibleSessionIDs.subtracting(visible)
        let changed = visibleSessionIDs != visible
        visibleSessionIDs = visible
        for sessionID in departed where sessionID != selectedSessionID {
            releaseResizeOwnership(sessionID)
        }
        let selectedID = navigation.selectedTabID.flatMap { tabID in
            projection.tabs.first(where: { $0.id == tabID })?.sessionID
        }
        var seeding: [TerminalSessionID] = []
        var alreadySubscribed = 0
        for sessionID in visible where sessionID != selectedID {
            // Only a Session without a subscription will actually subscribe;
            // recording every leaf made the event look like a burst of seeds
            // when nothing was re-subscribed.
            guard !outputSubscriptions.contains(sessionID) else {
                alreadySubscribed += 1
                continue
            }
            guard backgroundAttachTokens[sessionID] == nil else { continue }
            nextBackgroundAttachToken &+= 1
            let token = nextBackgroundAttachToken
            backgroundAttachTokens[sessionID] = token
            seeding.append(sessionID)
            Task { @MainActor [weak self] in
                await self?.attachBackgroundSession(sessionID, token: token)
            }
        }
        // Every seed below is a `session.subscribe`, and a subscribe answers
        // with a complete atomic state. A burst here is therefore a burst of
        // full snapshot installs, which is what a visible reflow looks like.
        if !seeding.isEmpty {
            TerminalDiagnostics.log("visible_sessions_seed", [
                "visible": String(visible.count),
                "seeding": String(seeding.count),
                "subscribed": String(alreadySubscribed),
                "changed": changed ? "true" : "false",
                "sessions": seeding.map(\.description).sorted().joined(separator: ","),
            ])
        }
        guard let selectedID, visible.contains(selectedID) else { return }
        Task { @MainActor [weak self] in
            await self?.presentSelectedSession()
        }
    }

    /// Releases the viewport ownership a passive pane adopted while it was on
    /// screen. The daemon only clears it for the current owner, so this is a
    /// no-op for a pane that never resized. Input focus is untouched: the peer
    /// never claimed it for a passive pane.
    func releaseResizeOwnership(_ sessionID: TerminalSessionID) {
        passiveResizeTasks[sessionID]?.cancel()
        passiveResizeTasks[sessionID] = nil
        passiveResizeBuffers[sessionID] = nil
        guard let wire, outputSubscriptions.contains(sessionID) else { return }
        Task {
            _ = try? await wire.focus(
                sessionID: sessionID.description,
                focused: false,
                size: nil
            )
        }
    }

    func attachBackgroundSession(
        _ sessionID: TerminalSessionID,
        token: UInt64
    ) async {
        defer {
            if backgroundAttachTokens[sessionID] == token {
                backgroundAttachTokens.removeValue(forKey: sessionID)
            }
        }
        guard backgroundAttachTokens[sessionID] == token,
              let wire,
              let session = projection.session(id: sessionID),
              session.state.isActive,
              !outputSubscriptions.contains(sessionID) else {
            TerminalDiagnostics.logVerbose("background_attach_skipped", [
                "session": sessionID.description,
                "subscribed": outputSubscriptions.contains(sessionID) ? "true" : "false",
                "tokenCurrent": backgroundAttachTokens[sessionID] == token ? "true" : "false",
                "active": projection.session(id: sessionID)?.state.isActive == true ? "true" : "false",
            ])
            return
        }

        let surface: GhosttySurface
        if let existing = surfaceManager.surface(for: sessionID) {
            surface = existing
        } else {
            outputAnchors.removeValue(forKey: sessionID)
            suppressFramedAnchorUpdates.remove(sessionID)
            surface = makeSurface(for: session)
            surfaceManager.insert(surface, recoveryGated: true)
        }
        guard self.wire === wire,
              backgroundAttachTokens[sessionID] == token else { return }
        surfaceManager.beginRecovery(for: sessionID)
        do {
            try await seedSessionSubscription(
                using: wire,
                sessionID: sessionID,
                size: nil,
                claimControl: false
            )
            guard self.wire === wire,
                  backgroundAttachTokens[sessionID] == token else { return }
            noteOutputSubscriptionAdded(sessionID, reason: "attachBackgroundSession")
        } catch {
            // A sibling's recovery failure must not tear down the selected
            // pane or the shared WebSocket. The next visibility update can
            // retry from the same Session-keyed anchor.
            if self.wire === wire,
               backgroundAttachTokens[sessionID] == token,
               selectedSessionID != sessionID {
                removeMountedSurface(sessionID: sessionID)
            }
        }
    }

    /// Whether this Session is a Host-owned browser rather than a terminal.
    ///
    /// A browser Session carries no PTY (RFC 0022 §3): it has no surface, no
    /// subscribe, no grid, and no resize. Treating one as a terminal mounts an
    /// empty pane and reports that pane's character grid as the browser's pixel
    /// viewport, which shrinks the page.
    func isBrowserSession(_ sessionID: TerminalSessionID) -> Bool {
        projection.session(id: sessionID)?.kind == .browser
    }

    /// Whether this Session is an ACP Agent, which has no terminal.
    func isConversationSession(_ sessionID: TerminalSessionID) -> Bool {
        conversationSessionIDs.contains(sessionID)
    }

    /// Presents the Session the navigation selects.
    ///
    /// `activatingInput` marks the calls that come from the user entering a
    /// Session — a row, a Tab, the palette, a shortcut, a fresh Session, or the
    /// Settings window closing. Those are the calls that have to leave the
    /// keyboard in the Session's own input instead of on the control that was
    /// just used. Roster-driven restoration stays passive so a reconnect does
    /// not take focus away from whatever the user is doing.
    func presentSelectedSession(activatingInput: Bool = false) async {
        guard let tabID = navigation.selectedTabID,
              let sessionID = projection.tabs.first(where: { $0.id == tabID })?.sessionID else { return }
        // A stopped Session has no runtime to attach to. Its pane shows the output
        // the Host kept and the one action that continues it, so it must never
        // ask for a subscription, the control lease, or the keyboard.
        if let stopped = projection.sessions.first(where: { $0.id == sessionID && $0.isStopped }) {
            presentStoppedSession(stopped, activatingInput: activatingInput)
            return
        }
        // A browser Session is presented by the browser region, not here. Leaving
        // the Terminal attached to its previous Session is what keeps that
        // Session on screen beside the viewer.
        guard !isConversationSession(sessionID) else {
            // The Conversation surface owns the pane and its keyboard focus.
            if activatingInput {
                surfaceManager.cancelPendingInputFocus()
            }
            relinquishTerminalFocus()
            if activatingInput {
                requestConversationFocus(sessionID)
            }
            return
        }
        guard !isBrowserSession(sessionID) else {
            if activatingInput {
                surfaceManager.cancelPendingInputFocus()
            }
            TerminalDiagnostics.log("present_skipped_browser", [
                "session": sessionID.description,
            ])
            // The browser now owns the content area, on its own or beside the
            // Terminal. Either way the keyboard intent moved to the viewer, and
            // leaving the Terminal focused would send typing to a pane the user
            // is not looking at.
            relinquishTerminalFocus()
            return
        }
        // Retained before the attach so every path below — promotion, a cold
        // subscribe, or the retry after a pane appears late — claims the
        // keyboard with the user's instruction rather than as a layout turn.
        if activatingInput {
            surfaceManager.requestInputFocus(for: sessionID)
        }
        // A retained surface is the source of truth across ordinary navigation:
        // reparent it and swap the control lease. Re-subscribe only after a
        // transport gap (the preserved session set) or when no live surface or
        // subscription exists at all.
        if surfaceManager.surface(for: sessionID) != nil,
           reconnectPreservedSessions.contains(sessionID) {
            await attachSelectedSession(preservingExistingSurface: true)
            return
        }
        // A sibling pane may be seeding this Session in the background. Let it
        // finish so promotion can reuse that subscription, but never wait
        // indefinitely: a hung or slow seed must fall through to the cold path
        // instead of leaving the pane unattached.
        let backgroundAttachDeadline = ContinuousClock.now + .seconds(2)
        while backgroundAttachTokens[sessionID] != nil,
              ContinuousClock.now < backgroundAttachDeadline {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return
            }
            guard navigation.selectedTabID == tabID else { return }
        }
        // Promote only a surface that is actually usable to present. A retained
        // surface can outlive its native renderer — a cleared `state.surface`,
        // an idle eviction that kept the Swift object, or a view that never
        // reattached — and `schedulePresent` waits on `terminalSurfaceIsReady`,
        // so promoting it would leave the pane black forever: nothing else would
        // re-create the native surface. Falling back to the cold path runs
        // `beginRecovery`/`waitForSurfaceReady` and re-subscribes, which revives
        // it. The predicate deliberately ignores AppKit visibility so it stays
        // stable before the reconciliation that re-attaches the view.
        if surfaceManager.surface(for: sessionID) != nil,
           outputSubscriptions.contains(sessionID),
           surfaceManager.isReadyToInstallRecovery(sessionID) {
            await promoteRetainedSession(sessionID)
            return
        }
        await attachSelectedSession()
    }

    /// Promotes an already-current retained surface without touching the
    /// terminal byte stream. The daemon-side work is one control-lease swap;
    /// the pixels on screen are the live surface itself, not a replay.
    func promoteRetainedSession(_ sessionID: TerminalSessionID) async {
        guard let wire else { return }
        if selectedSessionID != sessionID {
            if let previousSessionID = selectedSessionID {
                // Split siblings stay mounted, but only one Session owns the
                // daemon control lease. Release the previous focus before
                // promoting the newly selected retained surface.
                blur(sessionID: previousSessionID)
            }
            pendingFocusSessionID = nil
            pendingFocusSize = nil
            pendingFocusResizeSize = nil
            cancelResizeRequests()
            attachedSessionID = nil
            focusedSessionID = nil
        }
        inputRouter.prepare(for: sessionID)
        selectedSessionID = sessionID
        TerminalDiagnostics.log("tab_promote", [
            "session": sessionID.description,
        ])
        guard selectedSessionID == sessionID, self.wire === wire else { return }
        attachedSessionID = sessionID
        TerminalDiagnostics.log("promote_complete", [
            "session": sessionID.description,
        ])
        surfaceManager.requestPresent(sessionID)
        inputRouter.activate(for: sessionID) { [wire] data in
            try? await wire.sendInput(sessionID: sessionID.description, payload: data)
        }
        let measuredSize = surfaceManager.viewportGrid(for: sessionID)
        // Focus ownership is claimed only when the surface actually gained
        // keyboard focus: either the manager parked a request here while the
        // promotion was in flight, or a split sibling is already the first
        // responder and will not report focus again. An unfocused window
        // switching panes must not steal resize authority from another
        // endpoint viewing the same terminal.
        //
        // The claim goes through `session.focus`, never `claimControl`: only a
        // real focus records the client's control lease, so a reconnect
        // reclaims it for this pane instead of the sibling that held it.
        guard pendingFocusSessionID == sessionID
            || surfaceManager.ownsTerminalFocus(sessionID) else { return }
        let pendingSize = pendingFocusSize ?? measuredSize
        pendingFocusSessionID = nil
        pendingFocusSize = nil
        sendFocus(
            sessionID: sessionID,
            focused: true,
            size: pendingSize,
            reason: "promote"
        )
    }

    /// Ends a recovery-failure streak once a payload actually installed.
    ///
    /// Installing the snapshot is the first moment the Host has proved it can
    /// produce a recovery payload; a subscribe acknowledgement cannot. The
    /// retry that follows a failure is cancelled here for the same reason —
    /// the pane is drawing again, so nothing is waiting to re-attach.
    func noteRecoveryPayloadInstalled(_ sessionID: TerminalSessionID) {
        recoveryFailureStreak.noteInstalled(sessionID)
        recoveryFailureTasks.removeValue(forKey: sessionID)?.cancel()
    }

    /// Recovers an attach whose recovery payload the Host failed to produce.
    ///
    /// `session.subscribe` is acknowledged before that payload, so the client
    /// has already marked the attach complete and is waiting for markers that
    /// will never come. Cancel the staged recovery, drop the stale
    /// subscription, and attach again from a clean boundary. Bounded, because
    /// a Host that keeps failing must end in a visible error rather than a
    /// reconnect loop.
    func handleRecoveryFailed(_ sessionID: TerminalSessionID, reason: String) {
        let attempt = recoveryFailureStreak.noteFailure(sessionID)
        TerminalDiagnostics.log("recovery_failed", [
            "session": sessionID.description,
            "reason": reason,
            "attempt": String(attempt),
        ])
        // The Host detached this subscription when the payload failed, so the
        // client's copy is stale either way.
        surfaceManager.cancelRecovery(for: sessionID)
        noteOutputSubscriptionDropped(sessionID, reason: "recoveryFailed")
        clearAtomicRecoveryState(for: sessionID)
        reconnectPreservedSessions.remove(sessionID)
        if attachedSessionID == sessionID {
            attachedSessionID = nil
        }
        if selectedSessionID == sessionID {
            focusedSessionID = nil
            focusClaimInFlight = false
            focusClaimGeneration += 1
            focusTask?.cancel()
            focusTask = nil
            // Nothing can accept these bytes until the re-attach lands.
            inputRouter.discard(for: sessionID)
        }
        guard selectedSessionID == sessionID else {
            // A background surface re-attaches when it is selected; the stale
            // subscription is gone, so that path takes the cold attach.
            return
        }
        guard let delay = RecoveryFailureRetry.delay(afterAttempt: attempt) else {
            recoveryFailureStreak.clear(sessionID)
            TerminalDiagnostics.log("recovery_retries_exhausted", [
                "session": sessionID.description,
                "reason": reason,
            ])
            present(NSError(
                domain: "WarrenRemote",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Terminal recovery failed: " + reason]
            ))
            return
        }
        recoveryFailureTasks[sessionID]?.cancel()
        recoveryFailureTasks[sessionID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.selectedSessionID == sessionID else { return }
            self.recoveryFailureTasks[sessionID] = nil
            TerminalDiagnostics.log("recovery_retry", [
                "session": sessionID.description,
                "attempt": String(attempt),
            ])
            await self.attachSelectedSession()
        }
    }

    /// Recovers the selected Session after its promotion stalled.
    ///
    /// `attachSelectedSession` refuses a Session that is already selected and
    /// attached, and a stalled promotion leaves exactly that state, so clear
    /// the attach marker first: the pane is attached but has never drawn.
    func recoverStalledPrimarySession(_ sessionID: TerminalSessionID) async {
        guard sessionID == selectedSessionID, wire != nil else { return }
        TerminalDiagnostics.log("present_stall_recovery", [
            "session": sessionID.description,
        ])
        attachedSessionID = nil
        await attachSelectedSession()
    }

}
