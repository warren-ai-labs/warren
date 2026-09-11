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

    init(heatmap: WarrenUsageHeatmap, tokens: WarrenColorTokens, selectedDay: Binding<String?>) {
        self.heatmap = heatmap
        self.tokens = tokens
        self._selectedDay = selectedDay
        var index: [Int: WarrenUsageHeatmapCell] = [:]
        index.reserveCapacity(heatmap.cells.count)
        for cell in heatmap.cells {
            index[cell.week * 7 + cell.weekday] = cell
        }
        self.cellsByPosition = index
    }

    /// Cell edge and gap. Sized so a full year fits the settings content width
    /// without horizontal scrolling.
    private let cellSize: CGFloat = 11
    private let cellGap: CGFloat = 3
    private let weekdayLabelWidth: CGFloat = 24

    private var columnWidth: CGFloat { cellSize + cellGap }

    var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            monthHeader
            HStack(alignment: .top, spacing: cellGap) {
                weekdayLabels
                grid
            }
            legend
        }
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
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(fill)
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            }
            .onHover { isHovered = $0 }
            .onTapGesture(perform: onSelect)
            .help(tooltip)
            .accessibilityElement()
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("usage.heatmap.cell.\(cell.day)")
    }

    private var fill: Color {
        guard let intensity = cell.intensity else {
            return tokens.muted.opacity(0.5)
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

    private var tooltip: String {
        let day = WarrenUsageFormatting.dayLabel(cell.day)
        guard cell.tokens > 0 else { return "\(day) — no activity" }
        var lines = [
            day,
            "\(WarrenUsageFormatting.exact(cell.tokens)) tokens",
            WarrenUsageFormatting.money(cell.cost),
        ]
        if let reason = WarrenUsageFormatting.incompleteReason(cell.cost) {
            lines.append(reason)
        }
        return lines.joined(separator: "\n")
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
