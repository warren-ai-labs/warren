import AppKit
import GhosttyAdapter
import SwiftUI
import WarrenDesktop
import WarrenDesignSystem
import WarrenDomain
import WarrenTransport

// The Desktop Conversation surface (RFC 0023 §9, `chat-view.html`).
//
// Everything is quiet unless it needs the person: the answer owns the reading
// column at full contrast, the person's message is a bubble that marks it as
// theirs, and one collapsed line carries the whole work trail. The only moving
// thing is the highlight on the live "Working for …" line. Orange is spent in
// exactly three places — a decision's outline, the "needs you" status dot, and
// context over 85% — so it never reads as decoration.

/// The events and status one Conversation surface renders.
@MainActor
final class WarrenConversationFeed: ObservableObject {
    struct PendingPrompt: Identifiable, Equatable {
        let id: String
        let text: String
        var attachments: [String] = []
        var failure: String?
    }

    /// One file on its way to the Host: first the upload (its chip shows a 2pt
    /// progress bar), then a Host-issued reference the next turn carries.
    struct PendingAttachment: Identifiable, Equatable {
        let id: String
        let name: String
        var size: Int64
        var progress: Double
        var reference: WarrenRemoteAgentAttachmentRef?
        var failure: String?

        /// Still uploading: no reference yet and no failure to show.
        var isUploading: Bool { reference == nil && failure == nil }

        init(
            id: String,
            name: String,
            size: Int64 = 0,
            progress: Double = 0,
            reference: WarrenRemoteAgentAttachmentRef? = nil,
            failure: String? = nil
        ) {
            self.id = id
            self.name = name
            self.size = size
            self.progress = progress
            self.reference = reference
            self.failure = failure
        }
    }

    let sessionID: TerminalSessionID
    @Published private(set) var conversation = WarrenConversation()
    @Published private(set) var revision = 0
    @Published private(set) var loaded = false
    @Published var status: AgentStatus?
    @Published var pendingPrompts: [PendingPrompt] = []
    @Published var pendingAttachments: [PendingAttachment] = []
    /// Prompts written while the Agent was busy, sent in order when it is next
    /// ready (`WarrenRemoteApplicationModel.drainConversationQueue`).
    @Published var queuedPrompts: [QueuedPrompt] = []

    struct QueuedPrompt: Identifiable, Equatable {
        let id: String
        let text: String
        var attachments: [WarrenRemoteAgentAttachmentRef] = []
    }

    /// The stream the local replica was last read for; owned by the model.
    var seededStreamID: String?

    private var events: [UInt64: WarrenRemoteAgentEvent] = [:]
    private var streamID: String?
    /// Folds live batches forward; a batch that reaches back (a page of
    /// history) re-projects from every event held.
    private var projector = WarrenConversation.Projector()

    init(sessionID: TerminalSessionID) {
        self.sessionID = sessionID
    }

    func markLoaded() { loaded = true }

    /// Adds a batch from the replica or the live stream. A sequence is an
    /// immutable position, so the first event seen for it wins.
    func merge(_ incoming: [WarrenRemoteAgentEvent], streamID: String) {
        if self.streamID != streamID {
            // A new execution is a new conversation (RFC 0016 §3).
            self.streamID = streamID
            events.removeAll()
            projector = WarrenConversation.Projector()
        }
        var added: [WarrenRemoteAgentEvent] = []
        for event in incoming where events[event.sequence] == nil {
            events[event.sequence] = event
            added.append(event)
        }
        guard !added.isEmpty else { return }
        if !projector.append(added) {
            projector = WarrenConversation.Projector()
            _ = projector.append(Array(events.values))
        }
        conversation = projector.conversation()
        let echoed = Set(conversation.turns.compactMap(\.promptCausedBy))
        pendingPrompts.removeAll { echoed.contains($0.id) }
        revision &+= 1
    }
}

/// Everything the surface needs from its host. A value rather than the model,
/// so the view can be driven by a fixture in tests without a live connection.
struct WarrenConversationActions {
    var openSession: (String) -> Void = { _ in }
    var sessionExists: (String) -> Bool = { _ in false }
    /// Opens a changed file's diff in the right sidebar's Changes tab.
    var reviewFile: (WarrenConversation.FileChange) -> Void = { _ in }
    var supportsConfig = false
    var canHandoff = false
    /// Whether this Session's Host advertises `agent-attachments-v1`.
    var supportsAttachments = false
    /// Sends a prompt, carrying the Host references of any files attached to it.
    var send: (String, [WarrenRemoteAgentAttachmentRef]) -> Void = { _, _ in }
    /// Uploads one local file and leaves its reference on the feed's chip.
    var attach: (URL) -> Void = { _ in }
    var stop: () -> Void = {}
    var setConfig: (String, String) async -> Void = { _, _ in }
    var handoff: () async -> Void = {}
    var resolveDecision: (WarrenConversation.Decision, String) async throws -> Void = { _, _ in }
    /// Resolves a question with the typed answer (the wire's `text`).
    var resolveDecisionText: (WarrenConversation.Decision, String) async throws -> Void = { _, _ in }
    /// Dismisses a permission or confirmation (`resolution["cancelled"]`).
    var cancelDecision: (WarrenConversation.Decision) async throws -> Void = { _ in }
}

struct WarrenConversationSurface: View {
    let sessionID: TerminalSessionID
    /// Observed so the activation token read in `body` is current. Without the
    /// subscription SwiftUI can skip this view's body — its stored properties do
    /// not change when the model publishes — and the request would never reach
    /// the composer.
    @ObservedObject var model: WarrenRemoteApplicationModel
    /// Whether this pane is the one the user is entering. The composer only
    /// consumes an activation token while it is true, so a Session in a
    /// passive split pane, or one covered by an overlay, does not take the
    /// keyboard from what the user is doing.
    var wantsInputFocus: Bool = false

    var body: some View {
        WarrenConversationView(
            sessionID: sessionID,
            feed: model.conversationFeed(for: sessionID),
            providerName: providerName,
            root: model.projection.session(id: sessionID)?.workingDirectory,
            branch: workspaceBranch,
            actions: actions,
            focusRequest: model.conversationFocusTokens[sessionID] ?? 0,
            wantsInputFocus: wantsInputFocus
        )
    }

    private var workspaceBranch: String? {
        guard let session = model.projection.session(id: sessionID),
              let workspaceID = session.workspaceID else { return nil }
        return model.projection.workspace(id: workspaceID)?.branch
    }

    private var providerName: String {
        let session = model.projection.session(id: sessionID)
        return (session?.agentProvider ?? session?.kind)?.displayName ?? "Agent"
    }

    private var actions: WarrenConversationActions {
        var actions = WarrenConversationActions()
        actions.openSession = { model.openSession(named: $0) }
        actions.sessionExists = { model.sessionIsOpen(named: $0) }
        actions.supportsConfig = model.supportsConversationConfig(sessionID)
        actions.canHandoff = model.conversationHasConversation(sessionID)
        actions.supportsAttachments = model.supportsConversationAttachments(sessionID)
        actions.send = { [weak model] text, attachments in
            guard let model else { return }
            let feed = model.conversationFeed(for: sessionID)
            let busy = feed.status?.activity == .working || feed.status?.activity == .blocked
            if busy || !feed.queuedPrompts.isEmpty || feed.pendingPrompts.contains(where: { $0.failure == nil }) {
                model.queueConversationPrompt(text, attachments: attachments, in: feed)
            } else {
                model.submitConversationPrompt(text, attachments: attachments, in: feed)
            }
        }
        actions.attach = { [weak model] url in
            guard let model else { return }
            model.addConversationAttachment(url, in: model.conversationFeed(for: sessionID))
        }
        actions.reviewFile = { [weak model] file in
            guard let model,
                  let workspaceID = model.projection.session(id: sessionID)?.workspaceID,
                  let workspace = model.projection.workspace(id: workspaceID) else { return }
            model.inspector(for: workspace).reveal(path: file.file)
            NotificationCenter.default.post(
                name: WarrenDesktopCommand.reviewFile,
                object: WarrenDesktopReviewFileRequest(workspaceID: workspaceID, path: file.file)
            )
        }
        actions.stop = { [weak model] in
            guard let model, let turn = model.conversationFeed(for: sessionID).conversation.turns.last else { return }
            Task { @MainActor in try? await model.cancelConversationTurn(sessionID, turnID: turn.id) }
        }
        actions.setConfig = { [weak model] id, value in
            guard let model else { return }
            try? await model.setConversationConfig(id, value: value, in: sessionID)
        }
        actions.handoff = { [weak model] in
            guard let model else { return }
            try? await model.handoffConversation(sessionID)
        }
        actions.resolveDecision = { [weak model] decision, optionID in
            guard let model else { return }
            try await model.resolveConversationDecision(decision, optionID: optionID, in: sessionID)
        }
        actions.resolveDecisionText = { [weak model] decision, text in
            guard let model else { return }
            try await model.resolveConversationDecision(decision, resolution: ["text": .string(text)], in: sessionID)
        }
        actions.cancelDecision = { [weak model] decision in
            guard let model else { return }
            try await model.resolveConversationDecision(decision, resolution: ["cancelled": .boolean(true)], in: sessionID)
        }
        return actions
    }
}

private struct ConversationRootKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

/// A render-harness seam: force the pane's disclosures open so a still image
/// can show the expanded work trail without a pointer event.
struct ConversationForcesExpandedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The Session's directory; step targets and changed files under it are
    /// shown relative to it.
    fileprivate var conversationRoot: String? {
        get { self[ConversationRootKey.self] }
        set { self[ConversationRootKey.self] = newValue }
    }

    /// Opens every collapsed disclosure on mount. Test-only; the pane's real
    /// resting state is collapsed.
    var conversationForcesExpanded: Bool {
        get { self[ConversationForcesExpandedKey.self] }
        set { self[ConversationForcesExpandedKey.self] = newValue }
    }
}

