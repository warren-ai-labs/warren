import Foundation

/// One aggregate's token counts, split into classes that each carry their own
/// unit price. The four are disjoint and sum to the real total.
public struct WarrenUsageBuckets: Equatable, Sendable {
    public let freshInput: Int64
    public let cacheWrite: Int64
    public let cacheRead: Int64
    public let output: Int64
    /// The reasoning subset of `output`, shown for context. It is already
    /// counted inside `output` and must never be added to a total.
    public let reasoning: Int64

    public init(
        freshInput: Int64 = 0,
        cacheWrite: Int64 = 0,
        cacheRead: Int64 = 0,
        output: Int64 = 0,
        reasoning: Int64 = 0
    ) {
        self.freshInput = freshInput
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.reasoning = reasoning
    }

    public var total: Int64 { freshInput + cacheWrite + cacheRead + output }

    /// Share of cacheable input that was served from cache.
    ///
    /// Derived here rather than stored by the Host so there is one definition.
    /// The denominator is the input that could have been cached; output is
    /// excluded because it never can be.
    public var cacheHitRate: Double? {
        let cacheable = freshInput + cacheWrite + cacheRead
        guard cacheable > 0 else { return nil }
        return Double(cacheRead) / Double(cacheable)
    }
}

/// A money amount together with how completely it could be derived.
///
/// Completeness is carried rather than inferred: an amount whose price was only
/// partly known must read as a lower bound, or the panel shows a total that
/// looks whole while omitting spend that really happened.
/// A money amount split by the token class that incurred it.
///
/// Worth its own type because the money shape and the token shape answer
/// different questions and routinely disagree: measured over real history, cache
/// reads are 94% of tokens but 44% of spend, while fresh input is 5% of tokens
/// and 42% of spend. A composition bar drawn from tokens alone therefore says
/// almost nothing about where the money went.
public struct WarrenUsageBucketCost: Equatable, Sendable {
    public let freshInput: Int64
    public let cacheWrite: Int64
    public let cacheRead: Int64
    public let output: Int64

    public init(
        freshInput: Int64 = 0,
        cacheWrite: Int64 = 0,
        cacheRead: Int64 = 0,
        output: Int64 = 0
    ) {
        self.freshInput = freshInput
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
    }

    public var total: Int64 { freshInput + cacheWrite + cacheRead + output }

    /// The share of the amount one class accounts for, or nil when nothing was
    /// priced and a share would be a made-up number.
    public func share(_ value: Int64) -> Double? {
        guard total > 0 else { return nil }
        return Double(value) / Double(total)
    }
}

public struct WarrenUsageCost: Equatable, Sendable {
    public let nanoUSD: Int64
    public let calls: Int64
    public let pricedCalls: Int64
    /// Providers active on the Host that report no token counts at all, so
    /// their spend is absent from every figure here.
    public let unmeasuredProviders: [String]
    /// Models whose tokens were counted but could not be priced. Naming them is
    /// what makes a lower bound actionable rather than merely humble.
    public let unpricedModels: [String]
    /// The amount split by the token class that incurred it. Always sums to
    /// `nanoUSD`.
    public let byBucket: WarrenUsageBucketCost

    public init(
        nanoUSD: Int64 = 0,
        calls: Int64 = 0,
        pricedCalls: Int64 = 0,
        unmeasuredProviders: [String] = [],
        unpricedModels: [String] = [],
        byBucket: WarrenUsageBucketCost = WarrenUsageBucketCost()
    ) {
        self.nanoUSD = nanoUSD
        self.calls = calls
        self.pricedCalls = pricedCalls
        self.unmeasuredProviders = unmeasuredProviders
        self.unpricedModels = unpricedModels
        self.byBucket = byBucket
    }

    public var usd: Double { Double(nanoUSD) / 1_000_000_000 }

    /// True when every call was priced and no provider is unmeasured.
    public var isComplete: Bool {
        pricedCalls >= calls && unmeasuredProviders.isEmpty
    }

    /// Calls whose price was unknown, so the amount omits their spend.
    public var unpricedCalls: Int64 { max(calls - pricedCalls, 0) }

