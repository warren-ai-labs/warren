import SwiftUI
import WarrenTransport

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// UITextView's stock insertion caret follows the line fragment height, which
/// is visibly taller than the compact SF Pro glyphs used by the composer.
/// Keep the native editing behavior, but make the caret follow the font's
/// point-size scale just like the text it accompanies.
private final class AgentComposerTextView: UITextView {
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        guard let font else { return rect }

        let targetHeight = max(1, ceil(font.pointSize))
        rect.origin.y += (rect.height - targetHeight) / 2
        rect.size.height = targetHeight
        return rect
    }
}

private struct AgentComposerInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> AgentComposerTextView {
        let view = AgentComposerTextView(frame: .zero)
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let textColor = UIColor(red: 234 / 255, green: 232 / 255, blue: 230 / 255, alpha: 1)

        view.delegate = context.coordinator
        view.font = font
        view.textColor = textColor
        view.tintColor = textColor
        view.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.isScrollEnabled = false
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: 5, left: 7, bottom: 5, right: 2)
        view.textContainer.maximumNumberOfLines = 3
        view.textContainer.lineBreakMode = .byWordWrapping
        view.autocorrectionType = .default
        view.autocapitalizationType = .sentences
        view.returnKeyType = .default
        view.accessibilityLabel = "Agent message"
        view.text = text
        return view
    }

    func updateUIView(_ view: AgentComposerTextView, context: Context) {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        if view.font != font {
            view.font = font
            view.typingAttributes[.font] = font
        }
        if view.text != text {
            view.text = text
        }

        if isFocused, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !isFocused, view.isFirstResponder {
            view.resignFirstResponder()
        }
        view.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textViewDidChange(_ textView: UITextView) {
            guard text.wrappedValue != textView.text else { return }
            text.wrappedValue = textView.text
        }

        func textViewDidBeginEditing(_: UITextView) {
            if !isFocused.wrappedValue {
                isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_: UITextView) {
            if isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }
    }
}
#endif

private struct AgentChatTopOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct AgentChatBottomOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = .greatestFiniteMagnitude

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Native Agent transcript surface. It follows Warren Web's mobile hierarchy:
/// assistant prose is open and readable, while reasoning/tool activity is a
/// compact disclosure rail. The composer is the one raised surface on the
/// page, not every message.
public struct AgentChatView: View {
    @ObservedObject private var model: IOSApplicationModel
    @ObservedObject private var agentState: IOSAgentLiveState
    private let sessionID: String
    @State private var draft = ""
    @State private var renderedBlocks: [AgentDisplayBlock] = []
    @State private var didEstablishInitialScroll = false
    @State private var didTriggerHistoryPull = false
    @State private var historyScrollAnchorID: String?
    @State private var isNearLatest = true
    @State private var showReturnToLatest = false
    @State private var workingPhrase = AgentWorkingPhrases.defaultPhrase
    @State private var lastObservedUserEventKey: String?
    @State private var didInitializeUserTurnTracking = false
    @FocusState private var composerFocused: Bool

    private let historyPullThreshold: CGFloat = 56
    private let latestVisibilityThreshold: CGFloat = 72

    public init(model: IOSApplicationModel, sessionID: String) {
        self.model = model
        self._agentState = ObservedObject(wrappedValue: model.agentState)
        self.sessionID = sessionID
    }

    public var body: some View {
        // The chat surface stays mounted underneath the terminal so switching
        // modes does not discard its composer state. Avoid rebuilding the
        // transcript grouping for every PTY frame while that surface is
        // hidden. `renderedBlocks` is refreshed only when Agent events change;
        // connection and terminal publications therefore remain cheap.
        let blocks = model.displayMode == .agent ? renderedBlocks : []

        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // The sentinel follows the scroll content rather
                            // than the viewport. Pulling past the top threshold
                            // requests the next conversation page; scrolling to
                            // the top alone never changes the page.
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(
                                        key: AgentChatTopOffsetPreferenceKey.self,
                                        value: geometry.frame(in: .named("agent-chat-scroll")).minY
                                    )
                            }
                            .frame(height: 1)

                            if model.historyLoadingBySessionID.contains(sessionID) {
                                AgentHistoryLoadMoreRow(isLoading: true, action: {})
                                    .transition(.opacity)
                            } else if model.agentHistoryLoaded(for: sessionID),
                                      model.agentHistoryHasMore(for: sessionID) {
                                AgentHistoryLoadMoreRow(isLoading: false) {
                                    requestOlderHistory(blocks: blocks, force: true)
                                }
                            }