/// The Conversation pane's fixed measurements, from the design.
private enum ConversationLayout {
    /// The outer reading column, composer included.
    static let column: CGFloat = 720
    static let widePadding: CGFloat = 24
    static let narrowPadding: CGFloat = 16
    /// 44 between turns, 8 under the last one.
    static let turnGap: CGFloat = 44
    static let lastTurnGap: CGFloat = 8
    /// 12 between an answer's blocks, 16 from the message to the work trail.
    static let innerGap: CGFloat = 12
    static let askGap: CGFloat = 16
    static let bubbleRadius: CGFloat = 12
    static let panelRadius: CGFloat = 12
    /// A pane narrower than this is a split pane: chips lose their labels and
    /// the message bubble takes more of the width.
    static let narrowBreakpoint: CGFloat = 560
    static let bubbleWidthRatio: CGFloat = 0.75
    static let bubbleWidthRatioNarrow: CGFloat = 0.88
    /// The folded message height and its fade.
    static let foldedMaxHeight: CGFloat = 208
}

/// Reading leading for each of the pane's text roles, as the design's
/// size/line-height pairs. SwiftUI's `lineSpacing` is the extra leading on top
/// of the font's own, so these are the pairs minus that leading.
private enum ConversationLeading {
    static let reading: CGFloat = 4
    static let readingTitle: CGFloat = 3
    static let reasoning: CGFloat = 4
    static let mono: CGFloat = 4
    static let monoSmall: CGFloat = 3
}

struct WarrenConversationView: View {
    /// Named only so a focus claim can be attributed in the diagnostics log.
    var sessionID: TerminalSessionID? = nil
    @ObservedObject var feed: WarrenConversationFeed
    let providerName: String
    let root: String?
    var branch: String? = nil
    let actions: WarrenConversationActions
    /// Moves once per activation. The composer focuses when it sees a new
    /// value, which is what lets an activation issued before the pane existed
    /// still land once it mounts.
    var focusRequest: UInt = 0
    var wantsInputFocus: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var textHeight: CGFloat = 22
    @State private var pinnedToBottom = true
    @State private var hasNewReply = false
    @State private var jumpRequest = 0
    @State private var followPending = false
    @State private var width: CGFloat = 700
    @State private var viewportHeight: CGFloat = 0
    @State private var stopping = false
    @State private var focused = false
    @State private var actionError: String?
    /// The answer in flight or last failed for the pending decision. One owner
    /// for the dock's buttons and the 1–9 / Return / Esc keys, so a key press
    /// shows the same progress as a click and cannot answer twice.
    @State private var decisionAttempt: WarrenConversationDecisionAttempt?

    private var palette: WarrenConversationPalette {
        WarrenConversationPalette.resolved(for: colorScheme)
    }

    private var narrow: Bool { width < ConversationLayout.narrowBreakpoint }
    private var horizontalPadding: CGFloat {
        narrow ? ConversationLayout.narrowPadding : ConversationLayout.widePadding
    }
    private var contentWidth: CGFloat {
        max(0, min(width, ConversationLayout.column) - horizontalPadding * 2)
    }

