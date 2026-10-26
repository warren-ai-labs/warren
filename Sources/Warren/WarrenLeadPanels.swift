import SwiftUI
import WarrenDesignSystem
import WarrenDesktop
import WarrenDomain
import WarrenTransport

// The "needs you" panels (RFC 0024 §7), all shaped like the composer they rest
// on: one eyebrow with the attention dot, no outline in the accent, and a
// single filled default action.

/// A decision's option rows. The `highlight` row is the one Return answers and
/// is the only row carrying the `↵` hint; numbers answer the others directly.
struct WarrenLeadDecisionPanel: View {
    let question: String
    let reason: String?
    let options: [String]
    let highlight: Int
    let onChoose: (Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenLeadEyebrow(text: "Lead needs a decision")
            Text(question)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            VStack(spacing: 1) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    row(index: index, option: option)
                }
            }
            // The rows' highlight bleeds past the text column, as the design's
            // own choice list does, so a pointed-at row reads as a band.
            .padding(.horizontal, -8)
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(index: Int, option: String) -> some View {
        Button {
            onChoose(index)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.ink4)
                    .frame(width: 14)
                Text(option)
                    .font(.system(size: 13.5))
                    .foregroundStyle(highlight == index ? palette.ink : palette.ink2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\u{21B5}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.ink4)
                    .opacity(highlight == index ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
            .background(
                highlight == index ? palette.bubble : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(WarrenLeadQuietRowStyle(highlighted: highlight == index, palette: palette))
        .accessibilityLabel(option)
        .accessibilityHint("Press \(index + 1)")
    }
}

/// One checklist. A circle toggles passed; Problem is a hover affordance that
/// moves the note into the composer. Nothing is sent until every row is
/// resolved and Send to Lead is pressed.
struct WarrenLeadChecksPanel: View {
    let checks: [WarrenLeadMessage.Check]
    let outcomes: [WarrenLeadReply.CheckOutcome?]
    let noting: Int?
    let onToggle: (Int) -> Void
    let onProblem: (Int) -> Void
    let onClear: (Int) -> Void
    let onAllPassed: () -> Void
    let onSend: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// The row the pointer is on. Design here means the whole row: Problem
    /// appears on it, not only while the pointer is on the word.
    @State private var hovered: Int?

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }
    private var resolved: Int { outcomes.filter { $0 != nil }.count }
    private var allResolved: Bool { !checks.isEmpty && resolved == checks.count }
    private var eyebrow: String {
        checks.count == 1
            ? "Lead asks you to check 1 thing on main"
            : "Lead asks you to check \(checks.count) things on main"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WarrenLeadEyebrow(text: eyebrow)
            VStack(spacing: 1) {
                ForEach(Array(checks.enumerated()), id: \.offset) { index, check in
                    row(index: index, check: check)
                }
            }
            .padding(.horizontal, -8)
            .padding(.top, 8)
            HStack(spacing: 6) {
                Text("\(resolved) of \(checks.count) checked")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink4)
                Spacer(minLength: 6)
                if !allResolved {
                    button("All passed", role: .secondary, action: onAllPassed)
                }
                button("Send to Lead", key: "\u{21B5}", role: .primary, action: onSend)
                    .disabled(!allResolved)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func row(index: Int, check: WarrenLeadMessage.Check) -> some View {
        let outcome = outcomes.indices.contains(index) ? outcomes[index] : nil
        let isProblem: Bool
        let note: String
        switch outcome {
        case .problem(let value):
            isProblem = true
            note = value
        default:
            isProblem = false
            note = ""
        }
        let waiting = noting == index
        return HStack(alignment: .top, spacing: 10) {
            Button {
                if waiting {
                    onClear(index)
                } else {
                    onToggle(index)
                }
            } label: {
                Circle()
                    .fill(isProblem ? palette.red : (outcome == .passed ? palette.green : Color.clear))
                    .overlay {
                        if isProblem {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(palette.card)
                        } else if outcome == .passed {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(palette.card)
                        } else {
                            Circle()
                                .strokeBorder(waiting ? palette.red : palette.ink4, lineWidth: 1.25)
                        }
                    }
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            .accessibilityLabel("Mark passed")
            VStack(alignment: .leading, spacing: 1) {
                Text(check.what)
                    .font(.system(size: 13.5))
                    .foregroundStyle(outcome == .passed ? palette.ink3 : palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(check.at)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.ink4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isProblem, !note.isEmpty {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if isProblem || waiting {
                Button("Clear") { onClear(index) }
                    .buttonStyle(WarrenLeadProblemButtonStyle(palette: palette, visible: true))
            } else {
                Button("Problem") { onProblem(index) }
                    .buttonStyle(WarrenLeadProblemButtonStyle(palette: palette, visible: hovered == index))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            hovered == index ? palette.bubble : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hovered = index
            } else if hovered == index {
                hovered = nil
            }
        }
    }

    private func button(
        _ title: String,
        key: String? = nil,
        role: WarrenLeadActionRole,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                if let key {
                    Text(key)
                        .font(.system(size: 10.5, design: .monospaced))
                        // The filled default's own key sits back a step, as the
                        // design's `kbd` inside a primary button does.
                        .opacity(role == .primary ? 0.5 : 1)
                }
            }
        }
        .buttonStyle(WarrenLeadActionButtonStyle(role: role, palette: palette))
    }
}

/// The Crew list, shaped like the Plan strip: a folded summary over the
/// composer and member rows on demand. Closed members fold into one row and
/// are never clickable.
struct WarrenLeadCrewStrip: View {
    let members: [WarrenLeadCrewMember]
    let latest: String
    let onOpen: (String) -> Void
    @State private var open = false
    @State private var closedOpen = false
    @State private var hoveredID: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }
    private var live: [WarrenLeadCrewMember] { members.filter(\.isLive) }
    private var closed: [WarrenLeadCrewMember] { members.filter { !$0.isLive } }
    private var done: Int {
        live.filter { $0.mark?.tier != .live }.count
    }
    private var label: String {
        live.isEmpty ? "CREW" : "CREW \(done)/\(live.count)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(label)
                        .font(WarrenTypography.monoSmall)
                        .foregroundStyle(palette.ink4)
                        .warrenNumericTransition(value: done)
                    HStack(spacing: 4) {
                        ForEach(live) { member in
                            if let mark = member.mark, mark.isDrawn {
                                WarrenLeadStatusDot(mark: mark, palette: palette)
                            } else {
                                Circle()
                                    .strokeBorder(palette.ink4, lineWidth: 1.25)
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }
                    Text(latest)
                        .font(WarrenTypography.caption)
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if !closed.isEmpty {
                        Text("\(closed.count) closed")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.ink4)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.ink4)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Crew, \(done) of \(live.count) done")
            .accessibilityValue(latest)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(live) { member in
                        row(member, closed: false)
                    }
                    if !closed.isEmpty, !live.isEmpty {
                        Button {
                            withAnimation(WarrenMotion.animation(.overlay, reduceMotion: reduceMotion)) {
                                closedOpen.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                                    .rotationEffect(.degrees(closedOpen ? 90 : 0))
                                Text("\(closed.count) closed")
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(palette.ink4)
                            .frame(height: 28)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            Rectangle().fill(palette.line).frame(height: 1)
                        }
                        .padding(.top, 2)
                    }
                    if live.isEmpty || closedOpen {
                        ForEach(closed) { member in
                            row(member, closed: true)
                        }
                    }
                }
                .padding(.horizontal, -6)
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func row(_ member: WarrenLeadCrewMember, closed: Bool) -> some View {
        if closed {
            rowLabel(member, closed: true)
                .accessibilityLabel("Closed Session \(member.title)")
        } else {
            Button {
                onOpen(member.id)
            } label: {
                rowLabel(member, closed: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Session \(member.title)")
        }
    }

    private func rowLabel(_ member: WarrenLeadCrewMember, closed: Bool) -> some View {
        HStack(spacing: 9) {
            WarrenDesktopSessionKindBadge(session: member.session, size: 14)
                .opacity(closed ? 0.45 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if !closed, let mark = member.mark, mark.isDrawn {
                        WarrenLeadStatusDot(
                            mark: mark,
                            palette: palette,
                            size: 6,
                            ring: palette.raise
                        )
                        .offset(x: 2, y: 2)
                    }
                }
            Text(member.title)
                .font(.system(size: 12.5))
                .foregroundStyle(closed ? palette.ink3 : palette.ink2)
                .lineLimit(1)
                .fixedSize()
            Text(member.result ?? "")
                .font(.system(size: 12))
                .foregroundStyle(closed ? palette.ink4 : palette.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let age = member.ageLabel, !age.isEmpty {
                Text(age)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(palette.ink4)
            }
            if !closed {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink4)
                    .opacity(hoveredID == member.id ? 1 : 0)
            }
        }
        .frame(height: 30)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .background(
            hoveredID == member.id && !closed ? palette.bubble : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .onHover { inside in
            if inside {
                hoveredID = member.id
            } else if hoveredID == member.id {
                hoveredID = nil
            }
        }
    }
}

/// The piece of a Crew member the strip needs, resolved once from the live
/// Session row so the view has no model dependency.
struct WarrenLeadCrewMember: Identifiable {
    let id: String
    let session: WarrenDesktopSession
    let markerTitle: String?

    var isLive: Bool { session.state.isActive }
    /// The name the Lead used for this member, else the name the person gave
    /// its Session, else the Session's own title. A Lead that wrote
    /// `[#agent:…|Parse markers]` named the work, and that is what the Crew
    /// strip and the inline reference must read, not the provider's default
    /// "Codex".
    var title: String {
        if let markerTitle = markerTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !markerTitle.isEmpty {
            return markerTitle
        }
        if let custom = session.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return session.title
    }
    var mark: WarrenActivityMark? { session.effectiveActivityMark ?? session.rowStatusMark }
    var result: String? {
        for value in [session.resultSentence, session.lastActivity, session.primaryLine, session.currentStep] {
            let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        // A closed Session has nothing left to report; its mark would only
        // repeat the word "Closed" beside a row that is already greyed out.
        guard isLive, let mark else { return nil }
        switch mark {
        case .working: return "Working"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .exited: return "Closed"
        case .approvalNeeded, .inputNeeded, .attentionUnspecified: return "Needs you"
        }
    }
    /// The age of a live member, or the time a closed one stopped.
    var ageLabel: String? {
        guard let date = session.activityUpdatedAt ?? session.turnStartedAt ?? session.createdAt else { return nil }
        if isLive { return WarrenLeadCrewMember.formatAge(Date().timeIntervalSince(date)) }
        return "Closed \(WarrenLeadCrewMember.formatTime(date))"
    }

    static func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func formatAge(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

// MARK: - Shared pieces

struct WarrenLeadEyebrow: View {
    let text: String
    var trailing: String?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: WarrenConversationPalette { WarrenConversationPalette.resolved(for: colorScheme) }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(palette.accent)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
            if let trailing {
                Spacer(minLength: 6)
                Text(trailing)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(palette.ink4)
            }
        }
        .frame(height: 18)
    }
}

enum WarrenLeadActionRole { case primary, secondary }

struct WarrenLeadActionButtonStyle: ButtonStyle {
    let role: WarrenLeadActionRole
    let palette: WarrenConversationPalette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let primary = role == .primary
        let disabled = !isEnabled
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12.5, weight: primary ? .medium : .regular))
            .foregroundStyle(
                primary
                    ? (disabled ? palette.ink4 : palette.card)
                    : (hovering ? palette.ink : palette.ink2)
            )
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                if primary {
                    shape.fill(disabled ? palette.bubble : (configuration.isPressed ? palette.ink2 : palette.ink))
                } else if hovering || configuration.isPressed {
                    shape.fill(configuration.isPressed ? palette.press : palette.bubble)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .opacity(primary ? 1 : (disabled ? 0.35 : 1))
    }
}

private struct WarrenLeadQuietRowStyle: ButtonStyle {
    let highlighted: Bool
    let palette: WarrenConversationPalette
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                highlighted || hovering ? palette.bubble : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .onHover { hovering = $0 }
    }
}

private struct WarrenLeadProblemButtonStyle: ButtonStyle {
    let palette: WarrenConversationPalette
    let visible: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(hovering ? palette.ink : palette.ink3)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                hovering ? palette.bubble : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .opacity(visible || hovering ? 1 : 0)
            .onHover { hovering = $0 }
    }
}