    /// Average cost of the calls the amount actually covers.
    ///
    /// The denominator is `pricedCalls`, not `calls`: dividing a partial amount
    /// by every call reports an average that is low by exactly the share of
    /// spend the panel already admits it is missing.
    public var usdPerPricedCall: Double? {
        guard pricedCalls > 0 else { return nil }
        return usd / Double(pricedCalls)
    }
}

/// What an explicit Usage rebuild replaced.
///
/// Reported back to the person who asked for it, because a rebuild that silently
/// finished leaves them unable to tell a correction from a no-op. The two counts
/// are the interesting part: their difference is how many repeated observations
/// were collapsed, which is the size of the error the rebuild just removed.
public struct WarrenUsageRebuildSummary: Equatable, Sendable {
    /// Providers whose stored usage was replaced. Anything absent kept its rows,
    /// because this Host could not enumerate that provider's transcripts.
    public let providers: [String]
    public let observations: Int64
    public let calls: Int64
    public let days: Int64
    /// When the Host committed the replacement. Nil against an older Host.
    public let completedAt: Date?

    public init(
        providers: [String] = [],
        observations: Int64 = 0,
        calls: Int64 = 0,
        days: Int64 = 0,
        completedAt: Date? = nil
    ) {
        self.providers = providers
        self.observations = observations
        self.calls = calls
        self.days = days
        self.completedAt = completedAt
    }

    /// Repeated observations that were counted once. A resumed conversation
    /// reports its whole history again, so this is routinely non-zero.
    public var collapsedRepeats: Int64 { max(observations - calls, 0) }

    /// The stamp this rebuild leaves behind, so the panel can show its age
    /// without refetching the whole payload.
    public var stamp: WarrenUsageRebuildStamp? {
        completedAt.map {
            WarrenUsageRebuildStamp(completedAt: $0, providers: providers, calls: calls)
        }
    }
}

/// When the stored Usage projection was last replaced.
///
/// Shown because a rebuild is the only thing that corrects historical counting:
/// figures produced by an older parser look exactly like current ones, so their
/// age is part of reading them.
public struct WarrenUsageRebuildStamp: Equatable, Sendable {
    public let completedAt: Date
    /// The providers that rebuild covered. Anything else holds figures from live
    /// accumulation or an earlier rebuild.
    public let providers: [String]
    public let calls: Int64

    public init(completedAt: Date, providers: [String] = [], calls: Int64 = 0) {
        self.completedAt = completedAt
        self.providers = providers
        self.calls = calls
    }
}

/// One local day of usage.
public struct WarrenUsageDay: Equatable, Sendable, Identifiable {
    public let day: String
    public let buckets: WarrenUsageBuckets
    public let cost: WarrenUsageCost

    public var id: String { day }

    public init(day: String, buckets: WarrenUsageBuckets, cost: WarrenUsageCost) {
        self.day = day
        self.buckets = buckets
        self.cost = cost
    }
}

/// One Host-local intraday usage bucket for a single Agent and model. `minute`
/// is measured from local midnight, so the value can be displayed without
/// converting a Host-local timestamp through the client's timezone.
///
/// The Agent and model are what let the curve answer "when did this model run
/// today". Older Hosts send neither, in which case the row is the whole bucket
/// and a filter cannot narrow it.
public struct WarrenUsageInterval: Equatable, Sendable, Identifiable {
    public let day: String
    public let minute: Int
    public let provider: String
    public let model: String
    public let buckets: WarrenUsageBuckets
    public let cost: WarrenUsageCost

    /// Includes the Agent and model, because several rows now share one minute.
    public var id: String { "\(day)-\(minute)-\(provider)-\(model)" }

    public init(
        day: String,
        minute: Int,
        provider: String = "",
        model: String = "",
        buckets: WarrenUsageBuckets,
        cost: WarrenUsageCost
    ) {
        self.day = day
        self.minute = minute
        self.provider = provider
        self.model = model
        self.buckets = buckets
        self.cost = cost
    }
}

/// Display grain for the intraday curve. The Host always sends the 5-minute
/// base buckets; one-hour points are formed by merging adjacent buckets.
public enum WarrenUsageCurveGranularity: Int, CaseIterable, Identifiable, Sendable {
    case halfHour = 30
    case hour = 60

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .halfHour: "30 min"
        case .hour: "1 hour"
        }
    }
}

