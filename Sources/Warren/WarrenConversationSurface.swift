import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenTransport

// The Desktop Conversation surface (RFC 0023 §9).
//
// Everything is quiet unless it needs the person: one collapsed work trail per
// turn, reasoning on demand, the answer as the only full-contrast text, and a
// decision dock pinned above the composer as the single element that takes the
// attention hue. The only thing that moves is the highlight on the live
// "Working for …" line, which settles into "Worked for …" when the turn ends.

/// The events and status one Conversation surface renders.
@MainActor
final class WarrenConversationFeed: ObservableObject {
    struct PendingPrompt: Identifiable, Equatable {
        let id: String
        let text: String
        var failure: String?
    }

    let sessionID: TerminalSessionID
    @Published private(set) var conversation = WarrenConversation()
    @Published private(set) var revision = 0
    @Published private(set) var loaded = false
    @Published var status: AgentStatus?
    @Published var pendingPrompts: [PendingPrompt] = []
    /// Prompts written while the Agent was busy, sent in order when it is next
    /// ready (`WarrenRemoteApplicationModel.drainConversationQueue`).
    @Published var queuedPrompts: [QueuedPrompt] = []

    struct QueuedPrompt: Identifiable, Equatable {
        let id: String
        let text: String
    }

    /// The stream the local replica was last read for; owned by the model.
    var seededStreamID: String?

    private var events: [UInt64: WarrenRemoteAgentEvent] = [:]
    private var streamID: String?

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
        }
        var changed = false
        for event in incoming where events[event.sequence] == nil {
            events[event.sequence] = event
            changed = true
        }
        guard changed else { return }
        conversation = WarrenConversation.project(Array(events.values))
        let echoed = Set(conversation.turns.compactMap(\.promptCausedBy))
        pendingPrompts.removeAll { echoed.contains($0.id) }
        revision &+= 1
    }
}

struct WarrenConversationSurface: View {
    let sessionID: TerminalSessionID
    let model: WarrenRemoteApplicationModel

    var body: some View {
        WarrenConversationView(
            feed: model.conversationFeed(for: sessionID),
            providerName: providerName,
            model: model
        )
        .environment(\.conversationRoot, model.projection.session(id: sessionID)?.workingDirectory)
    }

    private var providerName: String {
        let session = model.projection.session(id: sessionID)
        return (session?.agentProvider ?? session?.kind)?.displayName ?? "Agent"
    }
}

/// The measure the transcript and the composer share, so the composer's edges
/// line up with the text above it.
private let conversationColumnWidth: CGFloat = 736

private struct ConversationRootKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// The Session's directory; step targets and changed files under it are
    /// shown relative to it.
    fileprivate var conversationRoot: String? {
        get { self[ConversationRootKey.self] }
        set { self[ConversationRootKey.self] = newValue }
    }
}

private struct WarrenConversationView: View {
    @ObservedObject var feed: WarrenConversationFeed
    let providerName: String
    let model: WarrenRemoteApplicationModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var pinnedToBottom = true
    @State private var hasNewActivity = false
    @State private var actionError: String?
    @State private var stopping = false

