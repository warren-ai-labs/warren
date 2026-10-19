import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain
import WarrenObservation

/// A decision a Session is waiting on, as the client holds it without loading
/// that Session's Conversation: the headline, what it is about, and the
/// options the provider sent, in the order the Conversation's dock shows them.
public struct WarrenDesktopPendingDecision: Hashable, Sendable {
    public struct Option: Hashable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let isReject: Bool

        public init(id: String, label: String, isReject: Bool = false) {
            self.id = id
            self.label = label
            self.isReject = isReject
        }
    }

    /// The Host's interaction id, which the Agent's attention names too.
    public let id: String
    /// "Claude wants to run a command".
    public let ask: String
    /// The command or file the request is about; empty when there is none.
    public let detail: String
    public let options: [Option]

    public init(id: String, ask: String, detail: String, options: [Option]) {
        self.id = id
        self.ask = ask
        self.detail = detail
        self.options = options
    }
}

/// The decisions the current Host's Sessions are waiting on, and the one way
/// to answer them: the same Host request the Conversation's dock sends.
public struct WarrenDesktopPendingDecisions {
    public var decisions: [TerminalSessionID: WarrenDesktopPendingDecision]
    public var resolve: @MainActor (TerminalSessionID, _ decisionID: String, _ optionID: String) async throws -> Void

    public init(
        decisions: [TerminalSessionID: WarrenDesktopPendingDecision] = [:],
        resolve: @escaping @MainActor (TerminalSessionID, _ decisionID: String, _ optionID: String) async throws -> Void = { _, _, _ in
            throw URLError(.unsupportedURL)
        }
    ) {
        self.decisions = decisions
        self.resolve = resolve
    }
}

/// One row of the approval tray.
struct WarrenDesktopApprovalTrayEntry: Identifiable, Equatable {
    let id: TerminalSessionID
    let kind: TerminalSessionKind
    let title: String
    /// "project · branch".
    let location: String
    let mark: WarrenActivityMark
    /// What the Agent is asking, as one line.
    let ask: String
    /// The command or file the decision is about, when the decision is known.
    let detail: String?
    /// The decision itself, when this client holds it; nil leaves the row
    /// with Open only.
    let decision: WarrenDesktopPendingDecision?
}

/// The "N waiting" tray: every other Session on this Host an Agent has stopped
/// for, answerable without leaving the Session on screen.
enum WarrenDesktopApprovalTray {
    static let width: CGFloat = 440
    /// Faces the pill stacks; the count carries the rest.
    static let maxFaces = 3
    static let faceSize: CGFloat = 14

    /// The tray's rows, strongest request first and otherwise in the
    /// projection's order.
    ///
    /// Who is waiting comes from `WarrenDesktopSidebarAttention.waiting`, the
    /// same population and the same mark the sidebar dot reads, so the pill
    /// and the dot cannot disagree about whether anyone needs a person.
    static func entries(
        sessions: [WarrenDesktopSession],
        selectedTabID: String?,
        decisions: [TerminalSessionID: WarrenDesktopPendingDecision],
        title: (WarrenDesktopSession) -> String,
        location: (WarrenDesktopSession) -> String
    ) -> [WarrenDesktopApprovalTrayEntry] {
        entries(
            waiting: WarrenDesktopSidebarAttention.waiting(sessions, selectedTabID: selectedTabID),
            decisions: decisions,
            title: title,
            location: location
        )
    }

    /// The rows for an already chosen population of waiting Sessions. The
    /// system alerts use it with every waiting Session, the current Tab's
    /// included, because a person away from the window is not looking at it.
    static func entries(
        waiting: [WarrenDesktopSession],
        decisions: [TerminalSessionID: WarrenDesktopPendingDecision],
        title: (WarrenDesktopSession) -> String,
        location: (WarrenDesktopSession) -> String
    ) -> [WarrenDesktopApprovalTrayEntry] {
        var rows: [(order: Int, entry: WarrenDesktopApprovalTrayEntry)] = []
        for (order, session) in waiting.enumerated() {
            guard let mark = session.activityMark else { continue }
            let decision = answerableDecision(decisions[session.id], for: session)
            let detail = decision.map(\.detail).flatMap { $0.isEmpty ? nil : $0 }
            rows.append((order, WarrenDesktopApprovalTrayEntry(
                id: session.id,
                kind: session.presentedKind,
                title: title(session),
                location: location(session),
                mark: mark,
                ask: decision?.ask ?? askLine(for: session, mark: mark),
                detail: detail,
                decision: decision
            )))
        }
        return rows
            .sorted { left, right in
                left.entry.mark == right.entry.mark
                    ? left.order < right.order
                    : left.entry.mark > right.entry.mark
            }
            .map(\.entry)
    }

