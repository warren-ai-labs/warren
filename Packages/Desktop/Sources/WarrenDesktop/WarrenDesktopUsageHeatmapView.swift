import SwiftUI
import WarrenDesignSystem

/// The calendar grid of daily token usage.
///
/// Shades come from the Ember highlight rather than a green ramp: green reads as
/// success in a developer tool, which is the wrong connotation for spend.
struct WarrenDesktopUsageHeatmapView: View {
    let heatmap: WarrenUsageHeatmap
    let tokens: WarrenColorTokens
    @Binding var selectedDay: String?

    /// Cells indexed by grid position.
    ///
    /// Built once per heatmap because the grid asks for every one of its ~371
    /// positions on each render; scanning the cell array for each of those would
    /// be tens of thousands of comparisons per frame, on a view that re-renders
    /// whenever the pointer enters a cell.
    private let cellsByPosition: [Int: WarrenUsageHeatmapCell]
    private let cellsByDay: [String: WarrenUsageHeatmapCell]
    /// Held in `@State` as a plain reference, so hover never re-renders the grid;
    /// only the readout layer observes it.
    @State private var hoverTracker = WarrenUsageHoverTracker()

    init(heatmap: WarrenUsageHeatmap, tokens: WarrenColorTokens, selectedDay: Binding<String?>) {
        self.heatmap = heatmap
        self.tokens = tokens
        self._selectedDay = selectedDay
        var index: [Int: WarrenUsageHeatmapCell] = [:]
        var byDay: [String: WarrenUsageHeatmapCell] = [:]
        index.reserveCapacity(heatmap.cells.count)
        byDay.reserveCapacity(heatmap.cells.count)
        for cell in heatmap.cells {
            index[cell.week * 7 + cell.weekday] = cell
            byDay[cell.day] = cell
        }
        self.cellsByPosition = index
        self.cellsByDay = byDay
    }

    /// The width the card gives the calendar, measured rather than assumed.
    ///
    /// The cell edge used to be a fixed 11pt sized for one settings width, so a
    /// year (53 columns, ~770pt) overflowed the card whenever the column was
    /// narrower and sat in a corner of it whenever the window was wider.
    @State private var availableWidth: CGFloat = 0

    private let weekdayLabelWidth: CGFloat = 24

    /// Cell edge: the columns share the measured width, within a range where a
    /// cell is still a target and a short range does not turn into tiles.
    private var cellSize: CGFloat {
        let weeks = CGFloat(max(heatmap.weekCount, 1))
        guard availableWidth > 0 else { return 11 }
        let room = availableWidth - weekdayLabelWidth - 3
        let fitted = (room / weeks - 3).rounded(.down)
        return min(max(fitted, 6), 16)
    }

    /// Narrow cells get a narrower gap, so the shade still outweighs the space.
    private var cellGap: CGFloat { cellSize < 9 ? 2 : 3 }