    private var tokens: WarrenColorTokens { WarrenColorTokens.resolved(for: colorScheme) }
    private var lastTurn: WarrenConversation.Turn? { feed.conversation.turns.last }
    private var busy: Bool {
        feed.status?.activity == .working || feed.status?.activity == .blocked
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                timeline
                if hasNewActivity {
                    Button("New activity ↓") { hasNewActivity = false; pinnedToBottom = true }
                        .buttonStyle(.plain)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, WarrenSpacing.medium)
                        .padding(.vertical, WarrenSpacing.xs)
                        .background(tokens.popoverSurface, in: Capsule())
                        .overlay(Capsule().strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
                        .padding(.bottom, WarrenSpacing.compact)
                }
            }
            bottomDock
        }
        .background(tokens.background)
        .onChange(of: feed.status?.activity) { activity in
            if activity != .working, activity != .blocked { stopping = false }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if feed.loaded, feed.conversation.turns.isEmpty, feed.pendingPrompts.isEmpty {
                        Text("Ask \(providerName) to do something in this workspace.")
                            .font(WarrenTypography.dialogBody)
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 120)
                    }
                    ForEach(feed.conversation.turns) { turn in
                        WarrenConversationTurnView(
                            turn: turn,
                            live: turn.id == lastTurn?.id,
                            waiting: turn.id == lastTurn?.id && !feed.conversation.decisions.isEmpty,
                            openSession: { model.openSession(named: $0) },
                            sessionExists: { model.sessionIsOpen(named: $0) }
                        )
                    }
                    ForEach(feed.pendingPrompts) { prompt in
                        WarrenConversationPromptView(text: prompt.text, meta: prompt.failure ?? "Sending…")
                            .opacity(0.72)
                    }
                    if !feed.queuedPrompts.isEmpty {
                        VStack(alignment: .trailing, spacing: WarrenSpacing.compact) {
                            ForEach(feed.queuedPrompts) { prompt in
                                WarrenConversationQueuedPromptView(text: prompt.text) {
                                    feed.queuedPrompts.removeAll { $0.id == prompt.id }
                                }
                            }
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { pinnedToBottom = true; hasNewActivity = false }
                        .onDisappear { pinnedToBottom = false }
                }
                .frame(maxWidth: conversationColumnWidth, alignment: .leading)
                .padding(.horizontal, WarrenSpacing.large)
                .padding(.top, WarrenSpacing.large)
                .padding(.bottom, WarrenSpacing.standard)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: feed.revision) { _ in
                if pinnedToBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                } else {
                    hasNewActivity = true
                }
            }
            .onChange(of: feed.pendingPrompts.count) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: feed.queuedPrompts.count) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: hasNewActivity) { value in
                if !value, pinnedToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Bottom dock

    /// The decision, when one is pending, sits on the composer; the composer
    /// carries every control for the Session.
    private var bottomDock: some View {
        let conversation = feed.conversation
        let configurable = model.supportsConversationConfig(feed.sessionID)
        return VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            if let decision = conversation.decisions.first {
                WarrenConversationDecisionDock(
                    decision: decision,
                    count: conversation.decisions.count,
                    onDecide: { optionID in
                        try await model.resolveConversationDecision(decision, optionID: optionID, in: feed.sessionID)
                    }
                )
                .id(decision.id)
            }
            if let actionError {
                Text(actionError)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.destructive)
                    .padding(.horizontal, WarrenSpacing.xs)
            }
            WarrenConversationComposer(
                placeholder: busy ? "Queue a follow-up · Esc to stop" : "Message \(providerName)",
                disabledReason: conversation.decisions.isEmpty ? nil : "Answer the decision above to continue",
                busy: busy && conversation.decisions.isEmpty,
                stopping: stopping,
                statusNote: statusNote,
                plan: conversation.plan,
                mode: configurable ? conversation.modeOption : nil,
                modelOptions: configurable ? conversation.modelOptions : [],
                modelSummary: conversation.modelSummary,
                context: conversation.context,
                canHandoff: model.conversationHasConversation(feed.sessionID),
                onSetConfig: setConfig,
                onHandoff: handoff,
                onSend: send,
                onStop: stop
            )
        }
        .frame(maxWidth: conversationColumnWidth + 2 * WarrenSpacing.compact)
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.bottom, WarrenSpacing.standard)
        .frame(maxWidth: .infinity)
    }

    /// Anything other than ready or working; those two are already visible
    /// as the send or stop button and the live work line.
    private var statusNote: String? {
        switch feed.status?.activity {
        case .failed: "Failed"
        case .exited: "Ended"
        case nil: feed.loaded ? nil : "Starting"
        default: nil
        }
    }

    private func setConfig(_ id: String, _ value: String) async {
        do {
            try await model.setConversationConfig(id, value: value, in: feed.sessionID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func handoff() async {
        do {
            try await model.handoffConversation(feed.sessionID)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// A message written while the Agent works, or behind earlier queued ones,
    /// waits its turn; otherwise it goes now.
    private func send(_ text: String) {
        actionError = nil
        pinnedToBottom = true
        if busy || !feed.queuedPrompts.isEmpty || feed.pendingPrompts.contains(where: { $0.failure == nil }) {
            model.queueConversationPrompt(text, in: feed)
        } else {
            model.submitConversationPrompt(text, in: feed)
        }
    }

    private func stop() {
        guard !stopping, let turn = lastTurn, turn.status == .running else { return }
        stopping = true
        Task { @MainActor in
            do {
                try await model.cancelConversationTurn(feed.sessionID, turnID: turn.id)
            } catch {
                stopping = false
                actionError = error.localizedDescription
            }
        }
    }
}

// MARK: - Turn

/// The person's message: a compact bubble on the trailing side, so the
/// agent's answers own the reading column.
private struct WarrenConversationPromptView: View {
    let text: String
    var meta: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .trailing, spacing: WarrenSpacing.xs) {
            Text(text)
                .font(WarrenConversationText.body)
                .lineSpacing(WarrenConversationText.lineSpacing)
                .foregroundStyle(tokens.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(tokens.tertiaryWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let meta {
                Text(meta)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, WarrenSpacing.xs)
            }
        }
        .padding(.leading, 96)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A queued follow-up: the bubble it will become, outlined rather than
/// filled, with a way to take it back before it is sent.
private struct WarrenConversationQueuedPromptView: View {
    let text: String
    let onRemove: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(alignment: .center, spacing: WarrenSpacing.compact) {
            Spacer(minLength: 96)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: 18, height: 18)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove from queue")
            .accessibilityLabel("Remove queued message")
            VStack(alignment: .trailing, spacing: WarrenSpacing.xs) {
                Text(text)
                    .font(WarrenConversationText.body)
                    .lineSpacing(WarrenConversationText.lineSpacing)
                    .foregroundStyle(tokens.foreground.opacity(0.8))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(tokens.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
                Label("Queued", systemImage: "clock")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, WarrenSpacing.xs)
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct WarrenConversationTurnView: View {
    let turn: WarrenConversation.Turn
    let live: Bool
    let waiting: Bool
    let openSession: (String) -> Void
    let sessionExists: (String) -> Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let running = live && turn.status == .running
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            if let prompt = turn.prompt {
                WarrenConversationPromptView(
                    text: prompt,
                    meta: turn.promptAttachments.isEmpty ? nil : turn.promptAttachments.joined(separator: ", ")
                )
                .padding(.bottom, WarrenSpacing.xs)
            }
            if turn.reasoning.count > 0 {
                WarrenConversationDisclosure(label: reasoningLabel(running: running)) {
                    Text(turn.reasoning.text)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if running || !turn.steps.isEmpty || !turn.narration.isEmpty {
                WarrenConversationWorkTrail(
                    turn: turn,
                    running: running,
                    waiting: waiting,
                    openSession: openSession,
                    sessionExists: sessionExists
                )
            }
            let answer = running
                ? WarrenConversation.visibleStreamingText(turn.answer, complete: turn.answerComplete)
                : turn.answer
            if !answer.isEmpty {
                WarrenConversationMarkdown(text: answer)
            }
            ForEach(Array(turn.notices.enumerated()), id: \.offset) { _, notice in
                Text(notice).font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground)
            }
            ForEach(Array(turn.errors.enumerated()), id: \.offset) { _, error in
                Text(error)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.destructive)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !running, turn.status == .cancelled, turn.errors.isEmpty {
                Text("Stopped.").font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground)
            }
            if !turn.files.isEmpty {
                WarrenConversationFilesCard(files: turn.files)
            }
            if !running, !turn.answer.isEmpty {
                WarrenConversationAnswerFooter(answer: turn.answer, endedAt: turn.endedAt)
            }
        }
    }

    private func reasoningLabel(running: Bool) -> String {
        if running, turn.answer.isEmpty, turn.steps.isEmpty { return "Thinking" }
        let seconds = turn.reasoning.seconds
        return seconds > 0 ? "Thought for \(seconds)s" : "Thought"
    }
}

/// Copy and the time the answer landed, quiet under the answer.
private struct WarrenConversationAnswerFooter: View {
    let answer: String
    let endedAt: Date?
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        HStack(spacing: WarrenSpacing.small) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: 10))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy answer")
            if let endedAt {
                Text(Self.format(endedAt))
                    .font(.system(size: 11).monospacedDigit())
            }
        }
        .padding(.top, -WarrenSpacing.xs)
        .foregroundStyle(tokens.mutedForeground.opacity(0.75))
    }

    static func format(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

/// A quiet one-line toggle that reveals its content below.
private struct WarrenConversationDisclosure<Content: View, Trailing: View>: View {
    let label: String
    var trailing: Trailing
    @ViewBuilder var content: () -> Content
    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme

    init(label: String, @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.trailing = trailing()
        self.content = content
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                    Text(label)
                        .font(WarrenTypography.supporting)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    trailing
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .padding(.leading, WarrenSpacing.medium)
            }
        }
    }
}

extension WarrenConversationDisclosure where Trailing == EmptyView {
    init(label: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(label: label, trailing: { EmptyView() }, content: content)
    }
}

private struct WarrenConversationChangeCount: View {
    let additions: Int
    let deletions: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        if additions > 0 || deletions > 0 {
            HStack(spacing: WarrenSpacing.xs) {
                Text("+\(additions)").foregroundStyle(additions > 0 ? tokens.success : tokens.mutedForeground.opacity(0.6))
                Text("−\(deletions)").foregroundStyle(deletions > 0 ? tokens.destructive : tokens.mutedForeground.opacity(0.6))
            }
            .font(WarrenTypography.compactCode)
        }
    }
}