    private var conversation: WarrenConversation { feed.conversation }
    private var lastTurn: WarrenConversation.Turn? { conversation.turns.last }
    private var busy: Bool {
        feed.status?.activity == .working || feed.status?.activity == .blocked
    }
    private var isEmptyConversation: Bool {
        feed.loaded && conversation.turns.isEmpty && feed.pendingPrompts.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            bottomDock
        }
        .background(palette.card)
        .environment(\.conversationRoot, root)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .topLeading) { keyboardShortcuts.opacity(0) }
        .onChange(of: feed.status?.activity) { activity in
            if activity != .working, activity != .blocked { stopping = false }
        }
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isEmptyConversation {
                        emptySession
                            .frame(minHeight: max(0, viewportHeight - 12), alignment: .bottom)
                    } else {
                        ForEach(Array(conversation.turns.enumerated()), id: \.element.id) { index, turn in
                            WarrenConversationTurnView(
                                turn: turn,
                                live: turn.id == lastTurn?.id,
                                waiting: turn.id == lastTurn?.id && !conversation.decisions.isEmpty,
                                isLast: index == conversation.turns.count - 1,
                                contentWidth: contentWidth,
                                narrow: narrow,
                                providerName: providerName,
                                linkedSessionsOpen: turn.steps.compactMap(\.terminalSessionID).map(actions.sessionExists),
                                actions: actions,
                                onEditPrompt: bringIntoComposer,
                                onRetry: retry
                            )
                            .equatable()
                            .padding(.bottom, index == conversation.turns.count - 1
                                ? ConversationLayout.lastTurnGap
                                : ConversationLayout.turnGap)
                        }
                        ForEach(feed.pendingPrompts) { prompt in
                            WarrenConversationPromptView(
                                prompt: prompt.text,
                                attachments: prompt.attachments,
                                meta: prompt.failure ?? "Sending…",
                                contentWidth: contentWidth,
                                narrow: narrow,
                                onCopy: { copyMessage(prompt.text) },
                                onEdit: nil
                            )
                            .opacity(0.72)
                            .padding(.bottom, ConversationLayout.turnGap)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { pinnedToBottom = true; hasNewReply = false }
                        .onDisappear { pinnedToBottom = false }
                }
                .frame(maxWidth: ConversationLayout.column, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.top, ConversationSpacing.compact)
                .padding(.bottom, ConversationSpacing.compact)
                .frame(maxWidth: .infinity)
            }
            .modifier(ConversationBottomAnchor())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .task {
                try? await Task.sleep(nanoseconds: 30_000_000)
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: viewportHeight) { _ in
                guard pinnedToBottom else { return }
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: feed.revision) { _ in
                if pinnedToBottom { followLatest(proxy) }
                else { hasNewReply = true }
            }
            .onChange(of: feed.pendingPrompts.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: feed.queuedPrompts.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: jumpRequest) { _ in
                hasNewReply = false
                pinnedToBottom = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    /// Follows a streaming answer at most once a frame. Tokens can publish
    /// faster than the display refreshes, and each `scrollTo` lays the whole
    /// transcript out again; the trailing scroll still lands on the newest line.
    private func followLatest(_ proxy: ScrollViewProxy) {
        guard !followPending else { return }
        followPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 16_000_000)
            followPending = false
            if pinnedToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: Bottom dock

    private var bottomDock: some View {
        VStack(spacing: 0) {
            if hasNewReply, !isEmptyConversation {
                newReplyButton
                    .padding(.bottom, ConversationSpacing.small)
            }
            composerStack
            composer
        }
        .frame(maxWidth: ConversationLayout.column)
        .padding(.horizontal, horizontalPadding)
        .padding(.bottom, narrow ? 12 : 14)
        .frame(maxWidth: .infinity)
    }

    private var newReplyButton: some View {
        Button {
            jumpRequest &+= 1
        } label: {
            HStack(spacing: 6) {
                Circle().fill(palette.green).frame(width: 6, height: 6)
                Text("New reply")
                Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
            }
            .font(WarrenTypography.caption)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(palette.raise, in: Capsule())
            .overlay(Capsule().strokeBorder(palette.focus, lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 7, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// Everything waiting on the person, stacked from the top: a problem
    /// banner, then the decision, then the plan and the queue, nearest the
    /// composer the things it is about to act on.
    @ViewBuilder
    private var composerStack: some View {
        let plan = feed.status?.activity == .working ? conversation.plan.flatMap { $0.total > 0 ? $0 : nil } : nil
        let decision = conversation.decisions.first
        let hasPanels = actionError != nil || decision != nil || plan != nil || !feed.queuedPrompts.isEmpty
        let panelIdentity = "\(actionError ?? "-")|\(decision?.id ?? "-")|\(plan?.current ?? "-")|\(feed.queuedPrompts.count)"
        if hasPanels {
            VStack(spacing: -1) {
                if let actionError {
                    WarrenConversationStackPanel(outline: palette.red.opacity(0.55), roundsTop: true) {
                        WarrenConversationBanner(message: actionError) { self.actionError = nil }
                    }
                }
                if let decision {
                    WarrenConversationStackPanel(outline: palette.accent.opacity(0.55), roundsTop: actionError == nil) {
                        WarrenConversationDecisionDock(
                            decision: decision,
                            count: conversation.decisions.count,
                            providerName: providerName,
                            attempt: decisionAttempt?.decisionID == decision.id ? decisionAttempt : nil,
                            onChoose: { optionID in choose(decision, optionID: optionID) }
                        )
                    }
                    // A new decision is a new panel, so an answered one leaves
                    // and the next rises in, instead of the text swapping in place.
                    .id(decision.id)
                }
                if plan != nil || !feed.queuedPrompts.isEmpty {
                    WarrenConversationStackPanel(
                        outline: palette.line2,
                        roundsTop: actionError == nil && decision == nil
                    ) {
                        VStack(alignment: .leading, spacing: 0) {
                            if let plan {
                                WarrenConversationPlanStrip(plan: plan)
                            }
                            if plan != nil, !feed.queuedPrompts.isEmpty {
                                Rectangle().fill(palette.line).frame(height: 1)
                            }
                            if !feed.queuedPrompts.isEmpty {
                                WarrenConversationQueuePanel(
                                    prompts: feed.queuedPrompts,
                                    onEdit: { prompt in
                                        feed.queuedPrompts.removeAll { $0.id == prompt.id }
                                        bringIntoComposer(prompt.text)
                                    },
                                    onRemove: { prompt in
                                        feed.queuedPrompts.removeAll { $0.id == prompt.id }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(.bottom, -1)
            .animation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion), value: panelIdentity)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !feed.pendingAttachments.isEmpty {
                WarrenConversationAttachmentChips(attachments: feed.pendingAttachments) { id in
                    feed.pendingAttachments.removeAll { $0.id == id }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }
            ZStack(alignment: .topLeading) {
                if draft.isEmpty {
                    Text(placeholder)
                        .font(WarrenTypography.reading)
                        .foregroundStyle(palette.ink4)
                        .padding(.leading, 1)
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
                WarrenConversationTextView(
                    sessionID: sessionID,
                    text: $draft,
                    height: $textHeight,
                    isEditable: true,
                    focusRequest: focusRequest,
                    wantsInputFocus: wantsInputFocus,
                    onSubmit: submitDraft,
                    onEscape: handleEscape,
                    onSelectOption: selectDecisionOption,
                    onRestorePrevious: restorePrevious,
                    onJumpToLatest: { jumpRequest &+= 1 },
                    onCopyLastAnswer: copyLastAnswer,
                    onFocusChange: { focused = $0 }
                )
                .frame(height: min(max(textHeight, 46), 220))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            composerFooter
        }
        .background(palette.raise, in: RoundedRectangle(cornerRadius: WarrenRadius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.composer, style: .continuous)
                .strokeBorder(focused ? palette.focus : palette.line2, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
    }

    private func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls { actions.attach(url) }
        }
    }

    private var placeholder: String {
        if !conversation.decisions.isEmpty { return "Or tell \(providerName) what to do instead" }
        if busy { return "Add a follow-up, sent after this turn" }
        return isEmptyConversation ? "Ask \(providerName) to do something on this branch" : "Reply to \(providerName)"
    }

    private var composerFooter: some View {
        HStack(spacing: 6) {
            if actions.supportsAttachments {
                Button(action: pickAttachments) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.ink3)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .warrenTooltip("Add files")
                .accessibilityLabel("Add files")
            }

            if actions.supportsConfig, let mode = conversation.modeOption {
                WarrenConversationChip(
                    icon: WarrenConversationModeIcon.symbol(mode.currentValue),
                    label: mode.shortName,
                    narrow: narrow,
                    options: [mode],
                    onSetConfig: actions.setConfig
                )
            }
            if let note = statusNote {
                Text(note).font(WarrenTypography.caption).foregroundStyle(palette.accent)
            }
            Spacer(minLength: 6)
            if focused, !narrow {
                Text("↵ send")
                    .font(WarrenTypography.caption)
                    .foregroundStyle(palette.ink4)
                    .padding(.trailing, 4)
            }
            if let context = conversation.context, context.size > 0 {
                WarrenConversationContextMeter(context: context)
            }
            if !conversation.modelOptions.isEmpty {
                WarrenConversationChip(
                    icon: narrow ? "cpu" : nil,
                    label: conversation.modelSummary.isEmpty ? "Model" : conversation.modelSummary,
                    narrow: narrow,
                    options: conversation.modelOptions,
                    onSetConfig: actions.setConfig
                )
            }
            sendButton
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var sendButton: some View {
        if busy {
            Button(action: stop) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.card)
                    .frame(width: 9, height: 9)
                    .frame(width: 28, height: 28)
                    .background(palette.ink.opacity(stopping ? 0.4 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(stopping)
            .warrenTooltip(stopping ? "Stopping…" : "Stop", shortcut: stopping ? nil : "Esc")
            .accessibilityLabel("Stop")
        } else {
            Button(action: submitDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canSend ? palette.card : palette.ink4)
                    .frame(width: 28, height: 28)
                    .background(canSend ? palette.ink : palette.press, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .warrenTooltip("Send", shortcut: "⏎")
            .accessibilityLabel("Send")
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !feed.pendingAttachments.contains(where: \.isUploading)
    }

    private var statusNote: String? {
        switch feed.status?.activity {
        case .failed: "Failed"
        case .exited: "Ended"
        case nil: feed.loaded ? nil : "Starting"
        default: nil
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("") { jumpRequest &+= 1 }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("", action: copyLastAnswer)
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Empty session

    private var emptySession: some View {
        let place = root.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            Text("What should we work on?")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.ink)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                Text(place.isEmpty ? "this workspace" : "~/" + place)
                if let branch, !branch.isEmpty {
                    Text("·")
                    Text(branch)
                }
            }
            .font(WarrenTypography.mono)
            .foregroundStyle(palette.ink4)
            .padding(.bottom, 10)
            if !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions.prefix(3), id: \.self) { suggestion in
                        Button {
                            draft = suggestion
                        } label: {
                            Text(suggestion)
                                .font(WarrenTypography.caption)
                                .foregroundStyle(palette.ink2)
                                .padding(.horizontal, 11)
                                .frame(height: 28)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var suggestions: [String] {
        ["Summarize this branch", "Run the tests and fix failures", "Explain what changed here"]
    }

    // MARK: Actions

    private func submitDraft() {
        // Return on an empty composer takes the dock's first option, as its
        // ↵ hint says.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let decision = conversation.decisions.first,
           let first = decision.options.first {
            choose(decision, optionID: first.id)
            return
        }
        guard canSend else { return }
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        textHeight = 22
        pinnedToBottom = true
        hasNewReply = false
        if let decision = conversation.decisions.first {
            reject(decision, explaining: value)
            return
        }
        let attachments = feed.pendingAttachments.compactMap(\.reference)
        // Uploaded files go out with the message; a chip that failed stays so
        // the failure is still visible after the send.
        feed.pendingAttachments.removeAll { $0.reference != nil }
        actions.send(value, attachments)
    }

    /// A message written at a pending decision is an answer, not a prompt.
    ///
    /// A question takes the text as its answer. A permission or confirmation
    /// cannot carry a note: the Host's resolution accepts only an option id,
    /// and the ACP permission response has no note field either. So the typed
    /// text dismisses the decision as `cancelled` and is then sent as the next
    /// prompt — the two steps that produce "reject and explain".
    private func reject(_ decision: WarrenConversation.Decision, explaining note: String) {
        switch WarrenConversationDecisionReply.reply(kind: decision.kind, typed: note) {
        case .answer(let text):
            Task { @MainActor in
                do {
                    try await actions.resolveDecisionText(decision, text)
                } catch {
                    actionError = error.localizedDescription
                    restoreDraft(text)
                }
            }
        case .rejectThenPrompt(let text):
            Task { @MainActor in
                do {
                    try await actions.cancelDecision(decision)
                    actions.send(text, [])
                } catch {
                    actionError = error.localizedDescription
                    restoreDraft(text)
                }
            }
        }
    }

    /// Puts failed text back ahead of any draft typed while it was in flight.
    private func restoreDraft(_ text: String) {
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = current.isEmpty ? text : text + "\n\n" + current
    }

    private func stop() {
        guard !stopping, let turn = lastTurn, turn.status == .running else { return }
        stopping = true
        actions.stop()
    }

    private func handleEscape() {
        if let decision = conversation.decisions.first {
            choose(decision, optionID: rejectionOptionID(for: decision))
        } else if busy {
            stop()
        } else {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func selectDecisionOption(_ digit: Int) -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let decision = conversation.decisions.first,
              digit >= 1, digit <= decision.options.count else { return false }
        choose(decision, optionID: decision.options[digit - 1].id)
        return true
    }

    private func rejectionOptionID(for decision: WarrenConversation.Decision) -> String {
        let reject = decision.options.last { $0.isReject } ?? decision.options.last
        return reject?.id ?? ""
    }

    private func choose(_ decision: WarrenConversation.Decision, optionID: String) {
        guard !optionID.isEmpty else { return }
        if let attempt = decisionAttempt, attempt.decisionID == decision.id, attempt.optionID != nil { return }
        decisionAttempt = WarrenConversationDecisionAttempt(decisionID: decision.id, optionID: optionID)
        Task { @MainActor in
            do {
                // On success the attempt stays, holding the buttons, until the
                // Host retires the decision and the dock moves on.
                try await actions.resolveDecision(decision, optionID)
            } catch {
                decisionAttempt = WarrenConversationDecisionAttempt(
                    decisionID: decision.id,
                    optionID: nil,
                    error: error.localizedDescription
                )
            }
        }
    }

    private func restorePrevious() -> Bool {
        if let queued = feed.queuedPrompts.last {
            feed.queuedPrompts.removeAll { $0.id == queued.id }
            draft = queued.text
            return true
        }
        if let prompt = conversation.turns.last(where: { $0.prompt != nil })?.prompt {
            draft = prompt
            return true
        }
        return false
    }

    /// Puts a message back in the composer after anything already typed, so
    /// bringing one back never discards a draft.
    private func bringIntoComposer(_ text: String) {
        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = current.isEmpty ? text : current + "\n\n" + text
    }

    /// Re-sends the turn's own prompt. For a CLI agent a retry *is* the same
    /// prompt sent again, so the client replays the message it already has;
    /// it is offered only on the last turn (see the answer footer). A true
    /// `retry(turnID)` would need a Host command and is not needed here.
    private func retry(_ turn: WarrenConversation.Turn) {
        guard let prompt = turn.prompt, !prompt.isEmpty else { return }
        pinnedToBottom = true
        actions.send(prompt, [])
    }

    private func copyMessage(_ text: String) {
        WarrenCopyFeedback.shared.copy(text, announcing: "Copied message")
    }

    private func copyLastAnswer() {
        guard let answer = lastTurn?.answer else { return }
        WarrenCopyFeedback.shared.copy(answer, announcing: "Copied answer")
    }
}

/// Pins the transcript to the newest content on first layout. `defaultScrollAnchor`
/// is the platform's own answer on macOS 14; older systems fall back to the
/// deferred `scrollTo` in the reader above.
private struct ConversationBottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            content
        }
    }
}

private enum ConversationSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let small: CGFloat = 6
    static let compact: CGFloat = 8
    static let medium: CGFloat = 12
}

/// What typing into the composer at a pending decision means.
///
/// A question can take the text as its answer (`resolution["text"]`). A
/// permission or confirmation cannot: the Host's resolution has no note field,
/// so the text has to come back as the next prompt after the dismissal.
enum WarrenConversationDecisionReply: Equatable {
    case answer(String)
    case rejectThenPrompt(String)

    static func reply(kind: String, typed: String) -> WarrenConversationDecisionReply {
        kind == "question" ? .answer(typed) : .rejectThenPrompt(typed)
    }
}

// MARK: - Turn

private struct WarrenConversationTurnView: View, Equatable {
    let turn: WarrenConversation.Turn
    let live: Bool
    let waiting: Bool
    let isLast: Bool
    let contentWidth: CGFloat
    let narrow: Bool
    let providerName: String
    /// Whether each step's linked terminal Session is open, in step order.
    /// The step rows ask `actions.sessionExists`, which the equality below
    /// cannot see, so the answer travels with the compared inputs.
    let linkedSessionsOpen: [Bool]
    let actions: WarrenConversationActions
    let onEditPrompt: (String) -> Void
    let onRetry: (WarrenConversation.Turn) -> Void

    /// Lets a settled turn skip its body while the live one streams. The
    /// closures are left out: they capture the model, this Session and the
    /// pane's state storage, none of which change under one transcript.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.turn == rhs.turn
            && lhs.live == rhs.live
            && lhs.waiting == rhs.waiting
            && lhs.isLast == rhs.isLast
            && lhs.contentWidth == rhs.contentWidth
            && lhs.narrow == rhs.narrow
            && lhs.providerName == rhs.providerName
            && lhs.linkedSessionsOpen == rhs.linkedSessionsOpen
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        let running = live && turn.status == .running
        VStack(alignment: .leading, spacing: ConversationLayout.innerGap) {
            if let prompt = turn.prompt {
                WarrenConversationPromptView(
                    prompt: prompt,
                    attachments: turn.promptAttachments,
                    meta: nil,
                    contentWidth: contentWidth,
                    narrow: narrow,
                    onCopy: { WarrenCopyFeedback.shared.copy(prompt, announcing: "Copied message") },
                    onEdit: { onEditPrompt(prompt) }
                )
                .padding(.bottom, ConversationLayout.askGap - ConversationLayout.innerGap)
            }
            if running || !turn.steps.isEmpty || !turn.narration.isEmpty {
                WarrenConversationWorkTrail(
                    turn: turn,
                    running: running,
                    waiting: waiting,
                    contentWidth: contentWidth,
                    actions: actions
                )
            }
            if !turn.reasoning.text.isEmpty {
                WarrenConversationDisclosure(label: reasoningLabel) {
                    Text(turn.reasoning.text)
                        .font(WarrenTypography.body)
                        .lineSpacing(ConversationLeading.reasoning)
                        .foregroundStyle(palette.ink3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            let answer = running
                ? WarrenConversation.visibleStreamingText(turn.answer, complete: turn.answerComplete)
                : turn.answer
            if !answer.isEmpty {
                WarrenConversationMarkdown(text: answer, style: .answer, streaming: running && !turn.answerComplete)
            }
            ForEach(Array(turn.notices.enumerated()), id: \.offset) { _, notice in
                switch notice.kind {
                case .command:
                    // A slash command the person ran, as one quiet mono line.
                    (Text(notice.command).font(WarrenTypography.monoSmall)
                        + Text(notice.args.isEmpty ? "" : " \(notice.args)").font(WarrenTypography.caption))
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                case .output:
                    Text(notice.text)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(palette.ink3)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .note:
                    Text(notice.text).font(WarrenTypography.caption).foregroundStyle(palette.ink3)
                }
            }
            ForEach(Array(turn.errors.enumerated()), id: \.offset) { _, error in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(palette.red).frame(width: 6, height: 6).padding(.top, 7)
                    Text(error)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(palette.ink2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !running, turn.status == .cancelled, turn.errors.isEmpty {
                Text("Stopped.").font(WarrenTypography.caption).foregroundStyle(palette.ink3)
            }
            if !turn.files.isEmpty {
                WarrenConversationFilesCard(
                    files: turn.files,
                    onReview: actions.reviewFile,
                    onReviewAll: { actions.reviewFile(turn.files[0]) }
                )
            }
            if !running, !turn.answer.isEmpty {
                WarrenConversationAnswerFooter(
                    answer: turn.answer,
                    endedAt: turn.endedAt,
                    visible: isLast || hovering,
                    // Retry replays the prompt, so it is offered only on the
                    // last turn: an earlier turn's prompt is old context.
                    onRetry: isLast ? { onRetry(turn) } : nil
                )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var reasoningLabel: String {
        let seconds = turn.reasoning.seconds
        return seconds > 0 ? "Thought for \(seconds)s" : "Thought"
    }

}

// MARK: - Person's message

/// The person's message: a bubble on the trailing side, so the answers own the
/// reading column. A long paste folds at eight lines with an inline "Show more",
/// and hovering reveals Copy and Edit and resend.
private struct WarrenConversationPromptView: View {
    let prompt: String
    let attachments: [String]
    var meta: String?
    let contentWidth: CGFloat
    let narrow: Bool
    let onCopy: () -> Void
    var onEdit: (() -> Void)?

    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private static let foldedLineLimit = 8

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        let folds = Self.isLong(prompt)
        let maxWidth = contentWidth * (narrow
            ? ConversationLayout.bubbleWidthRatioNarrow
            : ConversationLayout.bubbleWidthRatio)
        HStack(spacing: 0) {
            Spacer(minLength: contentWidth * 0.12)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(attachments, id: \.self) { name in
                            WarrenConversationAttachmentChip(name: name)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .bottomLeading) {
                        WarrenConversationMarkdown(text: prompt, style: .message, streaming: false)
                            .frame(maxHeight: folds && !expanded ? ConversationLayout.foldedMaxHeight : nil, alignment: .top)
                            .padding(.bottom, folds && !expanded ? 24 : 0)
                            .clipped()
                        if folds && !expanded {
                            LinearGradient(
                                colors: [palette.bubble.opacity(0), palette.bubble],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 64)
                            .allowsHitTesting(false)
                        }
                        if folds {
                            Button {
                                expanded.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(expanded ? "Show less" : "Show more")
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .rotationEffect(.degrees(expanded ? 180 : 0))
                                }
                                .font(WarrenTypography.caption)
                                .foregroundStyle(palette.ink3)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 14)
                            .padding(.bottom, 8)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.bubble, in: RoundedRectangle(cornerRadius: ConversationLayout.bubbleRadius, style: .continuous))
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
                if hovering || meta != nil {
                    HStack(spacing: 2) {
                        if let meta {
                            Text(meta).font(WarrenTypography.caption).foregroundStyle(palette.ink4)
                        }
                        iconButton("square.on.square", label: "Copy", action: onCopy)
                        if let onEdit {
                            iconButton("pencil", label: "Edit and resend", action: onEdit)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onHover { hovering = $0 }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.ink4)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .warrenTooltip(label)
        .accessibilityLabel(label)
    }

    static func isLong(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).count > foldedLineLimit
    }
}

private struct WarrenConversationAttachmentChip: View {
    let name: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").font(.system(size: 11))
            Text(name).lineLimit(1)
        }
        .font(WarrenTypography.caption)
        .foregroundStyle(WarrenConversationPalette.resolved(for: colorScheme).ink2)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 26)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(WarrenConversationPalette.resolved(for: colorScheme).line2, lineWidth: 1)
        )
    }
}

/// Attachment chips above the composer's text area. One in flight shows a 2pt
/// progress bar along the chip's bottom edge and its percentage instead of a
/// spinner; one that failed shows the reason and stays until it is removed.
private struct WarrenConversationAttachmentChips: View {
    let attachments: [WarrenConversationFeed.PendingAttachment]
    let onRemove: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        HStack(spacing: 6) {
            ForEach(attachments) { attachment in
                HStack(spacing: 6) {
                    Image(systemName: attachment.failure == nil ? "doc" : "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text(attachment.name).lineLimit(1)
                    Text(detail(attachment))
                        .foregroundStyle(attachment.failure == nil ? palette.ink4 : palette.red)
                        .lineLimit(1)
                    Button {
                        onRemove(attachment.id)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
                .font(WarrenTypography.caption)
                .foregroundStyle(attachment.failure == nil ? palette.ink2 : palette.red)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(palette.raise, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            attachment.failure == nil ? palette.line2 : palette.red.opacity(0.6),
                            lineWidth: 1
                        )
                )
                .overlay(alignment: .bottomLeading) {
                    if attachment.isUploading {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(palette.ink3)
                                .frame(width: geometry.size.width * min(1, max(0, attachment.progress)), height: 2)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    /// The chip's second field: percent while uploading, the reason on
    /// failure, and the file's size once it is ready.
    private func detail(_ attachment: WarrenConversationFeed.PendingAttachment) -> String {
        if attachment.isUploading {
            return "\(Int((attachment.progress * 100).rounded()))%"
        }
        if let failure = attachment.failure { return failure }
        return attachment.size > 0
            ? ByteCountFormatter.string(fromByteCount: attachment.size, countStyle: .file)
            : ""
    }
}

// MARK: - Disclosures

private struct WarrenConversationDisclosure<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationForcesExpanded) private var forcesExpanded

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: ConversationSpacing.xxs) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(palette.ink4)
                    Text(label)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(palette.ink3)
                        .lineLimit(1)
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(palette.line).frame(width: 1)
                    }
                    .padding(.leading, 6)
            }
        }
        .onAppear { if forcesExpanded { open = true } }
    }
}

// MARK: - Work trail

private struct WarrenConversationWorkTrail: View {
    let turn: WarrenConversation.Turn
    let running: Bool
    let waiting: Bool
    let contentWidth: CGFloat
    let actions: WarrenConversationActions

    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.conversationForcesExpanded) private var forcesExpanded

    private static let windowSize = 3

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        let additions = turn.files.reduce(0) { $0 + $1.additions }
        let deletions = turn.files.reduce(0) { $0 + $1.deletions }
        let failures = turn.steps.filter { $0.kind == .tool && $0.status == .failed }.count
        let window = Array(turn.steps.sorted { $0.order < $1.order }.suffix(Self.windowSize))
        VStack(alignment: .leading, spacing: ConversationSpacing.xxs) {
            Button {
                if !turn.steps.isEmpty { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if running {
                        if waiting {
                            Text("Waiting").font(WarrenTypography.caption).foregroundStyle(palette.ink3)
                        } else {
                            // The label ticks on its own clock: a settled
                            // turn view skips re-renders, and a long tool run
                            // publishes nothing for the count to ride on.
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                WarrenConversationShimmer(
                                    text: "Working for \(elapsed(at: context.date))",
                                    font: WarrenTypography.caption,
                                    base: palette.ink3,
                                    highlight: palette.ink
                                )
                            }
                        }
                    } else {
                        Text(turn.settledLabel)
                            .font(WarrenTypography.caption)
                            .foregroundStyle(palette.ink3)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if additions > 0 || deletions > 0 {
                            HStack(spacing: 4) {
                                Text("+\(additions)").foregroundStyle(palette.green)
                                Text("−\(deletions)").foregroundStyle(palette.red)
                            }
                            .font(WarrenTypography.monoSmall)
                        }
                    }
                    if failures > 0 {
                        Text("\(failures) failed")
                            .font(WarrenTypography.caption)
                            .foregroundStyle(palette.red)
                    }
                    if !turn.steps.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(palette.ink4)
                    }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if running, !open, !window.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(window.enumerated()), id: \.element.id) { index, step in
                        WarrenConversationStepLine(step: step, dim: index < window.count - 1, current: index == window.count - 1)
                            .transition(.offset(y: 3).combined(with: .opacity))
                    }
                }
                .padding(.leading, 20)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: window.map(\.id))
            }

            if open {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(turn.steps.sorted { $0.order < $1.order }) { step in
                        WarrenConversationStepRow(step: step, openSession: actions.openSession, sessionExists: actions.sessionExists)
                    }
                }
                .padding(.vertical, 2)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(palette.line).frame(width: 1)
                }
                .padding(.leading, 6)
            }
        }
        .onAppear { if forcesExpanded, !turn.steps.isEmpty { open = true } }
    }

    private func elapsed(at date: Date) -> String {
        guard let startedAt = turn.startedAt else { return "0s" }
        return WarrenConversation.formatElapsed(date.timeIntervalSince(startedAt))
    }
}

/// A stepped highlight sweep across secondary text: 2 s per pass in 20 steps,
/// off under Reduce Motion. The transcript's only moving thing; 10 Hz keeps the
/// sweep legible while asking half as many display cycles of the pane as 20 Hz.
struct WarrenConversationShimmer: View {
    let text: String
    var font: Font = WarrenTypography.caption
    let base: Color
    let highlight: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stepInterval: TimeInterval = 0.1
    private static let stepsPerPass: Double = 20

    var body: some View {
        if reduceMotion {
            Text(text).font(font).foregroundStyle(base)
        } else {
            TimelineView(.periodic(from: .now, by: Self.stepInterval)) { context in
                let step = (context.date.timeIntervalSinceReferenceDate / Self.stepInterval).rounded(.down)
                let phase = step.truncatingRemainder(dividingBy: Self.stepsPerPass) / Self.stepsPerPass
                let center = -0.5 + 2 * phase
                Text(text)
                    .font(font)
                    .foregroundStyle(
                        LinearGradient(
                            stops: [
                                .init(color: base, location: 0.4),
                                .init(color: highlight, location: 0.5),
                                .init(color: base, location: 0.6),
                            ],
                            startPoint: UnitPoint(x: center - 1, y: 0.5),
                            endPoint: UnitPoint(x: center + 1, y: 0.5)
                        )
                    )
            }
        }
    }
}

private struct WarrenConversationStepLine: View {
    let step: WarrenConversation.Step
    let dim: Bool
    let current: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationRoot) private var root

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        let line = step.line(relativeTo: root)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: WarrenConversationStepIcon.symbol(for: step.toolKind))
                .font(.system(size: 11))
                .foregroundStyle(palette.ink4)
            Text(line.verb).font(WarrenTypography.captionEmphasis).foregroundStyle(palette.ink2)
            if !line.target.isEmpty {
                Text(line.target)
                    .font(WarrenTypography.monoSmall)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(dim ? 0.55 : 1)
    }
}

private struct WarrenConversationStepRow: View {
    let step: WarrenConversation.Step
    var openSession: (String) -> Void = { _ in }
    var sessionExists: (String) -> Bool = { _ in false }
    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationRoot) private var root
    @Environment(\.conversationForcesExpanded) private var forcesExpanded

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        let line = step.line(relativeTo: root)
        let detail = step.error.isEmpty ? step.output : step.error
        let hasOutput = !detail.isEmpty
        let hasDiff = step.diff?.text.isEmpty == false
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if hasOutput || hasDiff { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: WarrenConversationStepIcon.symbol(for: step.toolKind))
                        .font(.system(size: 11))
                        .foregroundStyle(step.status == .failed ? palette.red : palette.ink4)
                    Text(line.verb)
                        .font(WarrenTypography.captionEmphasis)
                        .foregroundStyle(step.status == .failed ? palette.red : palette.ink2)
                    if !line.target.isEmpty {
                        Text(line.target)
                            .font(WarrenTypography.monoSmall)
                            .foregroundStyle(palette.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let diff = step.diff {
                        WarrenConversationChangeCount(additions: diff.additions, deletions: diff.deletions)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasOutput && !hasDiff)
            if let terminal = step.terminalSessionID, sessionExists(terminal) {
                Button("Open Terminal") { openSession(terminal) }
                    .buttonStyle(.plain)
                    .font(WarrenTypography.caption)
                    .foregroundStyle(palette.blue)
                    .padding(.leading, 18)
            }
            if open {
                if let diff = step.diff, !diff.text.isEmpty {
                    WarrenConversationDiffView(text: diff.text)
                } else if hasOutput {
                    WarrenConversationOutputBox(text: detail)
                }
            }
        }
        .onAppear {
            let hasDiff = step.diff?.text.isEmpty == false
            let hasOutput = !(step.error.isEmpty && step.output.isEmpty)
            if forcesExpanded, hasOutput, !hasDiff { open = true }
        }
    }
}

private enum WarrenConversationStepIcon {
    static func symbol(for toolKind: String) -> String {
        switch toolKind {
        case "read": "doc.text"
        case "edit", "write": "pencil"
        case "delete": "trash"
        case "move": "arrow.right"
        case "ran": "terminal"
        case "grep", "glob", "search": "magnifyingglass"
        case "fetch": "globe"
        case "think": "brain"
        case "skill": "puzzlepiece"
        default: "gearshape"
        }
    }
}

private struct WarrenConversationChangeCount: View {
    let additions: Int
    let deletions: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        if additions > 0 || deletions > 0 {
            HStack(spacing: 4) {
                Text("+\(additions)").foregroundStyle(palette.green)
                Text("−\(deletions)").foregroundStyle(palette.red)
            }
            .font(WarrenTypography.monoSmall)
        }
    }
}

// MARK: - Answer footer

private struct WarrenConversationAnswerFooter: View {
    let answer: String
    let endedAt: Date?
    let visible: Bool
    /// Nil on a turn that is not the last: only the newest turn can be retried.
    let onRetry: (() -> Void)?
    @ObservedObject private var copyFeedback = WarrenCopyFeedback.shared
    @State private var copySource = UUID().uuidString
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        HStack(spacing: 2) {
            iconButton(copyFeedback.confirms(copySource) ? "checkmark" : "square.on.square", label: "Copy") {
                copyFeedback.copy(answer, confirmingIn: copySource)
            }
            if let onRetry {
                iconButton("arrow.clockwise", label: "Retry", action: onRetry)
            }
            Menu {
                Button("Copy Markdown") {
                    copyFeedback.copy(answer, announcing: "Copied Markdown")
                }
                if let onRetry {
                    Button("Retry Turn", action: onRetry)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.ink4)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .warrenTooltip("More")
            if let endedAt {
                Text(Self.format(endedAt))
                    .font(WarrenTypography.monoSmall)
                    .foregroundStyle(palette.ink4)
                    .padding(.leading, 6)
            }
        }
        .padding(.top, 2)
        .padding(.leading, -4)
        .opacity(visible ? 1 : 0)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(palette.ink4)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .warrenTooltip(label)
        .accessibilityLabel(label)
    }

    static func format(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

// MARK: - Markdown

/// The Conversation's Markdown, shared by the answer (`.answer`, 15/22, blocks
/// 12 apart) and the person's bubble (`.message`, blocks 8 apart, headings as
/// bold body, code in the raised bubble tone).
struct WarrenConversationMarkdown: View {
    enum Style { case answer, message }
    let text: String
    var style: Style
    var streaming: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        let blocks = WarrenMarkdownCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, tokens: palette, isLast: index == blocks.count - 1)
                    .padding(.top, index == 0 ? 0 : spacing(before: index, blocks: blocks))
            }
        }
        .foregroundStyle(palette.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: WarrenMarkdownBlock, tokens: WarrenConversationPalette, isLast: Bool) -> some View {
        switch block {
        case .paragraph(let value):
            inline(value, tokens: tokens, caret: streaming && isLast)
                .font(WarrenTypography.reading)
                .lineSpacing(ConversationLeading.reading)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inline(value, tokens: tokens, caret: false)
                .font(style == .answer ? WarrenTypography.readingTitle : WarrenTypography.readingStrong)
                .lineSpacing(ConversationLeading.readingTitle)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items), .orderedList(let items):
            VStack(alignment: .leading, spacing: style == .message ? 2 : 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marker(item, tokens: tokens)
                        inline(item.text, tokens: tokens, caret: false)
                            .font(WarrenTypography.reading)
                            .lineSpacing(ConversationLeading.reading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
            .padding(.leading, 22)
        case .quote(let value):
            inline(value, tokens: tokens, caret: false)
                .font(WarrenTypography.reading)
                .lineSpacing(ConversationLeading.reading)
                .foregroundStyle(palette.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(style == .message ? palette.quote : palette.line2)
                        .frame(width: 2)
                }
        case .alert(let alert):
            VStack(alignment: .leading, spacing: 4) {
                Label(alert.title, systemImage: alert.kind.symbol)
                    .font(WarrenTypography.readingEmphasis)
                    .foregroundStyle(alertTint(alert.kind, tokens: tokens))
                inline(alert.content, tokens: tokens, caret: false)
                    .font(WarrenTypography.reading)
                    .lineSpacing(ConversationLeading.reading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                Rectangle().fill(alertTint(alert.kind, tokens: tokens)).frame(width: 2)
            }
        case .table(let table):
            WarrenConversationTable(table: table, style: style, inline: { inline($0, tokens: tokens, caret: false) })
        case .code(let language, let value):
            WarrenConversationCodeFence(language: language, code: value, style: style)
        case .divider:
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private func marker(_ item: WarrenMarkdownListItem, tokens: WarrenConversationPalette) -> some View {
        if let checked = item.taskState {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(checked ? palette.green : palette.ink3)
        } else if item.marker == "•" {
            Text(item.depth == 0 ? "•" : "◦")
                .font(WarrenTypography.reading)
                .foregroundStyle(style == .message ? palette.ink3 : palette.ink4)
                .frame(minWidth: 10, alignment: .center)
        } else {
            Text(item.marker)
                .font(WarrenTypography.reading.monospacedDigit())
                .foregroundStyle(style == .message ? palette.ink3 : palette.ink4)
                .frame(minWidth: 18, alignment: .trailing)
        }
    }

    /// Room above a block. An answer's headings open a section (22 above, 8
    /// below); a bubble's blocks are a flat 8.
    private func spacing(before index: Int, blocks: [WarrenMarkdownBlock]) -> CGFloat {
        guard style == .answer else { return 8 }
        if case .heading = blocks[index - 1] { return 8 }
        switch blocks[index] {
        case .heading(let level, _): return level <= 2 ? 22 : 14
        case .code, .table: return 12
        default: return 12
        }
    }

    private func alertTint(_ kind: WarrenMarkdownAlertKind, tokens: WarrenConversationPalette) -> Color {
        switch kind {
        case .note, .important: palette.blue
        case .tip: palette.green
        case .warning: palette.accent
        case .caution: palette.red
        }
    }

    private func inline(_ value: String, tokens: WarrenConversationPalette, caret: Bool) -> Text {
        // The streaming paragraph changes with every token, so caching it
        // would only crowd settled text out of the cache.
        guard let attributed = styledInline(value, cacheable: !caret) else { return Text(value) }
        var text = Text(attributed)
        if caret {
            text = text + Text(" ▌").foregroundColor(palette.ink3)
        }
        return text
    }

    /// The parsed and coloured fragment, or nil when Foundation cannot parse
    /// it. Keyed by everything that styles it: the source, the style and the
    /// appearance the palette resolves from.
    private func styledInline(_ value: String, cacheable: Bool) -> AttributedString? {
        let key = "\(style == .answer ? "a" : "m")\(colorScheme == .light ? "l" : "d")|\(value)"
        if let cached = WarrenConversationInlineCache.shared.value(for: key) { return cached }
        let source = WarrenMarkdownCache.shared.preservedLineBreaks(for: value)
        let codeFont = Font.system(size: 13, design: .monospaced)
        let codeBackground = style == .message ? palette.ink.opacity(0.07) : palette.bubble
        guard var attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return nil
        }
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = codeFont
                attributed[run.range].backgroundColor = codeBackground
                attributed[run.range].foregroundColor = palette.ink
            } else if let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = style == .answer ? WarrenTypography.readingStrong : WarrenTypography.readingStrong
            }
            if run.link != nil {
                attributed[run.range].underlineStyle = .single
                attributed[run.range].foregroundColor = palette.ink
            }
        }
        if cacheable { WarrenConversationInlineCache.shared.store(attributed, for: key) }
        return attributed
    }
}

/// Styled inline Markdown for the Conversation. Every settled answer re-renders
/// whenever its pane does, and `AttributedString(markdown:)` per paragraph was
/// the transcript's heaviest body cost. Bounded like `WarrenMarkdownCache`.
private final class WarrenConversationInlineCache: @unchecked Sendable {
    static let shared = WarrenConversationInlineCache()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private let cache = NSCache<NSString, Box>()

    private init() {
        cache.countLimit = 1024
        cache.totalCostLimit = 8 * 1024 * 1024
    }

    func value(for key: String) -> AttributedString? {
        cache.object(forKey: key as NSString)?.value
    }

    func store(_ value: AttributedString, for key: String) {
        cache.setObject(Box(value), forKey: key as NSString, cost: key.utf8.count)
    }
}

/// A fenced code block. The answer's block has a language header and a copy
/// button and scrolls sideways; the bubble's is a plain raised box.
private struct WarrenConversationCodeFence: View {
    let language: String?
    let code: String
    var style: WarrenConversationMarkdown.Style = .answer
    @ObservedObject private var copyFeedback = WarrenCopyFeedback.shared
    @State private var copySource = UUID().uuidString
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        if style == .answer {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text((language?.isEmpty == false ? language! : "text").lowercased())
                        .font(WarrenTypography.monoSmall)
                        .foregroundStyle(palette.ink4)
                    Spacer(minLength: 0)
                    Button {
                        copyFeedback.copy(code, confirmingIn: copySource)
                    } label: {
                        Image(systemName: copyFeedback.confirms(copySource) ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.ink4)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .warrenTooltip("Copy code")
                }
                .frame(height: 30)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.line).frame(height: 1)
                }
                WarrenConversationLeadingScroll(.horizontal) {
                    Text(code)
                        .font(WarrenTypography.mono)
                        .lineSpacing(ConversationLeading.mono)
                        .foregroundStyle(palette.ink2)
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                }
            }
            .background(palette.code, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
        } else {
            WarrenConversationLeadingScroll(.horizontal) {
                Text(code)
                    .font(WarrenTypography.mono)
                    .lineSpacing(ConversationLeading.mono)
                    .foregroundStyle(palette.ink2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .background(palette.raise, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
        }
    }
}

private struct WarrenConversationTable: View {
    let table: WarrenMarkdownTable
    var style: WarrenConversationMarkdown.Style = .answer
    let inline: (String) -> Text
    @Environment(\.colorScheme) private var colorScheme
    @State private var headerHeight: CGFloat = 0

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    cell(header, column: column)
                        .font(WarrenTypography.captionEmphasis)
                        .foregroundStyle(palette.ink3)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(palette.line).frame(height: 1)
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                        cell(value, column: column).font(WarrenTypography.body)
                    }
                }
            }
        }
        .background(alignment: .top) { palette.code.frame(height: headerHeight) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }

    private var compactColumns: Set<Int> {
        let rows = [table.headers] + table.rows
        let count = rows.map(\.count).max() ?? 0
        return Set((0..<count).filter { column in
            count > 1 && rows.allSatisfy { column >= $0.count || $0[column].count <= 28 }
        })
    }

    private func cell(_ value: String, column: Int) -> some View {
        let alignment = column < table.alignments.count ? table.alignments[column] : .leading
        let frameAlignment: Alignment = alignment == .trailing ? .trailing : alignment == .center ? .center : .leading
        let compact = compactColumns.contains(column)
        return inline(value)
            .lineSpacing(ConversationLeading.monoSmall)
            .foregroundStyle(palette.ink2)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: compact, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: compact ? nil : .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }
}

/// Tool output inside the work trail: a code-toned box that stops at 120 and
/// scrolls on its own.
private struct WarrenConversationOutputBox: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        WarrenConversationLeadingScroll([.horizontal, .vertical]) {
            Text(text)
                .font(WarrenTypography.monoSmall)
                .lineSpacing(ConversationLeading.monoSmall)
                .foregroundStyle(palette.ink3)
                .textSelection(.enabled)
                .fixedSize()
                .padding(8)
        }
        .frame(maxHeight: 120)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

private struct WarrenConversationDiffView: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400)
        WarrenConversationLeadingScroll([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(WarrenTypography.monoSmall)
                        .foregroundStyle(color(for: line, tokens: palette))
                }
            }
            .textSelection(.enabled)
            .fixedSize()
            .padding(8)
        }
        .frame(maxHeight: 280)
        .background(palette.code, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func color(for line: Substring, tokens: WarrenConversationPalette) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { return tokens.ink4 }
        if line.hasPrefix("+") { return tokens.green }
        if line.hasPrefix("-") { return tokens.red }
        return tokens.ink3
    }
}