                            if blocks.isEmpty {
                                AgentEmptyState()
                                    .frame(maxWidth: .infinity, minHeight: 240)
                            } else {
                                ForEach(blocks) { block in
                                    displayBlockView(block)
                                        .id(block.id)
                                }
                            }
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(
                                        key: AgentChatBottomOffsetPreferenceKey.self,
                                        value: geometry.frame(in: .named("agent-chat-scroll")).maxY
                                    )
                            }
                            .frame(height: 1)
                            .id("agent-bottom")
                            .onAppear {
                                isNearLatest = true
                                showReturnToLatest = false
                            }
                            .onDisappear {
                                isNearLatest = false
                            }
                        }
                        .frame(maxWidth: 820)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    }
                    .background(IOSTheme.background)
                    .scrollIndicators(.hidden)
                    .coordinateSpace(name: "agent-chat-scroll")
                    // `defaultScrollAnchor(.bottom)` repositions a ScrollView
                    // in the same layout pass as the keyboard inset and looks
                    // like a jump on iPhone. We establish the initial position
                    // explicitly, then use the same short ease for intentional
                    // repositioning only.
                    .animation(.easeInOut(duration: 0.30), value: composerFocused)
                    .onAppear {
                        guard !didEstablishInitialScroll else { return }
                        didEstablishInitialScroll = true
                        isNearLatest = true
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo("agent-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: agentState.agentEventRevisionBySessionID[sessionID] ?? 0) { _, _ in
                        observeAgentRevision(using: proxy)
                    }
                    .onPreferenceChange(AgentChatTopOffsetPreferenceKey.self) { offset in
                        handleTopOffset(offset, blocks: blocks)
                    }
                    .onPreferenceChange(AgentChatBottomOffsetPreferenceKey.self) { bottomY in
                        let distanceFromLatest = bottomY - viewport.size.height
                        let wasNearLatest = isNearLatest
                        isNearLatest = distanceFromLatest <= latestVisibilityThreshold
                        if isNearLatest {
                            showReturnToLatest = false
                        } else if wasNearLatest && !showReturnToLatest {
                            // A user scroll, rather than a live event, moved
                            // the transcript away from the latest message.
                            // Keep the button hidden until a new event arrives.
                            showReturnToLatest = false
                        }
                    }
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    #endif
                    // Tapping transcript chrome is the same intent as dragging
                    // it: leave the conversation visible and quietly return
                    // focus to the page. The composer remains the only surface
                    // that keeps the keyboard alive.
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            guard composerFocused else { return }
                            composerFocused = false
                            model.dismissKeyboard()
                        }
                    )
                    .onChange(of: composerFocused) { _, focused in
                        if focused {
                            // Agent input is the control affordance. The first
                            // focus request claims the Host lease; users never
                            // need a separate unlock button before composing.
                            model.focusTerminal()
                            // Let the focus transaction install the keyboard
                            // safe-area inset, then animate the existing
                            // transcript in the very next run-loop turn.
                            Task { @MainActor in
                                await Task.yield()
                                guard composerFocused else { return }
                                scrollToLatest(using: proxy, animated: true)
                            }
                        } else {
                            // Dismissing the keyboard shrinks the safe-area
                            // inset. Follow the same bottom marker in that
                            // transaction so the transcript settles against
                            // the composer instead of leaving a floating gap.
                            let wasNearLatest = isNearLatest
                            guard wasNearLatest else { return }
                            Task { @MainActor in
                                await Task.yield()
                                guard !composerFocused else { return }
                                withAnimation(.easeInOut(duration: 0.30)) {
                                    proxy.scrollTo("agent-bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                    .onChange(of: model.currentSessionID) { _, selectedSessionID in
                        guard selectedSessionID == sessionID else { return }
                        didEstablishInitialScroll = false
                        didTriggerHistoryPull = false
                        historyScrollAnchorID = nil
                        showReturnToLatest = false
                        isNearLatest = true
                        Task { @MainActor in
                            await Task.yield()
                            scrollToLatest(using: proxy, animated: false)
                        }
                    }
                    .onChange(of: model.historyLoadingBySessionID) { wasLoading, isLoading in
                        guard wasLoading.contains(sessionID), !isLoading.contains(sessionID) else { return }
                        restoreHistoryScrollAnchor(using: proxy)
                    }

                    if showReturnToLatest {
                        Button {
                            scrollToLatest(using: proxy, animated: true)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(IOSTheme.secondaryText)
                                .frame(width: 27, height: 27)
                                .background(IOSTheme.chrome.opacity(0.96), in: Circle())
                                .overlay {
                                    Circle()
                                        .stroke(IOSTheme.ring.opacity(0.90), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Return to latest message")
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                        .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Animate the composer/safe-area inset with the focus transition too;
        // otherwise the ScrollView offset is smooth while the input surface
        // itself still appears one frame later.
        .animation(.easeInOut(duration: 0.30), value: composerFocused)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.displayMode == .agent {
                VStack(alignment: .leading, spacing: 0) {
                    if let attention = model.agentAttention(for: sessionID) {
                        AgentAttentionBanner(attention: attention) {
                            model.setDisplayMode(.terminal)
                            model.focusTerminal()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if shouldShowWorking {
                        AgentWorkingFooter(phrase: workingPhrase)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer
                }
                .animation(.easeInOut(duration: 0.22), value: shouldShowWorking)
                .animation(.easeInOut(duration: 0.22), value: model.agentAttention(for: sessionID))
                .animation(.easeInOut(duration: 0.22), value: composerFocused)
            }
        }
        .onAppear {
            refreshRenderedBlocks()
            lastObservedUserEventKey = latestUserEventKey()
            didInitializeUserTurnTracking = model.agentHistoryLoaded(for: sessionID)
            if !model.agentHistoryLoaded(for: sessionID) {
                model.loadOlderAgentHistory()
            }
        }
        .onChange(of: model.currentSessionID) { _, selectedSessionID in
            guard selectedSessionID == sessionID else { return }
            didTriggerHistoryPull = false
            historyScrollAnchorID = nil
            showReturnToLatest = false
            isNearLatest = true
            workingPhrase = AgentWorkingPhrases.defaultPhrase
            lastObservedUserEventKey = latestUserEventKey()
            didInitializeUserTurnTracking = model.agentHistoryLoaded(for: sessionID)
            guard !model.agentHistoryLoaded(for: sessionID) else { return }
            model.loadOlderAgentHistory()
        }
    }

    private func refreshRenderedBlocks() {
        renderedBlocks = agentDisplayBlocks(from: agentState.agentEventsBySessionID[sessionID] ?? [])
    }

    private func handleTopOffset(
        _ offset: CGFloat,
        blocks: [AgentDisplayBlock]
    ) {
        // At rest the sentinel is just below the scroll view's top edge. A
        // positive offset means the user is pulling down into the bounce
        // region. Re-arm only after they release/re-enter the rest zone so a
        // single gesture cannot issue several page requests.
        if offset < historyPullThreshold * 0.45 {
            didTriggerHistoryPull = false
        }
        guard offset >= historyPullThreshold, !model.historyLoadingBySessionID.contains(sessionID) else { return }
        requestOlderHistory(blocks: blocks)
    }

    private func requestOlderHistory(
        blocks: [AgentDisplayBlock],
        force: Bool = false
    ) {
        guard model.agentHistoryLoaded(for: sessionID),
              model.agentHistoryHasMore(for: sessionID),
              !model.historyLoadingBySessionID.contains(sessionID),
              force || !didTriggerHistoryPull else { return }

        didTriggerHistoryPull = true
        historyScrollAnchorID = blocks.first?.id
        model.loadOlderAgentHistory()
    }

    private func handleNewContent(using proxy: ScrollViewProxy) {
        guard historyScrollAnchorID == nil else { return }
        if isNearLatest {
            // Keep a live response pinned without an animation on every
            // streamed delta. Repeated animated scrolls are perceived as page
            // jumps, especially while the user is changing scroll direction.
            scrollToLatest(using: proxy, animated: false)
        } else {
            showReturnToLatest = true
        }
    }

    private func observeAgentRevision(using proxy: ScrollViewProxy) {
        let currentUserEventKey = latestUserEventKey()
        if !didInitializeUserTurnTracking {
            if model.agentHistoryLoaded(for: sessionID) {
                lastObservedUserEventKey = currentUserEventKey
                didInitializeUserTurnTracking = true
            }
        } else if currentUserEventKey != lastObservedUserEventKey {
            workingPhrase = AgentWorkingPhrases.random(excluding: workingPhrase)
            lastObservedUserEventKey = currentUserEventKey
        }

        refreshRenderedBlocks()
        guard historyScrollAnchorID == nil else { return }
        // The revision is published before the new LazyVStack rows have been
        // laid out. Wait one turn so an intentional follow-to-latest targets
        // the new bottom marker instead of the previous page.
        Task { @MainActor in
            await Task.yield()
            handleNewContent(using: proxy)
        }
    }

    private func latestUserEventKey() -> String? {
        agentState.agentEventsBySessionID[sessionID]?
            .last(where: \.isUserEvent)
            .map { "\($0.sequence):\($0.id)" }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        isNearLatest = true
        showReturnToLatest = false
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                proxy.scrollTo("agent-bottom", anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo("agent-bottom", anchor: .bottom)
            }
        }
    }

    private func restoreHistoryScrollAnchor(using proxy: ScrollViewProxy) {
        guard let anchorID = historyScrollAnchorID else { return }
        // The loading flag can be removed in the same main-actor turn as the
        // event merge. Refresh the local block cache before checking the anchor
        // so the row insertion cannot race the restoration transaction.
        refreshRenderedBlocks()
        // The model publishes the history-loading flag after merging the new
        // page. Yield once so LazyVStack has installed the older blocks before
        // anchoring the previous first block; this keeps the visible content
        // in place while the new rows appear above it.
        Task { @MainActor in
            await Task.yield()
            guard renderedBlocks.contains(where: { $0.id == anchorID }) else {
                historyScrollAnchorID = nil
                return
            }
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(anchorID, anchor: .top)
            }
            historyScrollAnchorID = nil
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = model.agentDisabledReason,
               model.hasControlLease,
               model.agentAttention(for: sessionID) == nil,
               agentStatus?.activity != .working {
                Label(reason, systemImage: model.hasControlLease ? "hourglass" : "lock.fill")
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 18)
                    .lineLimit(2)
                    .iosNaturalWrap()
                    .layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .bottom, spacing: 7) {
                    ZStack(alignment: .topLeading) {
                        Text("Message \(agentKind)…")
                            .font(IOSTypography.input)
                            .foregroundStyle(IOSTheme.secondaryText.opacity(0.78))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .opacity(draft.isEmpty ? 1 : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(!draft.isEmpty)
#if canImport(UIKit)
                        AgentComposerInput(
                            text: $draft,
                            isFocused: Binding(
                                get: { composerFocused },
                                set: { composerFocused = $0 }
                            )
                        )
                            .frame(minHeight: 30, maxHeight: 46)
#else
                        TextField("", text: $draft, axis: .vertical)
                            .font(IOSTypography.input)
                            .foregroundStyle(IOSTheme.text)
                            .lineLimit(1...3)
                            .frame(minHeight: 30, maxHeight: 46)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 0)
                            .textFieldStyle(.plain)
                            .focused($composerFocused)
                            .accessibilityLabel("Agent message")
#endif
                    }
                    Button {
                        let value = draft
                        draft = ""
                        workingPhrase = AgentWorkingPhrases.random(excluding: workingPhrase)
                        model.sendAgentMessage(value)
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(IOSTheme.background)
                            .frame(width: 26, height: 26)
                            .background(IOSTheme.text, in: Circle())
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.32)
                    .accessibilityLabel("Send Agent message")
                    .padding(.bottom, 2)
                }

                HStack(spacing: 8) {
                    Text(agentKind)
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.secondaryText)
                    if let mode = agentMode {
                        AgentModeBadge(title: mode)
                    }
                    if let queued = model.agentQueuedMessageCountBySessionID[sessionID], queued > 0 {
                        Text("·")
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Text("Queued \(queued)")
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.amber)
                    }
                    if let agentModel = model.agentModel(for: sessionID) {
                        Text("·")
                            .foregroundStyle(IOSTheme.tertiaryText)
                        Text(agentModel)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 3)
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.top, 1)
            .background(IOSTheme.raised, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(IOSTheme.ring.opacity(0.92), lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
        }
        .padding(.top, 3)
        .background(IOSTheme.background)
    }

    private var agentStatus: WarrenRemoteAgentStatus? {
        guard let session = model.roster?.sessions.first(where: { $0.id == sessionID }),
              session.isAgentBacked else { return nil }
        return model.agentStatusBySessionID[sessionID] ?? session.agentStatus
    }

    private var agentKind: String {
        let sessionKind = model.roster?.sessions.first(where: { $0.id == sessionID })?.kind
        if let label = agentKindLabel(sessionKind) { return label }

        if let provider = agentState.agentEventsBySessionID[sessionID]?.reversed()
            .compactMap({ event -> String? in
                let value = event.provider.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
            .first {
            return agentKindLabel(provider) ?? provider.capitalized
        }
        return "Agent"
    }

    private func agentKindLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex": return "Codex"
        case "claude", "claude-code": return "Claude"
        case "opencode", "open-code": return "OpenCode"
        default: return nil
        }
    }

    private var canSend: Bool {
        model.canSendAgent && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowWorking: Bool {
        guard agentStatus?.activity == .working else { return false }
        guard let last = (agentState.agentEventsBySessionID[sessionID] ?? [])
            .last(where: { !$0.isHiddenFromMobile }) else { return true }
        // A provider may briefly publish `working` after its final assistant
        // event. The completed message is the stronger visual signal, so do
        // not leave a shimmer below it during that race.
        return !(last.isAssistantEvent && !(last.content?.isEmpty ?? true))
    }

    private var agentMode: String? {
        let session = model.roster?.sessions.first(where: { $0.id == sessionID })
        let provider = agentKind == "Agent" ? session?.kind : agentKind
        return agentModeLabel(provider: provider, command: session?.command)
    }
}

private struct AgentEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(IOSTheme.amber)
            Text("What can I help you with?")
                .font(IOSTypography.navigationTitle)
                .foregroundStyle(IOSTheme.text)
            Text("Messages, tool calls and results will appear here.")
                .font(IOSTypography.body)
                .foregroundStyle(IOSTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Renders provider output with the native mobile Markdown surface. The parser
/// keeps block structure (including GFM tables and lists) separate from the
/// conversation view, so this wrapper remains the single call site used by
/// user, assistant, and reasoning messages.
private struct AgentMarkdownText: View {
    private let value: String
    private let font: Font

    init(value: String, font: Font = IOSTypography.body) {
        self.value = value
        self.font = font
    }

    var body: some View {
        IOSMarkdownView(value: value, font: font)
    }
}

private struct AgentAttentionBanner: View {
    let attention: WarrenRemoteAgentAttention
    let openTerminal: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(IOSTypography.label)
                    .foregroundStyle(IOSTheme.text)
                if !message.isEmpty {
                    Text(message)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .lineLimit(3)
                        .iosNaturalWrap()
                }
            }
            Spacer(minLength: 4)
            if attention.kind == .approval {
                Button(action: openTerminal) {
                    Label("Terminal", systemImage: "terminal")
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.text)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 9)
                .frame(minHeight: 32)
                .background(IOSTheme.accentSubtle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityLabel("Open Terminal to approve")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(IOSTheme.chrome)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(color.opacity(0.34))
                .frame(height: 1)
        }
    }

    private var title: String {
        "Needs attention"
    }

    private var message: String {
        switch attention.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "question": return "Question · Reply in the composer to continue."
        case "permission", "approval": return "Permission · Review the request in Terminal."
        case "stalled", "no_progress", "no_progress_detected": return "No progress detected · Check the Agent in Terminal."
        case "unexpectedabort", "unexpected_abort": return "Unexpected interruption · Check the Agent in Terminal."
        default:
            switch attention.kind {
            case .input: return "Question · Reply in the composer to continue."
            case .approval: return "Permission · Review the request in Terminal."
            case .warning, .unknown: return "Check the Agent in Terminal."
            }
        }
    }

    private var symbol: String {
        switch attention.kind {
        case .input: return "text.bubble"
        case .approval: return "checkmark.shield"
        case .warning, .unknown: return "exclamationmark.triangle"
        }
    }

    private var color: Color {
        switch attention.kind {
        case .input: return IOSTheme.blue
        case .approval: return IOSTheme.amber
        case .warning, .unknown: return IOSTheme.yellow
        }
    }
}

private struct AgentWorkingFooter: View {
    let phrase: String

    var body: some View {
        HStack(spacing: 7) {
            IOSShimmerText(phrase, color: IOSTheme.accent, font: IOSTypography.working)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .background(IOSTheme.background)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IOSTheme.separator.opacity(0.45))
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(phrase)
    }
}

private struct AgentHistoryLoadMoreRow: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(IOSTheme.tertiaryText)
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(IOSTheme.tertiaryText)
                }
                Text("LOAD EARLIER")
                    .font(IOSTypography.status)
                    .tracking(0.7)
                    .foregroundStyle(IOSTheme.tertiaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "Loading earlier messages" : "Load earlier messages")
    }
}

private enum AgentWorkingPhrases {
    static let defaultPhrase = "Fermenting…"
    static let all: [String] = [
        "Fermenting…",
        "Fiddle-faddling…",
        "Booping…",
        "Pondering…",
        "Whirring…",
        "Tinkering…",
        "Conjuring…",
        "Mulling…",
        "Warming up…",
        "Plotting…",
        "Wiggling…",
        "Riffing…",
        "Hatching…",
        "Stirring…",
        "Percolating…",
        "Polishing…",
    ]

    static func random(excluding current: String) -> String {
        let candidates = all.filter { $0 != current }
        return (candidates.isEmpty ? all : candidates).randomElement() ?? defaultPhrase
    }
}

private struct AgentModeBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(IOSTypography.metadata)
            .foregroundStyle(IOSTheme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(IOSTheme.accentSubtle, in: Capsule())
            .accessibilityLabel("Agent mode \(title)")
    }
}