/// The turn's work. While the turn runs, a live "Working for …" line carries
/// the transcript's only moving highlight over a rolling window of at most
/// three steps; when the turn ends the window settles into one line,
/// "Worked for … · Read 4 files", and a hairline separates it from the answer.
private struct WarrenConversationWorkTrail: View {
    let turn: WarrenConversation.Turn
    let running: Bool
    let waiting: Bool
    let openSession: (String) -> Void
    let sessionExists: (String) -> Bool

    @State private var open = false
    @State private var settlingWindow: [WarrenConversation.Step] = []
    @State private var folded = false
    @State private var lastWindow: [WarrenConversation.Step] = []
    @Environment(\.conversationRoot) private var root
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let windowSize = 3
    private static let settleDuration = 0.42

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let additions = turn.files.reduce(0) { $0 + $1.additions }
        let deletions = turn.files.reduce(0) { $0 + $1.deletions }
        let window = Array(turn.steps.sorted { $0.order < $1.order }.suffix(Self.windowSize))
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Button {
                if !entries.isEmpty { open.toggle() }
            } label: {
                HStack(spacing: WarrenSpacing.small) {
                    headLabel(tokens: tokens)
                    let failures = turn.steps.filter { $0.kind == .tool && $0.status == .failed }.count
                    if failures > 0 {
                        Text("\(failures) failed").font(WarrenTypography.supporting).foregroundStyle(tokens.destructive)
                    }
                    WarrenConversationChangeCount(additions: additions, deletions: deletions)
                    if !entries.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .offset(y: !settlingWindow.isEmpty && !folded ? -3 : 0)
            if running, !open, !window.isEmpty {
                windowRows(window, tokens: tokens, live: true)
            }
            if !settlingWindow.isEmpty, !open {
                windowRows(settlingWindow, tokens: tokens, live: false)
                    .frame(height: folded ? 0 : nil, alignment: .top)
                    .opacity(folded ? 0 : 1)
                    .clipped()
            }
            if open {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    ForEach(entries, id: \.id) { entry in
                        switch entry.kind {
                        case .note(let text):
                            Text(text)
                                .font(WarrenTypography.supporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, WarrenSpacing.xxs)
                        case .step(let step):
                            WarrenConversationStepRow(step: step, openSession: openSession, sessionExists: sessionExists)
                        }
                    }
                }
                .padding(.leading, WarrenSpacing.compact)
                .overlay(alignment: .leading) {
                    Rectangle().fill(tokens.border).frame(width: WarrenSpacing.hairline)
                }
                .padding(.leading, WarrenSpacing.medium)
            }
            if !running, !turn.answer.isEmpty {
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
                    .padding(.top, WarrenSpacing.xs)
            }
        }
        .onAppear { if running { lastWindow = window } }
        .onChange(of: window.map(\.id)) { _ in if running { lastWindow = window } }
        .onChange(of: running) { isRunning in
            guard !isRunning, !lastWindow.isEmpty, !reduceMotion else { return }
            settlingWindow = lastWindow
            folded = false
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: Self.settleDuration)) { folded = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration + 0.05) {
                settlingWindow = []
                folded = false
            }
        }
    }

    @ViewBuilder
    private func headLabel(tokens: WarrenColorTokens) -> some View {
        if running, waiting {
            Text("Waiting").font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground)
        } else if running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = turn.startedAt.map { context.date.timeIntervalSince($0) } ?? 0
                WarrenConversationShimmer(
                    text: "Working for \(WarrenConversation.formatElapsed(elapsed))",
                    base: tokens.mutedForeground,
                    highlight: tokens.foreground
                )
            }
        } else {
            Text(turn.settledLabel)
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func windowRows(_ steps: [WarrenConversation.Step], tokens: WarrenColorTokens, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                let current = live && index == steps.count - 1 && (step.status == .running || step.status == .pending)
                let line = step.line(relativeTo: root)
                Text(line.target.isEmpty ? line.verb : "\(line.verb) \(line.target)")
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(step.status == .failed ? tokens.destructive : (current ? tokens.mutedForeground : tokens.mutedForeground.opacity(0.65)))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, WarrenSpacing.medium + WarrenSpacing.xs)
    }

    private struct Entry {
        enum Kind { case note(String), step(WarrenConversation.Step) }
        let id: String
        let order: Int
        let kind: Kind
    }

    private var entries: [Entry] {
        // Narration carries no sequence of its own here, so it leads the list;
        // steps keep the order the Agent took them in.
        let notes = turn.narration.enumerated().map { Entry(id: "note-\($0.offset)", order: -1, kind: .note($0.element)) }
        let steps = turn.steps.sorted { $0.order < $1.order }.map { Entry(id: "step-\($0.id)", order: Int($0.order), kind: .step($0)) }
        return notes + steps
    }
}

