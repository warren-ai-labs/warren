import SwiftUI
import WarrenDesignSystem

/// A single day's intraday curve. The Host sends durable 5-minute buckets for
/// the selected day; this view can merge them into one-hour points, and plot
/// either tokens or the equivalent cost, without another network request.
public struct WarrenDesktopUsageCurveView: View {
    let intervals: [WarrenUsageInterval]
    let day: String?
    let baseBucketMinutes: Int
    let tokens: WarrenColorTokens
    @Binding var granularity: WarrenUsageCurveGranularity
    @Binding var metric: WarrenUsageCurveMetric
    /// Names the active filter, so a narrowed curve says what it is showing
    /// rather than looking like a quiet day.
    let scopeLabel: String?
    /// Keeps the rows the active filter selects.
    let include: ((WarrenUsageInterval) -> Bool)?

    @State private var hoveredMinute: Int? = nil

    public init(
        intervals: [WarrenUsageInterval],
        day: String?,
        baseBucketMinutes: Int = 5,
        tokens: WarrenColorTokens = .dark,
        granularity: Binding<WarrenUsageCurveGranularity>,
        metric: Binding<WarrenUsageCurveMetric>,
        scopeLabel: String? = nil,
        include: ((WarrenUsageInterval) -> Bool)? = nil
    ) {
        self.intervals = intervals
        self.day = day
        self.baseBucketMinutes = baseBucketMinutes
        self.tokens = tokens
        self._granularity = granularity
        self._metric = metric
        self.scopeLabel = scopeLabel
        self.include = include
    }

    private var isViewingToday: Bool {
        guard let day else { return true }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return day == formatter.string(from: Date())
    }

    private var currentMinuteOfDay: Int {
        let calendar = Calendar.current
        let now = Date()
        let h = calendar.component(.hour, from: now)
        let m = calendar.component(.minute, from: now)
        return h * 60 + m
    }

    private var effectiveMaxMinute: Int {
        if isViewingToday {
            let step = granularity.rawValue
            let nowMinute = currentMinuteOfDay
            let rounded = max(60, ((nowMinute + step - 1) / step) * step)
            return min(1_440, rounded)
        }
        return 1_440
    }

    /// The slice of the clock the chart actually draws. A day's work rarely fills
    /// 24 hours, and stretching the axis to midnight-to-midnight spends most of
    /// the width on a flat zero line, so the window closes in on the active span
    /// and snaps to a tick that labels cleanly.
    private struct CurveWindow {
        let start: Int
        let end: Int
        let tick: Int

        var span: Int { max(end - start, 1) }
        var ticks: [Int] { Array(stride(from: start, through: end, by: tick)) }
    }

    private func curveWindow(active: [WarrenUsageCurvePoint]) -> CurveWindow {
        let ceiling = effectiveMaxMinute
        guard let first = active.first?.minute, let last = active.last?.minute else {
            return snapped(start: 0, end: ceiling)
        }
        // One empty bucket of margin so the curve visibly rises from and returns
        // to zero instead of being cut off at the frame edge.
        let step = granularity.rawValue
        var low = max(0, first - step)
        var high = min(ceiling, last + step)
        // A few minutes of activity stretched across the full width reads as a
        // spike out of nowhere; keep at least two hours of context.
        if high - low < 120 {
            low = max(0, high - 120)
            high = min(ceiling, low + 120)
        }
        return snapped(start: low, end: high)
    }

    private func snapped(start: Int, end: Int) -> CurveWindow {
        let span = max(end - start, 1)
        var tick = 360
        for candidate in [30, 60, 120, 180, 240] where span <= candidate * 6 {
            tick = candidate
            break
        }
        let low = (start / tick) * tick
        let high = min(1_440, max(low + tick, ((end + tick - 1) / tick) * tick))
        return CurveWindow(start: low, end: high, tick: tick)
    }

    private var points: [WarrenUsageCurvePoint] {
        guard let day else { return [] }
        return WarrenUsageCurveBuilder.build(
            intervals: intervals,
            day: day,
            granularity: granularity,
            baseBucketMinutes: baseBucketMinutes,
            untilMinute: isViewingToday ? effectiveMaxMinute : nil,
            include: include
        )
    }