    /// The decision only when it is the request the Agent is stopped on and
    /// it has options to press. When the attention names another request the
    /// client's fold is behind, and answering it would answer the wrong thing.
    static func answerableDecision(
        _ decision: WarrenDesktopPendingDecision?,
        for session: WarrenDesktopSession
    ) -> WarrenDesktopPendingDecision? {
        guard let decision, !decision.options.isEmpty else { return nil }
        if let requestID = session.agentStatus?.attention?.requestID,
           !requestID.isEmpty,
           requestID != decision.id {
            return nil
        }
        return decision
    }

    /// The Host's own reason when it sent one, else the mark's status word —
    /// the same sentence the sidebar row's tooltip uses.
    static func askLine(for session: WarrenDesktopSession, mark: WarrenActivityMark) -> String {
        let reason = session.agentStatus?.attention?.reason
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reason.isEmpty ? mark.statusWord : reason
    }

    static func accessibilityLabel(count: Int) -> String {
        count == 1 ? "1 Session is waiting on you" : "\(count) Sessions are waiting on you"
    }
}

/// The tray's rows as the window currently resolves them.
///
/// The menu layer renders a panel from a view captured when it opened, so the
/// panel reads its rows from here to stay current while it is open: an answer
/// arriving from another client removes its row in place.
@MainActor
final class WarrenDesktopApprovalTrayStore: ObservableObject {
    @Published private(set) var entries: [WarrenDesktopApprovalTrayEntry] = []

    func update(_ entries: [WarrenDesktopApprovalTrayEntry]) {
        guard self.entries != entries else { return }
        self.entries = entries
    }
}