private func agentModeLabel(provider: String?, command: String?) -> String? {
    let kind = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let command = command?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    guard !kind.isEmpty || !command.isEmpty else { return nil }

    switch kind {
    case "codex":
        // `--dangerously-bypass-hook-trust` is Warren's hook bootstrap flag;
        // it does not disable Codex approvals or the sandbox and must not be
        // presented as YOLO.
        if command.contains("--dangerously-bypass-approvals-and-sandbox")
            || command.contains("--full-auto")
            || command.contains("--yolo") {
            return "YOLO"
        }
        if command.contains("--ask-for-approval") { return "Ask" }
    case "claude", "claude-code":
        if command.contains("--dangerously-skip-permissions") || command.contains("bypasspermissions") {
            return "YOLO"
        }
        if command.contains("acceptedits") { return "Edit" }
        if command.contains("permission-mode plan") { return "Plan" }
        if command.contains("permission-mode default") { return "Ask" }
        if command.contains("permission-mode dontask") { return "Auto" }
    case "opencode", "open-code":
        if command.contains("--dangerously") || command.contains("--yolo") || command.contains("--auto-approve") {
            return "YOLO"
        }
        if let value = commandOptionValue(command, options: ["--agent", "--mode"]) {
            return value.capitalized
        }
    default:
        break
    }
    return nil
}

