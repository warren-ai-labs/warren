import SwiftUI
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
        }
        view.invalidateIntrinsicContentSize()
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
    @State private var draft = ""
    @State private var renderedBlocks: [AgentDisplayBlock] = []
    @State private var didEstablishInitialScroll = false
    @State private var didTriggerHistoryPull = false
    @State private var historyScrollAnchorID: String?
    @State private var isNearLatest = true
    @State private var showReturnToLatest = false
    @State private var workingPhrase = AgentWorkingPhrases.defaultPhrase
    @State private var localAttachments: [IOSAgentLocalAttachment] = []
    @State private var isUploadingAttachments = false
    @State private var isFileImporterPresented = false
    @State private var isQueueSheetPresented = false
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
                                        canInteract: model.supportsAgentCapability(WarrenRemoteAgentCapability.interactions),
                                        isLastUser: userEventKey(for: block) == latestUserEventKey,
                                        onEditResend: { value in
                                            draft = value
                                            composerFocused = true
                                        }
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
        // The system owns keyboard-inset animation. Keeping focus out of the
        // view-level animation transaction prevents a responder hand-off
        // while the composer is being laid out.
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
                .animation(.easeInOut(duration: 0.22), value: shouldShowWorking)
                .animation(.easeInOut(duration: 0.22), value: model.agentAttention(for: sessionID))
            }
        }
        .onAppear {
            draft = model.agentDraft(for: sessionID)
            refreshRenderedBlocks()
            if !model.agentHistoryLoaded(for: sessionID) {
                model.loadOlderAgentHistory()
            }
        }
        .onChange(of: draft) { _, value in
            model.updateAgentDraft(value, for: sessionID)
        }
        .onDisappear {
            model.flushAgentDraft(draft, for: sessionID)
        }
        .onChange(of: model.currentSessionID) { _, selectedSessionID in
            guard selectedSessionID == sessionID else { return }
            didTriggerHistoryPull = false
            historyScrollAnchorID = nil
            showReturnToLatest = false
            isNearLatest = true
            workingPhrase = AgentWorkingPhrases.defaultPhrase
            guard !model.agentHistoryLoaded(for: sessionID) else { return }
            model.loadOlderAgentHistory()
        }
        .sheet(isPresented: $isQueueSheetPresented) {
            IOSAgentQueueSheet(model: model, sessionID: sessionID)
        }
        .onChange(of: workingTurnKey) { _, _ in
            workingPhrase = AgentWorkingPhrases.next(after: workingPhrase)
        }
    }

    private func refreshRenderedBlocks() {
        renderedBlocks = agentDisplayBlocks(from: agentState.agentEventsBySessionID[sessionID] ?? [])
    }

    private func userEventKey(for block: AgentDisplayBlock) -> String? {
        guard case .event(let event) = block, event.isUserEvent else { return nil }
        return "\(event.sequence):\(event.id)"
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

            VStack(alignment: .leading, spacing: 0) {
                if !localAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(localAttachments) { attachment in
                                attachmentChip(attachment)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 30)
                    .padding(.top, 6)
                }

                HStack(alignment: .bottom, spacing: 5) {
                    attachmentControls
                    ZStack(alignment: .topLeading) {
                        Text("Message…")
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        sendComposerMessage()
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
                .padding(.horizontal, 8)
                .padding(.top, 6)

                HStack(spacing: 8) {
                    if let metadata = agentComposerMetadata {
                        Text(metadata)
                            .font(IOSTypography.metadata)
                            .foregroundStyle(IOSTheme.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Agent type and model: \(metadata)")
                    }
                    if let queued = model.agentQueuedMessageCountBySessionID[sessionID], queued > 0 {
                        Button {
                            isQueueSheetPresented = true
                        } label: {
                            Text("Queued \(queued)")
                                .font(IOSTypography.metadata)
                                .foregroundStyle(IOSTheme.amber)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(queued) queued messages")
                    }
                    if model.canInterruptAgentTurn {
                        Button {
                            model.cancelAgentTurn()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(IOSTheme.red)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel Agent turn")
                        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                sendComposerMessage(sendNow: true)
                            } label: {
                                Text("Send now")
                                    .font(IOSTypography.metadata)
                                    .foregroundStyle(IOSTheme.amber)
                                    .frame(minHeight: 28)
                            }
                            .buttonStyle(.plain)
                            .disabled(isUploadingAttachments)
                            .accessibilityLabel("Send message now and interrupt Agent turn")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 5)
            }
            .padding(.horizontal, 4)
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

    @ViewBuilder
    private var attachmentControls: some View {
        let attachmentsSupported = model.supportsAgentCapability(WarrenRemoteAgentCapability.attachments)
        HStack(spacing: 2) {
#if os(iOS)
            PhotosPicker(selection: $photoItems, maxSelectionCount: 5, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!attachmentsSupported)
            .accessibilityLabel("Choose photos")
#endif
            Button {
                isFileImporterPresented = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(IOSTheme.secondaryText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!attachmentsSupported)
            .accessibilityLabel("Choose a file")
        }
        .opacity(attachmentsSupported ? 1 : 0.42)
        .accessibilityValue(attachmentsSupported ? "Available" : "Unavailable on this Host")
#if os(iOS)
        .onChange(of: photoItems) { _, items in
            loadPhotos(items)
        }
#endif
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImporter
        )
    }

    private func attachmentChip(_ attachment: IOSAgentLocalAttachment) -> some View {
        HStack(spacing: 4) {
            Text(attachment.name)
                .font(IOSTypography.metadata)
                .lineLimit(1)
            switch attachment.state {
            case .selected:
                EmptyView()
            case .uploading:
                Text("\(Int(attachment.progress * 100))%")
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.amber)
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(IOSTheme.green)
            case .failed:
                Button("Retry") { retryAttachment(attachment.id) }
                    .font(IOSTypography.metadata)
                    .foregroundStyle(IOSTheme.red)
            case .aborted:
                Text("Aborted")
                    .foregroundStyle(IOSTheme.secondaryText)
            }
            Button {
                localAttachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(IOSTheme.tertiaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(IOSTheme.muted.opacity(0.6), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityValue(attachment.state.rawValue)
    }

    private func sendComposerMessage(sendNow: Bool = false) {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isUploadingAttachments else { return }
        let selected = localAttachments
        guard selected.allSatisfy({ $0.state == .selected || $0.state == .ready }) else { return }
        guard !selected.isEmpty else {
            let accepted = sendNow
                ? model.sendAgentMessageNow(value)
                : model.sendAgentMessage(value)
            guard accepted else { return }
            draft = ""
            model.clearAgentDraft(for: sessionID)
            return
        }
        isUploadingAttachments = true
        Task { @MainActor in
            var references: [WarrenRemoteAgentAttachmentRef] = []
            for attachment in selected {
                guard let index = localAttachments.firstIndex(where: { $0.id == attachment.id }) else { continue }
                localAttachments[index].state = .uploading
                localAttachments[index].failureReason = nil
                do {
                    let reference = try await model.uploadAgentAttachment(
                        data: attachment.data,
                        name: attachment.name,
                        mime: attachment.mime,
                        sessionID: sessionID
                    ) { progress in
                        guard let progressIndex = localAttachments.firstIndex(where: { $0.id == attachment.id }) else { return }
                        localAttachments[progressIndex].progress = progress
                    }
                    references.append(reference)
                    if let readyIndex = localAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        localAttachments[readyIndex].state = .ready
                        localAttachments[readyIndex].reference = reference
                    }
                } catch {
                    if let failedIndex = localAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        localAttachments[failedIndex].state = .failed
                        localAttachments[failedIndex].failureReason = error.localizedDescription
                    }
                    isUploadingAttachments = false
                    return
                }
            }
            isUploadingAttachments = false
            let accepted = sendNow
                ? model.sendAgentMessageNow(value, attachments: references)
                : model.sendAgentMessage(value, attachments: references)
            guard accepted else { return }
            draft = ""
            model.clearAgentDraft(for: sessionID)
            localAttachments.removeAll()
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
        guard !items.isEmpty else { return }
        photoItems = []
        Task { @MainActor in
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { continue }
                let type = item.supportedContentTypes.first?.preferredMIMEType ?? "image/*"
                localAttachments.append(IOSAgentLocalAttachment(name: "Photo", mime: type, data: data))
            }
        }
    }
#endif

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = (UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
                ?? "application/octet-stream"
            localAttachments.append(IOSAgentLocalAttachment(name: url.lastPathComponent, mime: mime, data: data))
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
        let type = agentTypeLabel
        let modelName = model.agentModel(for: sessionID)
        let values = [type, modelName].compactMap { value -> String? in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var agentTypeLabel: String? {
        guard let session = model.roster?.sessions.first(where: { $0.id == sessionID }) else { return nil }
        let raw = session.kind.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.lowercased() != "shell" else { return nil }
        switch raw.lowercased() {
        case "codex": return "Codex"
        case "claude", "claude-code": return "Claude"
        case "opencode", "open-code": return "OpenCode"
        default: return raw.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }

    private var latestUserEventKey: String? {
        agentState.agentEventsBySessionID[sessionID]?
            .last(where: \.isUserEvent)
            .map { "\($0.sequence):\($0.id)" }
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
        model.canSendAgent && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                                HStack {
                                    Button("Save") {
                                        guard !editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                        _ = model.editQueuedAgentMessage(sessionID: sessionID, itemID: item.id, text: editingText, attachments: item.attachments)
                                        editingID = nil
                                    }
                                    Button("Cancel") { editingID = nil }
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
                                }
                                if item.status != .sending && editingID != item.id {
                                    Button {
                                        editingID = item.id
                                        editingText = item.text
                                    } label: {
                                        Image(systemName: "pencil")
                                    }
                                    .accessibilityLabel("Edit queued message")
                                    Button("Move to front") { _ = model.moveQueuedAgentMessageToFront(sessionID: sessionID, itemID: item.id) }
                                    Button("Delete", role: .destructive) { deleteID = item.id }
                                } else if item.status == .sending {
                                    Text("Sending…")
                                        .foregroundStyle(IOSTheme.secondaryText)
                                }
                            }
                            .font(IOSTypography.metadata)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent working: \(phrase)")
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
        result.append(.activity(AgentActivityGroup(entries: activityEntries)))
        activityEntries.removeAll(keepingCapacity: true)
        pendingTools.removeAll(keepingCapacity: true)
    }

    for event in renderEvents {
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
private func displayBlockView(
    _ block: AgentDisplayBlock,
    canInteract: Bool,
    isLastUser: Bool = false,
    onEditResend: @escaping (String) -> Void = { _ in },
    onInteraction: @escaping (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never>
) -> some View {
    switch block {
    case .event(let event):
        AgentEventBlock(
            event: event,
            canInteract: canInteract,
            isLastUser: isLastUser,
            onEditResend: onEditResend,
            onInteraction: onInteraction
        )
    case .activity(let activity):
        AgentActivityGroupBlock(activity: activity)
    }
}

private struct AgentEventBlock: View {
    let event: WarrenRemoteAgentEvent
    let canInteract: Bool
    let isLastUser: Bool
    let onEditResend: (String) -> Void
    let onInteraction: (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never>

    init(
        event: WarrenRemoteAgentEvent,
        canInteract: Bool = false,
        isLastUser: Bool = false,
        onEditResend: @escaping (String) -> Void = { _ in },
        onInteraction: @escaping (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never> = { _, _, _ in Task { true } }
    ) {
        self.event = event
        self.canInteract = canInteract
        self.isLastUser = isLastUser
        self.onEditResend = onEditResend
        self.onInteraction = onInteraction
    }

    var body: some View {
        Group {
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
                    AgentMessageActions(
                        event: event,
                        isLastUser: isLastUser,
                        alignment: .trailing,
                        onEditResend: onEditResend
                    )
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
            VStack(alignment: .leading, spacing: 3) {
                eventBody
                if event.isAssistantEvent {
                    AgentMessageActions(
                        event: event,
                        alignment: .leading,
                        onEditResend: onEditResend
                    )
                }
            }
            .padding(.vertical, 7)
        }
        }
#if canImport(UIKit)
        .contextMenu {
            if let text = IOSAgentMessageActions.copyableText(for: event) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy message")
            }
        }
#endif
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

private struct AgentMessageActions: View {
    let event: WarrenRemoteAgentEvent
    var isLastUser = false
    let alignment: Alignment
    let onEditResend: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
#if canImport(UIKit)
            if let text = IOSAgentMessageActions.copyableText(for: event) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy message")
                .frame(width: 28, height: 28)
            }
#endif
            if isLastUser,
               let text = IOSAgentMessageActions.copyableText(for: event) {
                Button {
                    onEditResend(text)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit and resend message")
                .frame(width: 28, height: 28)
            }
        }
        .foregroundStyle(IOSTheme.tertiaryText)
        .frame(maxWidth: .infinity, alignment: alignment)
        .accessibilityElement(children: .contain)
    }
}

private struct AgentStructuredEventBlock: View {
    let event: WarrenRemoteAgentEvent
    let canInteract: Bool
    let onInteraction: (String, String, [String: WarrenRemoteJSONValue]) -> Task<Bool, Never>
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
                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                    Text(title)
                        .font(IOSTypography.label)
                        .foregroundStyle(IOSTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(stateLabel)
                        .font(IOSTypography.metadata)
                        .foregroundStyle(stateColor)
                }
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(stateLabel)

            if expanded || kind == "question" || kind == "permission" {
                detail
                    .padding(.leading, 20)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 7)
        .background(IOSTheme.muted.opacity(kind == "question" || kind == "permission" ? 0.34 : 0.16), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                            .disabled(submitting || state != "pending" || !questionsAreValid)
                        Button("Cancel", role: .cancel) { cancelInteraction(requestID: requestID, kind: kind) }
                            .disabled(submitting || state != "pending")
                    }
                    .font(IOSTypography.label)
                }
            } else if !state.isEmpty {
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
                    .font(IOSTypography.label)
                    .disabled(submitting || state != "pending")
                }
            } else if !state.isEmpty {
                Text(stateLabel)
                    .font(IOSTypography.status)
                    .foregroundStyle(stateColor)
            }
        case "plan", "todo":
            ForEach(planItems) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: item.state == "completed" ? "checkmark.circle.fill" : item.state == "in_progress" ? "circle.lefthalf.filled" : "circle")
                        .foregroundStyle(item.state == "completed" ? IOSTheme.green : IOSTheme.secondaryText)
                    Text(item.label)
                        .font(IOSTypography.status)
                        .foregroundStyle(IOSTheme.secondaryText)
                    Spacer(minLength: 0)
                }
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
        case "failed": return "Failed"
        case "in_progress": return "In progress"
        default: return state.isEmpty ? "Details" : state.capitalized
        }
    }

    private var stateColor: Color {
        switch state {
        case "failed": return IOSTheme.red
        case "pending", "submitting", "in_progress": return IOSTheme.amber
        case "resolved", "completed": return IOSTheme.green
        default: return IOSTheme.secondaryText
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
            // Keep the activity rail non-verbal while a pulse makes a running
            // group discoverable without adding another status label.
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