    public var body: some View {
        let allPoints = points
        let active = allPoints.filter { value(of: $0) > 0 }
        let peak = max(active.map { value(of: $0) }.max() ?? 0, 1)
        let hoveredPoint = closestPoint(in: active, to: hoveredMinute)

        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            header(hoveredPoint: hoveredPoint, active: active, peak: peak)
            if day == nil || active.isEmpty {
                // A filtered curve that came back empty is a different fact from a
                // quiet day, and conflating them makes the filter look broken.
                Text(scopeLabel.map { "No intraday usage for \($0) on this day." }
                    ?? "No intraday usage recorded for this day.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 150, alignment: .center)
            } else {
                let window = curveWindow(active: active)
                chart(
                    allPoints: allPoints.filter { $0.minute >= window.start && $0.minute <= window.end },
                    active: active,
                    peak: peak,
                    hoveredPoint: hoveredPoint,
                    window: window
                )
            }
        }
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
        .accessibilityIdentifier("usage.curve")
    }

    private func header(
        hoveredPoint: WarrenUsageCurvePoint?,
        active: [WarrenUsageCurvePoint],
        peak: Double
    ) -> some View {
        HStack(alignment: .center, spacing: WarrenSpacing.small) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                HStack(spacing: WarrenSpacing.xs) {
                    Text(scopeLabel.map { "Intraday Timeline · \($0)" } ?? "Intraday Timeline")
                        .font(WarrenTypography.settingsBodyEmphasis)
                        .foregroundStyle(tokens.foreground)

                    if let hoveredPoint {
                        Text("·  \(minuteLabel(hoveredPoint.minute)): \(axisLabel(value(of: hoveredPoint)))")
                            .font(WarrenTypography.settingsMeta)
                            .foregroundStyle(tokens.highlight)
                            .monospacedDigit()
                    }
                }

                if let day {
                    Text("\(WarrenUsageFormatting.dayLabel(day)) · Peak \(peakLabel(for: peak))")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                } else {
                    Text("Select a day in the heatmap to view hourly distribution")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }
            }

            Spacer(minLength: 0)