private func commandOptionValue(_ command: String, options: [String]) -> String? {
    let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
    for (index, token) in tokens.enumerated() {
        let value = String(token)
        for option in options {
            if value == option, index + 1 < tokens.count {
                let next = String(tokens[index + 1])
                return next.isEmpty ? nil : next
            }
            if value.hasPrefix(option + "=") {
                let next = String(value.dropFirst(option.count + 1))
                return next.isEmpty ? nil : next
            }
        }
    }
    return nil
}

private enum AgentDisplayBlock: Identifiable {
    case event(WarrenRemoteAgentEvent)
    case activity(AgentActivityGroup)

    var id: String {
        switch self {
        case .event(let event): return "event-\(event.idForSwiftUI)"
        case .activity(let group): return group.id
        }
    }
}

private struct AgentActivityGroup {
    let entries: [AgentActivityEntry]

    var id: String {
        let first = entries.first?.sequence ?? 0
        let last = entries.last?.sequence ?? first
        return "activity-\(first)-\(last)"
    }

    var reasoningCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .reasoning = entry { count += 1 }
        }
    }

    var reasoningEvents: [WarrenRemoteAgentEvent] {
        entries.compactMap { entry in
            guard case .reasoning(let event) = entry else { return nil }
            return event
        }
    }

    var toolCount: Int {
        entries.reduce(into: 0) { count, entry in
            if case .tool = entry { count += 1 }
        }
    }

    var toolBlocks: [AgentToolBlock] {
        entries.compactMap { entry in
            guard case .tool(let tool) = entry else { return nil }
            return tool
        }
    }

    var title: String {
        var parts: [String] = []
        if reasoningCount > 0 { parts.append("Thinking × \(reasoningCount)") }
        if toolCount > 0 { parts.append("Tools × \(toolCount)") }
        return parts.isEmpty ? "Activity" : parts.joined(separator: " · ")
    }

    var firstToolSummary: String? {
        for entry in entries {
            if case .tool(let tool) = entry,
               let summary = toolSummary(for: tool.call) {
                return summary
            }
        }
        return nil
    }

    /// A collapsed activity row should still tell the reader why it exists.
    /// Tool input is the most actionable preview; when a provider only emits
    /// reasoning, show its first line instead of leaving a blank rail.
    var preview: String? {
        if let summary = firstToolSummary { return summary }
        for entry in entries {
            guard case .reasoning(let event) = entry,
                  let content = event.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
            return truncateToolSummary(firstLine, maxLength: 90)
        }
        return nil
    }

    var status: AgentActivityStatus {
        let toolStatuses = entries.compactMap { entry -> String? in
            guard case .tool(let tool) = entry else { return nil }
            return tool.status
        }
        if toolStatuses.contains("error") { return .failed }
        if toolStatuses.contains("interrupted") { return .interrupted }
        if toolStatuses.contains("running") { return .running }
        return .completed
    }
}