/// A stepped highlight sweep across secondary text (adapted from Synara's
/// text shimmer): 2 s per pass in 40 steps, off under Reduce Motion.
struct WarrenConversationShimmer: View {
    let text: String
    let base: Color
    let highlight: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text).font(WarrenTypography.supporting).foregroundStyle(base)
        } else {
            TimelineView(.periodic(from: .now, by: 0.05)) { context in
                let step = (context.date.timeIntervalSinceReferenceDate / 0.05).rounded(.down)
                let phase = step.truncatingRemainder(dividingBy: 40) / 40
                let center = -0.5 + 2 * phase
                Text(text)
                    .font(WarrenTypography.supporting)
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

private struct WarrenConversationStepRow: View {
    let step: WarrenConversation.Step
    var openSession: (String) -> Void = { _ in }
    var sessionExists: (String) -> Bool = { _ in false }
    @State private var open = false
    @Environment(\.conversationRoot) private var root
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let line = step.line(relativeTo: root)
        let detail = step.diff?.text.isEmpty == false ? nil : (step.error.isEmpty ? step.output : step.error)
        let expandable = (detail?.isEmpty == false) || step.diff?.text.isEmpty == false
        VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            Button {
                if expandable { open.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.small) {
                    Circle()
                        .fill(step.status == .failed ? tokens.destructive : tokens.mutedForeground.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(line.verb).font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground)
                    if !line.target.isEmpty {
                        Text(line.target)
                            .font(WarrenTypography.compactCode)
                            .foregroundStyle(tokens.mutedForeground.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let diff = step.diff {
                        WarrenConversationChangeCount(additions: diff.additions, deletions: diff.deletions)
                    }
                    if step.kind == .decision, !step.choice.isEmpty {
                        Text(step.choice).font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground.opacity(0.7))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            if let terminal = step.terminalSessionID, sessionExists(terminal) {
                Button("Open terminal") { openSession(terminal) }
                    .buttonStyle(.plain)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.link)
                    .padding(.leading, WarrenSpacing.medium)
            }
            if open {
                if let diff = step.diff, !diff.text.isEmpty {
                    WarrenConversationDiffView(text: diff.text)
                } else if let detail, !detail.isEmpty {
                    WarrenConversationCodeBlock(text: detail)
                }
            }
        }
        .padding(.vertical, WarrenSpacing.xxs)
    }
}
/// Reading type for the Conversation: one body size and leading shared by the
/// answer, the person's bubble, and the composer.
private enum WarrenConversationText {
    // 13 pt at roughly 1.6 leading, the measure Synara reads at.
    static let body = Font.system(size: 13)
    static let strong = Font.system(size: 13, weight: .semibold)
    static let lineSpacing: CGFloat = 6
    static let code = Font.system(size: 12, design: .monospaced)
    static let inlineCode = Font.system(size: 11.5, design: .monospaced)
}

/// What the turn changed, as a card: a summary header and one row per file
/// that opens its diff.
private struct WarrenConversationFilesCard: View {
    let files: [WarrenConversation.FileChange]
    @State private var showAll = false
    @Environment(\.colorScheme) private var colorScheme

    private static let collapsedCount = 5

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let additions = files.reduce(0) { $0 + $1.additions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        let visible = showAll ? files : Array(files.prefix(Self.collapsedCount))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.compact) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.mutedForeground)
                Text(files.count == 1 ? "Edited 1 file" : "Edited \(files.count) files")
                    .font(WarrenTypography.bodyEmphasis)
                    .foregroundStyle(tokens.foreground)
                WarrenConversationChangeCount(additions: additions, deletions: deletions)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.vertical, 10)
            ForEach(visible) { file in
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
                WarrenConversationFileRow(file: file)
            }
            if files.count > Self.collapsedCount {
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
                Button {
                    showAll.toggle()
                } label: {
                    HStack(spacing: WarrenSpacing.small) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(showAll ? 90 : 0))
                        Text(showAll ? "Show fewer files" : "Show \(files.count - Self.collapsedCount) more files")
                            .font(WarrenTypography.supporting)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(tokens.mutedForeground)
                    .padding(.horizontal, WarrenSpacing.medium)
                    .padding(.vertical, WarrenSpacing.compact)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(tokens.inputSurface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
    }
}

private struct WarrenConversationFileRow: View {
    let file: WarrenConversation.FileChange
    @State private var open = false
    @Environment(\.conversationRoot) private var root
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let hasDiff = file.diffs.contains { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if hasDiff { open.toggle() }
            } label: {
                HStack(spacing: WarrenSpacing.compact) {
                    Text(WarrenConversation.displayPath(file.file, root: root))
                        .font(WarrenTypography.code)
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: WarrenSpacing.compact)
                    WarrenConversationChangeCount(additions: file.additions, deletions: file.deletions)
                    if hasDiff {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                    }
                }
                .padding(.horizontal, WarrenSpacing.medium)
                .padding(.vertical, WarrenSpacing.compact)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    ForEach(Array(file.diffs.enumerated()), id: \.offset) { _, diff in
                        WarrenConversationDiffView(text: diff)
                    }
                }
                .padding(.horizontal, WarrenSpacing.compact)
                .padding(.bottom, WarrenSpacing.compact)
            }
        }
    }
}