            Picker("Metric", selection: $metric) {
                ForEach(WarrenUsageCurveMetric.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .accessibilityIdentifier("usage.curve.metric")

            Picker("Granularity", selection: $granularity) {
                ForEach(WarrenUsageCurveGranularity.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            .accessibilityIdentifier("usage.curve.granularity")
        }
    }

    private func peakLabel(for peak: Double) -> String {
        metric == .tokens
            ? "\(WarrenUsageFormatting.tokens(Int64(peak))) tokens"
            : WarrenUsageFormatting.money(peak)
    }

    private func chart(
        allPoints: [WarrenUsageCurvePoint],
        active: [WarrenUsageCurvePoint],
        peak: Double,
        hoveredPoint: WarrenUsageCurvePoint?,
        window: CurveWindow
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(alignment: .top, spacing: WarrenSpacing.xs) {
                axisLabels(peak: peak)
                GeometryReader { geometry in
                    plot(
                        geometry: geometry,
                        allPoints: allPoints,
                        active: active,
                        peak: peak,
                        hovered: hoveredPoint,
                        window: window
                    )
                }
                .frame(height: 150)
            }
            timeLabels(window: window)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: metric)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: granularity)
        .help(chartHelp(peak: peak))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel(peak: peak))
    }

    private func axisLabels(peak: Double) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(axisLabel(peak))
            Spacer(minLength: 0)
            Text(axisLabel(peak / 2))
            Spacer(minLength: 0)
            Text("0")
        }
        .font(WarrenTypography.settingsGroupLabel)
        .foregroundStyle(tokens.mutedForeground)
        .monospacedDigit()
        .frame(width: 48, height: 150, alignment: .trailing)
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .tokens: WarrenUsageFormatting.tokens(Int64(value))
        case .cost: WarrenUsageFormatting.money(value)
        }
    }

    private func minuteLabel(_ minute: Int) -> String {
        let h = minute / 60
        let m = minute % 60
        return String(format: "%02d:%02d", h, m)
    }

    private func closestPoint(in points: [WarrenUsageCurvePoint], to minute: Int?) -> WarrenUsageCurvePoint? {
        guard let minute, !points.isEmpty else { return nil }
        var best: WarrenUsageCurvePoint? = nil
        var bestDiff = Int.max
        for pt in points {
            let diff = abs(pt.minute - minute)
            if diff < bestDiff {
                bestDiff = diff
                best = pt
            }
        }
        return best
    }

    private func plot(
        geometry: GeometryProxy,
        allPoints: [WarrenUsageCurvePoint],
        active: [WarrenUsageCurvePoint],
        peak: Double,
        hovered: WarrenUsageCurvePoint?,
        window: CurveWindow
    ) -> some View {
        let width = max(geometry.size.width, 1)
        let height = max(geometry.size.height, 1)
        let line = curvePath(points: allPoints, width: width, height: height, peak: peak, window: window)
        let area = areaPath(points: allPoints, width: width, height: height, peak: peak, window: window)

        return ZStack(alignment: .topLeading) {
            gridPath(width: width, height: height, window: window)
                .stroke(tokens.muted.opacity(0.35), lineWidth: 0.5)

            area.fill(
                LinearGradient(
                    colors: [
                        tokens.highlight.opacity(0.32),
                        tokens.highlight.opacity(0.08),
                        tokens.highlight.opacity(0.01)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            line.stroke(
                tokens.highlight,
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )

            ForEach(active) { point in
                Circle()
                    .fill(tokens.highlight)
                    .frame(width: 4, height: 4)
                    .position(
                        x: x(for: point.minute, width: width, window: window),
                        y: y(for: value(of: point), height: height, peak: peak)
                    )
            }

            if let hovered {
                let hx = x(for: hovered.minute, width: width, window: window)
                let hy = y(for: value(of: hovered), height: height, peak: peak)

                Path { p in
                    p.move(to: CGPoint(x: hx, y: 0))
                    p.addLine(to: CGPoint(x: hx, y: height))
                }
                .stroke(tokens.highlight.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Circle()
                    .fill(tokens.highlight)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(tokens.background, lineWidth: 1.5))
                    .position(x: hx, y: hy)
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let fraction = max(0, min(1, value.location.x / width))
                    hoveredMinute = window.start + Int(fraction * CGFloat(window.span))
                }
                .onEnded { _ in
                    hoveredMinute = nil
                }
        )
    }

    private func timeLabels(window: CurveWindow) -> some View {
        let ticks = window.ticks
        return HStack(spacing: 0) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { index, minute in
                Text(minuteLabel(minute))
                if index < ticks.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .font(WarrenTypography.settingsGroupLabel)
        .foregroundStyle(tokens.mutedForeground)
        .monospacedDigit()
        .padding(.leading, 52)
    }

    private func gridPath(width: CGFloat, height: CGFloat, window: CurveWindow) -> Path {
        Path { path in
            for fraction in [0.0, 0.5, 1.0] {
                let y = height * CGFloat(fraction)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
            // One line per time label, so a point can be read back to a clock time.
            for minute in window.ticks.dropFirst().dropLast() {
                let x = x(for: minute, width: width, window: window)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))
            }
        }
    }

    private func curvePath(
        points: [WarrenUsageCurvePoint],
        width: CGFloat,
        height: CGFloat,
        peak: Double,
        window: CurveWindow
    ) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(
                to: CGPoint(
                    x: x(for: first.minute, width: width, window: window),
                    y: y(for: value(of: first), height: height, peak: peak)
                )
            )
            for point in points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: x(for: point.minute, width: width, window: window),
                        y: y(for: value(of: point), height: height, peak: peak)
                    )
                )
            }
        }
    }

    private func areaPath(
        points: [WarrenUsageCurvePoint],
        width: CGFloat,
        height: CGFloat,
        peak: Double,
        window: CurveWindow
    ) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: x(for: first.minute, width: width, window: window), y: height))
            path.addLine(
                to: CGPoint(
                    x: x(for: first.minute, width: width, window: window),
                    y: y(for: value(of: first), height: height, peak: peak)
                )
            )
            for point in points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: x(for: point.minute, width: width, window: window),
                        y: y(for: value(of: point), height: height, peak: peak)
                    )
                )
            }
            path.addLine(to: CGPoint(x: x(for: last.minute, width: width, window: window), y: height))
            path.closeSubpath()
        }
    }

    private func value(of point: WarrenUsageCurvePoint) -> Double {
        switch metric {
        case .tokens: Double(point.tokens)
        case .cost: point.cost.usd
        }
    }

    private func x(for minute: Int, width: CGFloat, window: CurveWindow) -> CGFloat {
        width * CGFloat(minute - window.start) / CGFloat(window.span)
    }

    private func y(for value: Double, height: CGFloat, peak: Double) -> CGFloat {
        height * (1 - CGFloat(value) / CGFloat(peak))
    }

    private func chartHelp(peak: Double) -> String {
        guard let day else { return "No intraday usage recorded" }
        return "\(WarrenUsageFormatting.dayLabel(day))\n"
            + "Peak \(axisLabel(peak))\n"
            + "\(granularity.label) buckets"
    }

    private func chartAccessibilityLabel(peak: Double) -> String {
        guard let day else { return "Daily usage curve, no day selected" }
        return "Daily usage curve for \(WarrenUsageFormatting.dayLabel(day)), "
            + "\(metric.label), peak \(axisLabel(peak)), "
            + granularity.label
    }
}
