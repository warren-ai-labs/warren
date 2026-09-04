import SwiftUI
import WarrenDesignSystem
import WarrenTransport

#if os(iOS)
import PhotosUI
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit)
/// UITextView's stock insertion caret follows the line fragment height, which
/// is visibly taller than the compact SF Pro glyphs used by the composer.
/// Keep the native editing behavior, but make the caret follow the font's
/// point-size scale just like the text it accompanies.
private final class AgentComposerTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.height > 0, let font else { return }
        let singleLine = contentSize.height <= font.lineHeight + 14
        let verticalInset: CGFloat = singleLine
            ? max(6, floor((bounds.height - font.lineHeight) / 2))
            : 6
        if abs(textContainerInset.top - verticalInset) > 0.5
            || abs(textContainerInset.bottom - verticalInset) > 0.5 {
            textContainerInset.top = verticalInset
            textContainerInset.bottom = verticalInset
        }
        let shouldScroll = contentSize.height > bounds.height + 2
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fitting = super.sizeThatFits(size)
        let minHeight: CGFloat = 34
        let maxHeight: CGFloat = 94
        return CGSize(width: size.width, height: min(max(fitting.height, minHeight), maxHeight))
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : 300
        return sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

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
    let isDisabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> AgentComposerTextView {
        let view = AgentComposerTextView(frame: .zero)
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let textColor = UIColor(IOSTheme.text)

        view.delegate = context.coordinator
        view.font = font
        view.textColor = textColor
        view.tintColor = textColor
        view.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]
        view.backgroundColor = .clear
        view.isEditable = !isDisabled
        view.adjustsFontForContentSizeCategory = true
        // Keep the composer bounded while letting long drafts and large
        // Dynamic Type scroll inside the field instead of being clipped.
        view.isScrollEnabled = true
        view.showsVerticalScrollIndicator = false
        view.textContainer.lineFragmentPadding = 0
        // layoutSubviews derives the exact vertical inset after Auto Layout
        // gives the text view its 44pt row height.
        view.textContainerInset = UIEdgeInsets(top: 8, left: 7, bottom: 8, right: 2)
        view.textContainer.maximumNumberOfLines = 0
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
        view.isEditable = !isDisabled

        // UIKit owns the responder while the text view is editing. Do not
        // resign from updateUIView: SwiftUI can briefly deliver a stale
        // binding during a model/layout publication (including a keyboard
        // key press), which would collapse the keyboard after every tap.
        context.coordinator.updateFocusIntent(isFocused)
        if isFocused, !view.isFirstResponder {
            let requestID = context.coordinator.focusRequestID
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator,
                      coordinator.wantsFocus,
                      coordinator.focusRequestID == requestID,
                      !view.isFirstResponder else { return }
                view.becomeFirstResponder()
            }
        } else if !isFocused, view.isFirstResponder {
            let requestID = context.coordinator.focusRequestID
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, let coordinator,
                      !coordinator.wantsFocus,
                      coordinator.focusRequestID == requestID,
                      view.isFirstResponder else { return }
                view.resignFirstResponder()
            }
        }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AgentComposerTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        fileprivate private(set) var wantsFocus = false
        fileprivate private(set) var focusRequestID: UInt = 0

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func updateFocusIntent(_ focused: Bool) {
            guard wantsFocus != focused else { return }
            wantsFocus = focused
            focusRequestID &+= 1
        }

        func textViewDidChange(_ textView: UITextView) {
            guard text.wrappedValue != textView.text else { return }
            text.wrappedValue = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_: UITextView) {
            wantsFocus = true
            if !isFocused.wrappedValue {
                isFocused.wrappedValue = true
            }
        }

        func textViewDidEndEditing(_: UITextView) {
            wantsFocus = false
            focusRequestID &+= 1
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var renderedBlocks: [AgentDisplayBlock] = []
    @State private var didEstablishInitialScroll = false
    @State private var didTriggerHistoryPull = false
    @State private var historyScrollAnchorID: String?
    @State private var isNearLatest = true
    @State private var showReturnToLatest = false
    @State private var workingPhrase = AgentWorkingPhrases.defaultPhrase
    @State private var draftSessionID: String?
    @State private var localAttachments: [IOSAgentLocalAttachment] = []
    @State private var isUploadingAttachments = false
    @State private var attachmentUploadGeneration = 0
    @State private var isFileImporterPresented = false
    @State private var isQueueSheetPresented = false
    @State private var sendStatus = ""
    @State private var attachmentFeedback = ""
    @State private var attachmentFeedbackGeneration = 0
    @State private var sendStatusGeneration = 0
    @State private var cancelPending = false
#if os(iOS)
    @State private var photoItems: [PhotosPickerItem] = []
#endif
#if canImport(UIKit)
    // The UIKit text view reports responder changes through its coordinator;
    // a plain State binding avoids SwiftUI's FocusState transaction briefly
    // clearing the responder while the keyboard is publishing input.
    @State private var composerFocused = false
#else
    @FocusState private var composerFocused: Bool
#endif

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
                            } else if let historyError = model.agentHistoryError(for: sessionID), !historyError.isEmpty {
                                AgentHistoryLoadMoreRow(
                                    isLoading: false,
                                    error: historyError,
                                    action: { requestOlderHistory(blocks: blocks, force: true) }
                                )
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
                                    displayBlockView(
                                        block,
                                        canInteract: model.supportsAgentCapability(WarrenRemoteAgentCapability.interactions)
                                    ) { requestID, kind, response in
                                        model.respondToAgentInteraction(
                                            sessionID: sessionID,
                                            requestID: requestID,
                                            kind: kind,
                                            response: response
                                        )
                                    }
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
                        guard bottomY.isFinite else { return }
                        let distanceFromLatest = bottomY - viewport.size.height
                        let wasNearLatest = isNearLatest
                        isNearLatest = distanceFromLatest <= latestVisibilityThreshold

                        if isNearLatest {
                            showReturnToLatest = false
                        } else if wasNearLatest {
                            // Show the escape hatch as soon as the user leaves
                            // the latest-message visibility window.
                            showReturnToLatest = true
                        }
                    }
                    #if os(iOS)
                    .scrollDismissesKeyboard(.interactively)
                    .scrollBounceBehavior(.always, axes: .vertical)
                    #endif
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            if composerFocused {
                                composerFocused = false
                                model.dismissKeyboard()
                            }
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
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
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
                                .font(IOSTypography.label)
                                .foregroundStyle(IOSTheme.secondaryText)
                                .frame(width: 27, height: 27)
                                .background(IOSTheme.chrome.opacity(0.96), in: Circle())
                                .overlay {
                                    Circle()
                                        .stroke(IOSTheme.ring.opacity(0.90), lineWidth: 1)
                                }
                                // Keep the glyph compact while giving the
                                // floating affordance the full iOS hit area.
                                .frame(width: 44, height: 44)
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
        // The system owns keyboard-inset animation. Keeping focus out of the
        // view-level animation transaction prevents a responder hand-off
        // while the composer is being laid out.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomTray
        }
        .onAppear {
            draftSessionID = sessionID
            draft = model.agentDraft(for: sessionID)
            refreshRenderedBlocks()
            model.ensureAgentSubscribed(for: sessionID)
            if !model.agentHistoryLoaded(for: sessionID) {
                model.loadOlderAgentHistory()
            }
        }
        .onChange(of: draft) { _, value in
            model.updateAgentDraft(value, for: draftSessionID ?? sessionID)
        }
        .onDisappear {
            // Invalidate any in-flight Host upload before this view can be
            // reused for another Session. The task may still finish, but its
            // progress and completion are no longer allowed to touch state.
            attachmentUploadGeneration &+= 1
            sendStatusGeneration &+= 1
            attachmentFeedbackGeneration &+= 1
            model.flushAgentDraft(draft, for: draftSessionID ?? sessionID)
        }
        .onChange(of: model.currentSessionID) { _, selectedSessionID in
            attachmentUploadGeneration &+= 1
            guard let selectedSessionID, selectedSessionID != draftSessionID else { return }
            if let previousSessionID = draftSessionID {
                model.flushAgentDraft(draft, for: previousSessionID)
            }
            draftSessionID = selectedSessionID
            draft = model.agentDraft(for: selectedSessionID)
            localAttachments.removeAll()
            isUploadingAttachments = false
            isFileImporterPresented = false
            isQueueSheetPresented = false
            sendStatus = ""
            attachmentFeedback = ""
            sendStatusGeneration &+= 1
            attachmentFeedbackGeneration &+= 1
            cancelPending = false
            refreshRenderedBlocks(for: selectedSessionID)
            didTriggerHistoryPull = false
            historyScrollAnchorID = nil
            showReturnToLatest = false
            isNearLatest = true
            workingPhrase = AgentWorkingPhrases.defaultPhrase
            guard !model.agentHistoryLoaded(for: selectedSessionID) else { return }
            model.loadOlderAgentHistory()
        }
        .sheet(isPresented: $isQueueSheetPresented) {
            IOSAgentQueueSheet(model: model, sessionID: sessionID)
                .iosSheetPresentation(.medium, .large)
        }
        .onChange(of: workingTurnKey) { _, _ in
            workingPhrase = AgentWorkingPhrases.next(after: workingPhrase)
        }
        .onChange(of: model.canInterruptAgentTurn) { _, canInterrupt in
            if !canInterrupt { cancelPending = false }
        }
        .onChange(of: model.agentActionError) { _, error in
            guard let error, !error.isEmpty else { return }
            if sendStatus == "sending" {
                sendStatus = "failed"
            }
            cancelPending = false
        }
    }

    private func refreshRenderedBlocks(for requestedSessionID: String? = nil) {
        let targetSessionID = requestedSessionID ?? sessionID
        renderedBlocks = agentDisplayBlocks(from: agentState.agentEventsBySessionID[targetSessionID] ?? [])
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
        let retryingAfterError = model.agentHistoryError(for: sessionID) != nil
        guard (model.agentHistoryLoaded(for: sessionID) || retryingAfterError),
              model.agentHistoryHasMore(for: sessionID),
              !model.historyLoadingBySessionID.contains(sessionID),
              force || !didTriggerHistoryPull else { return }

        didTriggerHistoryPull = true
        historyScrollAnchorID = blocks.first?.id
        model.loadOlderAgentHistory()
    }

    private func handleNewContent(
        using proxy: ScrollViewProxy,
        shouldFollowLatest: Bool? = nil
    ) {
        guard historyScrollAnchorID == nil else { return }
        if shouldFollowLatest ?? isNearLatest {
            // Keep a live response pinned without an animation on every
            // streamed delta. Repeated animated scrolls are perceived as page
            // jumps, especially while the user is changing scroll direction.
            scrollToLatest(using: proxy, animated: false)
        } else {
            showReturnToLatest = true
        }
    }

    private func observeAgentRevision(using proxy: ScrollViewProxy) {
        // Capture the user's intent before refreshing the rows. Updating the
        // LazyVStack can briefly remove the bottom sentinel, so reading the
        // live proximity state after that layout pass would incorrectly stop
        // following a conversation that was already at the latest message.
        let shouldFollowLatest = isNearLatest
        refreshRenderedBlocks()
        guard historyScrollAnchorID == nil else { return }
        // The revision is published before the new LazyVStack rows have been
        // laid out. Wait through two main-actor turns so the new bottom marker
        // exists before an intentional follow-to-latest.
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            handleNewContent(using: proxy, shouldFollowLatest: shouldFollowLatest)
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, animated: Bool) {
        isNearLatest = true
        showReturnToLatest = false
        if animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.18)) {
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

    private var latestActionText: String? {
        latestAgentAction(from: agentState.agentEventsBySessionID[sessionID] ?? [])
    }

    @ViewBuilder
    private var bottomTray: some View {
        if model.displayMode == .agent {
            VStack(alignment: .leading, spacing: 0) {
                if let attention = model.agentAttention(for: sessionID) {
                    AgentAttentionBanner(
                        attention: attention,
                        openTerminal: {
                            model.setDisplayMode(.terminal)
                            model.focusTerminal()
                        },
                        focusComposer: { composerFocused = true }
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                if shouldShowWorking {
                    AgentWorkingFooter(
                        phrase: workingPhrase,
                        action: latestActionText
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                if let actionError = model.agentActionError, !actionError.isEmpty {
                    Text(actionError)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.red)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 4)
                        .accessibilityLabel("Agent action failed: \(actionError)")
                }
                composer
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: shouldShowWorking)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.agentAttention(for: sessionID))
        }
    }

    private var composer: some View {
        VStack(alignment: .center, spacing: 6) {
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
                    .containerRelativeFrame(.horizontal) { length, _ in length * 0.9 }
            }

            VStack(alignment: .leading, spacing: 6) {
                if !attachmentFeedback.isEmpty {
                    Text(attachmentFeedback)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                        .padding(.horizontal, 13)
                        .padding(.top, 4)
                        .accessibilityLabel(attachmentFeedback)
                }

                if !localAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(localAttachments) { attachment in
                                attachmentChip(attachment)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel("Selected attachments")
                }

                VStack(spacing: 0) {
                    // Row 1: Message input. Sized dynamically from 34pt up to 94pt
                    // via sizeThatFits, scrolling long drafts inside once max height is reached.
                    ZStack(alignment: .leading) {
                        if draft.isEmpty {
                            Text("Message…")
                                .font(IOSTypography.input)
                                .foregroundStyle(IOSTheme.secondaryText.opacity(0.78))
                                .lineLimit(1)
                                .padding(.leading, 7)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
#if canImport(UIKit)
                        AgentComposerInput(
                            text: $draft,
                            isFocused: Binding(
                                get: { composerFocused },
                                set: { composerFocused = $0 }
                            ),
                            isDisabled: isUploadingAttachments || sendStatus == "sending"
                        )
                        .frame(maxWidth: .infinity)
#else
                        GeometryReader { geometry in
                            TextField("", text: $draft, axis: .vertical)
                                .font(IOSTypography.input)
                                .foregroundStyle(IOSTheme.text)
                                .textFieldStyle(.plain)
                                .lineLimit(1...4)
                                .multilineTextAlignment(.leading)
                                .frame(width: geometry.size.width, alignment: .leading)
                                .disabled(isUploadingAttachments || sendStatus == "sending")
                                .focused($composerFocused)
                                .accessibilityLabel("Agent message")
                        }
                        .frame(minHeight: 34, maxHeight: 94)
#endif
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .padding(.horizontal, 8)

                    // Row 2: Attachment, model, keyboard dismiss, and send controls.
                    HStack(alignment: .center, spacing: 4) {
                        attachmentControlsWithPlus

                        if let metadata = agentComposerMetadata {
                            Text(metadata)
                                .font(IOSTypography.metadata)
                                .foregroundStyle(IOSTheme.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(IOSTheme.muted.opacity(0.25), in: Capsule())
                                .accessibilityLabel("Agent model: \(metadata)")
                        }

                        Spacer(minLength: 0)

                        if composerFocused {
                            IOSKeyboardDismissButton {
                                IOSHaptics.light()
                                composerFocused = false
                                model.dismissKeyboard()
                            }
                            .transition(.opacity)
                        }

                        Button {
                            sendComposerMessage()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(IOSTypography.button)
                                .foregroundStyle(IOSTheme.text)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend || isUploadingAttachments || sendStatus == "sending")
                        .opacity(canSend && !isUploadingAttachments && sendStatus != "sending" ? 1 : 0.32)
                        .accessibilityLabel("Send Agent message")
                    }
                    .frame(minHeight: 44, maxHeight: 44)
                    .padding(.horizontal, 4)
                }
                .background(IOSTheme.raised, in: RoundedRectangle(cornerRadius: IOSTheme.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: IOSTheme.radius, style: .continuous)
                        .stroke(
                            composerFocused ? IOSTheme.focusRing : IOSTheme.ring.opacity(0.92),
                            lineWidth: composerFocused ? 1.5 : 1
                        )
                }
                if !sendStatus.isEmpty {
                    Text(sendStatusLabel)
                        .font(IOSTypography.status)
                        .foregroundStyle(sendStatus == "failed" ? IOSTheme.red : IOSTheme.secondaryText)
                        .padding(.horizontal, 13)
                        .padding(.top, 4)
                        .accessibilityLabel(sendStatusLabel)
                }
            }
            .containerRelativeFrame(.horizontal) { length, _ in length * 0.9 }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 3)
        .padding(.bottom, 6)
        .background(IOSTheme.background)
    }

    @ViewBuilder
    private var attachmentControlsWithPlus: some View {
#if os(iOS)
        if model.supportsAgentCapability(WarrenRemoteAgentCapability.attachments) {
            // Keep one compact plus control, but expose both Photos and Files.
            // A PhotosPicker alone cannot attach PDFs, source files, or other
            // documents, while the file importer also handles images selected
            // from Files and iCloud Drive.
            Menu {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                    Label("Choose Photos", systemImage: "photo")
                }
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Choose Files", systemImage: "doc")
                }
            } label: {
                attachmentPlusLabel
            }
            .menuStyle(.automatic)
            .disabled(isUploadingAttachments || sendStatus == "sending")
            .accessibilityLabel("Choose photos or files")
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: handleFileImporter
            )
#if canImport(UIKit)
            .onChange(of: photoItems) { _, items in
                loadPhotos(items)
            }
#endif
        } else {
            filePickerButton
        }
#else
        filePickerButton
#endif
    }

    @ViewBuilder
    private var filePickerButton: some View {
        Button {
            isFileImporterPresented = true
        } label: {
            attachmentPlusLabel
        }
        .buttonStyle(.plain)
        .disabled(!model.supportsAgentCapability(WarrenRemoteAgentCapability.attachments) || isUploadingAttachments || sendStatus == "sending")
        .accessibilityLabel("Choose a file")
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImporter
        )
    }

    private var attachmentPlusLabel: some View {
        Image(systemName: "plus")
            .font(IOSTypography.button)
            .foregroundStyle(IOSTheme.secondaryText)
            .frame(width: 44, height: 44)
    }

    private func attachmentChip(_ attachment: IOSAgentLocalAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachment.mime.starts(with: "image/") ? "photo.fill" : "doc.fill")
                .font(IOSTypography.metadata)
                .foregroundStyle(IOSTheme.secondaryText)

            Text(attachment.name)
                .font(IOSTypography.metadata)
                .foregroundStyle(IOSTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)

            switch attachment.state {
            case .selected:
                EmptyView()
            case .uploading:
                Text("\(Int(attachment.progress * 100))%")
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.amber)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.green)
            case .failed:
                Button("Retry") { retryAttachment(attachment.id) }
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.red)
                    .frame(minHeight: 32)
            case .aborted:
                Text("Aborted")
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.secondaryText)
            }

            Button {
                localAttachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 18, height: 18)
                    .background(IOSTheme.muted.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(isUploadingAttachments)
            .opacity(isUploadingAttachments ? 0.52 : 1)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(IOSTheme.raised, in: Capsule())
        .overlay {
            Capsule()
                .stroke(IOSTheme.ring.opacity(0.85), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(attachment.state.rawValue)
    }

    private var sendStatusLabel: String {
        switch sendStatus {
        case "sending": return "Sending…"
        case "sent": return "Sent"
        case "failed": return "Send failed — retry"
        default: return ""
        }
    }

    private func showTransientFeedback(_ value: String, duration: TimeInterval = 1.6) {
        attachmentFeedbackGeneration &+= 1
        let generation = attachmentFeedbackGeneration
        attachmentFeedback = value
        guard duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard attachmentFeedbackGeneration == generation else { return }
            attachmentFeedback = ""
        }
    }

    private func showSendStatus(_ value: String, duration: TimeInterval? = 1.6) {
        sendStatusGeneration &+= 1
        let generation = sendStatusGeneration
        sendStatus = value
        guard let duration else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard sendStatusGeneration == generation else { return }
            sendStatus = ""
        }
    }

    private func cancelAgentTurn() {
        guard !cancelPending else { return }
        guard model.cancelAgentTurn() else {
            showSendStatus("failed", duration: 1.6)
            return
        }
        cancelPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            cancelPending = false
        }
    }

    private func sendComposerMessage(sendNow: Bool = false) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!value.isEmpty || !localAttachments.isEmpty),
              !isUploadingAttachments,
              sendStatus != "sending" else { return }
        let selected = localAttachments
        guard selected.allSatisfy({ $0.state == .selected || $0.state == .ready }) else { return }
        showSendStatus("sending", duration: nil)
        guard !selected.isEmpty else {
            let accepted = sendNow
                ? model.sendAgentMessageNow(value)
                : model.sendAgentMessage(value)
            guard accepted else {
                showSendStatus("failed")
                return
            }
            draft = ""
            model.clearAgentDraft(for: sessionID)
            composerFocused = false
            model.dismissKeyboard()
            IOSHaptics.light()
            showSendStatus("sent")
            return
        }
        isUploadingAttachments = true
        let uploadGeneration = attachmentUploadGeneration
        let uploadSessionID = sessionID
        Task { @MainActor in
            var references: [WarrenRemoteAgentAttachmentRef] = []
            for attachment in selected {
                guard attachmentUploadGeneration == uploadGeneration,
                      model.currentSessionID == uploadSessionID else { return }
                guard let index = localAttachments.firstIndex(where: { $0.id == attachment.id }) else { continue }
                if attachment.state == .ready, let reference = attachment.reference {
                    // A partial upload can leave earlier attachments ready
                    // while a later one fails. Reuse their opaque Host
                    // references on retry instead of sending the same bytes
                    // again.
                    references.append(reference)
                    continue
                }
                localAttachments[index].state = .uploading
                localAttachments[index].failureReason = nil
                do {
                    let reference = try await model.uploadAgentAttachment(
                        data: attachment.data,
                        name: attachment.name,
                        mime: attachment.mime,
                        sessionID: sessionID
                    ) { progress in
                        guard self.attachmentUploadGeneration == uploadGeneration,
                              self.model.currentSessionID == uploadSessionID else { return }
                        guard let progressIndex = localAttachments.firstIndex(where: { $0.id == attachment.id }) else { return }
                        localAttachments[progressIndex].progress = progress
                    }
                    guard attachmentUploadGeneration == uploadGeneration,
                          model.currentSessionID == uploadSessionID else { return }
                    references.append(reference)
                    if let readyIndex = localAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        localAttachments[readyIndex].state = .ready
                        localAttachments[readyIndex].reference = reference
                    }
                } catch {
                    guard attachmentUploadGeneration == uploadGeneration,
                          model.currentSessionID == uploadSessionID else { return }
                    if let failedIndex = localAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        localAttachments[failedIndex].state = .failed
                        localAttachments[failedIndex].failureReason = error.localizedDescription
                    }
                    isUploadingAttachments = false
                    showSendStatus("failed")
                    return
                }
            }
            guard attachmentUploadGeneration == uploadGeneration,
                  model.currentSessionID == uploadSessionID else { return }
            isUploadingAttachments = false
            let accepted = sendNow
                ? model.sendAgentMessageNow(value, attachments: references)
                : model.sendAgentMessage(value, attachments: references)
            guard accepted else {
                showSendStatus("failed")
                return
            }
            // Uploading runs asynchronously and the text view remains useful
            // while the bytes are in flight. Only clear the draft when it is
            // still the text that was submitted; preserve newer typing so a
            // successful upload can never discard the next message.
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == value {
                draft = ""
                model.clearAgentDraft(for: sessionID)
            }
            localAttachments.removeAll()
            composerFocused = false
            model.dismissKeyboard()
            showSendStatus("sent")
        }
    }

    private func retryAttachment(_ id: String) {
        guard let index = localAttachments.firstIndex(where: { $0.id == id }) else { return }
        localAttachments[index].state = .selected
        localAttachments[index].progress = 0
        localAttachments[index].failureReason = nil
    }