private enum AgentActivityStatus {
    case running
    case completed
    case failed
    case interrupted
}

private enum AgentActivityEntry {
    case reasoning(WarrenRemoteAgentEvent)
    case tool(AgentToolBlock)

    var sequence: UInt64 {
        switch self {
        case .reasoning(let event): return event.sequence
        case .tool(let tool): return tool.call.sequence
        }
    }
}

private struct AgentToolBlock {
    let call: WarrenRemoteAgentEvent
    var outputs: [WarrenRemoteAgentEvent]

    var id: String {
        let callID = call.callID?.isEmpty == false ? call.callID! : call.id
        return "tool-\(callID)-\(call.sequence)"
    }

    var status: String {
        let values = outputs.compactMap { $0.toolStatus?.lowercased() }
        if values.contains("error") { return "error" }
        if values.contains("interrupted") { return "interrupted" }
        if values.contains("running") || values.contains("working") { return "running" }
        if let callStatus = call.toolStatus?.lowercased(), !callStatus.isEmpty {
            return callStatus == "working" ? "running" : callStatus
        }
        return outputs.isEmpty ? "running" : "success"
    }
}

private func agentDisplayBlocks(from events: [WarrenRemoteAgentEvent]) -> [AgentDisplayBlock] {
    var result: [AgentDisplayBlock] = []
    var activityEntries: [AgentActivityEntry] = []
    var pendingTools: [String: Int] = [:]

    /// Activity is a timeline segment, not a whole user turn. Ending the
    /// segment at every visible conversation event keeps tool/thinking work
    /// between two assistant replies instead of folding the entire turn into
    /// one disclosure row.
    func flushActivity() {
        guard !activityEntries.isEmpty else { return }
        result.append(.activity(AgentActivityGroup(entries: activityEntries)))
        activityEntries.removeAll(keepingCapacity: true)
        pendingTools.removeAll(keepingCapacity: true)
    }

    for event in events {
        guard !event.isHiddenFromMobile else { continue }
        if event.isUserEvent {
            guard event.hasRenderableConversationContent else { continue }
            flushActivity()
            result.append(.event(event))
        } else if event.isToolCallEvent {
            let tool = AgentToolBlock(call: event, outputs: [])
            activityEntries.append(.tool(tool))
            if let key = event.correlationID {
                pendingTools[key] = activityEntries.count - 1
            }
        } else if event.isToolOutputEvent,
                  let key = event.correlationID,
                  let index = pendingTools[key],
                  index < activityEntries.count,
                  case .tool(var tool) = activityEntries[index] {
            tool.outputs.append(event)
            activityEntries[index] = .tool(tool)
        } else if event.isReasoningEvent && !event.hasRenderableActivityContent {
            // Providers sometimes emit an empty reasoning boundary before
            // the actual text. It is protocol metadata, not a useful mobile
            // row, so do not create a disclosure with no body.
            continue
        } else if event.isAssistantEvent && !event.hasRenderableConversationContent {
            // A role-only boundary carries model/usage metadata but no
            // conversation. Keeping it would create an empty message block
            // between the real user and assistant messages.
            continue
        } else if event.isReasoningEvent {
            activityEntries.append(.reasoning(event))
        } else if event.isToolOutputEvent {
            // Keep an unmatched output visible, but do not let it absorb a
            // preceding activity segment whose call was not correlated.
            flushActivity()
            result.append(.event(event))
        } else {
            // Assistant replies, system markers, and other visible events
            // delimit the activity segment so the timeline keeps its source
            // order instead of waiting for the next user message.
            flushActivity()
            result.append(.event(event))
        }
    }
    flushActivity()
    return result
}