// MARK: - Text blocks

/// Tool output inside the work trail: bounded and scrollable.
private struct WarrenConversationCodeBlock: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        WarrenConversationLeadingScroll([.horizontal, .vertical]) {
            Text(text)
                .font(WarrenTypography.compactCode)
                .foregroundStyle(tokens.mutedForeground)
                .textSelection(.enabled)
                .fixedSize()
                .padding(WarrenSpacing.compact)
        }
        .frame(maxHeight: 280)
        .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: WarrenRadius.medium))
    }
}

/// A fenced code block in an answer: its language and a copy button above
/// code that scrolls sideways instead of being cut off.
private struct WarrenConversationCodeFence: View {
    let language: String?
    let code: String
    @State private var copied = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WarrenSpacing.small) {
                Text((language?.isEmpty == false ? language! : "text").lowercased())
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy code")
            }
            .padding(.leading, WarrenSpacing.medium)
            .padding(.trailing, WarrenSpacing.small)
            .padding(.vertical, WarrenSpacing.xs + 1)
            WarrenConversationLeadingScroll(.horizontal) {
                Text(code)
                    .font(WarrenConversationText.code)
                    .lineSpacing(3)
                    .foregroundStyle(tokens.foreground.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, WarrenSpacing.medium)
                    .padding(.top, WarrenSpacing.xxs)
                    .padding(.bottom, WarrenSpacing.medium)
            }
        }
        .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
    }
}

private struct WarrenConversationDiffView: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(400)
        WarrenConversationLeadingScroll([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(String(line).isEmpty ? " " : String(line))
                        .font(WarrenTypography.compactCode)
                        .foregroundStyle(color(for: line, tokens: tokens))
                }
            }
            .textSelection(.enabled)
            .fixedSize()
            .padding(WarrenSpacing.compact)
        }
        .frame(maxHeight: 280)
        .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: WarrenRadius.small))
    }

    private func color(for line: Substring, tokens: WarrenColorTokens) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") { return tokens.mutedForeground.opacity(0.7) }
        if line.hasPrefix("+") { return tokens.success }
        if line.hasPrefix("-") { return tokens.destructive }
        return tokens.mutedForeground
    }
}


/// An answer, rendered from the Markdown blocks the iOS surface also reads
/// (`WarrenMarkdown`): headings in steps, nested lists, quotes, tables, and
/// code fences that scroll instead of clipping.
struct WarrenConversationMarkdown: View {
    let text: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let blocks = WarrenMarkdownCache.shared.blocks(for: text)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, tokens: tokens)
                    .padding(.top, index == 0 ? 0 : spacing(before: block))
            }
        }
        .foregroundStyle(tokens.foreground)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: WarrenMarkdownBlock, tokens: WarrenColorTokens) -> some View {
        switch block {
        case .paragraph(let value):
            inline(value, tokens: tokens)
                .font(WarrenConversationText.body)
                .lineSpacing(WarrenConversationText.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .heading(let level, let value):
            inline(value, tokens: tokens)
                .font(headingFont(level))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items), .orderedList(let items):
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.compact) {
                        marker(item, tokens: tokens)
                        inline(item.text, tokens: tokens)
                            .font(WarrenConversationText.body)
                            .lineSpacing(WarrenConversationText.lineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * 18)
                }
            }
        case .quote(let value):
            inline(value, tokens: tokens)
                .font(WarrenConversationText.body)
                .lineSpacing(WarrenConversationText.lineSpacing)
                .foregroundStyle(tokens.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, WarrenSpacing.medium)
                .overlay(alignment: .leading) {
                    Rectangle().fill(tokens.border).frame(width: 2)
                }
        case .alert(let alert):
            VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                Label(alert.title, systemImage: alert.kind.symbol)
                    .font(WarrenTypography.bodyEmphasis)
                    .foregroundStyle(alertTint(alert.kind, tokens: tokens))
                inline(alert.content, tokens: tokens)
                    .font(WarrenConversationText.body)
                    .lineSpacing(WarrenConversationText.lineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, WarrenSpacing.medium)
            .overlay(alignment: .leading) {
                Rectangle().fill(alertTint(alert.kind, tokens: tokens)).frame(width: 2)
            }
        case .table(let table):
            WarrenConversationTable(table: table, inline: { inline($0, tokens: tokens) })
        case .code(let language, let value):
            WarrenConversationCodeFence(language: language, code: value)
        case .divider:
            Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
        }
    }

    @ViewBuilder
    private func marker(_ item: WarrenMarkdownListItem, tokens: WarrenColorTokens) -> some View {
        if let checked = item.taskState {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(checked ? tokens.success : tokens.mutedForeground)
        } else if item.marker == "•" {
            Text(item.depth == 0 ? "•" : "◦")
                .font(WarrenConversationText.body)
                .foregroundStyle(tokens.mutedForeground)
                .frame(minWidth: 10, alignment: .center)
        } else {
            Text(item.marker)
                .font(WarrenConversationText.body.monospacedDigit())
                .foregroundStyle(tokens.mutedForeground)
                .frame(minWidth: 18, alignment: .trailing)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 19, weight: .semibold)
        case 2: .system(size: 16, weight: .semibold)
        case 3: .system(size: 14, weight: .semibold)
        default: .system(size: 13, weight: .semibold)
        }
    }

    /// Room above a block: headings open a section, so they take the most.
    private func spacing(before block: WarrenMarkdownBlock) -> CGFloat {
        switch block {
        case .heading(let level, _): level <= 2 ? 20 : 14
        case .code, .table: 12
        default: 10
        }
    }

    private func alertTint(_ kind: WarrenMarkdownAlertKind, tokens: WarrenColorTokens) -> Color {
        switch kind {
        case .note, .important: tokens.info
        case .tip: tokens.success
        case .warning: tokens.warning
        case .caution: tokens.destructive
        }
    }

    private func inline(_ value: String, tokens: WarrenColorTokens) -> Text {
        let source = WarrenMarkdownCache.shared.preservedLineBreaks(for: value)
        guard var attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        ) else {
            return Text(value)
        }
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = WarrenConversationText.inlineCode
                attributed[run.range].backgroundColor = tokens.foreground.opacity(0.09)
                attributed[run.range].foregroundColor = tokens.foreground.opacity(0.92)
            } else if let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) {
                attributed[run.range].font = WarrenConversationText.strong
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = tokens.link
            }
        }
        return Text(attributed)
    }
}

