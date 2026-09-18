import SwiftUI
import WarrenDesignSystem

/// Selectable ranges for the usage panel.
public enum WarrenUsageRange: String, CaseIterable, Identifiable, Sendable {
    case week = "7d"
    case month = "30d"
    case quarter = "90d"
    case year = "1y"

    public var id: String { rawValue }

    public var days: Int {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    public var label: String {
        switch self {
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "Year"
        }
    }
}

/// Load state, so the panel can tell "nothing recorded yet" apart from
/// "not fetched yet" and from an outright failure.
public enum WarrenUsageLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Which part of Usage a settings page should render.
public enum WarrenUsagePanelMode: Sendable {
    /// Range totals, the activity heatmap, and the range breakdowns.
    case overview
    /// One day: its intraday curve and its own breakdowns.
    case detail
}

/// The Usage panels.
///
/// One view drives both settings surfaces so the range picker, heatmap, and
/// day scoping have a single implementation. The Overview heatmap and the
/// Detail heatmap are the same control: picking a day in either one selects it,
/// so there is never a day the UI shows but cannot fetch.
public struct WarrenDesktopUsagePanel: View {
    let stats: WarrenUsageStats
    let state: WarrenUsageLoadState
    let tokens: WarrenColorTokens
    @Binding var range: WarrenUsageRange
    /// The day the person picked, or nil to follow the Host's most recent day.
    @Binding var selectedDay: String?
    /// Requests a fetch for a day range and an optional detail day.
    let onLoad: (_ days: Int, _ day: String?, _ force: Bool) -> Void
    /// Switches to the detail surface. Overview uses it to open the day the
    /// person clicked instead of leaving the click inert.
    let onOpenDetail: ((String) -> Void)?
    let mode: WarrenUsagePanelMode

    @State private var curveGranularity: WarrenUsageCurveGranularity = .halfHour
    @State private var curveMetric: WarrenUsageCurveMetric = .tokens
    @State private var selectedAgentFilter: String? = nil
    @State private var selectedModelFilter: String? = nil

    /// Rows shown per breakdown card before the rest collapse into a count.
    ///
    /// Four, because the three cards share one height: Agents and projects rarely
    /// exceed four, so a taller model list only buys blank space in its
    /// neighbours. Five left the Agent card with ~400pt of nothing under it.
    private let breakdownRowLimit = 4

    public init(
        stats: WarrenUsageStats,
        state: WarrenUsageLoadState,
        tokens: WarrenColorTokens,
        range: Binding<WarrenUsageRange>,
        selectedDay: Binding<String?>,
        onLoad: @escaping (_ days: Int, _ day: String?, _ force: Bool) -> Void,
        onOpenDetail: ((String) -> Void)? = nil,
        mode: WarrenUsagePanelMode = .detail
    ) {
        self.stats = stats
        self.state = state
        self.tokens = tokens
        self._range = range
        self._selectedDay = selectedDay
        self.onLoad = onLoad
        self.onOpenDetail = onOpenDetail
        self.mode = mode
    }

    private var heatmap: WarrenUsageHeatmap {
        WarrenUsageHeatmapBuilder.build(
            days: stats.days, fromDay: stats.fromDay, toDay: stats.toDay
        )
    }

    /// The day every detail surface renders. Falls back to the Host's default
    /// so the curve has something to draw before a day is picked.
    private var detailDay: String? {
        stats.resolvedDetailDay(selected: selectedDay)
    }

    private var detailDayStats: WarrenUsageDay? {
        guard let detailDay else { return nil }
        return stats.days.first { $0.day == detailDay }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.large) {
            rangePicker
            switch state {
            case .failed(let message):
                failureNotice(message)
            case .loading where stats.isEmpty:
                placeholder("Loading usage…")
            case .idle where stats.isEmpty:
                placeholder("Loading usage…")
            default:
                if stats.isEmpty {
                    placeholder("No Agent token usage recorded in this range.")
                } else {
                    content
                }
            }
        }
        .onChange(of: range) { _ in
            selectedDay = nil
            onLoad(range.days, nil, false)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .overview:
            overviewContent
        case .detail:
            detailContent
        }
    }

    // MARK: - Overview