    private var columnWidth: CGFloat { cellSize + cellGap }

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            monthHeader
            HStack(alignment: .top, spacing: cellGap) {
                weekdayLabels
                grid
            }
            .overlay {
                WarrenDesktopUsageHeatmapReadout(
                    tracker: hoverTracker,
                    cellsByDay: cellsByDay,
                    tokens: tokens,
                    gridOrigin: weekdayLabelWidth + cellGap,
                    cellSize: cellSize,
                    columnWidth: columnWidth
                )
            }
            // Above the legend, which the readout may overhang.
            .zIndex(1)
            legend
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .warrenMeasureWidth($availableWidth)
    }

    private var monthHeader: some View {
        ZStack(alignment: .topLeading) {
            // A clear track keeps the header's height stable when a range has
            // too few columns to carry any label.
            Color.clear.frame(height: 12)
            ForEach(heatmap.monthLabels) { label in
                Text(label.text)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .offset(x: weekdayLabelWidth + cellGap + CGFloat(label.week) * columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var weekdayLabels: some View {
        VStack(alignment: .trailing, spacing: cellGap) {
            ForEach(0..<7, id: \.self) { row in
                // Label alternate rows only; at 11pt every row would collide.
                Text(row % 2 == 1 ? weekdayName(row) : "")
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(width: weekdayLabelWidth, height: cellSize, alignment: .trailing)
            }
        }
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: cellGap) {
            ForEach(0..<max(heatmap.weekCount, 0), id: \.self) { week in
                VStack(spacing: cellGap) {
                    ForEach(0..<7, id: \.self) { weekday in
                        if let cell = cell(week: week, weekday: weekday) {
                            WarrenDesktopUsageHeatmapCellView(
                                cell: cell,
                                size: cellSize,
                                tokens: tokens,
                                isSelected: selectedDay == cell.day,
                                hoverTracker: hoverTracker,
                                onSelect: {
                                    // Toggle so clicking the same cell returns
                                    // the detail strip to the range summary.
                                    selectedDay = selectedDay == cell.day ? nil : cell.day
                                }
                            )
                        } else {
                            // Padding outside the range keeps columns aligned.
                            Color.clear.frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: WarrenSpacing.small) {
            Spacer(minLength: 0)
            Text("Less")
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.mutedForeground)
            ForEach(0...WarrenUsageHeatmapBuilder.shadeCount, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(
                        step == 0
                            ? tokens.muted.opacity(0.5)
                            : shade(for: Double(step) / Double(WarrenUsageHeatmapBuilder.shadeCount))
                    )
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More")
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.mutedForeground)
        }
    }

    private func cell(week: Int, weekday: Int) -> WarrenUsageHeatmapCell? {
        cellsByPosition[week * 7 + weekday]
    }

    private func shade(for intensity: Double) -> Color {
        // Opacity ramp on one hue: a multi-hue scale would imply categories
        // where this is a single continuous quantity.
        tokens.highlight.opacity(0.25 + 0.75 * intensity)
    }

    private func weekdayName(_ row: Int) -> String {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols
        let index = (calendar.firstWeekday - 1 + row) % 7
        return symbols.indices.contains(index) ? symbols[index] : ""
    }
}

/// One day cell. Split out so hover state stays local to the cell instead of
/// invalidating the whole grid on every pointer move.
private struct WarrenDesktopUsageHeatmapCellView: View {
    let cell: WarrenUsageHeatmapCell
    let size: CGFloat
    let tokens: WarrenColorTokens
    let isSelected: Bool
    /// Reported to, never observed: the cell keeps its own hover for its edge.
    let hoverTracker: WarrenUsageHoverTracker
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .onHover { inside in
                isHovered = inside
                hoverTracker.hover(cell.day, isInside: inside)
            }
            .onTapGesture(perform: onSelect)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("usage.heatmap.cell.\(cell.day)")
    }

    private var fill: Color {
        guard let intensity = cell.intensity else {
            return colorScheme == .light ? tokens.muted : tokens.muted.opacity(0.5)
        }
        return tokens.highlight.opacity(0.25 + 0.75 * intensity)
    }

    private var borderColor: Color {
        if isSelected { return tokens.foreground }
        if isHovered { return tokens.foreground.opacity(0.5) }
        // A dashed-looking edge is not available on a stroke this thin, so an
        // incomplete day is marked with a visible outline instead.
        if cell.hasIncompleteCost { return tokens.warning.opacity(0.7) }
        return .clear
    }

    private var borderWidth: CGFloat {
        isSelected ? 1.5 : 1
    }

    private var accessibilityText: String {
        guard cell.tokens > 0 else {
            return "\(WarrenUsageFormatting.dayLabel(cell.day)), no activity"
        }
        return "\(WarrenUsageFormatting.dayLabel(cell.day)), "
            + "\(WarrenUsageFormatting.exact(cell.tokens)) tokens, "
            + WarrenUsageFormatting.money(cell.cost)
    }
}

/// The heatmap's gliding readout: the same card the daily bars use, beside the
/// hovered cell. Kept apart from the grid so only this layer redraws on hover.
private struct WarrenDesktopUsageHeatmapReadout: View {
    @ObservedObject var tracker: WarrenUsageHoverTracker
    let cellsByDay: [String: WarrenUsageHeatmapCell]
    let tokens: WarrenColorTokens
    /// Where the first grid column starts, past the weekday labels.
    let gridOrigin: CGFloat
    let cellSize: CGFloat
    let columnWidth: CGFloat

    var body: some View {
        let cell = tracker.last.flatMap { cellsByDay[$0] }
        WarrenDesktopUsageReadoutLayer(
            content: cell.map { cell in
                // Tokens, because tokens are what the cell's shade encodes.
                WarrenUsageReadoutContent.make(
                    title: WarrenUsageFormatting.dayLabel(cell.day),
                    buckets: cell.buckets,
                    cost: cell.cost,
                    metric: .tokens,
                    hint: "Click to open this day"
                )
            },
            anchor: cell.map { cell in
                CGRect(
                    x: gridOrigin + CGFloat(cell.week) * columnWidth,
                    y: CGFloat(cell.weekday) * columnWidth,
                    width: cellSize,
                    height: cellSize
                )
            } ?? .zero,
            isVisible: tracker.hovered != nil,
            tokens: tokens
        )
    }
}