// MARK: - Changed files card

/// What the turn changed: a header and one row per file. A row opens the file's
/// diff in the right sidebar's Changes tab rather than unfolding here.
private struct WarrenConversationFilesCard: View {
    let files: [WarrenConversation.FileChange]
    let onReview: (WarrenConversation.FileChange) -> Void
    let onReviewAll: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.conversationRoot) private var root

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(files.count) file\(files.count == 1 ? "" : "s") changed")
                    .font(WarrenTypography.caption)
                    .foregroundStyle(palette.ink2)
                HStack(spacing: 4) {
                    Text("+\(additions)").foregroundStyle(palette.green)
                    Text("−\(deletions)").foregroundStyle(palette.red)
                }
                .font(WarrenTypography.monoSmall)
                Spacer(minLength: 0)
                Button("Review All", action: onReviewAll)
                    .buttonStyle(.plain)
                    .font(WarrenTypography.caption)
                    .foregroundStyle(palette.ink3)
                    .warrenTooltip("Open every change in the Changes tab")
            }
            .frame(height: 34)
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                Button {
                    onReview(file)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(palette.ink4)
                        Text(URL(fileURLWithPath: file.file).lastPathComponent)
                            .font(WarrenTypography.caption)
                            .foregroundStyle(palette.ink2)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(WarrenConversation.displayPath(file.file, root: root))
                            .font(WarrenTypography.caption)
                            .foregroundStyle(palette.ink4)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        WarrenConversationChangeCount(additions: file.additions, deletions: file.deletions)
                    }
                    .frame(height: 30)
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(file.file) in Changes")
                if index < files.count - 1 {
                    Rectangle().fill(palette.line.opacity(0.5)).frame(height: 1)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.line2, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Composer pieces

private struct WarrenConversationChip: View {
    let icon: String?
    let label: String
    let narrow: Bool
    let options: [WarrenConversation.ConfigOption]
    let onSetConfig: (String, String) async -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        Button {} label: {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                if !narrow {
                    Text(label).lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.6)
                }
            }
            .font(WarrenTypography.caption)
            .foregroundStyle(palette.ink3)
            .padding(.horizontal, narrow ? 0 : 9)
            .frame(width: narrow ? 28 : nil, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarrenConversationQuietButtonStyle())
        .warrenMenuPanel(width: 280) {
            WarrenConversationSelectorList(options: options, onSelect: { id, value in
                Task { await onSetConfig(id, value) }
            })
        }
        .warrenTooltip(label)
    }
}