private extension WarrenRemoteAgentEvent {
    var normalizedType: String { type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    var isUserEvent: Bool {
        normalizedType == "user" || role?.lowercased() == "user"
    }

    var isReasoningEvent: Bool {
        normalizedType == "reasoning"
            || normalizedType.contains("thinking")
            || normalizedType.contains("reason")
    }

    var isToolCallEvent: Bool {
        normalizedType == "tool_call" || normalizedType == "toolcall"
    }

    var isToolOutputEvent: Bool {
        normalizedType == "tool_output" || normalizedType == "tooloutput"
    }

    var isCompactionEvent: Bool {
        let type = normalizedType.replacingOccurrences(of: "-", with: "_")
        switch type {
        case "compact", "compacted", "compaction", "compacting",
             "context_compaction", "context_compacted", "context_compacting":
            return true
        default:
            break
        }

        // Codex currently reports compaction as a generic system event. Keep
        // the detection narrow so unrelated system notices remain unchanged.
        guard type == "system" else { return false }
        let text = [content, output, error]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        return text.contains("history compact") || text.contains("context compact")
    }

    var isCompactionInProgress: Bool {
        let type = normalizedType.replacingOccurrences(of: "-", with: "_")
        if type == "compacting" || type == "context_compacting" { return true }
        switch toolStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "loading", "running", "working", "compacting": return true
        default: return false
        }
    }