    private var overviewContent: some View {
        // One spacing step between cards, not two. The previous xlarge gap put as
        // much air between two cards as inside one, and left the calendar hint
        // floating in it, belonging to neither neighbour.
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            summaryGrid
            completenessNotice
            compositionCard
            heatmapCard(subtitle: heatmapSubtitle)
            breakdowns(providers: stats.providers, models: stats.models, projects: stats.projects)
            footnote
        }
    }

    /// Where the range's tokens and its money went, which are not the same shape.
    ///
    /// The Overview used to show four totals and no composition at all, so the
    /// obvious question after "$1,480 this year" -- on what -- had no answer
    /// without opening a single day.
    private var compositionCard: some View {
        let buckets = activeFilteredBuckets
        let cost = activeFilteredCost
        return VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            // No subtitle: the two bars are labelled "Tokens" and "Cost", so a line
            // saying it is a token mix with each class's share of cost only repeats
            // what the rows already say. The filter, when there is one, is the
            // exception -- that is a fact the card cannot show otherwise.
            HStack(spacing: WarrenSpacing.xs) {
                Text("Composition")
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.foreground)
                if let activeFilterLabel {
                    Text("· \(activeFilterLabel)")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            if activeFilterIsEmpty {
                Text("\(activeFilterLabel ?? "This selection") recorded no usage in this range.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
            } else {
                bucketBars(buckets, cost: cost)
                bucketLegend(buckets, cost: cost)
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
        .accessibilityIdentifier("usage.composition")
    }

    /// Nil unless the grid disagrees with the cards above it.
    ///
    /// The calendar always shows every Agent and model, because the Host sends one
    /// total per day rather than a per-model breakdown for each. Saying so while a
    /// filter is on is the honest option; saying "daily activity across the
    /// selected range" when nothing is filtered describes a calendar to someone
    /// looking at one, and the range itself is already printed beside it.
    private var heatmapSubtitle: String? {
        activeFilterLabel.map { "All Agents and models, not just \($0)" }
    }

    // MARK: - Detail

    private var detailContent: some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            detailStrip
            completenessNotice
            WarrenDesktopUsageCurveView(
                intervals: stats.intervals,
                day: detailDay,
                baseBucketMinutes: stats.intervalBucketMinutes,
                tokens: tokens,
                granularity: $curveGranularity,
                metric: $curveMetric,
                // The filter narrows the curve rather than only tinting a chip.
                // The Host sends one row per Agent and model per bucket, so this
                // is the same day summed over fewer rows, not another request.
                scopeLabel: activeFilterLabel,
                include: intervalMatchesFilter
            )
            dayBreakdowns
            footnote
        }
    }

    private var detailStrip: some View {
        // Filtered figures, so the strip agrees with the curve and the breakdown
        // rows underneath it rather than describing a day the filter excluded.
        let buckets = activeFilteredBuckets
        let cost = activeFilteredCost
        let dayTitle = detailDay.map { WarrenUsageFormatting.dayLabel($0) }
            ?? "\(range.label) total"
        let title = activeFilterLabel.map { "\(dayTitle) · \($0)" } ?? dayTitle
        let share = buckets.cacheHitRate.map(WarrenUsageFormatting.percent) ?? "—"

        return VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            HStack(alignment: .center, spacing: WarrenSpacing.small) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    HStack(spacing: WarrenSpacing.xs) {
                        Circle()
                            .fill(tokens.highlight)
                            .frame(width: 7, height: 7)
                        Text(title)
                            .font(WarrenTypography.settingsBodyEmphasis)
                            .foregroundStyle(tokens.foreground)

                        if let curDay = detailDay, let idx = stats.days.firstIndex(where: { $0.day == curDay }), stats.days.count > 1 {
                            HStack(spacing: 2) {
                                Button {
                                    if idx > 0 {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            selectedDay = stats.days[idx - 1].day
                                        }
                                        onLoad(range.days, selectedDay, false)
                                    }
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 9, weight: .regular))
                                        .frame(width: 20, height: 20)
                                        .background(tokens.border.opacity(0.18))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(idx == 0)
                                .opacity(idx == 0 ? 0.35 : 1)
                                .help("Previous day")

                                Button {
                                    if idx < stats.days.count - 1 {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                            selectedDay = stats.days[idx + 1].day
                                        }
                                        onLoad(range.days, selectedDay, false)
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .regular))
                                        .frame(width: 20, height: 20)
                                        .background(tokens.border.opacity(0.18))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .disabled(idx >= stats.days.count - 1)
                                .opacity(idx >= stats.days.count - 1 ? 0.35 : 1)
                                .help("Next day")
                            }
                            .padding(.leading, WarrenSpacing.xxs)
                        }
                    }
                    Text("Cache hit rate \(share) · \(WarrenUsageFormatting.calls(cost.calls))")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }

                Spacer(minLength: 0)

                if selectedDay != nil {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedDay = nil
                        }
                        onLoad(range.days, nil, false)
                    } label: {
                        HStack(spacing: 3) {
                            Text("Latest")
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.link)
                    .padding(.horizontal, WarrenSpacing.compact)
                    .padding(.vertical, WarrenSpacing.xxs)
                    .background(tokens.link.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                // The day's two headline figures, not one. Reading the strip and
                // then hunting the token total in the legend below made the count
                // look like a detail of the amount, which it is not: tokens are
                // what was measured and the amount is derived from them.
                VStack(alignment: .trailing, spacing: 0) {
                    Text(WarrenUsageFormatting.money(cost))
                        .font(WarrenTypography.pageTitle)
                        .foregroundStyle(tokens.highlight)
                    Text("\(WarrenUsageFormatting.tokens(buckets.total)) tokens")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                }
                .monospacedDigit()
            }

            if activeFilterIsEmpty {
                Text("\(activeFilterLabel ?? "This selection") recorded no usage on this day.")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
            } else {
                bucketBars(buckets, cost: cost)
                bucketLegend(buckets, cost: cost)
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
        .accessibilityIdentifier("usage.detail")
    }

    private var dayBreakdowns: some View {
        breakdowns(
            providers: scopedProviders,
            models: scopedModels,
            projects: scopedProjects,
            heading: detailDay == nil ? "Range breakdown" : "Day breakdown"
        )
    }

    // MARK: - Shared pieces

    // MARK: - Scope

    // Every figure on a surface is scoped the same way: the Overview describes
    // the whole range, the Detail surface describes one day.
    //
    // The scope used to be chosen by whether the Host had named a detail day,
    // which it does by default. Applying a filter on the Overview therefore
    // silently swapped the range total for the latest day's, while the list the
    // filter was picked from still described the range.

    private var scopedProviders: [WarrenUsageGroup] {
        mode == .overview ? stats.providers : stats.dayProviders
    }

    private var scopedModels: [WarrenUsageGroup] {
        mode == .overview ? stats.models : stats.dayModels
    }

    private var scopedProjects: [WarrenUsageGroup] {
        mode == .overview ? stats.projects : stats.dayProjects
    }

    /// Exposes the resolved scope so a test can prove which one a surface used.
    /// The scope is not observable from a rendered hosting view.
    var scopedProvidersForTesting: [WarrenUsageGroup] { scopedProviders }

    /// The group the active filter selects, or nil when nothing is filtered.
    ///
    /// A filter naming something absent from this scope resolves to an empty
    /// group rather than nil, because falling back to the unfiltered figure would
    /// label the whole range as one model that did not run.
    private var activeFilterGroup: WarrenUsageGroup? {
        if let model = selectedModelFilter {
            return scopedModels.first { $0.key == model }
                ?? WarrenUsageGroup(key: model, buckets: WarrenUsageBuckets(), cost: WarrenUsageCost())
        }
        if let agent = selectedAgentFilter {
            return scopedProviders.first { $0.key == agent }
                ?? WarrenUsageGroup(key: agent, buckets: WarrenUsageBuckets(), cost: WarrenUsageCost())
        }
        return nil
    }

    private var activeFilteredBuckets: WarrenUsageBuckets {
        activeFilterGroup?.buckets ?? (mode == .overview ? stats.total : detailDayStats?.buckets ?? WarrenUsageBuckets())
    }

    private var activeFilteredCost: WarrenUsageCost {
        activeFilterGroup?.cost ?? (mode == .overview ? stats.cost : detailDayStats?.cost ?? WarrenUsageCost())
    }

    private var activeFilterLabel: String? {
        activeFilterGroup?.displayName
    }

    /// Whether the active filter selects something that has no activity in scope.
    /// Saying so is the alternative to showing an unexplained row of zeroes.
    private var activeFilterIsEmpty: Bool {
        guard let group = activeFilterGroup else { return false }
        return group.buckets.total == 0
    }

    /// Keeps the intraday rows the active filter selects. Rows from a Host that
    /// sends no Agent or model cannot be narrowed, so they are kept: showing the
    /// unfiltered curve is better than showing an empty one.
    private func intervalMatchesFilter(_ interval: WarrenUsageInterval) -> Bool {
        if let model = selectedModelFilter, !interval.model.isEmpty {
            return interval.model == model
        }
        if let agent = selectedAgentFilter, !interval.provider.isEmpty {
            return interval.provider == agent
        }
        return true
    }

    private var rangePicker: some View {
        HStack(spacing: WarrenSpacing.small) {
            // Only where the range is what is being shown. The detail surface is
            // one day -- its strip, curve, and breakdowns all describe that day --
            // so every segment here changed nothing a reader could see, which
            // reads as a broken control rather than an inapplicable one. The day
            // itself is chosen in the calendar and stepped with the arrows beside
            // the date.
            if mode == .overview {
                Picker("Range", selection: $range) {
                    ForEach(WarrenUsageRange.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityIdentifier("usage.range")
            }

            // Agent filter
            Menu {
                Button("All Agents") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedAgentFilter = nil
                    }
                }
                Divider()
                // Scoped, so the menu cannot offer an Agent that did not run on
                // the day being shown and then resolve to an empty selection.
                ForEach(scopedProviders) { group in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedAgentFilter = (selectedAgentFilter == group.key) ? nil : group.key
                        }
                    } label: {
                        HStack {
                            Text(group.displayName)
                            if selectedAgentFilter == group.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.2")
                        .font(.system(size: 11, weight: .regular))
                    Text(selectedAgentFilter.flatMap { key in scopedProviders.first { $0.key == key }?.displayName } ?? "All Agents")
                        .font(WarrenTypography.settingsGroupLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .regular))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selectedAgentFilter != nil ? tokens.highlight.opacity(0.12) : tokens.chromeSurface)
                .foregroundStyle(selectedAgentFilter != nil ? tokens.highlight : tokens.foreground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selectedAgentFilter != nil ? tokens.highlight.opacity(0.4) : tokens.border.opacity(0.4), lineWidth: WarrenSpacing.hairline)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("usage.filter.agent")

            // Model filter
            Menu {
                Button("All Models") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedModelFilter = nil
                    }
                }
                Divider()
                ForEach(scopedModels) { group in
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedModelFilter = (selectedModelFilter == group.key) ? nil : group.key
                        }
                    } label: {
                        HStack {
                            Text(group.displayName)
                            if selectedModelFilter == group.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .regular))
                    Text(selectedModelFilter.flatMap { key in scopedModels.first { $0.key == key }?.displayName } ?? "All Models")
                        .font(WarrenTypography.settingsGroupLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .regular))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(selectedModelFilter != nil ? tokens.highlight.opacity(0.12) : tokens.chromeSurface)
                .foregroundStyle(selectedModelFilter != nil ? tokens.highlight : tokens.foreground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(selectedModelFilter != nil ? tokens.highlight.opacity(0.4) : tokens.border.opacity(0.4), lineWidth: WarrenSpacing.hairline)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("usage.filter.model")

            if selectedAgentFilter != nil || selectedModelFilter != nil {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                        selectedAgentFilter = nil
                        selectedModelFilter = nil
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11, weight: .regular))
                        Text("Reset")
                            .font(WarrenTypography.settingsMeta)
                    }
                    .foregroundStyle(tokens.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("usage.filter.reset")
            }

            Spacer(minLength: 0)

            if state == .loading {
                ProgressView().controlSize(.small)
            }

            Button {
                onLoad(range.days, selectedDay, true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .font(WarrenTypography.settingsSupporting)
            .accessibilityIdentifier("usage.refresh")
        }
    }

    private func heatmapCard(subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.standard) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text("Activity Calendar")
                        .font(WarrenTypography.settingsBodyEmphasis)
                        .foregroundStyle(tokens.foreground)
                    if let subtitle {
                        Text(subtitle)
                            .font(WarrenTypography.settingsMeta)
                            .foregroundStyle(tokens.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: WarrenSpacing.standard)
                if stats.fromDay.isEmpty == false {
                    Text("\(WarrenUsageFormatting.dayLabel(stats.fromDay)) – \(WarrenUsageFormatting.dayLabel(stats.toDay))")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                }
            }
            WarrenDesktopUsageHeatmapView(
                heatmap: heatmap,
                tokens: tokens,
                selectedDay: heatmapSelection
            )
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
    }

    private var heatmapSelection: Binding<String?> {
        Binding(
            get: { selectedDay },
            set: { day in
                guard let day else {
                    selectedDay = nil
                    return
                }
                selectedDay = day
                if mode == .overview, let onOpenDetail {
                    onOpenDetail(day)
                } else {
                    onLoad(range.days, day, false)
                }
            }
        )
    }

    private var summaryGrid: some View {
        let buckets = activeFilteredBuckets
        let cost = activeFilteredCost

        let activeDays = stats.days.filter { $0.buckets.total > 0 }.count
        // Four equal columns. The subtitles used to truncate mid-word ("US$0.022
        // per priced…") not because the row was too narrow but because they were
        // held to one line; they now wrap to two, which fits the settings width
        // without spending a second row of cards on four short numbers.
        return LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: WarrenSpacing.standard),
                count: 4
            ),
            alignment: .leading,
            spacing: WarrenSpacing.standard
        ) {
            metricCard(
                "Estimated Spend",
                WarrenUsageFormatting.money(cost),
                // The average divides by the calls the amount actually covers.
                // Dividing by every call understates it by exactly the share of
                // spend the panel already says it is missing.
                subtitle: cost.usdPerPricedCall.map {
                    "\(WarrenUsageFormatting.money($0)) per priced call"
                } ?? "No call in this range could be priced",
                icon: "dollarsign.circle",
                accent: tokens.highlight,
                emphasize: true,
                tinted: true
            )
            // Second, and at the same size: tokens are measured while cost is
            // derived from them, so the count is not a footnote to the amount.
            // Calls and cache hit rate follow because both are read off these two.
            metricCard(
                "Total Tokens",
                WarrenUsageFormatting.tokens(buckets.total),
                subtitle: "\(WarrenUsageFormatting.tokens(buckets.freshInput)) fresh · \(WarrenUsageFormatting.tokens(buckets.output)) output",
                icon: "sparkles",
                accent: tokens.mutedForeground,
                // Size but no tint: a peer of spend in rank, while the accent and
                // the tinted border stay spend's alone.
                emphasize: true
            )
            metricCard(
                "Model Calls",
                WarrenUsageFormatting.exact(cost.calls),
                // Activity belongs with the call count, not with the token total
                // where it used to sit: "active days" says nothing about tokens.
                subtitle: activeFilterLabel.map { "In the \($0) filter" }
                    ?? "over \(activeDays) active \(activeDays == 1 ? "day" : "days")",
                icon: "waveform.path.ecg",
                accent: tokens.mutedForeground
            )
            metricCard(
                "Cache Hit Rate",
                buckets.cacheHitRate.map(WarrenUsageFormatting.percent) ?? "—",
                subtitle: "\(WarrenUsageFormatting.tokens(buckets.cacheRead)) read · \(WarrenUsageFormatting.tokens(buckets.cacheWrite)) written",
                icon: "bolt.shield",
                accent: tokens.mutedForeground
            )
        }
    }

    /// One summary figure.
    ///
    /// - Parameter emphasize: ranks the card as one of the two measurements this
    ///   panel reports, spend and tokens, which get the larger type. Colour is a
    ///   separate matter: only spend is tinted. When all four cards were tinted,
    ///   the four semantic colours were spent here and could no longer mean fresh
    ///   input, cache write, cache read, and output in the composition below.
    private func metricCard(
        _ label: String,
        _ value: String,
        subtitle: String? = nil,
        icon: String,
        accent: Color,
        emphasize: Bool = false,
        tinted: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.small) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(tinted ? accent : tokens.mutedForeground)
                    .frame(width: 16)
                Text(label)
                    .font(WarrenTypography.settingsGroupLabel)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(value)
                .font(.system(size: emphasize ? 30 : 24, weight: .light))
                .foregroundStyle(tinted ? accent : tokens.foreground)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subtitle {
                Text(subtitle)
                    .font(WarrenTypography.settingsMeta)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(
                    tinted ? accent.opacity(0.28) : tokens.border.opacity(0.35),
                    lineWidth: WarrenSpacing.hairline
                )
        )
    }

    /// The four bucket colors, in the order the bars and legend always use them.
    private var bucketColors: (fresh: Color, cacheWrite: Color, cacheRead: Color, output: Color) {
        (tokens.highlight, tokens.warning, tokens.info, tokens.success)
    }

    /// Two stacked bars: what the tokens were, and what they cost.
    ///
    /// One bar could not carry this. Drawn from tokens it is 94% one color, with
    /// cache write and output at 0.2% and 0.3% rendering as two invisible pixels;
    /// drawn from cost the same data is four legible segments. Showing both, on
    /// labelled rows, is what makes the disagreement the point rather than a
    /// discrepancy the reader has to catch.
    private func bucketBars(_ buckets: WarrenUsageBuckets, cost: WarrenUsageCost) -> some View {
        let money = cost.byBucket
        return VStack(alignment: .leading, spacing: WarrenSpacing.xs) {
            barRow(
                "Tokens",
                parts: [
                    (buckets.freshInput, bucketColors.fresh),
                    (buckets.cacheWrite, bucketColors.cacheWrite),
                    (buckets.cacheRead, bucketColors.cacheRead),
                    (buckets.output, bucketColors.output),
                ]
            )
            if money.total > 0 {
                barRow(
                    "Cost",
                    parts: [
                        (money.freshInput, bucketColors.fresh),
                        (money.cacheWrite, bucketColors.cacheWrite),
                        (money.cacheRead, bucketColors.cacheRead),
                        (money.output, bucketColors.output),
                    ]
                )
            }
        }
    }

    private func barRow(_ label: String, parts: [(Int64, Color)]) -> some View {
        let total = max(parts.reduce(0) { $0 + $1.0 }, 1)
        return HStack(spacing: WarrenSpacing.small) {
            Text(label)
                .font(WarrenTypography.settingsGroupLabel)
                .foregroundStyle(tokens.mutedForeground)
                .frame(width: 44, alignment: .trailing)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        Rectangle()
                            .fill(part.1)
                            .frame(width: geometry.size.width * CGFloat(part.0) / CGFloat(total))
                    }
                }
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .accessibilityHidden(true)
    }

    private func bucketLegend(_ buckets: WarrenUsageBuckets, cost: WarrenUsageCost) -> some View {
        let total = max(buckets.total, 1)
        let money = cost.byBucket
        return VStack(alignment: .leading, spacing: WarrenSpacing.small) {
            HStack(alignment: .top, spacing: WarrenSpacing.standard) {
                bucketKey("Fresh input", buckets.freshInput, total, money.freshInput, money.share(money.freshInput), bucketColors.fresh)
                bucketKey("Cache write", buckets.cacheWrite, total, money.cacheWrite, money.share(money.cacheWrite), bucketColors.cacheWrite)
                bucketKey("Cache read", buckets.cacheRead, total, money.cacheRead, money.share(money.cacheRead), bucketColors.cacheRead)
                bucketKey("Output", buckets.output, total, money.output, money.share(money.output), bucketColors.output)
            }
            // Reasoning is a subset of output rather than a fifth bucket: it is
            // billed at the output rate and already counted there, so it is shown
            // as a share of output and never added to the bar above.
            if buckets.reasoning > 0 {
                Text("Output includes \(WarrenUsageFormatting.tokens(buckets.reasoning)) reasoning")
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
    }

    /// One class of tokens, with the share of tokens and the share of money it
    /// accounts for.
    ///
    /// Both shares are shown because they routinely disagree by an order of
    /// magnitude: cache reads dominate the token count while costing a tenth of
    /// the input rate, so a bar drawn from tokens alone points at the wrong line
    /// item. The money share is omitted when nothing here could be priced, rather
    /// than rendered as 0%.
    private func bucketKey(
        _ label: String,
        _ value: Int64,
        _ total: Int64,
        _ costNanoUSD: Int64,
        _ costShare: Double?,
        _ color: Color
    ) -> some View {
        let tokenShare = Double(value) / Double(total)
        return VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
            HStack(spacing: WarrenSpacing.xs) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(WarrenTypography.settingsGroupLabel)
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
            }
            // Money and tokens are both measurements this panel exists to report,
            // so they share one line at one size. Neither is a caption of the
            // other: the amount answers "what did this cost", the count answers
            // "how much did it move", and the whole point of this card is that the
            // two rank differently.
            HStack(alignment: .firstTextBaseline, spacing: WarrenSpacing.xs) {
                if costShare != nil {
                    Text(WarrenUsageFormatting.money(Double(costNanoUSD) / 1_000_000_000))
                        .foregroundStyle(tokens.foreground)
                    // Without a separator "US$638.15 524.3M" reads as one figure.
                    Text("·")
                        .foregroundStyle(tokens.mutedForeground.opacity(0.5))
                }
                Text(WarrenUsageFormatting.tokens(value))
                    .foregroundStyle(tokens.mutedForeground)
            }
            .font(WarrenTypography.settingsBody)
            .monospacedDigit()
            // The shares are derived from those two, so they sit below in small
            // print rather than competing with them.
            HStack(spacing: WarrenSpacing.xs) {
                if let costShare {
                    Text(WarrenUsageFormatting.percent(costShare))
                        .foregroundStyle(color)
                    Text("cost")
                        .foregroundStyle(tokens.mutedForeground.opacity(0.7))
                }
                Text(WarrenUsageFormatting.percent(tokenShare))
                    .foregroundStyle(tokens.mutedForeground)
                Text("tok")
                    .foregroundStyle(tokens.mutedForeground.opacity(0.7))
            }
            .font(WarrenTypography.settingsGroupLabel)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(
            "\(label)\n\(WarrenUsageFormatting.exact(value)) tokens"
                + " · \(WarrenUsageFormatting.percent(tokenShare)) of tokens"
                + (costShare.map {
                    "\n\(WarrenUsageFormatting.money(Double(costNanoUSD) / 1_000_000_000))"
                        + " · \(WarrenUsageFormatting.percent($0)) of cost"
                } ?? "")
        )
    }

    private func breakdowns(
        providers: [WarrenUsageGroup],
        models: [WarrenUsageGroup],
        projects: [WarrenUsageGroup],
        heading: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.medium) {
            if let heading {
                Text(heading)
                    .font(WarrenTypography.settingsBodyEmphasis)
                    .foregroundStyle(tokens.foreground)
            }
            HStack(alignment: .top, spacing: WarrenSpacing.standard) {
                breakdownCard(
                    "By Agent",
                    icon: "person.2",
                    groups: providers,
                    selectedKey: selectedAgentFilter,
                    onSelect: { group in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedAgentFilter = (selectedAgentFilter == group.key) ? nil : group.key
                        }
                    }
                )
                breakdownCard(
                    "By Model",
                    icon: "cpu",
                    groups: models,
                    selectedKey: selectedModelFilter,
                    onSelect: { group in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            selectedModelFilter = (selectedModelFilter == group.key) ? nil : group.key
                        }
                    }
                )
                // Projects are not a filter dimension: the Host does not break the
                // intraday curve down by project, so a project row is deliberately
                // not tappable rather than tappable and inert.
                breakdownCard(
                    "By Project",
                    icon: "folder",
                    groups: projects,
                    selectedKey: nil,
                    onSelect: nil
                )
            }
            // The cards fill this row's height so they end on one baseline instead
            // of stair-stepping. Pinning the row to its own ideal height is what
            // keeps that from becoming a licence to absorb the whole surface: with
            // spare space below, three cards of four rows each grew ~600pt of empty
            // background.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Color for one breakdown row, by its rank within its own card.
    ///
    /// Rank rather than brand. Guessing a vendor color from substrings of the key
    /// put three meanings on one color in a single screen -- green was Codex here,
    /// "Model Calls" in the summary, and Output in the composition bar -- and it
    /// collided anyway: `deepseek-v4.1-flash` matches no vendor and fell through
    /// to the same accent as `claude-opus-5`. The design system's identity palette
    /// exists for exactly this, is low-saturation enough not to compete with the
    /// four semantic bucket colors, and keeps the leading row emphatic because it
    /// is the largest one.
    private func rankColor(_ index: Int) -> Color {
        let palette = tokens.tabGroupTints
        guard !palette.isEmpty else { return tokens.highlight }
        return palette[index % palette.count]
    }

    private func breakdownCard(
        _ title: String,
        icon: String,
        groups: [WarrenUsageGroup],
        selectedKey: String? = nil,
        onSelect: ((WarrenUsageGroup) -> Void)? = nil
    ) -> some View {
        // Ranked and measured by cost, matching the amount on each row and the
        // order the Host sorted them into. Sizing the bars by tokens instead put
        // the shortest bar next to the largest amount: locally `claude` showed a
        // near-empty bar labelled 5.7% beside $933, while `codex` showed a full bar
        // labelled 79% beside $516. Tokens move to the second line, where nothing
        // suggests they explain the money.
        let total = groups.map(\.cost.nanoUSD).reduce(0, +)
        let visible = Array(groups.prefix(breakdownRowLimit))
        return VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            HStack(spacing: WarrenSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(tokens.mutedForeground)
                Text(title)
                    .font(WarrenTypography.settingsGroupLabel)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(tokens.mutedForeground)
                Spacer()
                if !groups.isEmpty {
                    Text("\(groups.count)")
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .monospacedDigit()
                }
            }
            .padding(.bottom, WarrenSpacing.xxs)

            if groups.isEmpty {
                Text("No activity recorded")
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, WarrenSpacing.large)
            } else {
                VStack(spacing: WarrenSpacing.small) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, group in
                        groupRow(
                            group,
                            rank: index,
                            total: total,
                            isSelected: selectedKey == group.key,
                            onSelect: onSelect != nil ? { onSelect?(group) } : nil
                        )
                    }
                }
                if groups.count > breakdownRowLimit {
                    Text("+\(groups.count - breakdownRowLimit) more")
                        .font(WarrenTypography.settingsGroupLabel)
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.top, WarrenSpacing.xxs)
                }
            }
            // Pushes short cards to the height of the tallest one, so the three
            // sit on one baseline instead of stair-stepping by 300pt when one
            // dimension happens to have more rows than another.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(WarrenSpacing.standard)
        .background(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .fill(tokens.chromeSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: WarrenRadius.large, style: .continuous)
                .strokeBorder(tokens.border.opacity(0.40), lineWidth: WarrenSpacing.hairline)
        )
    }

    private func groupRow(
        _ group: WarrenUsageGroup,
        rank: Int,
        total: Int64,
        isSelected: Bool = false,
        onSelect: (() -> Void)? = nil
    ) -> some View {
        // The share is of the card's total, and so is the fill width. Scaling the
        // fill to the largest row instead made the leading row full-width whatever
        // its share was, so a row reading "72.1% of spend" was drawn at 100%.
        let share = total > 0 ? Double(group.cost.nanoUSD) / Double(total) : nil
        let rowColor = rankColor(rank)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: WarrenSpacing.small) {
                Circle()
                    .fill(rowColor)
                    .frame(width: 6, height: 6)

                Text(group.displayName)
                    .font(WarrenTypography.settingsSupporting)
                    .foregroundStyle(isSelected ? tokens.highlight : tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: WarrenSpacing.xs)

                Text(WarrenUsageFormatting.money(group.cost))
                    .font(WarrenTypography.settingsBody)
                    .foregroundStyle(tokens.foreground)
                    .monospacedDigit()
            }

            HStack(spacing: WarrenSpacing.xs) {
                if let share {
                    Text("\(WarrenUsageFormatting.percent(share)) of spend")
                        .monospacedDigit()
                }
                if group.buckets.total > 0 {
                    if share != nil {
                        Text("·")
                    }
                    Text("\(WarrenUsageFormatting.tokens(group.buckets.total)) tokens")
                        .monospacedDigit()
                }
            }
            .font(WarrenTypography.settingsGroupLabel)
            .foregroundStyle(tokens.mutedForeground)
        }
        .padding(.horizontal, WarrenSpacing.compact)
        .padding(.vertical, WarrenSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The magnitude is the row's own filled width rather than a separate bar
        // beneath it. A 4pt bar spanning the row read as a rule under the label,
        // not as a quantity, and it cost a third line of height per row.
        .background(
            GeometryReader { geometry in
                let ratio = CGFloat(share ?? 0)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tokens.muted.opacity(0.20))
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [rowColor.opacity(0.30), rowColor.opacity(0.12)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * ratio, ratio > 0 ? 3 : 0))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isSelected ? tokens.highlight.opacity(0.55) : Color.clear,
                    lineWidth: WarrenSpacing.hairline
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?()
        }
        .help(
            "\(group.displayName)\n"
                + WarrenUsageFormatting.money(group.cost)
                + " · \(WarrenUsageFormatting.calls(group.cost.calls))\n"
                + "\(WarrenUsageFormatting.exact(group.buckets.total)) tokens"
                + (onSelect != nil ? "\nClick to filter" : "")
        )
    }

    /// Says what the amounts are missing, next to the amounts themselves.
    ///
    /// This used to live in the footnote under the whole panel, where a person
    /// reading a "≥" prefix had no way to know what the prefix was about without
    /// scrolling past the breakdowns to find out.
    @ViewBuilder
    private var completenessNotice: some View {
        if let reason = WarrenUsageFormatting.incompleteReason(stats.cost) {
            HStack(alignment: .top, spacing: WarrenSpacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(tokens.warning)
                // Two lines: what the mark means, and what is missing. The third
                // line used to explain that tokens are measured and cost derived,
                // which is true of every figure on the panel and so belongs to none
                // of them in particular.
                VStack(alignment: .leading, spacing: WarrenSpacing.xxs) {
                    Text("Amounts marked ≥ are lower bounds")
                        .font(WarrenTypography.settingsBodyEmphasis)
                        .foregroundStyle(tokens.foreground)
                    Text(reason)
                        .font(WarrenTypography.settingsMeta)
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(WarrenSpacing.compact)
            .background(
                RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                    .fill(tokens.warning.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: WarrenRadius.medium, style: .continuous)
                    .strokeBorder(tokens.warning.opacity(0.30), lineWidth: WarrenSpacing.hairline)
            )
            .accessibilityIdentifier("usage.incomplete")
        }
    }

    /// One quiet line of provenance: where the prices came from, and how old the
    /// counts are. Both were paragraphs explaining that cost is derived on read
    /// and that a rebuild recounts from transcripts -- true, and of no use to
    /// someone reading a total. The detail lives in the tooltip.
    private var footnote: some View {
        HStack(spacing: WarrenSpacing.xs) {
            Text(priceProvenance)
            Text("·")
                .foregroundStyle(tokens.mutedForeground.opacity(0.5))
            Text(WarrenUsageFormatting.rebuildAge(stats.lastRebuild))
                .accessibilityIdentifier("usage.rebuildAge")
            Spacer(minLength: 0)
        }
        .font(WarrenTypography.settingsGroupLabel)
        .foregroundStyle(tokens.mutedForeground)
        .lineLimit(1)
        .padding(.horizontal, WarrenSpacing.xxs)
        .help(
            "Costs are derived from token counts each time this panel loads, "
                + "so a price correction restates history.\n"
                + "A rebuild re-reads the stored transcripts and recounts every call."
        )
    }

    private var priceProvenance: String {
        guard let fetched = stats.pricesFetchedAt else {
            return "Prices unavailable"
        }
        return "Prices from models.dev, \(fetched.formatted(.relative(presentation: .named)))"
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: WarrenSpacing.compact) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(tokens.mutedForeground)
                .accessibilityHidden(true)
            Text(text)
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.mutedForeground)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WarrenSpacing.large)
        .accessibilityIdentifier("usage.placeholder")
    }

    private func failureNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: WarrenSpacing.compact) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(WarrenTypography.settingsSupporting)
                .foregroundStyle(tokens.destructive)
            Button("Try again") { onLoad(range.days, selectedDay, true) }
                .buttonStyle(.bordered)
                .font(WarrenTypography.settingsSupporting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("usage.error")
    }
}