private struct WarrenConversationQuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        configuration.label
            .background(
                (configuration.isPressed || hovering) && isEnabled ? palette.bubble : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

private struct WarrenConversationSelectorList: View {
    let options: [WarrenConversation.ConfigOption]
    let onSelect: (String, String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Divider().overlay(palette.line) }
                    if option.isToggle {
                        Toggle(isOn: Binding(
                            get: { option.currentValue.lowercased() == "on" },
                            set: { on in
                                let value = option.choices.first { $0.value.lowercased() == (on ? "on" : "off") }?.value
                                if let value { onSelect(option.id, value) }
                            }
                        )) {
                            Text(option.name).font(WarrenTypography.body).foregroundStyle(palette.ink)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.horizontal, 8)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.name)
                                .font(WarrenTypography.caption)
                                .foregroundStyle(palette.ink3)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 2)
                            ForEach(option.choices) { choice in
                                Button {
                                    guard choice.value != option.currentValue else { return }
                                    onSelect(option.id, choice.value)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(choice.name).font(WarrenTypography.body).foregroundStyle(palette.ink)
                                            if !choice.description.isEmpty, choice.description != choice.name {
                                                Text(choice.description)
                                                    .font(WarrenTypography.caption)
                                                    .foregroundStyle(palette.ink3)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        if choice.value == option.currentValue {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(palette.ink)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(WarrenConversationQuietButtonStyle())
                            }
                        }
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 460)
    }
}

