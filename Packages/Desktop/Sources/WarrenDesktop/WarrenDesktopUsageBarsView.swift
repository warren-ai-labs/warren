import SwiftUI
import WarrenDesignSystem

extension WarrenUsageBucket {
    /// The Usage page's own data colours. Every surface that splits tokens by
    /// class reads them from here, so the bars, the legend and the readout can
    /// never disagree about which colour means cache read.
    func color(_ tokens: WarrenColorTokens) -> Color {
        switch self {
        case .freshInput: tokens.highlight
        case .cacheWrite: tokens.warning
        case .cacheRead: tokens.info
        case .output: tokens.success
        }
    }
}

// MARK: - Readout

/// The floating card that reads out one day or week: its total and the four
/// classes with their colour keys.
///
/// Drawn by the page rather than left to `.help`, because the system tooltip
/// waits about a second at every target and then jumps; sweeping along a row
/// of bars should read each one at once, with a single card travelling along.
struct WarrenDesktopUsageReadout: View {
    let content: WarrenUsageReadoutContent
    let tokens: WarrenColorTokens

    static let width: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(content.title)
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.xs) {
                Text(content.total)
                    .font(WarrenTypography.settingsBodyEmphasis.weight(.semibold))
                    .foregroundStyle(tokens.foreground)
                if let secondary = content.secondary {
                    Text(secondary)
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .padding(.top, 2)

            if !content.rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(content.rows, id: \.bucket) { row in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(row.bucket.color(tokens))
                                .frame(width: 8, height: 8)
                            Text(row.bucket.label)
                                .foregroundStyle(tokens.mutedForeground)
                            Spacer(minLength: WarrenSpacing.xs)
                            Text(row.value)
                                .foregroundStyle(tokens.foreground)
                                .monospacedDigit()
                        }
                        .font(WarrenTypography.settingsGroupLabel)
                        .lineLimit(1)
                    }
                }
                .padding(.top, WarrenSpacing.small)
            }

            if let caveat = content.caveat {
                Text(caveat)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.warning)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WarrenSpacing.small)
            }

            if let hint = content.hint {
                Rectangle()
                    .fill(tokens.border.opacity(0.6))
                    .frame(height: WarrenSpacing.hairline)
                    .padding(.top, WarrenSpacing.small)
                Text(hint)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                .fill(tokens.popoverSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.7), lineWidth: WarrenSpacing.hairline)
        )
        .shadow(color: tokens.elevationShadow, radius: 14, y: 6)
    }
}

private struct WarrenUsageReadoutSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Places the readout beside an anchor and glides it to the next one.
///
/// Laid over the chart it describes. It keeps showing the last thing read out
/// while it fades, so leaving a bar does not snap the card back to an origin
/// before it disappears.
struct WarrenDesktopUsageReadoutLayer: View {
    let content: WarrenUsageReadoutContent?
    /// The described mark's frame, in this layer's coordinates.
    let anchor: CGRect
    let isVisible: Bool
    let tokens: WarrenColorTokens

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = CGSize(width: WarrenDesktopUsageReadout.width, height: 140)

