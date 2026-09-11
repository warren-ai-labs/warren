import SwiftUI
import WarrenDesignSystem

/// A single day's intraday token curve. The Host sends durable 5-minute
/// buckets; this view can merge them into one-hour points without another
/// network request.
public struct WarrenDesktopUsageCurveView: View {
    let intervals: [WarrenUsageInterval]
    let day: String?
    let baseBucketMinutes: Int
    let tokens: WarrenColorTokens
    @Binding var granularity: WarrenUsageCurveGranularity

    public init(
        intervals: [WarrenUsageInterval],
        day: String?,
        baseBucketMinutes: Int = 5,
        tokens: WarrenColorTokens,
        granularity: Binding<WarrenUsageCurveGranularity>
    ) {
        self.intervals = intervals
        self.day = day
        self.baseBucketMinutes = baseBucketMinutes
        self.tokens = tokens
        self._granularity = granularity
    }

    private var points: [WarrenUsageCurvePoint] {
        guard let day else { return [] }
        return WarrenUsageCurveBuilder.build(
            intervals: intervals,
            day: day,
            granularity: granularity,
            baseBucketMinutes: baseBucketMinutes
        )
    }

    private var activePoints: [WarrenUsageCurvePoint] {
        points.filter { $0.tokens > 0 }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            header
            if day == nil || activePoints.isEmpty {
                Text("No intraday usage recorded for this day.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 150, alignment: .center)
            } else {
                chart
            }
        }
        .padding(WarrenSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .accessibilityIdentifier("usage.curve")
    }

    private var header: some View {
        HStack(spacing: WarrenSpacing.small) {
            VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                Text("Daily usage curve")
                    .font(WarrenTypography.settingsBodyEmphasis)
                if let day {
                    Text(WarrenUsageFormatting.dayLabel(day))
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.mutedForeground)
                } else {
                    Text("Select a day in the heatmap")
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            Spacer(minLength: 0)
            Picker("Granularity", selection: $granularity) {
                ForEach(WarrenUsageCurveGranularity.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .accessibilityIdentifier("usage.curve.granularity")
        }
    }

    private var chart: some View {
        let peak = max(points.map(\.tokens).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(alignment: .top, spacing: WarrenSpacing.xs) {
                axisLabels(peak: peak)
                GeometryReader { geometry in
                    plot(geometry: geometry, peak: peak)
                }
                .frame(height: 150)
            }
            timeLabels
        }
        .help(chartHelp(peak: peak))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel(peak: peak))
    }

    private func axisLabels(peak: Int64) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(WarrenUsageFormatting.tokens(peak))
            Spacer(minLength: 0)
            Text(WarrenUsageFormatting.tokens(peak / 2))
            Spacer(minLength: 0)
            Text("0")
        }
        .font(WarrenTypography.settingsGroupLabel)
        .foregroundStyle(tokens.mutedForeground)
        .frame(width: 42, height: 150, alignment: .trailing)
    }

    private func plot(geometry: GeometryProxy, peak: Int64) -> some View {
        let width = max(geometry.size.width, 1)
        let height = max(geometry.size.height, 1)
        let active = points
        let line = curvePath(points: active, width: width, height: height, peak: peak)
        let area = areaPath(points: active, width: width, height: height, peak: peak)

        return ZStack(alignment: .topLeading) {
            gridPath(width: width, height: height)
                .stroke(tokens.muted.opacity(0.5), lineWidth: 0.5)
            area.fill(tokens.highlight.opacity(0.14))
            line.stroke(
                tokens.highlight,
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
            ForEach(active.filter { $0.tokens > 0 }) { point in
                Circle()
                    .fill(tokens.highlight)
                    .frame(width: 4, height: 4)
                    .position(
                        x: x(for: point.minute, width: width),
                        y: y(for: point.tokens, height: height, peak: peak)
                    )
            }
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
    }

    private var timeLabels: some View {
        HStack(spacing: 0) {
            Text("00:00")
            Spacer(minLength: 0)
            Text("06:00")
            Spacer(minLength: 0)
            Text("12:00")
            Spacer(minLength: 0)
            Text("18:00")
            Spacer(minLength: 0)
            Text("24:00")
        }
        .font(WarrenTypography.settingsGroupLabel)
        .foregroundStyle(tokens.mutedForeground)
        .padding(.leading, 47)
    }

    private func gridPath(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            for fraction in [0.0, 0.5, 1.0] {
                let y = height * CGFloat(fraction)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
    }

    private func curvePath(
        points: [WarrenUsageCurvePoint],
        width: CGFloat,
        height: CGFloat,
        peak: Int64
    ) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(
                to: CGPoint(
                    x: x(for: first.minute, width: width),
                    y: y(for: first.tokens, height: height, peak: peak)
                )
            )
            for point in points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: x(for: point.minute, width: width),
                        y: y(for: point.tokens, height: height, peak: peak)
                    )
                )
            }
        }
    }

    private func areaPath(
        points: [WarrenUsageCurvePoint],
        width: CGFloat,
        height: CGFloat,
        peak: Int64
    ) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: x(for: first.minute, width: width), y: height))
            path.addLine(
                to: CGPoint(
                    x: x(for: first.minute, width: width),
                    y: y(for: first.tokens, height: height, peak: peak)
                )
            )
            for point in points.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: x(for: point.minute, width: width),
                        y: y(for: point.tokens, height: height, peak: peak)
                    )
                )
            }
            path.addLine(to: CGPoint(x: x(for: last.minute, width: width), y: height))
            path.closeSubpath()
        }
    }

    private func x(for minute: Int, width: CGFloat) -> CGFloat {
        width * CGFloat(minute) / 1_440
    }

    private func y(for tokens: Int64, height: CGFloat, peak: Int64) -> CGFloat {
        height * (1 - CGFloat(tokens) / CGFloat(peak))
    }

    private func chartHelp(peak: Int64) -> String {
        guard let day else { return "No intraday usage recorded" }
        return "\(WarrenUsageFormatting.dayLabel(day))\n"
            + "Peak \(WarrenUsageFormatting.exact(peak)) tokens\n"
            + "\(granularity.label) buckets"
    }

    private func chartAccessibilityLabel(peak: Int64) -> String {
        guard let day else { return "Daily usage curve, no day selected" }
        return "Daily usage curve for \(WarrenUsageFormatting.dayLabel(day)), "
            + "peak \(WarrenUsageFormatting.exact(peak)) tokens, "
            + granularity.label
    }
}