/// The composer's context reading: a percentage, not a ring, so it never reads
/// as a spinner. It turns to the attention hue past 85%.
private struct WarrenConversationContextMeter: View {
    let context: WarrenConversation.Context
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        let fraction = min(1, max(0, Double(context.used) / Double(context.size)))
        let high = fraction > 0.85
        Text("\(Int((fraction * 100).rounded()))%")
            .font(WarrenTypography.caption.monospacedDigit())
            .warrenNumericTransition(value: Int((fraction * 100).rounded()))
            .foregroundStyle(high ? palette.accent : palette.ink4)
            .padding(.horizontal, 4)
            .frame(height: 28)
            .warrenTooltip("Context \(Int((fraction * 100).rounded()))% · \(Self.tokens(context.used)) of \(Self.tokens(context.size)) tokens")
            .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent used")
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 1_000 { return "\(Int((Double(value) / 1_000).rounded()))k" }
        return "\(value)"
    }
}

// MARK: - Stacked panels

/// One panel resting on the composer: the shared raised surface, square at the
/// bottom so it merges with the composer's top edge, outlined on its sides and
/// top only. Panels stack with a 1pt overlap, so one line separates them.
private struct WarrenConversationStackPanel<Content: View>: View {
    var outline: Color
    var roundsTop: Bool
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.raise, in: WarrenPanelShape(roundsTop: roundsTop, radius: ConversationLayout.panelRadius))
            .overlay(
                WarrenPanelOutline(roundsTop: roundsTop, radius: ConversationLayout.panelRadius)
                    .stroke(outline, lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .transition(.offset(y: 6).combined(with: .opacity))
    }
}

