import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenDomain

/// A Session row's second line, as the sidebar draws it: one primary fact on
/// the left, a fixed small fact on the right, and optionally a few quieter
/// facts appended after the primary.
///
/// The cases are what the line means, not how it looks; the row decides that
/// from the tone below. Kept free of AppKit so the model can be asserted
/// without mounting a view.
struct WarrenDesktopSessionSecondLine: Equatable {
    /// Whether the Session is working. The tone picks both the colour ladder
    /// and whether the primary fact carries the slow shimmer.
    enum Tone: Equatable {
        case running
        case idle
    }

    /// One appended fact. The context reminder draws in the amber tier, a
    /// failed command's exit code in the failure tier, and every other append
    /// keeps the tone's extra tier.
    struct Extra: Equatable {
        let text: String
        var isWarning = false
        var isFailure = false
    }

    /// The small fact pinned to the row's trailing column.
    enum Meta: Equatable {
        /// A plan, drawn as its icon and `done/total`.
        case plan(done: Int, total: Int)
        /// A short duration, either this turn's elapsed time or the time since
        /// the Session last did something.
        case time(String)
        case none
    }

    let tone: Tone
    let primary: String
    let extras: [Extra]
    let meta: Meta
    /// The idle placeholder a Session with nothing to report draws. It is drawn
    /// so the row does not look half-rendered, but there is nothing to announce.
    var isPlaceholder = false
    /// Whether an overflowing primary fades at its start. A location keeps its
    /// tail; a command keeps its verb.
    var isLocation = false
    /// Whether the primary is a shell command. A command draws in the monospaced
    /// face, so the row says "this is a command" without spelling out a verb.
    var isCommand = false