/// Which quantity the intraday curve plots. Tokens are the durable fact; cost
/// is the projection the pricing pass derives from them, so both are worth a
/// view without another Host request.
public enum WarrenUsageCurveMetric: String, CaseIterable, Identifiable, Sendable {
    case tokens
    case cost

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .tokens: "Tokens"
        case .cost: "Cost"
        }
    }
}

/// One point in the rendered intraday curve.
public struct WarrenUsageCurvePoint: Equatable, Sendable, Identifiable {
    public let day: String
    public let minute: Int
    public let buckets: WarrenUsageBuckets
    public let cost: WarrenUsageCost

    public var id: String { "\(day)-\(minute)" }
    public var tokens: Int64 { buckets.total }

    public init(
        day: String,
        minute: Int,
        buckets: WarrenUsageBuckets = WarrenUsageBuckets(),
        cost: WarrenUsageCost = WarrenUsageCost()
    ) {
        self.day = day
        self.minute = minute
        self.buckets = buckets
        self.cost = cost
    }
}

/// Builds a complete daily series, including zero-usage slots so the x-axis
/// remains a real clock rather than collapsing quiet periods.
public enum WarrenUsageCurveBuilder {
    /// - Parameter include: keeps only the rows a filter selects. The Host sends
    ///   one row per Agent and model per bucket, so a filtered curve is the same
    ///   data summed over fewer rows rather than a second request.
    public static func build(
        intervals: [WarrenUsageInterval],
        day: String,
        granularity: WarrenUsageCurveGranularity,
        baseBucketMinutes: Int = 5,
        untilMinute: Int? = nil,
        include: ((WarrenUsageInterval) -> Bool)? = nil
    ) -> [WarrenUsageCurvePoint] {
        let base = max(baseBucketMinutes, 1)
        let step = max(granularity.rawValue, base)
        guard 1_440 % step == 0 else { return [] }

        var aggregate: [Int: WarrenUsageCurvePoint] = [:]
        for interval in intervals where interval.day == day {
            guard interval.minute >= 0, interval.minute < 1_440 else { continue }
            if let include, !include(interval) { continue }
            let slot = (interval.minute / step) * step
            let current = aggregate[slot] ?? WarrenUsageCurvePoint(day: day, minute: slot)
            aggregate[slot] = WarrenUsageCurvePoint(
                day: day,
                minute: slot,
                buckets: add(current.buckets, interval.buckets),
                cost: add(current.cost, interval.cost)
            )
        }

        let maxMinute = min(1_440 - step, untilMinute ?? (1_440 - step))
        let effectiveMax = max(0, maxMinute)
        return stride(from: 0, through: effectiveMax, by: step).map { minute in
            aggregate[minute] ?? WarrenUsageCurvePoint(day: day, minute: minute)
        }
    }

    private static func add(
        _ left: WarrenUsageBuckets,
        _ right: WarrenUsageBuckets
    ) -> WarrenUsageBuckets {
        WarrenUsageBuckets(
            freshInput: left.freshInput + right.freshInput,
            cacheWrite: left.cacheWrite + right.cacheWrite,
            cacheRead: left.cacheRead + right.cacheRead,
            output: left.output + right.output,
            reasoning: left.reasoning + right.reasoning
        )
    }

    private static func add(
        _ left: WarrenUsageCost,
        _ right: WarrenUsageCost
    ) -> WarrenUsageCost {
        WarrenUsageCost(
            nanoUSD: left.nanoUSD + right.nanoUSD,
            calls: left.calls + right.calls,
            pricedCalls: left.pricedCalls + right.pricedCalls,
            unmeasuredProviders: Array(
                Set(left.unmeasuredProviders).union(right.unmeasuredProviders)
            ).sorted(),
            unpricedModels: Array(
                Set(left.unpricedModels).union(right.unpricedModels)
            ).sorted(),
            byBucket: WarrenUsageBucketCost(
                freshInput: left.byBucket.freshInput + right.byBucket.freshInput,
                cacheWrite: left.byBucket.cacheWrite + right.byBucket.cacheWrite,
                cacheRead: left.byBucket.cacheRead + right.byBucket.cacheRead,
                output: left.byBucket.output + right.byBucket.output
            )
        )
    }
}

