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
public struct WarrenUsageCost: Equatable, Sendable {
    public let nanoUSD: Int64
    public let calls: Int64
    public let pricedCalls: Int64
    /// Providers active on the Host that report no token counts at all, so
    /// their spend is absent from every figure here.
    public let unmeasuredProviders: [String]

    public init(
        nanoUSD: Int64 = 0,
        calls: Int64 = 0,
        pricedCalls: Int64 = 0,
        unmeasuredProviders: [String] = []
    ) {
        self.nanoUSD = nanoUSD
        self.calls = calls
        self.pricedCalls = pricedCalls
        self.unmeasuredProviders = unmeasuredProviders
    }

    public var usd: Double { Double(nanoUSD) / 1_000_000_000 }

    /// True when every call was priced and no provider is unmeasured.
    public var isComplete: Bool {
        pricedCalls >= calls && unmeasuredProviders.isEmpty
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

/// One Host-local intraday usage bucket. `minute` is measured from local
/// midnight, so the value can be displayed without converting a Host-local
/// timestamp through the client's timezone.
public struct WarrenUsageInterval: Equatable, Sendable, Identifiable {
    public let day: String
    public let minute: Int
    public let buckets: WarrenUsageBuckets
    public let cost: WarrenUsageCost

    public var id: String { "\(day)-\(minute)" }

    public init(
        day: String,
        minute: Int,
        buckets: WarrenUsageBuckets,
        cost: WarrenUsageCost
    ) {
        self.day = day
        self.minute = minute
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
    public static func build(
        intervals: [WarrenUsageInterval],
        day: String,
        granularity: WarrenUsageCurveGranularity,
        baseBucketMinutes: Int = 5
    ) -> [WarrenUsageCurvePoint] {
        let base = max(baseBucketMinutes, 1)
        let step = max(granularity.rawValue, base)
        guard 1_440 % step == 0 else { return [] }

        var aggregate: [Int: WarrenUsageCurvePoint] = [:]
        for interval in intervals where interval.day == day {
            guard interval.minute >= 0, interval.minute < 1_440 else { continue }
            let slot = (interval.minute / step) * step
            let current = aggregate[slot] ?? WarrenUsageCurvePoint(day: day, minute: slot)
            aggregate[slot] = WarrenUsageCurvePoint(
                day: day,
                minute: slot,
                buckets: add(current.buckets, interval.buckets),
                cost: add(current.cost, interval.cost)
            )
        }

        return stride(from: 0, to: 1_440, by: step).map { minute in
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
            ).sorted()
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
    /// When the unit prices behind `cost` were retrieved. Nil means no price
    /// table was available, so every amount is zero.
    public let pricesFetchedAt: Date?

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
        pricesFetchedAt: Date? = nil
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
        self.pricesFetchedAt = pricesFetchedAt
    }

    public var isEmpty: Bool { days.isEmpty && total.total == 0 }
}