    /// The line as assistive technology hears it, and the whole of it on hover.
    /// The primary is included as the Session reported it; the row shortens a
    /// command only for its own width.
    var announcement: String? {
        guard !isPlaceholder else { return nil }
        var parts: [String] = []
        if !primary.isEmpty { parts.append(primary) }
        parts.append(contentsOf: extras.map(\.text))
        switch meta {
        case .plan(let done, let total): parts.append("Plan \(done) of \(total)")
        case .time(let value): parts.append(value)
        case .none: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The colour tier each part draws in.
    struct Tint {
        let primary: Color
        let primaryPeak: Color
        let extra: Color
        let meta: Color
        let separator: Color
        let warning: Color
        let failure: Color

        static func resolve(tone: Tone, tokens: WarrenColorTokens) -> Tint {
            switch tone {
            case .running:
                Tint(
                    primary: tokens.sessionPrimaryRunningText,
                    primaryPeak: tokens.sessionPrimaryRunningHighlightText,
                    extra: tokens.sessionExtraRunningText,
                    meta: tokens.sessionMetaRunningText,
                    separator: tokens.sessionSeparatorRunningText,
                    warning: tokens.sessionContextWarningText,
                    failure: tokens.sessionFailureText
                )
            case .idle:
                Tint(
                    primary: tokens.sessionPrimaryIdleText,
                    primaryPeak: tokens.sessionPrimaryIdleText,
                    extra: tokens.sessionExtraIdleText,
                    meta: tokens.sessionMetaIdleText,
                    separator: tokens.sessionSeparatorIdleText,
                    warning: tokens.sessionContextWarningText,
                    failure: tokens.sessionFailureText
                )
            }
        }
    }
}

extension WarrenColorTokens {
    /// The Session second line's ladder.
    ///
    /// The design draws the line in two solid inks: the activity in `ink3` and
    /// its time, count and separators in `ink4`. Running and idle rows share
    /// them; the badge's dot already says which state a row is in, and dimming
    /// every idle line a further step left most of the rail a single grey.
    /// Only the shimmer's peak lifts above `ink3`, so light moving across a
    /// working line stays visible.
    var sessionPrimaryRunningText: Color { ink3 }
    var sessionPrimaryRunningHighlightText: Color { sidebarTextBase.opacity(0.99) }
    var sessionExtraRunningText: Color { ink3 }
    var sessionMetaRunningText: Color { ink4 }
    var sessionPrimaryIdleText: Color { ink3 }
    var sessionExtraIdleText: Color { ink3 }
    var sessionMetaIdleText: Color { ink4 }
    var sessionSeparatorRunningText: Color { ink4 }
    var sessionSeparatorIdleText: Color { ink4 }
    /// The `88% ctx` reminder. A reminder is not a state, so it does not take
    /// the attention hue; it is the palette's amber, softened like the rest
    /// of the line, and resolved per appearance rather than fixed for the
    /// dark ground.
    var sessionContextWarningText: Color { amber.opacity(0.78) }
    /// A resting shell's collapsed title. Between the leaf tier and the idle
    /// second line: still a name, but no longer a row saying anything.
    var sessionCollapsedTitleText: Color { sidebarTextBase.opacity(0.81) }
    /// A failed command's `exit 1` append. Red enough to read as failure on
    /// either ground, muted enough not to compete with the primary fact.
    var sessionFailureText: Color { destructive.opacity(0.8) }
}

/// How much of the line the row can draw, decided from measured text.
///
/// The primary fact is measured first and keeps the width it needs; an append
/// is added only when the primary plus that whole append fit. Nothing appended
/// is ever truncated, and the first append that does not fit stops the rest.
enum WarrenDesktopSessionSecondLineLayout {
    static let primaryFontSize: CGFloat = 11.5
    /// The wide scripts' size on the same line. Layout measures at the Latin
    /// size, which only errs toward leaving room.
    static let primaryWideFontSize: CGFloat = 11
    /// A shell command's own size. The monospaced face is a little smaller so
    /// its wider glyphs occupy the same run as the row's regular text.
    static let commandFontSize: CGFloat = 11
    /// The meta tier, a half step under the activity it trails.
    static let metaFontSize: CGFloat = 11
    /// The trailing column's ceiling, the width of `icon + 4/6` at the meta size.
    static let maximumMetaWidth: CGFloat = 35
    /// One separator, its two spaces included.
    static let separatorWidth: CGFloat = 10
    /// Between the primary-and-append segment and the trailing column.
    static let primaryMetaSpacing: CGFloat = 8
    static let planIconWidth: CGFloat = 11
    static let planIconSpacing: CGFloat = 4

    struct Result: Equatable {
        let extras: [WarrenDesktopSessionSecondLine.Extra]
        let metaWidth: CGFloat
        /// Whether the primary is wider than the room it was given, and so
        /// fades at its end. When true no append was added.
        let isPrimaryTruncated: Bool
    }

    /// The primary keeps whatever width it needs: appends are laid out after it
    /// and never squeeze it, so the design's 96pt floor holds by construction.
    /// When the primary alone does not fit, it is the only thing drawn and it
    /// fades at its end.
    static func fit(
        line: WarrenDesktopSessionSecondLine,
        availableWidth: CGFloat
    ) -> Result {
        // A command is already summarized to the words a person would name it
        // by; a step or a count is not a command, so it only loses its paths.
        let primary = line.isLocation || line.isCommand
            ? line.primary
            : WarrenDesktopActivityText.shortened(line.primary)
        let primaryWidth = textWidth(
            primary,
            fontSize: line.isCommand ? commandFontSize : primaryFontSize,
            monospaced: line.isCommand
        )
        let metaWidth = self.metaWidth(of: line.meta)
        let reserved = metaWidth + (metaWidth > 0 ? primaryMetaSpacing : 0)
        let limit = max(0, availableWidth - reserved)
        let isTruncated = primaryWidth > limit
        guard !isTruncated else {
            return Result(extras: [], metaWidth: metaWidth, isPrimaryTruncated: true)
        }
        var extras: [WarrenDesktopSessionSecondLine.Extra] = []
        var content = primaryWidth
        for extra in line.extras {
            let width = separatorWidth + textWidth(extra.text, fontSize: primaryFontSize, monospaced: false)
            guard content + width <= limit else { break }
            extras.append(extra)
            content += width
        }
        return Result(extras: extras, metaWidth: metaWidth, isPrimaryTruncated: false)
    }

    static func metaWidth(of meta: WarrenDesktopSessionSecondLine.Meta) -> CGFloat {
        switch meta {
        case .none:
            return 0
        case .time(let text):
            return min(
                maximumMetaWidth,
                textWidth(text, fontSize: metaFontSize, monospaced: true)
            )
        case .plan(let done, let total):
            let text = textWidth("\(done)/\(total)", fontSize: metaFontSize, monospaced: true)
            return min(maximumMetaWidth, planIconWidth + planIconSpacing + text)
        }
    }

    /// The width of a measured string in the row's own fonts. The row measures
    /// what it draws rather than trusting a frame, because the fit has to know
    /// the primary's whole width before it can decide about an append.
    static func textWidth(
        _ text: String,
        fontSize: CGFloat,
        monospaced: Bool
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let font = monospaced
            ? NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            : NSFont.systemFont(ofSize: fontSize)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The Session row's second line.
///
/// The trailing column is measured and claimed first, then the primary, then
/// any append that fits whole. The primary fades at its end when it does not
/// fit; an append never does, because it is only drawn when it fits.
struct WarrenDesktopSecondLineView: View {
    let line: WarrenDesktopSessionSecondLine
    let tokens: WarrenColorTokens

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fit = WarrenDesktopSessionSecondLineLayout.fit(line: line, availableWidth: width)
            let tint = WarrenDesktopSessionSecondLine.Tint.resolve(tone: line.tone, tokens: tokens)
            let spacing = fit.metaWidth > 0 ? WarrenDesktopSessionSecondLineLayout.primaryMetaSpacing : 0
            // A location keeps its tail when it overflows; while it fits there is
            // nothing to trim, so it stays where the line starts.
            let alignment: Alignment = line.isLocation && fit.isPrimaryTruncated ? .trailing : .leading
            HStack(spacing: spacing) {
                segment(fit: fit, tint: tint)
                    .frame(width: max(0, width - fit.metaWidth - spacing), alignment: alignment)
                    .clipped()
                    .mask(alignment: alignment) {
                        if fit.isPrimaryTruncated {
                            let fade = WarrenDesktopSidebarMetrics.sessionLineFadeWidth
                            let share = width > fade ? fade / width : 0
                            LinearGradient(
                                stops: line.isLocation
                                    ? [
                                        .init(color: .clear, location: 0),
                                        .init(color: .black, location: share),
                                        .init(color: .black, location: 1),
                                    ]
                                    : [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 1 - share),
                                        .init(color: .clear, location: 1),
                                    ],
                                startPoint: line.isLocation ? .trailing : .leading,
                                endPoint: line.isLocation ? .leading : .trailing
                            )
                            .frame(width: width)
                        } else {
                            Color.black
                        }
                    }
                if fit.metaWidth > 0 {
                    meta(tint: tint)
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// Second-line prose, script by script: a Chinese run half a step under
    /// the Latin one, as on the title above it.
    static func proseText(_ text: String) -> Text {
        WarrenDesktopTreeTypography.scriptText(
            text,
            latin: .system(size: WarrenDesktopSessionSecondLineLayout.primaryFontSize),
            wide: .system(size: WarrenDesktopSessionSecondLineLayout.primaryWideFontSize)
        )
    }

    /// The primary fact and the appends that fit, laid out at natural width so
    /// the caller can clip and fade the segment as a whole.
    private func segment(
        fit: WarrenDesktopSessionSecondLineLayout.Result,
        tint: WarrenDesktopSessionSecondLine.Tint
    ) -> some View {
        let primaryText = line.isLocation || line.isCommand
            ? line.primary
            : WarrenDesktopActivityText.shortened(line.primary)
        return HStack(spacing: 0) {
            Group {
                if line.isCommand {
                    Text(primaryText)
                        .font(.system(
                            size: WarrenDesktopSessionSecondLineLayout.commandFontSize,
                            design: .monospaced
                        ))
                } else {
                    Self.proseText(primaryText)
                }
            }
                .modifier(WarrenDesktopActivityShimmer(
                    base: tint.primary,
                    peak: tint.primaryPeak,
                    isActive: line.tone == .running
                ))
            ForEach(Array(fit.extras.enumerated()), id: \.offset) { _, extra in
                // The exit code's separator is one step smaller, as the design
                // draws it, so it does not read as part of the code itself.
                Text("·")
                    .font(.system(size: extra.isFailure ? 10 : WarrenDesktopSessionSecondLineLayout.primaryFontSize))
                    .foregroundStyle(tint.separator)
                    .frame(width: WarrenDesktopSessionSecondLineLayout.separatorWidth)
                Self.proseText(extra.text)
                    .foregroundStyle(
                        extra.isFailure
                            ? tint.failure
                            : (extra.isWarning ? tint.warning : tint.extra)
                    )
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private func meta(tint: WarrenDesktopSessionSecondLine.Tint) -> some View {
        switch line.meta {
        case .plan(let done, let total):
            HStack(spacing: WarrenDesktopSessionSecondLineLayout.planIconSpacing) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: WarrenDesktopSessionSecondLineLayout.planIconWidth))
                Text("\(done)/\(total)")
                    .font(.system(size: WarrenDesktopSessionSecondLineLayout.metaFontSize))
                    .monospacedDigit()
            }
            .foregroundStyle(tint.meta)
            .fixedSize()
        case .time(let text):
            Text(text)
                .font(.system(size: WarrenDesktopSessionSecondLineLayout.metaFontSize))
                .monospacedDigit()
                .foregroundStyle(tint.meta)
                .fixedSize()
        case .none:
            EmptyView()
        }
    }
}

extension WarrenDesktopWorkspaceSessionRow {
    /// The second line's content, before it is drawn.
    ///
    /// A working Session says what it is doing: the tool step it is on, the
    /// plan entry it is advancing, or the foreground command. A resting one
    /// says what this turn did, heaviest first, and falls back to the last
    /// action, the foreground command, or the fact that nothing has run here
    /// yet. The trailing column carries the plan's progress or a duration; the
    /// appends carry the context reminder and the quieter counts.
    static func secondLine(
        for session: WarrenDesktopSession,
        now: Date = Date()
    ) -> WarrenDesktopSessionSecondLine {
        if let shell = shellSecondLine(for: session, now: now) {
            return shell
        }
        let isRunning = session.activity == .working
        // The Host probes only the foreground process, not a shell's command
        // history, so this is the command running now, not the last one run.
        // A bound Agent's "command" is its provider name, which the badge and
        // the title already carry, so the command fallback is for programs only.
        // A shell's title may already lead with the command; the line still
        // reports the foreground command, which is the one fact a shell has.
        let command = session.isAgentSession
            ? nil
            : trimmed(foregroundCommand(for: session))
        let resolved: String?
        if isRunning {
            // A working Agent says what it is on: the tool step, or the plan
            // entry it is advancing. When neither is known the row holds the
            // last primary fact it showed (`primaryLine`) rather than dropping
            // to a foreground command or the previous turn's summary, because
            // both would swap the subject under the same running shimmer.
            resolved = firstNonEmpty([
                session.currentStep,
                session.plan?.currentStep,
                session.primaryLine,
            ])
        } else {
            // A resting Agent leads with what the turn accomplished when the
            // Host could ask a model for a sentence, and falls back to the
            // counts when it could not. `Edited 2 files` is the same line in
            // ten rows; a sentence is not.
            resolved = firstNonEmpty([
                session.resultSentence,
                session.turnCounts.first,
                command,
                session.lastActivity,
            ])
        }
        let isPlaceholder = resolved == nil
        let primary = resolved ?? "New session"
        let tone: WarrenDesktopSessionSecondLine.Tone = isRunning && !isPlaceholder ? .running : .idle

        var extras: [WarrenDesktopSessionSecondLine.Extra] = []
        if let context = contextReminder(for: session) {
            extras.append(context)
        }
        if isRunning && !isPlaceholder {
            if session.plan != nil,
               let started = session.turnStartedAt,
               now.timeIntervalSince(started) >= 1 {
                extras.append(.init(text: WarrenDesktopSessionSecondLineLayout.elapsed(now.timeIntervalSince(started))))
            }
            if let heaviest = session.turnCounts.first {
                extras.append(.init(text: heaviest))
            }
        } else if !isPlaceholder, session.turnCounts.count >= 2 {
            extras.append(.init(text: session.turnCounts[1]))
        }

        return WarrenDesktopSessionSecondLine(
            tone: tone,
            primary: primary,
            extras: extras,
            meta: isPlaceholder ? .none : meta(for: session, isRunning: isRunning, now: now),
            isPlaceholder: isPlaceholder
        )
    }

    /// The second line of a plain shell, from the OSC 133 prompt state the Host
    /// reports. Nil when the Host reported no marker: the row then keeps its
    /// foreground-command fallback rather than inventing a prompt state, and an
    /// Agent bound inside the shell keeps the Agent rule.
    ///
    /// The four states are the design's: a running command, the last command
    /// after it succeeded or failed, and the full directory before anything
    /// ran. A Session that has ended is not one of them: the sidebar lists only
    /// active Sessions, so an ended shell has no row to draw.
    static func shellSecondLine(
        for session: WarrenDesktopSession,
        now: Date
    ) -> WarrenDesktopSessionSecondLine? {
        guard session.presentedKind == .shell,
              !session.isAgentSession,
              let shell = session.shellState else {
            return nil
        }
        if shell.isRunningCommand, session.state.isActive {
            let command = WarrenDesktopActivityText.withoutLaunchPrefix(
                shell.runningCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            if !command.isEmpty {
                return WarrenDesktopSessionSecondLine(
                    tone: .running,
                    primary: CommandSummary.summarize(command),
                    extras: [],
                    meta: shellDuration(from: shell.commandStartedAt ?? shell.lastExitAt, now: now),
                    isCommand: true
                )
            }
        }
        let last = WarrenDesktopActivityText.withoutLaunchPrefix(
            shell.lastCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if !last.isEmpty {
            var extras: [WarrenDesktopSessionSecondLine.Extra] = []
            if let code = shell.displayedExitCode {
                extras.append(.init(text: "exit \(code)", isFailure: true))
            }
            return WarrenDesktopSessionSecondLine(
                tone: .idle,
                primary: CommandSummary.summarize(last),
                extras: extras,
                meta: shellDuration(from: shell.lastExitAt, now: now),
                isCommand: true
            )
        }
        // Nothing has run yet: the line still says where the shell is, in full,
        // with the session's own age on the right.
        let directory = TerminalSessionPresentation.abbreviatedPath(session.workingDirectory)
        let fallback = shell.shellName.isEmpty ? "Shell" : shell.shellName
        return WarrenDesktopSessionSecondLine(
            tone: .idle,
            primary: directory.isEmpty ? fallback : directory,
            extras: [],
            meta: shellDuration(from: session.createdAt, now: now),
            isLocation: true
        )
    }

    /// A short duration from a recorded instant, or `.none` when there is no
    /// instant to measure from.
    private static func shellDuration(
        from date: Date?,
        now: Date
    ) -> WarrenDesktopSessionSecondLine.Meta {
        guard let date else { return .none }
        return .time(WarrenDesktopSessionSecondLineLayout.elapsed(now.timeIntervalSince(date)))
    }

    /// The command in the foreground, as the Host reports it.
    private static func foregroundCommand(for session: WarrenDesktopSession) -> String {
        TerminalSessionPresentation.commandLabel(
            kind: session.presentedKind,
            process: session.runtimeProcess,
            commandLine: session.runtimeCommandLine
        )
    }

    /// The trailing small fact: the plan's progress wins, then a duration.
    /// A working Session without a plan reports how long this turn has run; a
    /// resting one reports how long ago it last did something.
    private static func meta(
        for session: WarrenDesktopSession,
        isRunning: Bool,
        now: Date
    ) -> WarrenDesktopSessionSecondLine.Meta {
        if let plan = session.plan, plan.total > 0 {
            return .plan(done: plan.done, total: plan.total)
        }
        if isRunning, let started = session.turnStartedAt {
            return .time(WarrenDesktopSessionSecondLineLayout.elapsed(now.timeIntervalSince(started)))
        }
        let age = WarrenDesktopActivityAge.label(since: session.activityUpdatedAt, now: now)
        return age.isEmpty ? .none : .time(age)
    }

    /// The `88% ctx` reminder, shown once the window is nearly full.
    private static func contextReminder(
        for session: WarrenDesktopSession
    ) -> WarrenDesktopSessionSecondLine.Extra? {
        guard let fraction = session.context?.fraction, fraction >= 0.8 else { return nil }
        return .init(text: "\(Int((fraction * 100).rounded()))% ctx", isWarning: true)
    }

    /// A shell's foreground command, unless the row's own title already leads
    /// with it: repeating the title in the line below reads as a fault.
    private static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// Durations as the sidebar draws them: `18s`, then `3m`, then `1h`. The
/// sidebar drops smaller units on purpose so a duration never reads as a
/// clock; the Conversation surface keeps its fuller `1m 12s` form.
extension WarrenDesktopSessionSecondLineLayout {
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }
}
