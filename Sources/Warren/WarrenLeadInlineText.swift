import SwiftUI
import WarrenDesignSystem
import WarrenDesktop
import WarrenDomain
import WarrenTransport

/// A Lead answer's inline text with `#agent` capsules where the marker was.
///
/// SwiftUI cannot put a view inside a `Text`, so the paragraph is laid out as
/// words and capsules in a small flow layout. The words keep the Markdown
/// styling the transcript already applies; a marker that does not resolve is
/// reconstructed as text, exactly as it was written.
struct WarrenLeadInlineText: View {
    let text: String
    let font: Font
    let lineHeight: CGFloat
    let palette: WarrenConversationPalette
    let session: (String) -> WarrenDesktopSession?
    let openSession: (String) -> Void
    let styled: (String) -> AttributedString?
    var color: Color? = nil

    private enum Token {
        case text(AttributedString)
        case space
        case lineBreak
        case agent(id: String, title: String?, session: WarrenDesktopSession)
    }

    var body: some View {
        let tokens = makeTokens()
        WarrenInlineFlowLayout(lineHeight: lineHeight) {
            ForEach(tokens.indices, id: \.self) { index in
                tokenView(tokens[index])
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func tokenView(_ token: Token) -> some View {
        switch token {
        case .text(let value):
            Text(value)
                .font(font)
                .foregroundStyle(color ?? palette.ink)
        case .space:
            Text(" ")
                .font(font)
        case .lineBreak:
            Color.clear
                .frame(width: 0, height: 0)
                .layoutValue(key: WarrenInlineLineBreakKey.self, value: true)
        case .agent(let id, let title, let session):
            WarrenLeadReferenceCapsule(
                session: session,
                title: title,
                palette: palette,
                onOpen: { openSession(id) }
            )
        }
    }

    private func makeTokens() -> [Token] {
        var tokens: [Token] = []
        for segment in WarrenLeadMessageParser.segments(in: text) {
            switch segment {
            case .text(let value):
                appendText(value, to: &tokens)
            case .marker(.agent(let id, let title)):
                if let session = session(id) {
                    tokens.append(.agent(id: id, title: title, session: session))
                } else {
                    appendText(Self.markerText(id: id, title: title), to: &tokens)
                }
            case .marker(.ask), .marker(.accept):
                // The request itself is drawn in the dock, not in the prose.
                continue
            }
        }
        return tokens
    }

    private func appendText(_ value: String, to tokens: inout [Token]) {
        guard let attributed = styled(value) else {
            appendPlain(value, to: &tokens)
            return
        }
        var start = attributed.startIndex
        for index in attributed.characters.indices {
            let character = attributed.characters[index]
            guard character.isWhitespace else { continue }
            if start < index {
                tokens.append(.text(AttributedString(attributed[start..<index])))
            }
            if character == "\n" {
                tokens.append(.lineBreak)
            } else {
                tokens.append(.space)
            }
            start = attributed.characters.index(after: index)
        }
        if start < attributed.endIndex {
            tokens.append(.text(AttributedString(attributed[start..<attributed.endIndex])))
        }
    }

    private func appendPlain(_ value: String, to tokens: inout [Token]) {
        var word = ""
        for character in value {
            if character == "\n" {
                if !word.isEmpty {
                    tokens.append(.text(AttributedString(word)))
                    word = ""
                }
                tokens.append(.lineBreak)
            } else if character.isWhitespace {
                if !word.isEmpty {
                    tokens.append(.text(AttributedString(word)))
                    word = ""
                }
                tokens.append(.space)
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { tokens.append(.text(AttributedString(word))) }
    }

    private static func markerText(id: String, title: String?) -> String {
        if let title, !title.isEmpty {
            return "[#agent:\(id)|\(title)]"
        }
        return "[#agent:\(id)]"
    }
}

/// The live or closed Crew reference capsule: the Session's own tile, its live
/// status dot, and its title.
struct WarrenLeadReferenceCapsule: View {
    let session: WarrenDesktopSession
    let title: String?
    let palette: WarrenConversationPalette
    let onOpen: () -> Void

    @State private var hovering = false

    private var isClosed: Bool { !session.state.isActive }
    /// The Lead's own name for the Session when it gave one: the marker's
    /// `|title`, else the person's custom title, else the Session's title.
    private var label: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let custom = session.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return custom
        }
        return session.title
    }

    var body: some View {
        if isClosed {
            capsule(closed: true)
                .accessibilityLabel("Closed Session \(label)")
        } else {
            Button(action: onOpen) {
                capsule(closed: false)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("Open Session \(label)")
        }
    }

    private func capsule(closed: Bool) -> some View {
        HStack(spacing: 6) {
            WarrenDesktopSessionKindBadge(session: session, size: 14)
                .opacity(closed ? 0.5 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if !closed, let mark = session.effectiveActivityMark ?? session.rowStatusMark, mark.isDrawn {
                        WarrenLeadStatusDot(
                            mark: mark,
                            palette: palette,
                            size: 6,
                            ring: palette.bubble
                        )
                        .offset(x: 2, y: 2)
                    }
                }
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(closed ? palette.ink3 : palette.ink)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.leading, 4)
        .padding(.trailing, 7)
        .frame(height: 22)
        .background(
            closed ? Color.clear : (hovering ? palette.press : palette.bubble),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            if closed {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(palette.line2, lineWidth: 1)
            }
        }
        .offset(y: -1)
    }
}

/// One activity mark in the Conversation's own palette. The dot is the shared
/// `WarrenActivityMarkView`, so a running Crew member pulses exactly as it does
/// in the sidebar.
struct WarrenLeadStatusDot: View {
    let mark: WarrenActivityMark
    let palette: WarrenConversationPalette
    var size: CGFloat = 6
    var ring: Color?

    var body: some View {
        WarrenActivityMarkView(
            mark: mark,
            color: Self.color(mark, palette: palette),
            dotSize: size
        )
        .background {
            if let ring {
                Circle()
                    .fill(ring)
                    .frame(width: size + 3, height: size + 3)
            }
        }
    }

    static func color(_ mark: WarrenActivityMark, palette: WarrenConversationPalette) -> Color {
        switch mark {
        case .failed: palette.red
        case .working: palette.green
        case .ready: palette.blue
        case .exited: palette.ink4
        case .approvalNeeded, .inputNeeded, .attentionUnspecified: palette.accent
        }
    }
}

struct WarrenInlineLineBreakKey: LayoutValueKey {
    static let defaultValue = false
}

/// A line-wrapping row of words and inline capsules. Height is the shared line
/// height, so a paragraph keeps the transcript's 15/22 rhythm even when a
/// capsule sits on one of its lines.
struct WarrenInlineFlowLayout: Layout {
    let lineHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        let measured = measure(subviews, width: width)
        return CGSize(width: measured.width, height: measured.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let width = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var line: [LayoutSubview] = []
        var lineWidth: CGFloat = 0

        func placeLine() {
            guard !line.isEmpty else { return }
            for subview in line {
                let size = subview.sizeThatFits(.unspecified)
                let dy = (lineHeight - size.height) / 2
                subview.place(
                    at: CGPoint(x: x, y: y + max(0, dy)),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width
            }
            x = bounds.minX
            y += lineHeight
            line.removeAll(keepingCapacity: true)
            lineWidth = 0
        }

        for subview in subviews {
            if subview[WarrenInlineLineBreakKey.self] {
                placeLine()
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + size.width > width {
                placeLine()
            }
            line.append(subview)
            lineWidth += size.width
        }
        placeLine()
    }

    private func measure(_ subviews: Subviews, width: CGFloat) -> CGSize {
        var x: CGFloat = 0
        var lines = 0
        var widest: CGFloat = 0
        var hasContent = false

        for subview in subviews {
            if subview[WarrenInlineLineBreakKey.self] {
                if hasContent {
                    lines += 1
                    widest = max(widest, x)
                }
                x = 0
                hasContent = false
                continue
            }
            let size = subview.sizeThatFits(.unspecified)
            if hasContent, x + size.width > width {
                lines += 1
                widest = max(widest, x)
                x = 0
            }
            x += size.width
            hasContent = true
        }
        if hasContent {
            lines += 1
            widest = max(widest, x)
        }
        return CGSize(width: min(widest, width), height: CGFloat(lines) * lineHeight)
    }
}