private struct WarrenConversationTable: View {
    let table: WarrenMarkdownTable
    let inline: (String) -> Text
    @Environment(\.colorScheme) private var colorScheme
    @State private var headerHeight: CGFloat = 0

    /// The table takes the reading column and wraps its cells, so a long cell
    /// grows its row instead of pushing the table sideways.
    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                    cell(header, column: column)
                        .font(WarrenTypography.bodyEmphasis)
                        .foregroundStyle(tokens.mutedForeground)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                        cell(value, column: column).font(WarrenConversationText.body)
                    }
                }
            }
        }
        // One band behind the header row: per-cell fills leave gaps where a
        // column hugs its content.
        .background(alignment: .top) { tokens.tertiaryWash.frame(height: headerHeight) }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
    }

    /// Columns whose every cell is short (names, paths, codes) hug their
    /// content, so the columns with prose get the width.
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
            .lineSpacing(3)
            .multilineTextAlignment(alignment == .trailing ? .trailing : alignment == .center ? .center : .leading)
            .fixedSize(horizontal: compact, vertical: true)
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.vertical, 7)
            .frame(maxWidth: compact ? nil : .infinity, maxHeight: .infinity, alignment: frameAlignment)
    }
}

// MARK: - Composer

/// The one place the person acts: the draft on top, and one row under it with
/// the permission mode and hand-off on the leading side, and the context,
/// the model, and send or stop on the trailing side (after Synara's composer).
private struct WarrenConversationComposer: View {
    let placeholder: String
    let disabledReason: String?
    let busy: Bool
    let stopping: Bool
    let statusNote: String?
    let plan: WarrenConversation.Plan?
    let mode: WarrenConversation.ConfigOption?
    let modelOptions: [WarrenConversation.ConfigOption]
    let modelSummary: String
    let context: WarrenConversation.Context?
    let canHandoff: Bool
    let onSetConfig: (String, String) async -> Void
    let onHandoff: () async -> Void
    let onSend: (String) -> Void
    let onStop: () -> Void

    @State private var text = ""
    @State private var height: CGFloat = 22
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let disabled = disabledReason != nil
        VStack(alignment: .leading, spacing: 0) {
            if let plan, plan.total > 0 {
                WarrenConversationPlanStrip(plan: plan)
                Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
            }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(disabledReason ?? placeholder)
                        .font(WarrenConversationText.body)
                        .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                        .padding(.leading, 5)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
                WarrenConversationTextView(
                    text: $text,
                    height: $height,
                    isEditable: !disabled,
                    onSubmit: submit,
                    onEscape: { if busy { onStop() } }
                )
                .frame(height: min(max(height, 40), 220))
            }
            .padding(.horizontal, WarrenSpacing.medium)
            .padding(.top, WarrenSpacing.medium)
            footer(tokens: tokens)
        }
        .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.28 : 0.06), radius: 12, y: 4)
    }

    private func footer(tokens: WarrenColorTokens) -> some View {
        HStack(spacing: WarrenSpacing.xs) {
            if let mode {
                WarrenConversationChip(
                    icon: Self.modeIcon(mode.currentValue),
                    label: mode.shortName,
                    options: [mode],
                    onSetConfig: onSetConfig
                )
            }
            if canHandoff {
                Button {
                    Task { await onHandoff() }
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 12))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(WarrenConversationChipStyle())
                .disabled(busy)
                .help(busy ? "Continue in terminal (stop the turn first)" : "Continue in terminal")
            }
            if let statusNote {
                Text(statusNote)
                    .font(WarrenTypography.supporting)
                    .foregroundStyle(tokens.warning)
                    .padding(.leading, WarrenSpacing.xs)
            }
            Spacer(minLength: WarrenSpacing.compact)
            if let context, context.size > 0 {
                WarrenConversationContextMeter(context: context)
            }
            if !modelOptions.isEmpty {
                WarrenConversationChip(
                    icon: nil,
                    label: modelSummary.isEmpty ? "Model" : modelSummary,
                    options: modelOptions,
                    onSetConfig: onSetConfig
                )
            }
            sendButton(tokens: tokens)
        }
        .padding(.leading, WarrenSpacing.small)
        .padding(.trailing, WarrenSpacing.compact)
        .padding(.vertical, WarrenSpacing.compact)
    }

    @ViewBuilder
    private func sendButton(tokens: WarrenColorTokens) -> some View {
        if busy {
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tokens.background)
                    .frame(width: 9, height: 9)
                    .frame(width: 28, height: 28)
                    .background(tokens.foreground.opacity(stopping ? 0.4 : 1), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .disabled(stopping)
            .help(stopping ? "Stopping…" : "Stop (⌘. or Esc)")
            .accessibilityLabel("Stop")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canSend ? tokens.background : tokens.mutedForeground)
                    .frame(width: 28, height: 28)
                    .background(canSend ? tokens.foreground : tokens.tertiaryWash, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
            .accessibilityLabel("Send")
        }
    }

    private var canSend: Bool {
        disabledReason == nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        onSend(value)
    }

    static func modeIcon(_ value: String) -> String {
        switch value.lowercased() {
        case "plan": "list.bullet.clipboard"
        case "default", "manual", "ask": "hand.raised"
        case "acceptedits": "pencil"
        case "bypasspermissions", "full-access", "yolo": "exclamationmark.shield"
        default: "checkmark.shield"
        }
    }
}