#if os(iOS)
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, !isUploadingAttachments else { return }
        photoItems = []
        let loadGeneration = attachmentUploadGeneration
        let loadSessionID = sessionID
        Task { @MainActor in
            var added = 0
            var failed = 0
            for item in items {
                let data: Data?
                do {
                    data = try await item.loadTransferable(type: Data.self)
                } catch {
                    failed += 1
                    continue
                }
                guard let data, !data.isEmpty else {
                    failed += 1
                    continue
                }
                guard attachmentUploadGeneration == loadGeneration,
                      model.currentSessionID == loadSessionID else { return }
                let type = item.supportedContentTypes.first?.preferredMIMEType ?? "image/*"
                localAttachments.append(IOSAgentLocalAttachment(name: "Photo", mime: type, data: data))
                added += 1
            }
            guard attachmentUploadGeneration == loadGeneration,
                  model.currentSessionID == loadSessionID else { return }
            if failed > 0 {
                showTransientFeedback(
                    added > 0 ? "Some photos could not be attached." : "Unable to attach photo. Try again."
                )
            } else if added > 0 {
                showTransientFeedback(added == 1 ? "Photo attached" : "Photos attached")
            }
        }
    }
#endif

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        guard !isUploadingAttachments else { return }
        guard case .success(let urls) = result else {
            showTransientFeedback("Unable to read attachment. Try again.")
            return
        }
        var added = 0
        var failed = 0
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                failed += 1
                continue
            }
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
                ?? "application/octet-stream"
            localAttachments.append(IOSAgentLocalAttachment(name: url.lastPathComponent, mime: mime, data: data))
            added += 1
        }
        if failed > 0 {
            showTransientFeedback(
                added > 0 ? "Some attachments could not be read." : "Unable to read attachment. Try again."
            )
        } else if added > 0 {
            showTransientFeedback(added == 1 ? "Attachment added" : "Attachments added")
        }
    }

    private var agentStatus: WarrenRemoteAgentStatus? {
        guard let session = model.roster?.sessions.first(where: { $0.id == sessionID }),
              session.isAgentBacked else { return nil }
        return model.agentStatusBySessionID[sessionID] ?? session.agentStatus
    }

    /// The composer keeps provider metadata to one quiet line. Session name,
    /// mode, and control state belong to the surrounding navigation chrome and
    /// are intentionally not repeated beside the input.
    private var agentComposerMetadata: String? {
        if let modelName = formatAgentModel(model.agentModel(for: sessionID)), !modelName.isEmpty {
            return modelName
        }
        return agentTypeLabel
    }

    private var agentTypeLabel: String? {
        guard let session = model.roster?.sessions.first(where: { $0.id == sessionID }) else { return nil }
        let raw = session.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.lowercased() != "shell" else { return nil }
        switch raw.lowercased() {
        case "codex": return "Codex"
        case "claude", "claude-code": return "Claude"
        case "antigravity", "agy": return "Antigravity"
        case "opencode", "open-code": return "OpenCode"
        case "pi": return "Pi"
        case "qoder": return "Qoder"
        case "trae": return "Trae"
        default: return raw.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private var shouldShowWorking: Bool {
        guard agentStatus?.activity == .working else { return false }
        guard let last = (agentState.agentEventsBySessionID[sessionID] ?? [])
            .last(where: { !$0.isHiddenFromMobile }) else { return true }
        // A completed assistant message is the stronger visual signal. A Host
        // may publish a trailing working status while that event settles.
        return !(last.isAssistantEvent && !(last.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    private var workingTurnKey: String {
        let events = agentState.agentEventsBySessionID[sessionID] ?? []
        if let explicit = model.agentTurnBySessionID[sessionID]?.id, explicit > 0 {
            return "turn:\(explicit)"
        }
        if let latestUser = events.last(where: \.isUserEvent) {
            if let turn = latestUser.turn, turn > 0 {
                return "turn:\(turn)"
            }
            let identity = latestUser.id.isEmpty
                ? "seq:\(latestUser.sequence)"
                : "id:\(latestUser.id)"
            return "user:\(identity)"
        }
        if let eventTurn = events.reversed().compactMap(\.turn).first, eventTurn > 0 {
            return "turn:\(eventTurn)"
        }
        return "unknown"
    }

    private var canSend: Bool {
        model.canSendAgent
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !localAttachments.isEmpty)
    }
}

private struct IOSAgentQueueSheet: View {
    @ObservedObject var model: IOSApplicationModel
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var editingID: String?
    @State private var editingText = ""
    @State private var deleteID: String?

    private var items: [IOSAgentQueueItem] {
        model.agentQueueBySessionID[sessionID]?.items ?? []
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    Text("No queued messages.")
                        .foregroundStyle(IOSTheme.secondaryText)
                } else {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            if editingID == item.id {
                                TextField("Queued message", text: $editingText, axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minHeight: 44)
                                HStack {
                                    Button("Save") {
                                        guard !editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                        _ = model.editQueuedAgentMessage(sessionID: sessionID, itemID: item.id, text: editingText, attachments: item.attachments)
                                        editingID = nil
                                    }
                                    .frame(minWidth: 44, minHeight: 44)
                                    Button("Cancel") { editingID = nil }
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                            } else {
                                Text(item.text)
                                    .font(IOSTypography.body)
                                    .foregroundStyle(IOSTheme.text)
                                    .textSelection(.enabled)
                            }
                            if !item.attachments.isEmpty {
                                Text(item.attachments.compactMap(\.name).joined(separator: ", "))
                                    .font(IOSTypography.metadata)
                                    .foregroundStyle(IOSTheme.secondaryText)
                            }
                            if let failure = item.failureReason {
                                Text(failure)
                                    .font(IOSTypography.metadata)
                                    .foregroundStyle(IOSTheme.red)
                            }
                            HStack(spacing: 12) {
                                if item.status == .failed {
                                    Button("Retry") { _ = model.retryQueuedAgentMessage(sessionID: sessionID, itemID: item.id) }
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                if item.status != .sending && editingID != item.id {
                                    Button {
                                        editingID = item.id
                                        editingText = item.text
                                    } label: {
                                        Image(systemName: "pencil")
                                            .frame(width: 44, height: 44)
                                    }
                                    .accessibilityLabel("Edit queued message")
                                    Button("Move to front") { _ = model.moveQueuedAgentMessageToFront(sessionID: sessionID, itemID: item.id) }
                                        .frame(minWidth: 44, minHeight: 44)
                                    Button("Delete", role: .destructive) { deleteID = item.id }
                                        .frame(minWidth: 44, minHeight: 44)
                                } else if item.status == .sending {
                                    Text("Sending…")
                                        .foregroundStyle(IOSTheme.secondaryText)
                                }
                            }
                            .font(IOSTypography.label)
                        }
                        .padding(.vertical, 4)
                        .confirmationDialog("Delete queued message?", isPresented: Binding(
                            get: { deleteID == item.id },
                            set: { if !$0 { deleteID = nil } }
                        ), titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                _ = model.deleteQueuedAgentMessage(sessionID: sessionID, itemID: item.id)
                                deleteID = nil
                            }
                            Button("Cancel", role: .cancel) { deleteID = nil }
                        }
                    }
                    .onMove { source, destination in
                        guard let sourceIndex = source.first,
                              items.indices.contains(sourceIndex) else { return }
                        let itemID = items[sourceIndex].id
                        // SwiftUI's destination is an insertion offset after
                        // the source row has been removed. Resolve the target
                        // against that remaining list; using the old array
                        // makes a move-to-end land before the last row.
                        var remaining = items
                        remaining.remove(at: sourceIndex)
                        let targetIndex = min(max(destination, 0), remaining.count)
                        let beforeID = targetIndex < remaining.count ? remaining[targetIndex].id : nil
                        _ = model.reorderQueuedAgentMessage(sessionID: sessionID, itemID: itemID, beforeID: beforeID)
                    }
                }
            }
            .navigationTitle("Queued messages")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
#if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
#endif
            }
        }
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
    let focusComposer: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(IOSTypography.label)
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
            if attention.kind == .input {
                Button(action: focusComposer) {
                    HStack(spacing: 4) {
                        Text("Reply")
                        Image(systemName: "arrow.turn.down.left")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(IOSTypography.label)
                    .foregroundStyle(IOSTheme.text)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(IOSTheme.accentSubtle, in: RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous))
                .accessibilityLabel("Reply to Agent question")
            } else {
                Button(action: openTerminal) {
                    HStack(spacing: 4) {
                        Text("Terminal")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .font(IOSTypography.label)
                    .foregroundStyle(IOSTheme.text)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(minHeight: 36)
                .background(IOSTheme.accentSubtle, in: RoundedRectangle(cornerRadius: WarrenRadius.small, style: .continuous))
                .accessibilityLabel("Open Terminal to review request")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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
        case .input: return IOSTheme.info
        case .approval: return IOSTheme.amber
        case .warning, .unknown: return IOSTheme.yellow
        }
    }
}

private struct AgentWorkingFooter: View {
    let phrase: String
    var action: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            contentView
                .overlay {
                    if !reduceMotion {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                            let phase = shimmerPhase(at: timeline.date)
                            let start = -1.20 + phase * 2.40
                            let end = start + 2.20
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .clear, location: 0.38),
                                    .init(color: Color.white.opacity(0.85), location: 0.50),
                                    .init(color: .clear, location: 0.62),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: UnitPoint(x: start, y: 0.5),
                                endPoint: UnitPoint(x: end, y: 0.5)
                            )
                            .mask(contentView)
                        }
                    }
                }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent working: \(phrase)\(action.map { " " + $0 } ?? "")")
    }

    private var contentView: some View {
        HStack(spacing: 7) {
            Text(phrase)
                .font(IOSTypography.working)
                .foregroundStyle(IOSTheme.accent)
            if let action, !action.isEmpty {
                Text(action)
                    .font(IOSTypography.working)
                    .foregroundStyle(Color(white: 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private func shimmerPhase(at date: Date) -> Double {
        let duration = 3.2
        let elapsed = date.timeIntervalSinceReferenceDate
        return (elapsed.truncatingRemainder(dividingBy: duration) + duration)
            .truncatingRemainder(dividingBy: duration) / duration
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

    static func next(after current: String) -> String {
        guard let index = all.firstIndex(of: current) else { return all.first ?? defaultPhrase }
        return all[(index + 1) % all.count]
    }
}

private struct AgentHistoryLoadMoreRow: View {
    let isLoading: Bool
    var error: String?
    let action: () -> Void

    init(isLoading: Bool, error: String? = nil, action: @escaping () -> Void) {
        self.isLoading = isLoading
        self.error = error
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(IOSTheme.tertiaryText)
                } else if error != nil {
                    Image(systemName: "exclamationmark.circle")
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.red)
                } else {
                    Image(systemName: "arrow.up.circle")
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.tertiaryText)
                }
                Text(isLoading
                    ? "LOADING EARLIER…"
                    : error == nil
                        ? "LOAD EARLIER"
                        : "COULDN’T LOAD EARLIER · TRY AGAIN")
                    .font(IOSTypography.status)
                    .tracking(0.7)
                    .foregroundStyle(error == nil ? IOSTheme.tertiaryText : IOSTheme.red)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(isLoading
            ? "Loading earlier messages"
            : error == nil
                ? "Load earlier messages"
                : "Earlier messages failed to load. Try again")
        .accessibilityHint(error == nil || isLoading ? "" : error ?? "")
    }
}

enum AgentDisplayBlock: Identifiable {
    case event(WarrenRemoteAgentEvent)
    case activity(AgentActivityGroup)

    var id: String {
        switch self {
        case .event(let event): return "event-\(event.idForSwiftUI)"
        case .activity(let group): return group.id
        }
    }
}

struct AgentActivityGroup {
    var entries: [AgentActivityEntry]

    var id: String {
        let first = entries.first?.sequence ?? 0
        let turn = entries.first?.turn ?? 0
        return "activity-\(turn)-\(first)"
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
        if reasoningCount > 0 {
            parts.append(reasoningCount == 1 ? "Thinking" : "Thinking × \(reasoningCount)")
        }
        if toolCount > 0 {
            if toolCount == 1, let firstTool = toolBlocks.first?.call.toolName {
                parts.append(displayToolName(firstTool))
            } else {
                let toolNames = Set(toolBlocks.compactMap { $0.call.toolName?.lowercased() })
                if toolNames.count == 1, let singleType = toolNames.first {
                    switch singleType {
                    case "read", "view_file", "viewfile", "read_file":
                        parts.append("Read \(toolCount) files")
                    case "edit", "write", "apply_patch", "replace_file_content", "write_to_file":
                        parts.append("Edited \(toolCount) files")
                    case "grep", "glob", "web_search", "grep_search", "find_by_name", "search_web":
                        parts.append("Searched \(toolCount) times")
                    case "shell", "exec", "execute", "run_command":
                        parts.append("Ran \(toolCount) commands")
                    default:
                        parts.append("\(displayToolName(singleType)) × \(toolCount)")
                    }
                } else {
                    parts.append("Tools × \(toolCount)")
                }
            }
        }
        return parts.isEmpty ? "Activity" : parts.joined(separator: " · ")
    }

    var mergedToolSummary: String? {
        let summaries = entries.compactMap { entry -> String? in
            guard case .tool(let tool) = entry else { return nil }
            return toolSummary(for: tool.call)
        }
        guard !summaries.isEmpty else { return nil }
        var unique: [String] = []
        for s in summaries where !unique.contains(s) {
            unique.append(s)
        }
        return truncateToolSummary(unique.joined(separator: " · "), maxLength: 140)
    }

    /// A collapsed activity row should still tell the reader why it exists.
    /// Tool input is the most actionable preview; when a provider only emits
    /// reasoning, show its first line instead of leaving a blank rail.
    var preview: String? {
        if let summary = mergedToolSummary { return summary }
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
        if toolStatuses.contains(where: { $0 == "error" || $0 == "failed" }) { return .failed }
        if toolStatuses.contains("interrupted") { return .interrupted }
        if toolStatuses.contains("running") { return .running }
        return .completed
    }
}

enum AgentActivityStatus {
    case running
    case completed
    case failed
    case interrupted
}

enum AgentActivityEntry {
    case reasoning(WarrenRemoteAgentEvent)
    case tool(AgentToolBlock)

    var sequence: UInt64 {
        switch self {
        case .reasoning(let event): return event.sequence
        case .tool(let tool): return tool.call.sequence
        }
    }

    var turn: UInt64? {
        switch self {
        case .reasoning(let event): return event.turn
        case .tool(let tool): return tool.call.turn
        }
    }
}

struct AgentToolBlock {
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

func agentDisplayBlocks(from events: [WarrenRemoteAgentEvent]) -> [AgentDisplayBlock] {
    var result: [AgentDisplayBlock] = []
    var activityEntries: [AgentActivityEntry] = []

    enum ToolLocation {
        case inCurrentActivity(index: Int)
        case inResultActivity(blockIndex: Int, entryIndex: Int)
    }
    var toolLocations: [String: ToolLocation] = [:]

    func toolKey(for event: WarrenRemoteAgentEvent) -> String? {
        if let key = event.correlationID, !key.isEmpty { return key }
        if let callID = event.callID, !callID.isEmpty { return callID }
        return event.id.isEmpty ? nil : event.id
    }

    // Structured objects are append-only updates keyed by their provider ID.
    // Keep the latest complete payload in the projection while preserving
    // every ordinary event (including unknown events for sequence order).
    var structuredByID: [String: WarrenRemoteAgentEvent] = [:]
    var renderEvents: [WarrenRemoteAgentEvent] = []
    for event in events where !event.isHiddenFromMobile {
        let type = event.normalizedType.replacingOccurrences(of: "-", with: "_")
        if IOSAgentStructuredEventKind(rawValue: type) != nil {
            let identity = event.id.isEmpty ? "seq-\(event.sequence)" : event.id
            structuredByID["\(type):\(identity)"] = event
        } else {
            renderEvents.append(event)
        }
    }
    renderEvents.append(contentsOf: structuredByID.values)
    renderEvents.sort { $0.sequence < $1.sequence }

    /// Activity is a timeline segment, not a whole user turn. Ending the
    /// segment at every visible conversation event keeps tool/thinking work
    /// between two assistant replies instead of folding the entire turn into
    /// one disclosure row.
    func flushActivity() {
        guard !activityEntries.isEmpty else { return }
        let blockIndex = result.count
        for (entryIndex, entry) in activityEntries.enumerated() {
            if case .tool(let tool) = entry, let key = toolKey(for: tool.call) {
                toolLocations[key] = .inResultActivity(blockIndex: blockIndex, entryIndex: entryIndex)
            }
        }
        result.append(.activity(AgentActivityGroup(entries: activityEntries)))
        activityEntries.removeAll(keepingCapacity: true)
    }

    for event in renderEvents {
        if event.isUserEvent {
            guard event.hasRenderableConversationContent else { continue }
            flushActivity()
            result.append(.event(event))
        } else if event.isToolCallEvent {
            let tool = AgentToolBlock(call: event, outputs: [])
            activityEntries.append(.tool(tool))
            if let key = toolKey(for: event) {
                toolLocations[key] = .inCurrentActivity(index: activityEntries.count - 1)
            }
        } else if event.isToolOutputEvent {
            let key = toolKey(for: event)
            var matched = false
            if let key, let loc = toolLocations[key] {
                switch loc {
                case .inCurrentActivity(let idx):
                    if idx < activityEntries.count, case .tool(var tool) = activityEntries[idx] {
                        tool.outputs.append(event)
                        activityEntries[idx] = .tool(tool)
                        matched = true
                    }
                case .inResultActivity(let blockIdx, let entryIdx):
                    if blockIdx < result.count, case .activity(var group) = result[blockIdx] {
                        if entryIdx < group.entries.count, case .tool(var tool) = group.entries[entryIdx] {
                            tool.outputs.append(event)
                            group.entries[entryIdx] = .tool(tool)
                            result[blockIdx] = .activity(group)
                            matched = true
                        }
                    }
                }
            }
            if !matched {
                flushActivity()
                result.append(.event(event))
            }
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
        } else {
            // Assistant replies, system markers, and other visible events
            // delimit the activity segment so the timeline keeps its source
            // order instead of waiting for the next user message.
            flushActivity()
            result.append(.event(event))
        }
    }
    flushActivity()
    var consolidated: [AgentDisplayBlock] = []
    for block in result {
        if case .activity(let nextGroup) = block,
           let last = consolidated.last,
           case .activity(let prevGroup) = last {
            consolidated[consolidated.count - 1] = .activity(AgentActivityGroup(entries: prevGroup.entries + nextGroup.entries))
        } else {
            consolidated.append(block)
        }
    }
    return consolidated
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
        return type == "compaction"
            || type == "compact"
            || type == "compacted"
            || type == "context_compaction"
            || type == "context_compacted"
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
        // Hidden events are those that don't contribute to conversation or activity state:
        // compaction (UI manages separately), usage/token stats, and system_instructions.
        return type == "compaction"
            || type == "compact"
            || type == "compacted"
            || type == "usage"
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
private func displayBlockView(
    _ block: AgentDisplayBlock,
    canInteract: Bool,
    onInteraction: @escaping (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never>
) -> some View {
    switch block {
    case .event(let event):
        AgentEventBlock(
            event: event,
            canInteract: canInteract,
            onInteraction: onInteraction
        )
    case .activity(let activity):
        AgentActivityGroupBlock(activity: activity)
    }
}

private struct AgentEventBlock: View {
    let event: WarrenRemoteAgentEvent
    let canInteract: Bool
    let onInteraction: (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never>

    init(
        event: WarrenRemoteAgentEvent,
        canInteract: Bool = false,
        onInteraction: @escaping (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never> = { _, _, _ in Task { true } }
    ) {
        self.event = event
        self.canInteract = canInteract
        self.onInteraction = onInteraction
    }

    var body: some View {
        Group {
        if isUser {
            HStack {
                Spacer(minLength: 34)
                AgentMarkdownText(value: event.content ?? "", font: IOSTypography.userMessage)
                    .foregroundStyle(IOSTheme.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(IOSTheme.muted.opacity(0.82), in: UnevenRoundedRectangle(
                        topLeadingRadius: WarrenRadius.sheet,
                        bottomLeadingRadius: WarrenRadius.sheet,
                        bottomTrailingRadius: WarrenRadius.sheet,
                        topTrailingRadius: WarrenRadius.xs
                    ))
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
        } else if ["question", "permission", "plan", "todo", "activity", "plugin", "subagent", "attachment"].contains(normalizedType) {
            AgentStructuredEventBlock(event: event, canInteract: canInteract, onInteraction: onInteraction)
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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

/// A status rail is a reserved visual column at the leading edge of a
/// disclosure row. Keeping it as a separate shape (instead of drawing a
/// full-height rectangle over the content) leaves a predictable gap before
/// the chevron and stays legible when nested rows are expanded.
private struct AgentStatusRail: View {
    let color: Color
    let width: CGFloat
    let opacity: Double
    let leadingInset: CGFloat
    let verticalInset: CGFloat

    init(
        color: Color,
        width: CGFloat = 2,
        opacity: Double = 0.86,
        leadingInset: CGFloat = 2,
        verticalInset: CGFloat = 3
    ) {
        self.color = color
        self.width = width
        self.opacity = opacity
        self.leadingInset = leadingInset
        self.verticalInset = verticalInset
    }

    var body: some View {
        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(color.opacity(opacity))
            .frame(width: width)
            .padding(.leading, leadingInset)
            .padding(.vertical, verticalInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct AgentStructuredEventBlock: View {
    let event: WarrenRemoteAgentEvent
    let canInteract: Bool
    let onInteraction: (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    @State private var selectedOption: String?
    @State private var selectedOptions: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]
    @State private var submitting = false

    private var kind: String {
        event.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private var payload: [String: WarrenRemoteJSONValue] { event.payload ?? [:] }

    private var state: String {
        payload.string("state")?.lowercased() ?? ""
    }

    private var requestID: String? {
        payload.string("requestId")?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(IOSTypography.label)
                        .frame(width: 12)
                    Image(systemName: symbol)
                        .font(IOSTypography.label)
                    Text(title)
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if !isFailure {
                        Text(stateLabel)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(stateColor)
                    }
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(stateLabel)

            if expanded || kind == "question" || kind == "permission" {
                detail
                    .padding(.leading, 12)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, WarrenSpacing.xs)
        .padding(.leading, 8)
        .padding(.trailing, WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            IOSTheme.muted.opacity(kind == "question" || kind == "permission" ? 0.24 : 0.06),
            in: RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
        )
        .overlay(alignment: .leading) {
            if expanded || isFailure {
                AgentStatusRail(color: stateColor, width: 2, opacity: 0.92, verticalInset: WarrenSpacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: state) { _, nextState in
            // A Host event is the source of truth for the final interaction
            // state. Once it leaves pending/submitting, allow a fresh card
            // update to render without retaining a local spinner forever.
            if nextState != "pending" && nextState != "submitting" {
                submitting = false
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch kind {
        case "question":
            if let requestID, !requestID.isEmpty, state == "pending" || state == "submitting" {
                if let description = payload.string("description"), !description.isEmpty {
                    Text(description)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
                ForEach(questionSpecs) { question in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(question.prompt)
                            .font(IOSTypography.label)
                            .foregroundStyle(IOSTheme.text)
                        ForEach(question.options) { option in
                            if canInteract {
                                Button {
                                    toggleQuestionOption(question, optionID: option.id)
                                } label: {
                                    interactionOptionRow(
                                        option,
                                        selected: isQuestionOptionSelected(question.id, optionID: option.id)
                                    )
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(IOSTheme.text)
                                .disabled(submitting || state != "pending")
                            } else {
                                interactionOptionRow(
                                    option,
                                    selected: false
                                )
                                .foregroundStyle(IOSTheme.secondaryText)
                                .accessibilityValue("Read only")
                            }
                        }
                        if question.allowCustom {
                            TextField(
                                "Custom answer",
                                text: Binding(
                                    get: { customAnswers[question.id] ?? "" },
                                    set: { customAnswers[question.id] = $0 }
                                ),
                                axis: .vertical
                            )
                            .textFieldStyle(.roundedBorder)
                            .font(IOSTypography.status)
                            .frame(minHeight: 44)
                            .disabled(!canInteract || submitting || state != "pending")
                            .accessibilityLabel("Custom answer for \(question.prompt)")
                        }
                    }
                    .padding(.vertical, 3)
                }
                if !canInteract {
                    Text("This Host does not support responding here.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.tertiaryText)
                }
                if questionSpecs.isEmpty {
                    Text(kind == "question" ? "Reply in the composer to continue." : "Review this request in Terminal.")
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
                if canInteract {
                    HStack(spacing: 10) {
                        Button("Submit") { submitQuestion(requestID: requestID) }
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(submitting || state != "pending" || !questionsAreValid)
                        Button("Cancel", role: .cancel) { cancelInteraction(requestID: requestID, kind: kind) }
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(submitting || state != "pending")
                    }
                    .font(IOSTypography.label)
                }
            } else if !state.isEmpty, !isFailure {
                Text(stateLabel)
                    .font(IOSTypography.status)
                    .foregroundStyle(stateColor)
            }
        case "permission":
            if let requestID, !requestID.isEmpty, state == "pending" || state == "submitting" {
                if let description = payload.string("description"), !description.isEmpty {
                    Text(description)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
                ForEach(options) { option in
                    if canInteract {
                        Button {
                            guard !submitting, state == "pending" else { return }
                            submitting = true
                            selectedOption = option.id
                            let task = onInteraction(requestID, kind, ["decision": .string(option.id)])
                            Task { @MainActor in
                                if await !task.value { submitting = false }
                            }
                        } label: {
                            interactionOptionRow(option, selected: selectedOption == option.id)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(IOSTheme.text)
                        .disabled(submitting || state != "pending")
                    } else {
                        interactionOptionRow(option, selected: false)
                            .foregroundStyle(IOSTheme.secondaryText)
                            .accessibilityValue("Read only")
                    }
                }
                if !canInteract {
                    Text("This Host does not support responding here.")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.tertiaryText)
                }
                if canInteract {
                    Button("Cancel", role: .cancel) {
                        cancelInteraction(requestID: requestID, kind: kind)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .font(IOSTypography.label)
                    .disabled(submitting || state != "pending")
                }
            } else if !state.isEmpty, !isFailure {
                Text(stateLabel)
                    .font(IOSTypography.status)
                    .foregroundStyle(stateColor)
            }
        case "plan", "todo":
            ForEach(planItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(item.label)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                    Spacer(minLength: 8)
                    if let state = planItemStateLabel(item.state) {
                        Text(state)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(planItemStateColor(item.state))
                            .lineLimit(1)
                    }
                }
                .frame(minHeight: 38, alignment: .leading)
            }
        default:
            if let summary = payload.string("summary") ?? payload.string("detail") ?? event.content,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summary)
                    .font(IOSTypography.status)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .textSelection(.enabled)
            }
            if kind == "attachment", let name = payload.string("name") {
                Text(name)
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.text)
            }
        }
    }

    private func interactionOptionRow(_ option: AgentInteractionOption, selected: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            VStack(alignment: .leading, spacing: 1) {
                Text(option.label)
                    .font(IOSTypography.label)
                if let description = option.description, !description.isEmpty {
                    Text(description)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    private var title: String {
        switch kind {
        case "question": return payload.string("title") ?? "Question"
        case "permission": return payload.string("title") ?? "Permission"
        case "plan": return payload.string("title") ?? "Plan"
        case "todo": return "Todo"
        case "activity": return payload.string("label") ?? "Activity"
        case "plugin": return payload.string("name") ?? "Plugin"
        case "subagent": return payload.string("label") ?? "Subagent"
        case "attachment": return "Attachment"
        default: return event.type.capitalized
        }
    }

    private var symbol: String {
        switch kind {
        case "question": return "questionmark.circle"
        case "permission": return "checkmark.shield"
        case "plan", "todo": return "checklist"
        case "activity": return "bolt"
        case "plugin": return "puzzlepiece.extension"
        case "subagent": return "person.2"
        case "attachment": return "paperclip"
        default: return "info.circle"
        }
    }

    private var stateLabel: String {
        switch state {
        case "pending": return "Pending"
        case "submitting": return "Submitting…"
        case "resolved", "completed": return "Completed"
        case "cancelled", "canceled": return "Cancelled"
        case "failed", "error": return "Failed"
        case "in_progress": return "In progress"
        default: return state.isEmpty ? "Details" : state.capitalized
        }
    }

    private var stateColor: Color {
        switch state {
        case "failed", "error": return IOSTheme.red
        case "pending", "submitting", "in_progress": return IOSTheme.amber
        case "resolved", "completed": return IOSTheme.green
        default: return IOSTheme.secondaryText
        }
    }

    private var isFailure: Bool {
        state == "failed" || state == "error"
    }

    private func planItemStateLabel(_ value: String) -> String? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": return "Pending"
        case "in_progress", "in-progress": return "In progress"
        case "completed", "complete", "done": return "Completed"
        case "cancelled", "canceled": return "Cancelled"
        case "", "failed", "error": return nil
        default: return value.capitalized
        }
    }

    private func planItemStateColor(_ value: String) -> Color {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed", "complete", "done": return IOSTheme.green
        case "in_progress", "in-progress": return IOSTheme.amber
        default: return IOSTheme.tertiaryText
        }
    }

    private var options: [AgentInteractionOption] {
        if kind == "permission" {
            return payload.array("options").compactMap { value in
                guard case .object(let object) = value,
                      let id = object.string("id") ?? object.string("value") else { return nil }
                return AgentInteractionOption(id: id, questionID: "decision", label: object.string("label") ?? id, description: object.string("description"))
            }
        }
        return payload.array("questions").flatMap { value -> [AgentInteractionOption] in
            guard case .object(let question) = value,
                  let questionID = question.string("id") else { return [] }
            return question.array("options").compactMap { option in
                guard case .object(let object) = option,
                      let id = object.string("id") ?? object.string("value") else { return nil }
                return AgentInteractionOption(id: id, questionID: questionID, label: object.string("label") ?? id, description: object.string("description"))
            }
        }
    }

    private var questionSpecs: [AgentQuestionSpec] {
        payload.array("questions").enumerated().compactMap { index, value in
            guard case .object(let question) = value else { return nil }
            let id = question.string("id")?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "question-\(index)"
            guard !id.isEmpty else { return nil }
            let prompt = question.string("prompt") ?? question.string("title") ?? "Question"
            let selection = question.string("selection")?.lowercased() == "multiple" ? "multiple" : "single"
            let required = question.bool("required") ?? true
            let allowCustom = question.bool("allowCustom") ?? false
            let values = question.array("options").enumerated().compactMap { optionIndex, value -> AgentInteractionOption? in
                guard case .object(let object) = value else { return nil }
                let optionID = object.string("id") ?? object.string("value") ?? "option-\(optionIndex)"
                return AgentInteractionOption(
                    id: optionID,
                    questionID: id,
                    label: object.string("label") ?? optionID,
                    description: object.string("description")
                )
            }
            return AgentQuestionSpec(
                id: id,
                prompt: prompt,
                selection: selection,
                required: required,
                allowCustom: allowCustom,
                options: values
            )
        }
    }

    private var questionsAreValid: Bool {
        questionSpecs.allSatisfy { question in
            guard question.required else { return true }
            return !(selectedOptions[question.id] ?? []).isEmpty
                || !(customAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func isQuestionOptionSelected(_ questionID: String, optionID: String) -> Bool {
        selectedOptions[questionID]?.contains(optionID) == true
    }

    private func toggleQuestionOption(_ question: AgentQuestionSpec, optionID: String) {
        guard !submitting, state == "pending" else { return }
        var selected = selectedOptions[question.id] ?? []
        if question.selection == "multiple" {
            if selected.contains(optionID) { selected.remove(optionID) }
            else { selected.insert(optionID) }
        } else {
            selected = [optionID]
        }
        selectedOptions[question.id] = selected
    }

    private func submitQuestion(requestID: String) {
        guard !submitting, state == "pending", questionsAreValid else { return }
        var answers: [String: WarrenRemoteJSONValue] = [:]
        var custom: [String: WarrenRemoteJSONValue] = [:]
        for question in questionSpecs {
            let selected = question.options.compactMap { option -> WarrenRemoteJSONValue? in
                isQuestionOptionSelected(question.id, optionID: option.id) ? .string(option.id) : nil
            }
            answers[question.id] = .array(selected)
            let customValue = customAnswers[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !customValue.isEmpty { custom[question.id] = .string(customValue) }
        }
        var response: [String: WarrenRemoteJSONValue] = ["answers": .object(answers)]
        if !custom.isEmpty { response["customAnswers"] = .object(custom) }
        submitting = true
        let task = onInteraction(requestID, kind, response)
        Task { @MainActor in
            if await !task.value { submitting = false }
        }
    }

    private func cancelInteraction(requestID: String, kind: String) {
        guard !submitting, state == "pending" else { return }
        submitting = true
        let task = onInteraction(requestID, kind, ["cancelled": .boolean(true)])
        Task { @MainActor in
            if await !task.value { submitting = false }
        }
    }

    private var planItems: [AgentPlanItem] {
        payload.array("items").compactMap { value in
            guard case .object(let object) = value else { return nil }
            let label = object.string("label") ?? object.string("title") ?? object.string("prompt")
            guard let label, !label.isEmpty else { return nil }
            return AgentPlanItem(label: label, state: object.string("state")?.lowercased() ?? "pending")
        }
    }
}

private struct AgentInteractionOption: Identifiable {
    let id: String
    let questionID: String
    let label: String
    let description: String?
}

private struct AgentQuestionSpec: Identifiable {
    let id: String
    let prompt: String
    let selection: String
    let required: Bool
    let allowCustom: Bool
    let options: [AgentInteractionOption]
}

private struct AgentPlanItem: Identifiable {
    let id = UUID()
    let label: String
    let state: String
}

private extension Dictionary where Key == String, Value == WarrenRemoteJSONValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func array(_ key: String) -> [WarrenRemoteJSONValue] {
        guard case .array(let value) = self[key] else { return [] }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .boolean(let value) = self[key] else { return nil }
        return value
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(IOSTypography.label)
                        .frame(width: 11)
                    Image(systemName: symbol)
                        .font(IOSTypography.label)
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
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(content)
                    .font(contentFont)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 12)
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 8)
        .padding(.trailing, WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            AgentStatusRail(color: IOSTheme.separator, width: 1, opacity: 0.52, verticalInset: 2)
        }
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
                    .font(IOSTypography.label)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    init(activity: AgentActivityGroup) {
        self.activity = activity
        _expanded = State(initialValue: activity.status == .failed || activity.status == .interrupted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(activity.status == .running ? IOSTheme.secondaryText : IOSTheme.secondaryText.opacity(0.55))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10, alignment: .center)
                    Image(systemName: activity.toolCount > 0 ? "terminal" : "brain")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(activity.status == .running ? IOSTheme.text : IOSTheme.secondaryText.opacity(0.75))
                        .frame(width: 14, height: 14, alignment: .center)
                    Text(activity.title)
                        .font(IOSTypography.status)
                        .foregroundStyle(activity.status == .running ? IOSTheme.text : (activity.status == .failed ? IOSTheme.red : IOSTheme.secondaryText))
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
                        .frame(width: 14, height: 14, alignment: .trailing)
                }
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(activity.title)
            .accessibilityValue("\(expanded ? "Expanded" : "Collapsed") · \(activityStatusLabel)")

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if !activity.reasoningEvents.isEmpty {
                        ForEach(Array(activity.reasoningEvents.enumerated()), id: \.element.idForSwiftUI) { index, event in
                            AgentReasoningEntry(
                                event: event,
                                step: activity.reasoningEvents.count > 1 ? index + 1 : nil
                            )
                        }
                    }
                    if !activity.toolBlocks.isEmpty {
                        ForEach(coalesceToolBlocks(activity.toolBlocks)) { group in
                            if group.tools.count == 1 {
                                AgentToolBlockView(tool: group.tools[0])
                            } else {
                                AgentCoalescedToolBlockView(group: group)
                            }
                        }
                    }
                }
                .padding(.leading, 6)
                .padding(.top, 2)
                .padding(.bottom, 3)
            }
        }
        .padding(.vertical, 1)
        .padding(.leading, 2)
        .padding(.trailing, WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            if activity.status == .failed {
                AgentStatusRail(
                    color: IOSTheme.red,
                    width: 1.5,
                    opacity: 0.86,
                    verticalInset: 2
                )
            }
        }
    }

    @ViewBuilder
    private var activityStatusMark: some View {
        switch activity.status {
        case .running, .completed:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(IOSTheme.red)
                .accessibilityLabel("Activity failed")
        case .interrupted:
            Image(systemName: "pause.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(IOSTheme.yellow)
                .accessibilityLabel("Activity interrupted")
        }
    }

    private var activityStatusLabel: String {
        switch activity.status {
        case .running: return "Running"
        case .failed: return "Failed"
        case .interrupted: return "Interrupted"
        case .completed: return "Completed"
        }
    }
}

/// Reasoning is useful context when debugging a turn, but it is not the
/// conversation itself. Keep it behind a second, quiet disclosure so opening
/// an activity group still exposes the actionable tool calls first.
private struct AgentReasoningEntry: View {
    let event: WarrenRemoteAgentEvent
    let step: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    init(event: WarrenRemoteAgentEvent, step: Int? = nil) {
        self.event = event
        self.step = step
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(IOSTheme.secondaryText.opacity(0.6))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10, alignment: .center)
                    Image(systemName: "brain")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(IOSTheme.secondaryText)
                        .frame(width: 14, height: 14, alignment: .center)
                    Text(step.map { "Step \($0)" } ?? "Thinking")
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                    if !expanded, let summary {
                        Text(summary)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Color.clear
                        .frame(width: 14, height: 14)
                }
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(minHeight: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thinking")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded, let content = event.content, !content.isEmpty {
                AgentMarkdownText(value: content, font: IOSTypography.helper)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .textSelection(.enabled)
                    .padding(.leading, 15)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var isCommand: Bool {
        isCommandTool(call: tool.call)
    }

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 10)
            if isCommand {
                Text("$")
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.tertiaryText)
                if let summary = toolSummary(for: tool.call) {
                    Text(summary)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(tool.status == "running" ? IOSTheme.text : (tool.status == "error" || tool.status == "failed" ? IOSTheme.red : IOSTheme.secondaryText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("exec")
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.secondaryText)
                }
            } else {
                Image(systemName: toolIconName(tool.call.toolName))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 14, height: 14, alignment: .center)
                Text(displayToolName(tool.call.toolName))
                    .font(IOSTypography.status)
                    .foregroundStyle(tool.status == "running" ? IOSTheme.text : (tool.status == "error" || tool.status == "failed" ? IOSTheme.red : IOSTheme.secondaryText))
                    .lineLimit(1)
                if let summary = toolSummary(for: tool.call) {
                    Text(summary)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(IOSTheme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            AgentToolStatusMark(status: tool.status)
                .frame(width: 14, height: 14, alignment: .trailing)
        }
        .foregroundStyle(IOSTheme.secondaryText)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .accessibilityLabel(isCommand ? "Command: \(toolSummary(for: tool.call) ?? "exec")" : displayToolName(tool.call.toolName))
        .accessibilityValue(toolStatusTitle(tool.status))
    }
}

private struct AgentCoalescedToolGroup: Identifiable {
    var id: String { "coalesced-\(toolName)-\(tools.first?.id ?? "")" }
    let toolName: String
    let tools: [AgentToolBlock]

    var status: String {
        let values = tools.map { $0.status }
        if values.contains("error") || values.contains("failed") { return "error" }
        if values.contains("interrupted") { return "interrupted" }
        if values.contains("running") { return "running" }
        return "success"
    }

    var summary: String? {
        let summaries = tools.compactMap { toolSummary(for: $0.call) }
        guard !summaries.isEmpty else { return nil }
        var unique: [String] = []
        for s in summaries where !unique.contains(s) {
            unique.append(s)
        }
        return truncateToolSummary(unique.joined(separator: ", "), maxLength: 140)
    }
}

private func coalesceToolBlocks(_ tools: [AgentToolBlock]) -> [AgentCoalescedToolGroup] {
    var groups: [AgentCoalescedToolGroup] = []
    for tool in tools {
        let name = (tool.call.toolName ?? "").lowercased()
        if let last = groups.last, last.toolName == name {
            var updatedTools = last.tools
            updatedTools.append(tool)
            groups[groups.count - 1] = AgentCoalescedToolGroup(toolName: name, tools: updatedTools)
        } else {
            groups.append(AgentCoalescedToolGroup(toolName: name, tools: [tool]))
        }
    }
    return groups
}

private struct AgentCoalescedToolBlockView: View {
    let group: AgentCoalescedToolGroup

    private var isCommand: Bool {
        isCommandTool(group.toolName)
    }

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 10)
            if isCommand {
                Text("$ × \(group.tools.count)")
                    .font(IOSTypography.status)
                    .foregroundStyle(group.status == "running" ? IOSTheme.text : (group.status == "error" || group.status == "failed" ? IOSTheme.red : IOSTheme.secondaryText))
                    .lineLimit(1)
            } else {
                Image(systemName: toolIconName(group.toolName))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 14, height: 14, alignment: .center)
                Text("\(displayToolName(group.toolName)) × \(group.tools.count)")
                    .font(IOSTypography.status)
                    .foregroundStyle(group.status == "running" ? IOSTheme.text : (group.status == "error" || group.status == "failed" ? IOSTheme.red : IOSTheme.secondaryText))
                    .lineLimit(1)
            }
            if let summary = group.summary {
                Text(summary)
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            AgentToolStatusMark(status: group.status)
                .frame(width: 14, height: 14, alignment: .trailing)
        }
        .foregroundStyle(IOSTheme.secondaryText)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .accessibilityLabel(isCommand ? "$ × \(group.tools.count)" : "\(displayToolName(group.toolName)) × \(group.tools.count)")
        .accessibilityValue(toolStatusTitle(group.status))
    }
}

private struct AgentToolOutputBlock: View {
    let event: WarrenRemoteAgentEvent

    var body: some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: 10)
            Image(systemName: toolIconName(event.toolName))
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(IOSTheme.secondaryText)
                .frame(width: 14, height: 14, alignment: .center)
            Text(displayToolName(event.toolName))
                .font(IOSTypography.status)
                .foregroundStyle(event.toolStatus?.lowercased() == "error" || event.toolStatus?.lowercased() == "failed" ? IOSTheme.red : IOSTheme.secondaryText)
                .lineLimit(1)
            if let output = event.output ?? event.content {
                let firstLine = output.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).first.map(String.init) ?? output
                Text(truncateToolSummary(firstLine, maxLength: 90))
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            AgentToolStatusMark(status: event.toolStatus ?? "success")
                .frame(width: 14, height: 14, alignment: .trailing)
        }
        .foregroundStyle(IOSTheme.secondaryText)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .padding(.vertical, 1)
        .padding(.leading, 2)
        .padding(.trailing, WarrenSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(displayToolName(event.toolName))
        .accessibilityValue(toolStatusTitle(event.toolStatus ?? "success"))
    }
}

/// Tool rows are deliberately denser than conversation rows. The status is
/// still announced to VoiceOver, while a symbol leaves the summary column
/// enough room for the command or file path on a narrow phone.
private struct AgentToolStatusMark: View {
    let status: String

    var body: some View {
        switch status.lowercased() {
        case "error", "failed", "failure":
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(IOSTheme.red)
                .frame(width: 14, height: 14, alignment: .center)
                .accessibilityLabel("Tool failed")
        case "interrupted":
            Image(systemName: "pause.circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(IOSTheme.yellow)
                .frame(width: 14, height: 14, alignment: .center)
                .accessibilityLabel("Tool interrupted")
        case "running", "working", "pending":
            IOSStatusDot(color: IOSTheme.yellow, size: 6)
                .frame(width: 14, height: 14, alignment: .center)
                .accessibilityLabel("Tool running")
        case "success", "completed", "done":
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(IOSTheme.secondaryText.opacity(0.65))
                .frame(width: 14, height: 14, alignment: .center)
                .accessibilityLabel("Tool completed")
        default:
            EmptyView()
        }
    }
}

private extension WarrenRemoteAgentEvent {
    var isAssistantEvent: Bool {
        normalizedType == "assistant" || role?.lowercased() == "assistant"
    }
}

func displayToolName(_ name: String?) -> String {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        return "Tool"
    }
    switch name.lowercased() {
    case "shell", "exec", "execute", "run_command": return "Shell"
    case "edit", "replace_file_content": return "Edit file"
    case "read", "view_file", "viewfile": return "Read file"
    case "grep", "grep_search": return "Search files"
    case "glob", "find_by_name", "list_dir": return "Find files"
    case "web_search", "search_web": return "Web search"
    case "fetch", "read_url_content": return "Web fetch"
    case "subagent", "invoke_subagent": return "Subagent"
    case "apply_patch": return "Apply patch"
    case "write", "write_to_file": return "Write file"
    case "question", "ask_user_question", "ask_question": return "Ask user"
    case "permission", "permission_request": return "Permission"
    case "reasoning": return "Thinking"
    default: return name
    }
}

func isCommandTool(_ name: String?) -> Bool {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else {
        return false
    }
    switch name {
    case "shell", "exec", "execute", "run_command", "bash", "local_shell_call":
        return true
    default:
        return false
    }
}

func isCommandTool(call: WarrenRemoteAgentEvent) -> Bool {
    if isCommandTool(call.toolName) { return true }
    if let input = call.toolInput, case .object(let obj) = input {
        return obj["command"] != nil || obj["cmd"] != nil || obj["CommandLine"] != nil || obj["args"] != nil || obj["argv"] != nil
    }
    return false
}

func toolIconName(_ name: String?) -> String {
    switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "shell", "exec", "execute", "run_command": return "terminal"
    case "edit", "replace_file_content", "write", "write_to_file", "apply_patch": return "pencil"
    case "read", "view_file", "viewfile": return "doc.text"
    case "grep", "grep_search", "glob", "find_by_name", "list_dir", "web_search", "search_web": return "magnifyingglass"
    case "fetch", "read_url_content": return "arrow.down.circle"
    case "subagent", "invoke_subagent": return "person.2"
    case "question", "ask_user_question", "ask_question": return "questionmark.bubble"
    case "permission", "permission_request": return "shield"
    case "reasoning": return "brain"
    default: return "hammer"
    }
}

func basename(_ path: String) -> String {
    let clean = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    if let lastSlash = clean.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
        let afterSlash = clean.index(after: lastSlash)
        return String(clean[afterSlash...])
    }
    return clean
}

func cleanDisplayPath(_ path: String) -> String {
    let clean = path.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    if clean.hasPrefix("/") && (clean.count > 30 || clean.hasPrefix("/Users/") || clean.hasPrefix("/home/")) {
        return basename(clean)
    }
    return clean
}

func extractPatchFiles(_ patch: String) -> [String] {
    var files: [String] = []
    let lines = patch.components(separatedBy: "\n")
    let markers = ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "+++ b/", "--- a/"]
    for line in lines {
        for marker in markers {
            if line.hasPrefix(marker) {
                let name = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && name != "/dev/null" && name != "dev/null" && !files.contains(name) {
                    files.append(name)
                }
                break
            }
        }
    }
    return files
}

func extractExecCommands(_ raw: String) -> [String] {
    var commands: [String] = []
    let callPattern = #"(?:exec_command|exec|execute)\s*\(\s*\{[^\n}]*["']?(?:cmd|command)["']?\s*:\s*"((?:[^"\\]|\\.)*)""#
    if let regex = try? NSRegularExpression(pattern: callPattern, options: []) {
        let nsString = raw as NSString
        let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            if match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    let val = nsString.substring(with: range)
                    let unescaped = val.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                    commands.append(unescaped)
                }
            }
        }
    }
    if commands.isEmpty {
        let jsonPattern = #"["'](?:cmd|command|CommandLine|code|script)["']\s*:\s*"((?:[^"\\]|\\.)*)""#
        if let regex = try? NSRegularExpression(pattern: jsonPattern, options: []) {
            let nsString = raw as NSString
            let matches = regex.matches(in: raw, options: [], range: NSRange(location: 0, length: nsString.length))
            for match in matches {
                if match.numberOfRanges > 1 {
                    let range = match.range(at: 1)
                    if range.location != NSNotFound {
                        let val = nsString.substring(with: range)
                        let unescaped = val.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                        commands.append(unescaped)
                    }
                }
            }
        }
    }
    return commands
}

func formatFileList(_ list: [String]) -> String {
    let valid = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    if valid.isEmpty { return "" }
    if valid.count == 1 { return truncateToolSummary(cleanDisplayPath(valid[0])) }
    if valid.count <= 3 {
        return valid.map { truncateToolSummary(basename($0)) }.joined(separator: ", ")
    }
    let firstTwo = valid.prefix(2).map { truncateToolSummary(basename($0)) }.joined(separator: ", ")
    return "\(firstTwo) (+\(valid.count - 2) more)"
}

func toolSummary(for event: WarrenRemoteAgentEvent) -> String? {
    let files = (event.files ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

    if let input = event.toolInput {
        if case .string(let raw) = input, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let commands = extractExecCommands(trimmed)
            if !commands.isEmpty {
                let first = truncateToolSummary(commands[0])
                let summary = commands.count > 1 ? "\(first)  (+\(commands.count - 1) more)" : first
                return !files.isEmpty ? "\(summary) · \(formatFileList(files))" : summary
            }
            return truncateToolSummary(trimmed)
        }

        if case .object(let object) = input {
            func getString(_ keys: [String]) -> String? {
                for key in keys {
                    if case .string(let val) = object[key], !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return val.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                return nil
            }

            let cleanAction: String = {
                if let action = getString(["toolAction", "toolSummary", "action"]) {
                    return action.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return ""
            }()

            if let cmd = getString(["command", "cmd", "CommandLine", "code", "script", "input"]) {
                let commandStr = truncateToolSummary(cmd)
                if !files.isEmpty {
                    return "\(commandStr) · \(formatFileList(files))"
                }
                return commandStr
            }
            for key in ["command", "cmd", "CommandLine", "args", "argv", "arguments"] {
                if case .array(let arr) = object[key] {
                    let strings = arr.compactMap { val -> String? in
                        if case .string(let s) = val, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            return s.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        return nil
                    }
                    if !strings.isEmpty {
                        let joined = strings.joined(separator: " ")
                        if !files.isEmpty {
                            return "\(truncateToolSummary(joined)) · \(formatFileList(files))"
                        }
                        return truncateToolSummary(joined)
                    }
                }
            }

            if let rawArgs = getString(["arguments"]) {
                if rawArgs.hasPrefix("{"),
                   let data = rawArgs.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let cmd = json["command"] as? String ?? json["cmd"] as? String ?? json["CommandLine"] as? String {
                        let commandStr = truncateToolSummary(cmd)
                        if !files.isEmpty {
                            return "\(commandStr) · \(formatFileList(files))"
                        }
                        return commandStr
                    }
                    if let arr = json["args"] as? [String] ?? json["argv"] as? [String] ?? json["command"] as? [String] {
                        let joined = arr.joined(separator: " ")
                        if !joined.isEmpty {
                            if !files.isEmpty {
                                return "\(truncateToolSummary(joined)) · \(formatFileList(files))"
                            }
                            return truncateToolSummary(joined)
                        }
                    }
                }
            }

            if case .string(let raw) = object["raw"], !raw.isEmpty {
                let commands = extractExecCommands(raw)
                if !commands.isEmpty {
                    let first = truncateToolSummary(commands[0])
                    let summary = commands.count > 1 ? "\(first)  (+\(commands.count - 1) more)" : first
                    if !files.isEmpty {
                        return "\(summary) · \(formatFileList(files))"
                    }
                    return summary
                }
                return raw.count > 200 ? String(raw.prefix(200)) + "…" : raw
            }

            if let filePath = getString(["file_path", "path", "TargetFile", "AbsolutePath", "file", "filename", "target"]) {
                let cleanP = cleanDisplayPath(filePath)
                if !cleanAction.isEmpty {
                    return "\(cleanAction): \(cleanP)"
                }
                return truncateToolSummary(cleanP)
            }

            if !files.isEmpty {
                let fileSummary = formatFileList(files)
                if !cleanAction.isEmpty {
                    return "\(cleanAction): \(fileSummary)"
                }
                return fileSummary
            }

            if case .string(let patch) = object["patch"], !patch.isEmpty {
                let patchFiles = extractPatchFiles(patch)
                if !patchFiles.isEmpty {
                    return formatFileList(patchFiles)
                }
            }

            if let query = getString(["query", "Query", "pattern", "Pattern"]) {
                let cleanQ = query.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines)
                if let scope = getString(["SearchPath", "SearchDirectory", "path"]) {
                    return "\"\(truncateToolSummary(cleanQ, maxLength: 50))\" in \(truncateToolSummary(basename(scope)))"
                }
                return "\"\(truncateToolSummary(cleanQ))\""
            }
            if case .array(let arr) = object["queries"] {
                let strings = arr.compactMap { val -> String? in
                    if case .string(let s) = val { return s }
                    return nil
                }
                if !strings.isEmpty {
                    return strings.joined(separator: ", ")
                }
            }

            if let url = getString(["url", "Url"]) {
                return truncateToolSummary(url.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).trimmingCharacters(in: .whitespacesAndNewlines))
            }

            if let text = getString(["prompt", "instruction", "Instruction", "description", "Description"]) {
                return truncateToolSummary(text)
            }

            if !cleanAction.isEmpty {
                return cleanAction
            }
        }
    }

    if !files.isEmpty {
        return formatFileList(files)
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

func latestAgentAction(from events: [WarrenRemoteAgentEvent]) -> String? {
    for (index, event) in events.enumerated().reversed() {
        let type = event.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if type == "tool_call" || type == "toolcall" {
            let isCmd = isCommandTool(call: event)
            if let summary = toolSummary(for: event), !summary.isEmpty {
                return isCmd ? summary : "\(displayToolName(event.toolName)) \(summary)"
            }
            return displayToolName(event.toolName)
        }
        if type == "tool_output" || type == "tooloutput" {
            let matchingCall: WarrenRemoteAgentEvent? = {
                if let callID = event.callID, !callID.isEmpty {
                    return events.first(where: {
                        let ct = $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return (ct == "tool_call" || ct == "toolcall") && ($0.callID == callID || $0.id == callID)
                    })
                }
                return events[0..<index].reversed().first(where: {
                    let ct = $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return (ct == "tool_call" || ct == "toolcall")
                })
            }()
            if let callEvent = matchingCall {
                let isCmd = isCommandTool(call: callEvent)
                if let summary = toolSummary(for: callEvent), !summary.isEmpty {
                    return isCmd ? summary : "\(displayToolName(callEvent.toolName)) \(summary)"
                }
                return displayToolName(callEvent.toolName)
            }
            if let toolName = event.toolName, !toolName.isEmpty {
                return displayToolName(toolName)
            }
        }
    }
    return nil
}