    var body: some View {
        GeometryReader { proxy in
            if let content {
                let origin = WarrenUsageReadoutPlacement.origin(
                    anchor: anchor,
                    size: size,
                    bounds: proxy.size
                )
                WarrenDesktopUsageReadout(content: content, tokens: tokens)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        GeometryReader { readout in
                            Color.clear.preference(key: WarrenUsageReadoutSizeKey.self, value: readout.size)
                        }
                    )
                    .onPreferenceChange(WarrenUsageReadoutSizeKey.self) { size = $0 }
                    .offset(x: origin.x, y: origin.y)
                    // The selection spring, so the card travels the way a
                    // selection plate does. Under Reduce Motion it jumps.
                    .animation(
                        reduceMotion ? nil : WarrenMotion.selection(reduceMotion: false),
                        value: anchor
                    )
                    .opacity(isVisible ? 1 : 0)
                    .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: isVisible)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Which mark the pointer is over, held outside the view tree.
///
/// A reference held in `@State` does not subscribe its owner, so the grid that
/// reports hover is not re-rendered by it; only the readout layer observes it.
/// The heatmap needs this: re-rendering ~371 cells on every pointer move is the
/// cost its per-cell hover state was split out to avoid.
@MainActor
final class WarrenUsageHoverTracker: ObservableObject {
    @Published private(set) var hovered: String?
    /// The last mark hovered, kept after the pointer leaves so the readout
    /// fades out where it was instead of jumping first.
    @Published private(set) var last: String?

    func hover(_ id: String, isInside: Bool) {
        if isInside {
            hovered = id
            if last != id { last = id }
        } else if hovered == id {
            hovered = nil
        }
    }
}

// MARK: - Daily bars

/// Daily (or weekly) bars for the last month of the range, each stacked by the
/// four token classes.
///
/// The composition card says where a whole range went; this says when. Cost is
/// the default measure because the stack is legible in money: in tokens the bar
/// is almost all cache read, which is true and worth a switch, but says little
/// about the spend each day drove.
struct WarrenDesktopUsageBarsView: View {
    let days: [WarrenUsageDay]
    let fromDay: String
    let toDay: String
    let tokens: WarrenColorTokens
    /// The page's day selection, the same binding the heatmap writes.
    @Binding var selectedDay: String?
    /// Says the bars ignore the active filter: the Host sends one total per
    /// day, not one per Agent or model.
    let filterNote: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metric: WarrenUsageCurveMetric = .cost
    @State private var grouping: WarrenUsageBarGrouping = .day
    @State private var hovered: Int?
    @State private var lastHovered: Int?
    /// False for the instant between a switch and the regrow, so the new bars
    /// rise from the baseline instead of morphing out of the old ones.
    @State private var grown = true
    @FocusState private var isFocused: Bool

    private let plotHeight: CGFloat = 180
    private let axisWidth: CGFloat = 44

    var body: some View {
        let bars = WarrenUsageBarsBuilder.build(
            days: days, fromDay: fromDay, toDay: toDay, grouping: grouping
        )
        let scale = WarrenUsageBarsBuilder.scale(peak: bars.map { $0.total(metric) }.max() ?? 0)

        return VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            header(bars: bars)
            HStack(alignment: .top, spacing: 0) {
                axis(scale: scale)
                VStack(alignment: .leading, spacing: WarrenSpacing.small) {
                    GeometryReader { geometry in
                        plot(bars: bars, scale: scale, width: geometry.size.width)
                    }
                    .frame(height: plotHeight)
                    xLabels(bars: bars)
                }
            }
            footer(bars: bars)
        }
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.cardSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
        .accessibilityIdentifier("usage.bars")
    }

    // MARK: Header and footer

    private func header(bars: [WarrenUsageBar]) -> some View {
        HStack(alignment: .top, spacing: WarrenSpacing.standard) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text("Daily Usage")
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.foreground)
                Text(subtitle(bars: bars))
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            WarrenSettingsSegmented(
                options: WarrenUsageCurveMetric.allCases.reversed().map { ($0, $0.label) },
                selection: Binding(get: { metric }, set: { switchMetric($0) }),
                accessibilityID: "usage.bars.metric"
            )
            .fixedSize()
            WarrenSettingsSegmented(
                options: WarrenUsageBarGrouping.allCases.map { ($0, $0.label) },
                selection: Binding(get: { grouping }, set: { switchGrouping($0) }),
                accessibilityID: "usage.bars.grouping"
            )
            .fixedSize()
        }
    }

    private func subtitle(bars: [WarrenUsageBar]) -> String {
        var parts: [String] = []
        if let first = bars.first?.firstDay, let last = bars.last?.lastDay {
            parts.append(WarrenUsageFormatting.dayRangeLabel(from: first, to: last))
        }
        parts.append(metric == .cost ? "Estimated spend" : "Tokens")
        if let filterNote {
            parts.append(filterNote)
        }
        return parts.joined(separator: " · ")
    }

    private func footer(bars: [WarrenUsageBar]) -> some View {
        let total = bars.reduce(0.0) { $0 + $1.total(metric) }
        let totalText = metric == .cost
            ? WarrenUsageFormatting.money(bars.dropFirst().reduce(bars.first?.cost ?? WarrenUsageCost()) { $0.adding($1.cost) })
            : "\(WarrenUsageFormatting.tokens(Int64(total))) tokens"
        return HStack(spacing: WarrenSpacing.standard) {
            ForEach(WarrenUsageBucket.allCases, id: \.self) { bucket in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(bucket.color(tokens))
                        .frame(width: 9, height: 9)
                    Text(bucket.label)
                }
            }
            Spacer(minLength: 0)
            Text("Total \(totalText)")
                .monospacedDigit()
                .warrenNumericTransition(value: totalText)
        }
        .font(WarrenTypography.settingsMeta)
        .foregroundStyle(tokens.mutedForeground)
        .lineLimit(1)
    }

    // MARK: Axes

    private func gridValues(_ scale: (top: Double, step: Double)) -> [Double] {
        Array(stride(from: scale.step, through: scale.top + scale.step / 2, by: scale.step))
    }

    private func axis(scale: (top: Double, step: Double)) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            ForEach(gridValues(scale), id: \.self) { value in
                Text(axisLabel(value))
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.trailing, WarrenSpacing.small)
                    .offset(y: plotHeight * (1 - CGFloat(value / scale.top)) - 7)
            }
        }
        .frame(width: axisWidth, height: plotHeight)
        .accessibilityHidden(true)
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .tokens: WarrenUsageFormatting.tokens(Int64(value))
        case .cost: WarrenUsageFormatting.money(value)
        }
    }

    private func xLabels(bars: [WarrenUsageBar]) -> some View {
        // One label a week for days, one per bar for weeks: thirty dates under
        // thirty bars collide at this width.
        let every = grouping == .day ? 7 : 1
        return GeometryReader { geometry in
            let slot = geometry.size.width / CGFloat(max(bars.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    if index % every == 0 {
                        Text(WarrenUsageFormatting.shortDayLabel(bar.firstDay))
                            .fixedSize()
                            .position(x: slot * (CGFloat(index) + 0.5), y: 7)
                    }
                }
            }
        }
        .font(WarrenTypography.settingsGroupLabel)
        .foregroundStyle(tokens.mutedForeground)
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    // MARK: Plot

    private func barWidth(slot: CGFloat) -> CGFloat {
        let preferred: CGFloat = grouping == .day ? 14 : 44
        return max(2, min(preferred, slot * 0.7))
    }

    private func barHeight(_ bar: WarrenUsageBar, top: Double) -> CGFloat {
        let value = bar.total(metric)
        guard value > 0 else { return 0 }
        // A day with any activity keeps a visible stub; rounding it to nothing
        // would draw it as the empty track.
        return max(2, plotHeight * CGFloat(value / top))
    }

    private func plot(bars: [WarrenUsageBar], scale: (top: Double, step: Double), width: CGFloat) -> some View {
        let count = max(bars.count, 1)
        let slot = width / CGFloat(count)
        let barWidth = barWidth(slot: slot)
        let readoutIndex = lastHovered.flatMap { bars.indices.contains($0) ? $0 : nil }
        let readoutAnchor: CGRect = readoutIndex.map { (index: Int) -> CGRect in
            let height = barHeight(bars[index], top: scale.top)
            return CGRect(
                x: slot * CGFloat(index) + (slot - barWidth) / 2,
                y: plotHeight - height,
                width: barWidth,
                height: height
            )
        } ?? .zero

        return ZStack(alignment: .bottomLeading) {
            Path { path in
                for value in gridValues(scale) {
                    let y = plotHeight * (1 - CGFloat(value / scale.top))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                path.move(to: CGPoint(x: 0, y: plotHeight))
                path.addLine(to: CGPoint(x: width, y: plotHeight))
            }
            .stroke(tokens.border.opacity(0.35), lineWidth: 0.5)

            ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                barColumn(
                    bar,
                    index: index,
                    height: barHeight(bar, top: scale.top),
                    width: barWidth
                )
                .offset(x: slot * CGFloat(index) + (slot - barWidth) / 2)
            }

            WarrenDesktopUsageReadoutLayer(
                content: readoutIndex.map { readoutContent(bars[$0]) },
                anchor: readoutAnchor,
                isVisible: hovered != nil,
                tokens: tokens
            )
        }
        .frame(width: width, height: plotHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let index = min(max(Int(point.x / slot), 0), bars.count - 1)
                if index >= 0, hovered != index { hover(index) }
            case .ended:
                hovered = nil
            }
        }
        .onTapGesture {
            if let hovered { activate(hovered, bars: bars) }
        }
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(-1, count: bars.count)
            case .right: step(1, count: bars.count)
            default: break
            }
        }
        .onExitCommand { hovered = nil }
        .modifier(
            WarrenUsageBarsKeyboard(isFocused: isFocused, tokens: tokens) {
                if let hovered { activate(hovered, bars: bars) }
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(grouping == .day ? "Daily" : "Weekly") \(metric == .cost ? "spend" : "tokens"), "
                + "\(bars.count) bars. Arrow keys move between them."
        )
    }

    private func barColumn(_ bar: WarrenUsageBar, index: Int, height: CGFloat, width: CGFloat) -> some View {
        let total = bar.total(metric)
        let shown = grown ? height : 0
        let isHovered = hovered == index
        let isSelected = selectedDay.map { bar.days.contains($0) } ?? false
        // Output on top, fresh input on the baseline: the order the legend
        // reads left to right, stacked bottom up.
        let stack: [WarrenUsageBucket] = Array(WarrenUsageBucket.allCases.reversed())

        return ZStack(alignment: .bottom) {
            if total > 0 {
                VStack(spacing: 0) {
                    ForEach(stack, id: \.self) { bucket in
                        Rectangle()
                            .fill(bucket.color(tokens))
                            .frame(
                                height: shown * CGFloat(
                                    bucket.value(metric, buckets: bar.buckets, cost: bar.cost) / total
                                )
                            )
                    }
                }
                .frame(width: width, height: shown, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            } else {
                // The empty track, so a quiet day reads as a day, not a gap.
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(tokens.muted.opacity(0.5))
                    .frame(width: width, height: 2)
            }
        }
        .opacity(hovered != nil && !isHovered ? 0.55 : 1)
        .background(alignment: .bottom) {
            // The ring: one on the hovered bar, and a firmer one on the bar that
            // holds the selected day, so the selection survives a sweep.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    tokens.foreground.opacity(isSelected ? 1 : 0.85),
                    lineWidth: 1.5
                )
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tokens.foreground.opacity(0.05))
                )
                .frame(width: width + 8, height: max(shown, 2) + 8)
                .offset(y: 4)
                .opacity(isHovered || isSelected ? 1 : 0)
        }
        .frame(width: width, height: plotHeight, alignment: .bottom)
        .animation(
            grown && !reduceMotion
                ? .spring(response: 0.45, dampingFraction: 0.86).delay(Double(index) * 0.014)
                : nil,
            value: grown
        )
        .animation(WarrenMotion.animation(.feedback, reduceMotion: reduceMotion), value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(bar))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activateFromAccessibility(bar) }
    }

    // MARK: Behaviour

    private func readoutContent(_ bar: WarrenUsageBar) -> WarrenUsageReadoutContent {
        let title = grouping == .day
            ? WarrenUsageFormatting.dayLabel(bar.firstDay)
            : WarrenUsageFormatting.dayRangeLabel(from: bar.firstDay, to: bar.lastDay, isPartial: bar.isPartial)
        return WarrenUsageReadoutContent.make(
            title: title,
            buckets: bar.buckets,
            cost: bar.cost,
            metric: metric,
            hint: grouping == .day ? "Click to open this day" : "Click to show its days"
        )
    }

    private func accessibilityText(_ bar: WarrenUsageBar) -> String {
        let content = readoutContent(bar)
        return ([content.title, content.total] + content.rows.map { "\($0.bucket.label) \($0.value)" })
            .joined(separator: ", ")
    }

    private func hover(_ index: Int) {
        hovered = index
        lastHovered = index
    }

    private func step(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        let current = hovered ?? (delta > 0 ? -1 : count)
        hover(min(max(current + delta, 0), count - 1))
    }

    /// A day selects that day exactly as a heatmap cell does; a week opens its
    /// days, with the readout on the first of them.
    private func activate(_ index: Int, bars: [WarrenUsageBar]) {
        guard bars.indices.contains(index) else { return }
        let bar = bars[index]
        switch grouping {
        case .day:
            selectedDay = selectedDay == bar.firstDay ? nil : bar.firstDay
        case .week:
            switchGrouping(.day)
            let dayBars = WarrenUsageBarsBuilder.build(
                days: days, fromDay: fromDay, toDay: toDay, grouping: .day
            )
            if let first = dayBars.firstIndex(where: { $0.firstDay == bar.firstDay }) {
                hover(first)
            }
        }
    }

    private func activateFromAccessibility(_ bar: WarrenUsageBar) {
        let bars = WarrenUsageBarsBuilder.build(
            days: days, fromDay: fromDay, toDay: toDay, grouping: grouping
        )
        if let index = bars.firstIndex(where: { $0.id == bar.id }) {
            activate(index, bars: bars)
        }
    }

    private func switchMetric(_ next: WarrenUsageCurveMetric) {
        guard next != metric else { return }
        metric = next
        regrow()
    }

    private func switchGrouping(_ next: WarrenUsageBarGrouping) {
        guard next != grouping else { return }
        grouping = next
        lastHovered = nil
        regrow()
    }

    /// Drops the bars to the baseline in the same update as the switch, then
    /// lets them rise one after another. Under Reduce Motion they simply swap.
    private func regrow() {
        hovered = nil
        guard !reduceMotion else { return }
        grown = false
        DispatchQueue.main.async {
            grown = true
        }
    }
}

/// Return and Space open the focused bar, and the chart draws its own focus
/// outline in place of the system ring, which is the accent colour Warren
/// keeps for live state. Both need macOS 14; before it the system ring stays
/// and the bars open by click or VoiceOver action.
private struct WarrenUsageBarsKeyboard: ViewModifier {
    let isFocused: Bool
    let tokens: WarrenColorTokens
    let activate: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusEffectDisabled()
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(tokens.focusRing, lineWidth: 1)
                        .padding(-4)
                        .opacity(isFocused ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .onKeyPress(.return) {
                    activate()
                    return .handled
                }
                .onKeyPress(.space) {
                    activate()
                    return .handled
                }
        } else {
            content
        }
    }
}