/// The top bar's "N waiting" pill. It draws nothing while nobody is waiting.
struct WarrenDesktopApprovalTrayPill: View {
    @ObservedObject var store: WarrenDesktopApprovalTrayStore
    let onOpen: (TerminalSessionID) -> Void
    let onResolve: @MainActor (TerminalSessionID, String, String) async throws -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.warrenMenuCenter) private var menuCenter: WarrenDesktopMenuCenter?
    @State private var isPresented = false

    var body: some View {
        if !store.entries.isEmpty {
            pill
        }
    }

    private var pill: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let entries = store.entries
        let count = entries.count
        let label = WarrenDesktopApprovalTray.accessibilityLabel(count: count)
        let hue = (entries.map(\.mark).max() ?? .approvalNeeded).color(tokens)
        return WarrenDesktopChromeCapsule {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    faces(entries, tokens: tokens)
                    HStack(spacing: 3) {
                        Text("\(count)")
                            .monospacedDigit()
                            .warrenNumericTransition(value: count)
                        Text("waiting")
                    }
                    .font(WarrenTypography.chromeLabel)
                    // The attention hue, from the same mark table as the
                    // sidebar dot, so the pill reads as the same request.
                    Circle()
                        .fill(hue)
                        .frame(width: 6, height: 6)
                }
                .padding(.leading, 7)
                .padding(.trailing, 10)
                .frame(height: WarrenLayoutMetrics.tabPillHeight)
                .contentShape(.rect)
            }
            .buttonStyle(WarrenChromeButtonStyle())
            .background(
                isPresented ? tokens.selectedTabPillFill : .clear,
                in: RoundedRectangle(cornerRadius: WarrenLayoutMetrics.tabPillRadius, style: .continuous)
            )
            .foregroundStyle(tokens.foreground)
            .warrenTooltip("Sessions waiting on you")
            .accessibilityLabel(label)
            .accessibilityHint("Show the Sessions waiting on you")
            .warrenSemanticElement(
                id: "approval-tray.pill",
                role: .button,
                label: label,
                value: "\(count)",
                isSelected: isPresented,
                action: toggle
            )
        }
        .fixedSize(horizontal: true, vertical: false)
        .warrenMenuPanel(
            isPresented: $isPresented,
            width: WarrenDesktopApprovalTray.width,
            edge: .below
        ) {
            WarrenDesktopApprovalTrayPanel(
                store: store,
                onOpen: onOpen,
                onResolve: onResolve,
                onDismiss: dismiss
            )
        }
    }

    private func faces(_ entries: [WarrenDesktopApprovalTrayEntry], tokens: WarrenColorTokens) -> some View {
        HStack(spacing: -5) {
            ForEach(Array(entries.prefix(WarrenDesktopApprovalTray.maxFaces))) { entry in
                WarrenDesktopSessionKindBadge(kind: entry.kind, size: WarrenDesktopApprovalTray.faceSize)
                    .padding(1)
                    .background(
                        tokens.workbenchCardFill,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private func toggle() {
        isPresented.toggle()
    }

    /// Closes the panel even when the last row has just gone and the pill is
    /// about to stop drawing, which would otherwise take the binding's own
    /// dismissal with it.
    private func dismiss() {
        isPresented = false
        menuCenter?.dismiss()
    }
}

/// The tray's panel: one row per waiting Session, driven from the keyboard.
///
/// Up and Down move between rows, Return opens the highlighted Session, a
/// number presses that option of the highlighted row's decision, and Esc
/// closes the panel.
struct WarrenDesktopApprovalTrayPanel: View {
    @ObservedObject var store: WarrenDesktopApprovalTrayStore
    let onOpen: (TerminalSessionID) -> Void
    let onResolve: @MainActor (TerminalSessionID, String, String) async throws -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.warrenWindowMaterial) private var windowMaterial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hotID: TerminalSessionID?
    /// The option in flight, by decision id. Keyed by the decision rather than
    /// the Session so a new request on the same Session starts unpressed.
    @State private var submitting: [String: String] = [:]
    @State private var errors: [String: String] = [:]

    private typealias Metrics = WarrenDesktopMenuMetrics

    var body: some View {
        let palette = WarrenDesktopMenuPalette.resolved(for: colorScheme)
        let entries = store.entries
        VStack(alignment: .leading, spacing: 0) {
            header(count: entries.count, palette: palette)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isFirst: index == 0, palette: palette)
                            .transition(.opacity)
                    }
                }
                .animation(
                    reduceMotion ? nil : .easeOut(duration: WarrenMotion.stateChangeDuration),
                    value: entries.map(\.id)
                )
            }
            .frame(maxHeight: 480)
        }
        .overlay { WarrenDesktopKeyCatcher(onKey: handle) }
        .onExitCommand(perform: onDismiss)
        .onAppear { reconcile(entries) }
        .onChange(of: entries) { reconcile($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waiting on you")
    }

    /// The same group header every other panel opens with, so the tray
    /// reads as one of the window's menus; the count and its scope sit on
    /// the accessory side.
    private func header(count: Int, palette: WarrenDesktopMenuPalette) -> some View {
        WarrenDesktopMenuGroupHeader(title: "WAITING ON YOU") {
            HStack(spacing: 4) {
                Text("\(count)")
                    .monospacedDigit()
                    .warrenNumericTransition(value: count)
                Text("\u{00B7} this Host")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(palette.meta)
            .padding(.trailing, Metrics.rowHorizontalPadding - 2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(count == 1 ? "1 Session on this Host" : "\(count) Sessions on this Host")
        }
    }

    private func row(
        _ entry: WarrenDesktopApprovalTrayEntry,
        isFirst: Bool,
        palette: WarrenDesktopMenuPalette
    ) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme, material: windowMaterial)
        let isHot = hotID == entry.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                WarrenDesktopSessionKindBadge(kind: entry.kind, size: 16)
                Text(entry.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isHot ? palette.rowHoverText : palette.rowText)
                    .lineLimit(1)
                Text(entry.location)
                    .font(WarrenTypography.monoSmall)
                    .foregroundStyle(palette.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open") { openSession(entry) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.info)
                    .warrenTooltip("Open this Session", shortcut: "\u{21A9}")
                    .accessibilityLabel("Open \(entry.title)")
                    .warrenSemanticElement(
                        id: "approval-tray.open.\(entry.id.description)",
                        role: .button,
                        label: "Open \(entry.title)",
                        action: { openSession(entry) }
                    )
            }

            Text(entry.ask)
                .font(WarrenTypography.caption)
                .foregroundStyle(palette.secondaryGlyph)
                .lineLimit(2)

            if let detail = entry.detail {
                Text(detail)
                    .font(WarrenTypography.code)
                    .foregroundStyle(palette.rowText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(palette.tileFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(palette.tileBorder, lineWidth: 1)
                    )
            }

            if let decision = entry.decision {
                HStack(spacing: 2) {
                    ForEach(Array(decision.options.enumerated()), id: \.element.id) { index, option in
                        optionButton(option, index: index, entry: entry, decision: decision, palette: palette)
                    }
                    Spacer(minLength: 0)
                }
                if let error = errors[decision.id] {
                    Text(error)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(palette.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(
            isHot ? palette.hoverFill : .clear,
            in: RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
        )
        .overlay(alignment: .top) {
            if !isFirst {
                Rectangle()
                    .fill(palette.divider)
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .onHover { inside in
            if inside { hotID = entry.id }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.title), \(entry.mark.accessibilityLabel)")
    }

    private func optionButton(
        _ option: WarrenDesktopPendingDecision.Option,
        index: Int,
        entry: WarrenDesktopApprovalTrayEntry,
        decision: WarrenDesktopPendingDecision,
        palette: WarrenDesktopMenuPalette
    ) -> some View {
        // The first of the dock's ordered options is its recommendation, so
        // the tray fills that keycap the same way.
        let recommended = index == 0
        let inFlight = submitting[decision.id]
        let chosen = inFlight == option.id
        let filled = recommended && !chosen
        let keycap = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Button {
            choose(option, of: decision, in: entry)
        } label: {
            HStack(spacing: 8) {
                // As in the dock, the chosen key turns into the spinner.
                ZStack {
                    if chosen {
                        WarrenBrailleSpinner(size: 10, accessibilityLabel: "Answering")
                    } else {
                        Text("\(index + 1)")
                            .font(WarrenTypography.monoSmall)
                            .foregroundStyle(recommended ? palette.surface : palette.keycapText)
                    }
                }
                .frame(width: 18, height: 18)
                .background(filled ? palette.rowText : Color.clear, in: keycap)
                .overlay(keycap.strokeBorder(filled ? Color.clear : palette.keycapBorder, lineWidth: 1))
                Text(option.label)
                    .font(.system(size: 13, weight: recommended ? .semibold : .medium))
                    .foregroundStyle(option.isReject ? palette.secondaryGlyph : palette.rowText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .buttonStyle(WarrenDesktopMenuRowStyle())
        .opacity(inFlight == nil || chosen ? 1 : 0.4)
        .disabled(inFlight != nil)
        .accessibilityLabel(option.label)
        .accessibilityHint("Answers \(entry.title)")
        .warrenSemanticElement(
            id: "approval-tray.option.\(entry.id.description).\(index + 1)",
            role: .button,
            label: option.label,
            isEnabled: inFlight == nil,
            action: { choose(option, of: decision, in: entry) }
        )
    }

    // MARK: Actions

    private func openSession(_ entry: WarrenDesktopApprovalTrayEntry) {
        onOpen(entry.id)
        onDismiss()
    }

    private func choose(
        _ option: WarrenDesktopPendingDecision.Option,
        of decision: WarrenDesktopPendingDecision,
        in entry: WarrenDesktopApprovalTrayEntry
    ) {
        guard submitting[decision.id] == nil else { return }
        submitting[decision.id] = option.id
        errors[decision.id] = nil
        let sessionID = entry.id
        Task { @MainActor in
            do {
                // The row leaves when the Host reports the Agent moving on;
                // until then it stays pressed so it cannot be answered twice.
                try await onResolve(sessionID, decision.id, option.id)
            } catch {
                errors[decision.id] = error.localizedDescription
                submitting[decision.id] = nil
            }
        }
    }

    /// Keeps the highlight on a row that still exists, closes the panel when
    /// the last row has gone, and forgets the state of answered decisions.
    private func reconcile(_ entries: [WarrenDesktopApprovalTrayEntry]) {
        guard !entries.isEmpty else {
            onDismiss()
            return
        }
        if hotID == nil || !entries.contains(where: { $0.id == hotID }) {
            hotID = entries.first?.id
        }
        let open = Set(entries.compactMap { $0.decision?.id })
        submitting = submitting.filter { open.contains($0.key) }
        errors = errors.filter { open.contains($0.key) }
    }

    // MARK: Keyboard

    private func handle(_ event: NSEvent) -> Bool {
        let entries = store.entries
        switch event.keyCode {
        case 125: // down
            move(1, in: entries)
        case 126: // up
            move(-1, in: entries)
        case 36, 76: // return
            guard let entry = entries.first(where: { $0.id == hotID }) else { return true }
            openSession(entry)
        case 53: // escape
            onDismiss()
        default:
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let digit = event.charactersIgnoringModifiers.flatMap({ Int($0) }),
                  let entry = entries.first(where: { $0.id == hotID }),
                  let decision = entry.decision,
                  digit >= 1, digit <= decision.options.count else { return false }
            choose(decision.options[digit - 1], of: decision, in: entry)
        }
        return true
    }

    private func move(_ step: Int, in entries: [WarrenDesktopApprovalTrayEntry]) {
        guard !entries.isEmpty else { return }
        let current = entries.firstIndex { $0.id == hotID } ?? (step > 0 ? -1 : entries.count)
        let next = (current + step + entries.count) % entries.count
        hotID = entries[next].id
    }
}