/// One aggregate along a single dimension: a provider, model, or project.
public struct WarrenUsageGroup: Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let buckets: WarrenUsageBuckets
    public let cost: WarrenUsageCost

    public var id: String { key }

    /// Text to show. Falls back to the key, then to an explicit unattributed
    /// marker so an empty row is never blank.
    public var displayName: String {
        if !label.isEmpty { return label }
        if !key.isEmpty { return key }
        return "Unattributed"
    }

    public init(key: String, label: String = "", buckets: WarrenUsageBuckets, cost: WarrenUsageCost) {
        self.key = key
        self.label = label
        self.buckets = buckets
        self.cost = cost
    }
}

/// The whole panel payload for one range.
public struct WarrenUsageStats: Equatable, Sendable {
    public let fromDay: String
    public let toDay: String
    public let total: WarrenUsageBuckets
    public let cost: WarrenUsageCost
    public let days: [WarrenUsageDay]
    public let intervals: [WarrenUsageInterval]
    /// The Host's canonical interval grain. Older Hosts omit this field and
    /// clients default to the current 5-minute contract.
    public let intervalBucketMinutes: Int
    public let providers: [WarrenUsageGroup]
    public let models: [WarrenUsageGroup]
    public let projects: [WarrenUsageGroup]
    /// The day `intervals` describes. The Host chooses the most recent day with
    /// data when the client names none, so the curve has something to draw on
    /// first open.
    public let detailDay: String?
    /// The same breakdowns as `providers`/`models`/`projects`, narrowed to
    /// `detailDay`. Empty against an older Host that does not send them.
    public let dayProviders: [WarrenUsageGroup]
    public let dayModels: [WarrenUsageGroup]
    public let dayProjects: [WarrenUsageGroup]
    /// When the unit prices behind `cost` were retrieved. Nil means no price
    /// table was available, so every amount is zero.
    public let pricesFetchedAt: Date?
    /// When the stored projection was last rebuilt. Nil when it has only ever
    /// been accumulated live, or against an older Host.
    public let lastRebuild: WarrenUsageRebuildStamp?

    public init(
        fromDay: String = "",
        toDay: String = "",
        total: WarrenUsageBuckets = WarrenUsageBuckets(),
        cost: WarrenUsageCost = WarrenUsageCost(),
        days: [WarrenUsageDay] = [],
        intervals: [WarrenUsageInterval] = [],
        intervalBucketMinutes: Int = 5,
        providers: [WarrenUsageGroup] = [],
        models: [WarrenUsageGroup] = [],
        projects: [WarrenUsageGroup] = [],
        detailDay: String? = nil,
        dayProviders: [WarrenUsageGroup] = [],
        dayModels: [WarrenUsageGroup] = [],
        dayProjects: [WarrenUsageGroup] = [],
        pricesFetchedAt: Date? = nil,
        lastRebuild: WarrenUsageRebuildStamp? = nil
    ) {
        self.fromDay = fromDay
        self.toDay = toDay
        self.total = total
        self.cost = cost
        self.days = days
        self.intervals = intervals
        self.intervalBucketMinutes = intervalBucketMinutes
        self.providers = providers
        self.models = models
        self.projects = projects
        self.detailDay = detailDay
        self.dayProviders = dayProviders
        self.dayModels = dayModels
        self.dayProjects = dayProjects
        self.pricesFetchedAt = pricesFetchedAt
        self.lastRebuild = lastRebuild
    }

    public var isEmpty: Bool { days.isEmpty && total.total == 0 }

    /// The day the detail surfaces should render: the caller's explicit pick,
    /// otherwise the Host's default. Nil only when the range has no data.
    public func resolvedDetailDay(selected: String?) -> String? {
        if let selected, days.contains(where: { $0.day == selected }) {
            return selected
        }
        if let detailDay, !detailDay.isEmpty { return detailDay }
        return days.map(\.day).max()
    }
}