/// A quiet capsule in the composer row that opens the selectors it stands for.
private struct WarrenConversationChip: View {
    let icon: String?
    let label: String
    let options: [WarrenConversation.ConfigOption]
    let onSetConfig: (String, String) async -> Void
    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        Button {
            open.toggle()
        } label: {
            HStack(spacing: WarrenSpacing.xs + 1) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11))
                }
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.6)
            }
            .font(WarrenTypography.supporting)
            .foregroundStyle(open ? tokens.foreground : tokens.mutedForeground)
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(height: 26)
            .contentShape(Capsule())
        }
        .buttonStyle(WarrenConversationChipStyle())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            WarrenConversationSelectorList(options: options, onSelect: { id, value in
                Task { await onSetConfig(id, value) }
            })
        }
    }
}

private struct WarrenConversationChipStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        configuration.label
            .foregroundStyle(tokens.mutedForeground)
            .background((configuration.isPressed || hovering) && isEnabled ? tokens.fillHover : Color.clear, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

/// Every choice of the chip's selectors, one section each, the current one
/// checked; an on/off selector is a single toggle row.
private struct WarrenConversationSelectorList: View {
    let options: [WarrenConversation.ConfigOption]
    let onSelect: (String, String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        ScrollView {
            VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    if index > 0 { Divider().overlay(tokens.border) }
                    if option.isToggle {
                        Toggle(isOn: Binding(
                            get: { option.currentValue.lowercased() == "on" },
                            set: { on in
                                let value = option.choices.first { $0.value.lowercased() == (on ? "on" : "off") }?.value
                                if let value { onSelect(option.id, value) }
                            }
                        )) {
                            Text(option.name).font(WarrenTypography.body).foregroundStyle(tokens.foreground)
                        }
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .padding(.horizontal, WarrenSpacing.compact)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.name)
                                .font(WarrenTypography.supporting)
                                .foregroundStyle(tokens.mutedForeground)
                                .padding(.horizontal, WarrenSpacing.compact)
                                .padding(.bottom, WarrenSpacing.xxs)
                            ForEach(option.choices) { choice in
                                Button {
                                    guard choice.value != option.currentValue else { return }
                                    onSelect(option.id, choice.value)
                                } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.compact) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(choice.name)
                                                .font(WarrenTypography.body)
                                                .foregroundStyle(tokens.foreground)
                                            if !choice.description.isEmpty, choice.description != choice.name {
                                                Text(choice.description)
                                                    .font(WarrenTypography.supporting)
                                                    .foregroundStyle(tokens.mutedForeground)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                        Spacer(minLength: WarrenSpacing.compact)
                                        if choice.value == option.currentValue {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(tokens.foreground)
                                        }
                                    }
                                    .padding(.horizontal, WarrenSpacing.compact)
                                    .padding(.vertical, WarrenSpacing.small)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(WarrenConversationChoiceStyle())
                            }
                        }
                    }
                }
            }
            .padding(WarrenSpacing.small)
        }
        .frame(width: 280)
        .frame(maxHeight: 460)
    }
}

/// How full the agent's context is, as a small ring; the numbers are in the
/// tooltip.
private struct WarrenConversationContextMeter: View {
    let context: WarrenConversation.Context
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        let fraction = min(1, max(0, Double(context.used) / Double(context.size)))
        let tint = fraction > 0.85 ? tokens.warning : tokens.mutedForeground
        HStack(spacing: WarrenSpacing.xs) {
            ZStack {
                Circle().stroke(tokens.border, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(WarrenTypography.supporting.monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.horizontal, WarrenSpacing.xs)
        .frame(height: 26)
        .contentShape(Rectangle())
        .help("Context \(Int((fraction * 100).rounded()))% · \(Self.tokens(context.used)) of \(Self.tokens(context.size)) tokens")
        .accessibilityLabel("Context \(Int((fraction * 100).rounded())) percent used")
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
        if value >= 1_000 { return "\(Int((Double(value) / 1_000).rounded()))k" }
        return "\(value)"
    }
}

/// The agent's plan on the composer's edge: progress and the current step,
/// opening into the checklist.
private struct WarrenConversationPlanStrip: View {
    let plan: WarrenConversation.Plan
    @State private var open = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: WarrenSpacing.small) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11))
                    Text("Plan \(plan.done)/\(plan.total)")
                        .foregroundStyle(tokens.foreground)
                    if plan.done < plan.total, !plan.current.isEmpty {
                        Text(plan.current).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(WarrenTypography.supporting)
                .foregroundStyle(tokens.mutedForeground)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
                    ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.small) {
                            Image(systemName: entry.state == "completed" ? "checkmark.circle.fill" : entry.state == "in_progress" ? "circle.dotted" : "circle")
                                .font(.system(size: 11))
                                .foregroundStyle(entry.state == "completed" ? tokens.success : tokens.mutedForeground)
                            Text(entry.title)
                                .strikethrough(entry.state == "completed")
                                .foregroundStyle(entry.state == "in_progress" ? tokens.foreground : tokens.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(WarrenTypography.body)
                    }
                }
                .padding(.leading, WarrenSpacing.xxs)
            }
        }
        .padding(.horizontal, WarrenSpacing.medium)
        .padding(.vertical, WarrenSpacing.compact)
    }
}