enum WarrenConversationModeIcon {
    static func symbol(_ value: String) -> String {
        switch value.lowercased() {
        case "plan": "list.bullet.clipboard"
        case "default", "manual", "ask": "hand.raised"
        case "acceptedits": "pencil"
        case "bypasspermissions", "full-access", "yolo": "exclamationmark.shield"
        default: "checkmark.shield"
        }
    }
}

/// A rectangle whose top corners take `radius` when asked and no corner does
/// otherwise. A shape of its own because the per-corner rectangle is not
/// available on every macOS Warren supports.
private struct WarrenPanelShape: Shape {
    let roundsTop: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        guard roundsTop else { return Path(rect) }
        let r = min(radius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The sides and top of `WarrenPanelShape`, open along the bottom.
private struct WarrenPanelOutline: Shape {
    let roundsTop: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: 0.5, dy: 0.5)
        let r = roundsTop ? min(radius, inset.width / 2, inset.height) : 0
        var path = Path()
        path.move(to: CGPoint(x: inset.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.minY + r))
        if r > 0 {
            path.addQuadCurve(to: CGPoint(x: inset.minX + r, y: inset.minY), control: CGPoint(x: inset.minX, y: inset.minY))
        }
        path.addLine(to: CGPoint(x: inset.maxX - r, y: inset.minY))
        if r > 0 {
            path.addQuadCurve(to: CGPoint(x: inset.maxX, y: inset.minY + r), control: CGPoint(x: inset.maxX, y: inset.minY))
        }
        path.addLine(to: CGPoint(x: inset.maxX, y: rect.maxY))
        return path
    }
}

/// The plan above the composer: one dot per step, so where the Agent is and
/// what is left reads at a glance. Done steps are filled, the current step is
/// a wider pill, and the rest are rings. Pointing at a dot names its step in
/// the title slot; clicking opens the whole list.
private struct WarrenConversationPlanStrip: View {
    let plan: WarrenConversation.Plan
    @State private var open = false
    @State private var hoveredStep: Int?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    /// The step the Agent is on, or past the end when every step is done.
    private var currentIndex: Int {
        plan.entries.firstIndex { $0.state == "in_progress" }
            ?? plan.entries.firstIndex { $0.state == "pending" }
            ?? plan.entries.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("PLAN \(plan.done)/\(plan.total)")
                        .font(WarrenTypography.monoSmall)
                        .foregroundStyle(palette.ink4)
                        .warrenNumericTransition(value: plan.done)
                    stepDots
                    Text(titleLine)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(hoveredStep == nil ? palette.ink2 : palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(palette.ink4)
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Plan, \(plan.done) of \(plan.total) done")
            .accessibilityValue(plan.current)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: entry.state == "completed" ? "checkmark.circle.fill" : entry.state == "in_progress" ? "circle.dotted" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.state == "completed" ? palette.green : palette.ink3)
                            Text(entry.title)
                                .font(WarrenTypography.caption)
                                .strikethrough(entry.state == "completed")
                                .foregroundStyle(entry.state == "in_progress" ? palette.ink : palette.ink3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var stepDots: some View {
        HStack(spacing: 4) {
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { index, _ in
                stepDot(index)
                    // A taller hit area than the 6pt dot, so pointing is easy.
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            hoveredStep = index
                        } else if hoveredStep == index {
                            hoveredStep = nil
                        }
                    }
            }
        }
        .animation(WarrenMotion.selection(reduceMotion: reduceMotion), value: currentIndex)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func stepDot(_ index: Int) -> some View {
        let isCurrent = index == currentIndex
        let isDone = index < plan.entries.count && plan.entries[index].state == "completed"
        Capsule()
            .fill(isCurrent ? palette.ink2 : (isDone ? palette.ink3 : Color.clear))
            .overlay {
                if !isCurrent && !isDone {
                    Capsule().strokeBorder(palette.focus, lineWidth: 1)
                }
            }
            .frame(width: isCurrent ? 22 : 6, height: 6)
            .overlay {
                if hoveredStep == index {
                    Capsule()
                        .strokeBorder(palette.ink4, lineWidth: 1)
                        .padding(-3)
                }
            }
    }

    /// The current step's title, or the pointed-at step's with where it
    /// stands.
    private var titleLine: String {
        if let hoveredStep, plan.entries.indices.contains(hoveredStep) {
            let stage = hoveredStep < currentIndex ? "Done" : (hoveredStep == currentIndex ? "Now" : "Next")
            return "\(stage) · \(plan.entries[hoveredStep].title)"
        }
        return plan.current.isEmpty ? "All steps done" : plan.current
    }
}

private struct WarrenConversationQueuePanel: View {
    let prompts: [WarrenConversationFeed.QueuedPrompt]
    let onEdit: (WarrenConversationFeed.QueuedPrompt) -> Void
    let onRemove: (WarrenConversationFeed.QueuedPrompt) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(prompts) { prompt in
                WarrenConversationQueueRow(
                    text: prompt.text,
                    onEdit: { onEdit(prompt) },
                    onRemove: { onRemove(prompt) }
                )
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }
}

private struct WarrenConversationQueueRow: View {
    let text: String
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .strokeBorder(palette.ink4, lineWidth: 1.25)
                .frame(width: 6, height: 6)
            Text(text)
                .font(WarrenTypography.caption)
                .foregroundStyle(palette.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(text)
            Spacer(minLength: 8)
            if hovering {
                iconButton("pencil", label: "Edit queued message", action: onEdit)
                iconButton("xmark", label: "Remove queued message", action: onRemove)
            }
        }
        .frame(minHeight: 30)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(palette.ink3)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .warrenTooltip(label)
        .accessibilityLabel(label)
    }
}