/// Daily totals and cost breakdowns. The detailed `WarrenDesktopUsagePanel`
/// remains a separate view so the settings secondary navigation can keep the
/// overview and intraday curve surfaces independent.
public struct WarrenDesktopUsageOverviewPanel: View {
    private let stats: WarrenUsageStats
    private let state: WarrenUsageLoadState
    private let tokens: WarrenColorTokens
    @Binding private var range: WarrenUsageRange
    @Binding private var selectedDay: String?
    private let onLoad: (Int, String?, Bool) -> Void
    private let onOpenDetail: ((String) -> Void)?

    public init(
        stats: WarrenUsageStats,
        state: WarrenUsageLoadState,
        tokens: WarrenColorTokens,
        range: Binding<WarrenUsageRange>,
        selectedDay: Binding<String?>,
        onLoad: @escaping (Int, String?, Bool) -> Void,
        onOpenDetail: ((String) -> Void)? = nil
    ) {
        self.stats = stats
        self.state = state
        self.tokens = tokens
        self._range = range
        self._selectedDay = selectedDay
        self.onLoad = onLoad
        self.onOpenDetail = onOpenDetail
    }

    public var body: some View {
        WarrenDesktopUsagePanel(
            stats: stats,
            state: state,
            tokens: tokens,
            range: $range,
            selectedDay: $selectedDay,
            onLoad: onLoad,
            onOpenDetail: onOpenDetail,
            mode: .overview
        )
    }
}