    var isHiddenFromMobile: Bool {
        let type = normalizedType.replacingOccurrences(of: "-", with: "_")
        let text = [content, output, error]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")
        // Codex emits a `usage` event with the literal "Token usage" body;
        // older providers have also used a generic assistant/system event for
        // the same line. It is bookkeeping, not conversation, so keep every
        // such line out of the mobile timeline.
        if text == "token usage" || text.hasPrefix("token usage") {
            return true
        }
        if usage != nil
            && content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return true
        }
        return type == "usage"
            || type == "token_usage"
            || type == "token_count"
            || type.hasSuffix("_usage")
            || type == "system_instructions"
    }

    var hasRenderableActivityContent: Bool {
        [content, output, error].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasRenderableConversationContent: Bool {
        guard let content else { return false }
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var correlationID: String? {
        if let callID, !callID.isEmpty { return callID }
        return id.isEmpty ? nil : id
    }
}

@ViewBuilder
@MainActor
private func displayBlockView(_ block: AgentDisplayBlock) -> some View {
    switch block {
    case .event(let event):
        AgentEventBlock(event: event)
    case .activity(let activity):
        AgentActivityGroupBlock(activity: activity)
    }
}

private struct AgentEventBlock: View {
    let event: WarrenRemoteAgentEvent

    var body: some View {
        if isUser {
            HStack {
                Spacer(minLength: 34)
                VStack(alignment: .trailing, spacing: 4) {
                    AgentMarkdownText(value: event.content ?? "", font: IOSTypography.userMessage)
                        .foregroundStyle(IOSTheme.text)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .background(IOSTheme.muted.opacity(0.82), in: UnevenRoundedRectangle(
                            topLeadingRadius: 16,
                            bottomLeadingRadius: 16,
                            bottomTrailingRadius: 16,
                            topTrailingRadius: 5
                        ))
                }
                .frame(maxWidth: 420, alignment: .trailing)
            }
            .padding(.vertical, 7)
        } else if isToolOutput {
            AgentToolOutputBlock(event: event)
        } else if event.isCompactionEvent {
            AgentCompactionMarker(event: event)
        } else if normalizedType == "error" {
            VStack(alignment: .leading, spacing: 9) {
                Text(event.error ?? event.content ?? "")
                    .font(IOSTypography.code)
                    .foregroundStyle(IOSTheme.red)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 7)
        } else if normalizedType == "attachment" {
            AgentSecondaryEventBlock(
                title: "Attachment",
                symbol: "paperclip",
                content: event.content ?? "",
                contentFont: IOSTypography.code
            )
        } else if normalizedType == "system" {
            AgentSecondaryEventBlock(
                title: "System",
                symbol: "info.circle",
                content: event.content ?? "System",
                contentFont: IOSTypography.metadata
            )
        } else if isSecondaryMetadata {
            AgentSecondaryEventBlock(
                title: event.type.isEmpty ? "Details" : event.type.capitalized,
                symbol: "info.circle",
                content: event.content ?? event.output ?? event.error ?? "",
                contentFont: IOSTypography.metadata
            )
        } else {
            eventBody
                .padding(.vertical, 7)
        }
    }

    private var eventBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let content = event.content, !content.isEmpty {
                AgentMarkdownText(value: content, font: IOSTypography.agentConversation)
                    .foregroundStyle(IOSTheme.agentText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let output = event.output, !output.isEmpty {
                Text(output)
                    .font(IOSTypography.code)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = event.error, !error.isEmpty {
                Text(error)
                    .font(IOSTypography.code)
                    .foregroundStyle(IOSTheme.red)
                    .textSelection(.enabled)
            }
            if let toolName = event.toolName, !toolName.isEmpty, event.content == nil, event.output == nil {
                Text(toolName)
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.secondaryText)
            }
        }
    }

    private var normalizedType: String { event.normalizedType }
    private var isUser: Bool { event.isUserEvent }
    private var isToolOutput: Bool { event.isToolOutputEvent }

    private var isSecondaryMetadata: Bool {
        guard !event.isAssistantEvent else { return false }
        switch normalizedType.replacingOccurrences(of: "-", with: "_") {
        case "metadata", "notice", "info", "status", "unknown", "event": return true
        default: return false
        }
    }

}

/// Provider metadata is useful when diagnosing a transcript, but it is not
/// part of the conversation. Keep it as a single quiet disclosure so a long
/// run does not push the user/assistant messages away from the viewport.
private struct AgentSecondaryEventBlock: View {
    let title: String
    let symbol: String
    let content: String
    let contentFont: Font
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 11)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .regular))
                    Text(title)
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.secondaryText)
                    if !expanded, let preview {
                        Text(preview)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(content)
                    .font(contentFont)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    private var preview: String? {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return truncateToolSummary(firstLine, maxLength: 90)
    }
}

/// Context compaction is a timeline marker rather than a conversation block.
/// Keep it on one quiet row, matching the compact marker used by the Web/Paseo
/// client, so a long transcript does not spend a full message block on it.
private struct AgentCompactionMarker: View {
    let event: WarrenRemoteAgentEvent

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
            HStack(spacing: 5) {
                Image(systemName: event.isCompactionInProgress ? "arrow.triangle.2.circlepath" : "scissors")
                    .font(.system(size: 11, weight: .medium))
                Text(label)
                    .font(IOSTypography.metadata)
                    .lineLimit(1)
            }
            .foregroundStyle(event.isCompactionInProgress ? IOSTheme.amber : IOSTheme.tertiaryText)
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
        .padding(.vertical, 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let value = event.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        return event.isCompactionInProgress ? "Compacting…" : "Context compacted"
    }
}

private struct AgentActivityGroupBlock: View {
    let activity: AgentActivityGroup
    @State private var expanded = false

    init(activity: AgentActivityGroup) {
        self.activity = activity
        _expanded = State(initialValue: activity.status == .failed || activity.status == .interrupted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)
                    Image(systemName: activity.toolCount > 0 ? "terminal" : "brain.head.profile")
                        .font(.system(size: 13, weight: .regular))
                    Text(activity.title)
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.text)
                        .lineLimit(1)
                    if !expanded, let summary = activity.preview {
                        Text(summary)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    activityStatusMark
                }
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activity.title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    if !activity.reasoningEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if activity.toolCount > 0 {
                                Text("Thinking")
                                    .font(IOSTypography.metadata)
                                    .foregroundStyle(IOSTheme.tertiaryText)
                            }
                            ForEach(Array(activity.reasoningEvents.enumerated()), id: \.element.idForSwiftUI) { index, event in
                                AgentReasoningEntry(
                                    event: event,
                                    step: activity.reasoningEvents.count > 1 ? index + 1 : nil
                                )
                            }
                        }
                    }
                    if !activity.toolBlocks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            if activity.reasoningCount > 0 {
                                Text("Tools")
                                    .font(IOSTypography.metadata)
                                    .foregroundStyle(IOSTheme.tertiaryText)
                            }
                            ForEach(activity.toolBlocks, id: \.id) { tool in
                                AgentToolBlockView(tool: tool)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(IOSTheme.muted.opacity(0.28), in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
                    }
                }
                .padding(.leading, 32)
                .padding(.bottom, 9)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(IOSTheme.separator)
                        .frame(width: 1)
                        .padding(.leading, 19)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var activityStatusMark: some View {
        switch activity.status {
        case .running:
            // Keep the activity rail non-verbal: the animated Working cue is
            // already anchored immediately above the composer. A small pulse
            // still makes a running group discoverable without duplicating it.
            IOSAgentActivityMark(activity: .working, slotSize: 18)
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IOSTheme.red)
                .accessibilityLabel("Activity failed")
        case .interrupted:
            Image(systemName: "pause.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IOSTheme.yellow)
                .accessibilityLabel("Activity interrupted")
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IOSTheme.green.opacity(0.86))
                .accessibilityLabel("Activity completed")
        }
    }
}

/// Reasoning is useful context when debugging a turn, but it is not the
/// conversation itself. Keep it behind a second, quiet disclosure so opening
/// an activity group still exposes the actionable tool calls first.
private struct AgentReasoningEntry: View {
    let event: WarrenRemoteAgentEvent
    let step: Int?
    @State private var expanded = false