private struct WarrenConversationBanner: View {
    let message: String
    let onDismiss: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(palette.red)
            Text(message)
                .font(WarrenTypography.caption)
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.ink4)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .warrenTooltip("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Decision dock

/// One answer to a pending decision: in flight while `optionID` is set, failed
/// when `error` is.
struct WarrenConversationDecisionAttempt: Equatable {
    let decisionID: String
    var optionID: String?
    var error: String?
}

/// The one loud place: the pending decision, resting on the composer. It is the
/// only element in the pane carrying the attention hue, as its outline and the
/// light falling from its top edge.
///
/// The question leads: what the Agent wants to do, at the size of a heading,
/// with the kind of step as its glyph and the provider's reason under it. The
/// answers sit in one row of buttons under the command, the recommendation
/// filled and the rejection set apart at the far end, each wearing its key.
/// When the row does not fit the pane, it falls back to a list.
private struct WarrenConversationDecisionDock: View {
    let decision: WarrenConversation.Decision
    let count: Int
    let providerName: String
    let attempt: WarrenConversationDecisionAttempt?
    let onChoose: (String) -> Void

    /// Lines of a command shown before it folds behind "Show all".
    static let commandLineLimit = 4
    static let commandLineHeight: CGFloat = 17
    static let glyphTile: CGFloat = 26

    @State private var showsWholeCommand = false
    @State private var commandHovered = false
    @State private var copySource = UUID().uuidString
    @ObservedObject private var copyFeedback = WarrenCopyFeedback.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }
    private var inFlight: String? { attempt?.optionID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !decision.detail.isEmpty {
                command
            }
            if let diff = decision.diff, !diff.text.isEmpty {
                WarrenConversationDiffView(text: diff.text).frame(maxHeight: 180)
            }
            answers
            if let error = attempt?.error {
                Text(error).font(WarrenTypography.caption).foregroundStyle(palette.red)
            }
        }
        .padding(12)
        .background(alignment: .top) {
            LinearGradient(
                colors: [palette.accent.opacity(0.12), palette.accent.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 56)
            .allowsHitTesting(false)
        }
        .animation(WarrenMotion.animation(.stateChange, reduceMotion: reduceMotion), value: attempt)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: WarrenConversationStepIcon.symbol(for: decision.toolKind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: Self.glyphTile, height: Self.glyphTile)
                .background(palette.bubble, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.line2, lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                // The provider's reason, unless it restates the title or the
                // command below it.
                if let reason = reasonLine {
                    Text(reason)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(palette.ink3)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if count > 1 {
                Text("1 / \(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(palette.ink3)
                    .warrenNumericTransition(value: count)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(palette.bubble, in: Capsule())
                    .accessibilityLabel("1 of \(count) requests")
            }
        }
    }

    /// The command or file the decision is about. A long one folds after a
    /// few lines instead of being cut off for good, and it copies in place,
    /// since the usual next step for a command one is unsure of is to run or
    /// read it elsewhere.
    private var command: some View {
        let lineCount = decision.detail.split(separator: "\n", omittingEmptySubsequences: false).count
        let folds = lineCount > Self.commandLineLimit
        let folded = folds && !showsWholeCommand
        let copied = copyFeedback.confirms(copySource)
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            (decision.toolKind == "ran" ? Text("$ ").foregroundColor(palette.ink4) + Text(decision.detail) : Text(decision.detail))
                .font(WarrenTypography.code)
                .foregroundStyle(palette.ink2)
                .lineSpacing(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(maxHeight: folded ? CGFloat(Self.commandLineLimit) * Self.commandLineHeight : nil, alignment: .top)
                .clipped()
                .padding(.leading, 10)
                .padding(.trailing, 34)
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    if folded {
                        LinearGradient(colors: [palette.code.opacity(0), palette.code], startPoint: .top, endPoint: .bottom)
                            .frame(height: 30)
                            .allowsHitTesting(false)
                    }
                }
                .background(palette.code, in: shape)
                .overlay(shape.strokeBorder(palette.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Button {
                        copyFeedback.copy(decision.detail, confirmingIn: copySource)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.on.square")
                            .font(.system(size: 11, weight: copied ? .semibold : .regular))
                            .foregroundStyle(copied ? palette.green : palette.ink4)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .opacity(commandHovered || copied ? 1 : 0)
                    .warrenTooltip("Copy")
                    .accessibilityLabel("Copy command")
                }
                .onHover { commandHovered = $0 }
            if folds {
                Button(showsWholeCommand ? "Show less" : "Show all \(lineCount) lines") {
                    withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                        showsWholeCommand.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(WarrenTypography.caption)
                .foregroundStyle(palette.ink3)
            }
        }
    }

    /// One row when it fits, otherwise the same buttons as a list.
    private var answers: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                    if option.id == escapeOptionID, index > 0 {
                        Spacer(minLength: 12)
                    }
                    answerButton(option, index: index, stretches: false)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                    answerButton(option, index: index, stretches: true)
                }
            }
        }
    }

    private var title: String {
        decision.ask(providerName: providerName)
    }

    /// The option Esc answers: the last rejection, as the composer's escape
    /// chain picks it.
    private var escapeOptionID: String? {
        (decision.options.last { $0.isReject } ?? decision.options.last)?.id
    }

    /// The provider's reason, or nil when it would repeat the title or the
    /// command the pane already shows.
    private var reasonLine: String? {
        let reason = decision.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return nil }
        if reason == decision.detail.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }
        if reason == title { return nil }
        return reason
    }

    private func answerButton(
        _ option: WarrenConversation.Decision.Option,
        index: Int,
        stretches: Bool
    ) -> some View {
        // No provider marks a recommendation: the ACP option carries only
        // id/name/kind and the CLI payloads carry only id/label. So the
        // client's convention is the first entry of `orderedOptions`, which
        // sorts allow-once, allow-always, reject-once, reject-always.
        let role: WarrenDecisionButtonStyle.Role = index == 0
            ? .recommended
            : option.isReject ? .reject : .secondary
        let chosen = inFlight == option.id
        // Every number key answers; the keycap names the shortest way in.
        let key = index == 0 ? "\u{21B5}" : option.id == escapeOptionID ? "Esc" : "\(index + 1)"
        return Button {
            onChoose(option.id)
        } label: {
            HStack(spacing: 8) {
                // The chosen option's key turns into the spinner, so the
                // answer shows where it was given, whether by click or key.
                ZStack {
                    if chosen {
                        WarrenLoadingIndicator(size: 10, accessibilityLabel: "Answering")
                    } else {
                        Text(key).font(.system(size: key.count > 1 ? 10 : 11, design: .monospaced))
                    }
                }
                .padding(.horizontal, key.count > 1 ? 4 : 0)
                .frame(minWidth: 18, minHeight: 18)
                .background(
                    role == .recommended ? palette.card.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(role == .recommended ? Color.clear : palette.line2, lineWidth: 1)
                )
                Text(option.label)
                    .font(.system(size: 13, weight: role == .recommended ? .semibold : .medium))
                    .lineLimit(1)
                if stretches { Spacer(minLength: 0) }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarrenDecisionButtonStyle(role: role))
        // The other options step back while one is on its way.
        .opacity(inFlight == nil || chosen ? 1 : 0.4)
        .disabled(inFlight != nil)
        .accessibilityLabel(option.label)
        .accessibilityHint("Press \(index + 1)")
    }
}

/// The decision dock's answers: the recommendation filled in ink, the other
/// choices outlined, a rejection plain.
private struct WarrenDecisionButtonStyle: ButtonStyle {
    enum Role { case recommended, secondary, reject }
    let role: Role

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let palette = WarrenConversationPalette.resolved(for: colorScheme)
        let active = hovering || configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .foregroundStyle(foreground(palette, active: active))
            .background(fill(palette, active: active, pressed: configuration.isPressed), in: shape)
            .overlay(shape.strokeBorder(role == .secondary ? palette.line2 : Color.clear, lineWidth: 1))
            .onHover { hovering = $0 }
    }

    private func foreground(_ palette: WarrenConversationPalette, active: Bool) -> Color {
        switch role {
        case .recommended: palette.card
        case .secondary: palette.ink2
        case .reject: active ? palette.ink2 : palette.ink3
        }
    }

    private func fill(_ palette: WarrenConversationPalette, active: Bool, pressed: Bool) -> Color {
        switch role {
        case .recommended: pressed ? palette.ink2 : palette.ink
        case .secondary, .reject: pressed ? palette.press : active ? palette.bubble : Color.clear
        }
    }
}

// MARK: - Composer text view

/// A plain multi-line text view: Return sends, Shift-Return inserts a line,
/// Escape runs the composer's own escape chain, and the number keys choose a
/// decision while the field is empty.
private struct WarrenConversationTextView: NSViewRepresentable {
    let sessionID: TerminalSessionID?
    @Binding var text: String
    @Binding var height: CGFloat
    let isEditable: Bool
    let focusRequest: UInt
    let wantsInputFocus: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onSelectOption: (Int) -> Bool
    let onRestorePrevious: () -> Bool
    let onJumpToLatest: () -> Void
    let onCopyLastAnswer: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.apply(self)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? ComposerTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.measure(textView)
        }
        textView.isEditable = isEditable
        textView.apply(self)
        // The composer is the Session's input, so entering the Session is what
        // focuses it. Mounting is not enough: the pane can be re-created by a
        // layout turn, and that must not pull the keyboard out of the editor or
        // the palette. The token is issued by the activation path instead.
        if context.coordinator.lastFocusRequest != focusRequest {
            TerminalDiagnostics.log("conversation_focus_seen", [
                "session": sessionID?.description ?? "nil",
                "token": String(focusRequest),
                "wantsInputFocus": wantsInputFocus ? "true" : "false",
            ])
        }
        if wantsInputFocus,
           context.coordinator.lastFocusRequest != focusRequest {
            let token = focusRequest
            DispatchQueue.main.async { [weak textView, weak coordinator = context.coordinator] in
                guard let textView, let coordinator,
                      coordinator.lastFocusRequest != token,
                      let window = textView.window,
                      window.isKeyWindow else { return }
                // Consume the token only once the window can own the keyboard;
                // a request made while the app is inactive is retried by the
                // next update instead of being silently dropped.
                coordinator.lastFocusRequest = token
                guard window.firstResponder !== textView else { return }
                guard window.makeFirstResponder(textView) else { return }
                TerminalDiagnostics.log("conversation_focus_claim", [
                    "session": sessionID?.description ?? "nil",
                    "token": String(token),
                ])
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WarrenConversationTextView
        /// The activation token the composer has already answered. Starts at
        /// zero so a request issued before this view existed is consumed on
        /// its first update.
        fileprivate var lastFocusRequest: UInt = 0
        init(_ parent: WarrenConversationTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification) { parent.onFocusChange(false) }

        func measure(_ textView: NSTextView) {
            guard let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let next = max(22, ceil(used))
            if abs(next - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = next }
            }
        }
    }

    final class ComposerTextView: NSTextView {
        var onSubmit: (() -> Void)?
        var onEscape: (() -> Void)?
        var onSelectOption: ((Int) -> Bool)?
        var onRestorePrevious: (() -> Bool)?
        var onJumpToLatest: (() -> Void)?
        var onCopyLastAnswer: (() -> Void)?

        func apply(_ parent: WarrenConversationTextView) {
            onSubmit = { parent.onSubmit() }
            onEscape = { parent.onEscape() }
            onSelectOption = { parent.onSelectOption($0) }
            onRestorePrevious = { parent.onRestorePrevious() }
            onJumpToLatest = { parent.onJumpToLatest() }
            onCopyLastAnswer = { parent.onCopyLastAnswer() }
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers ?? ""
            if flags.contains(.command) {
                if characters.lowercased() == "c", flags.contains(.shift) {
                    onCopyLastAnswer?()
                    return
                }
                if event.keyCode == 125 {
                    onJumpToLatest?()
                    return
                }
            }
            if event.keyCode == 53 {
                onEscape?()
                return
            }
            let returnKey = event.keyCode == 36 || event.keyCode == 76
            if returnKey, !flags.contains(.shift), !hasMarkedText() {
                onSubmit?()
                return
            }
            if event.keyCode == 126, string.isEmpty, onRestorePrevious?() == true {
                return
            }
            if string.isEmpty, let digit = Int(characters), (1...9).contains(digit), onSelectOption?(digit) == true {
                return
            }
            super.keyDown(with: event)
        }
    }
}

/// A scroll view whose content starts at its top-leading corner. SwiftUI
/// centers content narrower than the view, so a short diff or code line sat
/// in the middle of its block; the content is stretched to the view's width
/// and pinned leading instead.
private struct WarrenConversationLeadingScroll<Content: View>: View {
    let axes: Axis.Set
    var showsIndicators = true
    @ViewBuilder var content: () -> Content
    @State private var viewport: CGSize = .zero

    init(_ axes: Axis.Set, showsIndicators: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content
    }

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content()
                .frame(
                    minWidth: axes.contains(.horizontal) ? viewport.width : nil,
                    minHeight: axes.contains(.vertical) ? viewport.height : nil,
                    alignment: .topLeading
                )
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { viewport = $0 }
    }
}