// MARK: - Decision dock

/// The one loud place: the pending decision, resting on the composer. ⌘2…⌘4
/// choose an option, Return takes the default, Escape rejects once.
private struct WarrenConversationDecisionDock: View {
    let decision: WarrenConversation.Decision
    let count: Int
    let onDecide: (String) async throws -> Void

    @State private var submitting: String?
    @State private var error: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.compact) {
                Circle().fill(tokens.warning).frame(width: 8, height: 8)
                Text(decision.question).font(WarrenTypography.bodyEmphasis).foregroundStyle(tokens.foreground)
                Text(decision.title).font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground).lineLimit(1)
                Spacer(minLength: 0)
                if count > 1 {
                    Text("1/\(count)").font(WarrenTypography.supporting).foregroundStyle(tokens.mutedForeground)
                }
            }
            if !decision.detail.isEmpty, decision.detail != decision.title {
                Text(decision.detail)
                    .font(WarrenTypography.code)
                    .foregroundStyle(tokens.foreground)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(WarrenSpacing.compact)
                    .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: WarrenRadius.small))
            }
            if let diff = decision.diff, !diff.text.isEmpty {
                WarrenConversationDiffView(text: diff.text).frame(maxHeight: 180)
            }
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                    optionButton(option, index: index, tokens: tokens)
                }
            }
            .padding(.horizontal, -WarrenSpacing.small)
            if let error {
                Text(error).font(WarrenTypography.supporting).foregroundStyle(tokens.destructive)
            }
        }
        .padding(.horizontal, WarrenSpacing.standard)
        .padding(.vertical, WarrenSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.popoverSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tokens.warning.opacity(0.55), lineWidth: 1))
        .background(
            // Escape rejects once; Return is the default button's own shortcut.
            Button("") { if let reject = decision.options.first(where: { $0.kind == "reject_once" }) { choose(reject) } }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    @ViewBuilder
    private func optionButton(_ option: WarrenConversation.Decision.Option, index: Int, tokens: WarrenColorTokens) -> some View {
        let primary = index == 0
        let button = Button {
            choose(option)
        } label: {
            // A list row with a numbered key, the recommended answer first
            // (adapted from Synara's decision card).
            HStack(spacing: WarrenSpacing.compact) {
                Text("\(index + 1)")
                    .font(WarrenTypography.supporting.monospacedDigit())
                    .foregroundStyle(primary ? tokens.background : tokens.mutedForeground)
                    .frame(width: 18, height: 18)
                    .background(primary ? tokens.warning : Color.clear, in: Circle())
                    .overlay(Circle().strokeBorder(primary ? tokens.warning : tokens.border, lineWidth: 1))
                Text(submitting == option.id ? "\(option.label)…" : option.label)
                    .font(primary ? WarrenTypography.bodyEmphasis : WarrenTypography.body)
                    .foregroundStyle(option.isReject ? tokens.mutedForeground : tokens.foreground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, WarrenSpacing.small)
            .padding(.vertical, WarrenSpacing.xs + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarrenConversationChoiceStyle())
        .disabled(submitting != nil)
        .help("⌘\(index + 1)")
        if primary {
            button.keyboardShortcut(.defaultAction)
        } else if index < 4 {
            button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        } else {
            button
        }
    }

    private func choose(_ option: WarrenConversation.Decision.Option) {
        guard submitting == nil else { return }
        submitting = option.id
        error = nil
        Task { @MainActor in
            do {
                try await onDecide(option.id)
            } catch {
                self.error = error.localizedDescription
                submitting = nil
            }
        }
    }
}

private struct WarrenConversationChoiceStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        configuration.label
            .background(
                (configuration.isPressed || hovering) ? tokens.fillHover : Color.clear,
                in: RoundedRectangle(cornerRadius: WarrenRadius.medium)
            )
            .onHover { hovering = $0 }
    }
}

// MARK: - Composer text view

/// A plain multi-line text view: Return sends, Shift-Return inserts a line,
/// Escape stops a running turn.
private struct WarrenConversationTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEditable: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape() }
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
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
        textView.onSubmit = { [weak coordinator = context.coordinator] in coordinator?.parent.onSubmit() }
        textView.onEscape = { [weak coordinator = context.coordinator] in coordinator?.parent.onEscape() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WarrenConversationTextView
        init(_ parent: WarrenConversationTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            measure(textView)
        }

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

        override func keyDown(with event: NSEvent) {
            let returnKey = event.keyCode == 36 || event.keyCode == 76
            if returnKey, !event.modifierFlags.contains(.shift), !hasMarkedText() {
                onSubmit?()
                return
            }
            if event.keyCode == 53 {
                onEscape?()
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