    init(event: WarrenRemoteAgentEvent, step: Int? = nil) {
        self.event = event
        self.step = step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 11)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11, weight: .regular))
                    Text(step.map { "Step \($0)" } ?? "Thinking")
                        .font(IOSTypography.label)
                    if !expanded, let summary {
                        Text(summary)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thinking")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded, let content = event.content, !content.isEmpty {
                AgentMarkdownText(value: content, font: IOSTypography.helper)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 18)
            }
        }
    }

    private var summary: String? {
        guard let content = event.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else { return nil }
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? content
        return truncateToolSummary(firstLine, maxLength: 90)
    }
}

private struct AgentToolBlockView: View {
    let tool: AgentToolBlock
    @State private var expanded = false

    init(tool: AgentToolBlock) {
        self.tool = tool
        _expanded = State(initialValue: tool.status == "error" || tool.status == "interrupted")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)
                    Text(displayToolName(tool.call.toolName))
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.text)
                        .lineLimit(1)
                    if let summary = toolSummary(for: tool.call) {
                        Text(summary)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 3)
                    AgentToolStatusMark(status: tool.status)
                }
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayToolName(tool.call.toolName))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let summary = toolSummary(for: tool.call) {
                        Text(summary)
                            .font(IOSTypography.code)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(tool.outputs.enumerated()), id: \.offset) { _, output in
                        if let value = output.output, !value.isEmpty {
                            Text(value)
                                .font(IOSTypography.code)
                                .foregroundStyle(IOSTheme.secondaryText)
                                .textSelection(.enabled)
                        }
                        if let error = output.error, !error.isEmpty {
                            Text(error)
                                .font(IOSTypography.code)
                                .foregroundStyle(IOSTheme.red)
                                .textSelection(.enabled)
                        }
                    }
                    if tool.outputs.isEmpty, tool.call.toolStatus?.isEmpty ?? true {
                        Text("Waiting for output…")
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                    }
                }
                .padding(.leading, 19)
                .padding(.bottom, 6)
            }
        }
    }
}

private struct AgentToolOutputBlock: View {
    let event: WarrenRemoteAgentEvent
    @State private var expanded = false

    init(event: WarrenRemoteAgentEvent) {
        self.event = event
        let status = event.toolStatus?.lowercased() ?? ""
        _expanded = State(initialValue: status == "error" || status == "failed" || status == "interrupted")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)
                    Text(displayToolName(event.toolName))
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.text)
                    Spacer(minLength: 3)
                    AgentToolStatusMark(status: event.toolStatus ?? "success")
                }
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayToolName(event.toolName))
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let output = event.output, !output.isEmpty {
                        Text(output)
                            .font(IOSTypography.code)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .textSelection(.enabled)
                    }
                    if let error = event.error, !error.isEmpty {
                        Text(error)
                            .font(IOSTypography.code)
                            .foregroundStyle(IOSTheme.red)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 19)
                .padding(.bottom, 7)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Tool rows are deliberately denser than conversation rows. The status is
/// still announced to VoiceOver, while a symbol leaves the summary column
/// enough room for the command or file path on a narrow phone.
private struct AgentToolStatusMark: View {
    let status: String

    var body: some View {
        switch status.lowercased() {
        case "running", "working":
            IOSAgentActivityMark(activity: .working, slotSize: 17)
                .accessibilityLabel("Tool running")
        case "error", "failed":
            Image(systemName: "xmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IOSTheme.red)
                .accessibilityLabel("Tool failed")
        case "interrupted":
            Image(systemName: "pause.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(IOSTheme.yellow)
                .accessibilityLabel("Tool interrupted")
        default:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(IOSTheme.green.opacity(0.86))
                .accessibilityLabel("Tool completed")
        }
    }
}

private extension WarrenRemoteAgentEvent {
    var isAssistantEvent: Bool {
        normalizedType == "assistant" || role?.lowercased() == "assistant"
    }
}

private func displayToolName(_ name: String?) -> String {
    switch name {
    case "Bash", "shell": return "Shell"
    case "Edit": return "Edit file"
    case "Read": return "Read file"
    case "Grep": return "Search files"
    case "Glob": return "Find files"
    case "WebSearch", "web_search": return "Web search"
    case "ApplyPatch", "apply_patch": return "Apply patch"
    case "Task": return "Subagent"
    case "Write": return "Write file"
    default: return name?.isEmpty == false ? name! : "Tool"
    }
}

private func toolSummary(for event: WarrenRemoteAgentEvent) -> String? {
    guard let input = event.toolInput else { return nil }
    if case .string(let value) = input, !value.isEmpty {
        return truncateToolSummary(value)
    }
    guard case .object(let object) = input else { return nil }
    for key in ["command", "cmd", "file_path", "path", "query", "pattern", "prompt", "url"] {
        if case .string(let value) = object[key], !value.isEmpty {
            return truncateToolSummary(value)
        }
    }
    return nil
}

private func truncateToolSummary(_ value: String, maxLength: Int = 140) -> String {
    guard value.count > maxLength else { return value }
    return String(value.prefix(maxLength)) + "…"
}

private func toolStatusTitle(_ status: String) -> String {
    switch status.lowercased() {
    case "error", "failed": return "Failed"
    case "interrupted": return "Interrupted"
    case "running", "working": return "Running…"
    default: return "Completed"
    }
}

private func toolStatusColor(_ status: String) -> Color {
    switch status.lowercased() {
    case "error", "failed": return IOSTheme.red
    case "interrupted": return IOSTheme.yellow
    case "running", "working": return IOSTheme.amber
    default: return IOSTheme.green
    }
}
