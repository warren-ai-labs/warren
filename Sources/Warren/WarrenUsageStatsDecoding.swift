import Foundation
import WarrenDesktop

/// Parameters for one `usage.stats` request.
///
/// Extracted from the model so the trailing-window math and the cache key are
/// testable without a live transport. Days are the Host's local calendar days;
/// the client only names the window and must not reinterpret the boundaries.
struct WarrenUsageStatsRequest: Equatable {
    let fromDay: String
    let toDay: String
    /// The detail day, or nil to let the Host pick the most recent day with
    /// intraday data.
    let intervalDay: String?

    static func window(
        days: Int,
        selectedDay: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WarrenUsageStatsRequest {
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: now) ?? now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = (selectedDay?.isEmpty ?? true) ? nil : selectedDay
        return WarrenUsageStatsRequest(
            fromDay: formatter.string(from: start),
            toDay: formatter.string(from: now),
            intervalDay: day
        )
    }

    /// Identifies a payload for cache reuse. Switching Usage views with the same
    /// window and day must not refetch.
    var cacheKey: String { "\(fromDay)..\(toDay)..\(intervalDay ?? "-")" }

    var parameters: [String: String] {
        var params = ["fromDay": fromDay, "toDay": toDay]
        if let intervalDay { params["intervalDay"] = intervalDay }
        return params
    }
}

/// Wire shape of `usage.stats`, decoded into the desktop presentation model.
///
/// Kept as its own Codable layer rather than making the presentation types
/// Decodable: the panel's model carries derived helpers and display fallbacks
/// that have no business being part of a protocol contract.
///
/// Every field decodes explicitly through `decodeIfPresent`. Swift's synthesized
/// initializer treats a property default as a fallback only for the *type*, not
/// for a missing key, so it would reject a payload the Host legitimately sends:
/// Go omits zero-valued fields, meaning a quiet day arrives without `cacheWrite`
/// and a fully priced range without `unmeasuredProviders`.
struct WarrenUsageStatsResponse: Decodable {
    struct Buckets: Decodable {
        let freshInput: Int64
        let cacheWrite: Int64
        let cacheRead: Int64
        let output: Int64
        let reasoning: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            freshInput = try container.decodeIfPresent(Int64.self, forKey: .freshInput) ?? 0
            cacheWrite = try container.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0
            cacheRead = try container.decodeIfPresent(Int64.self, forKey: .cacheRead) ?? 0
            output = try container.decodeIfPresent(Int64.self, forKey: .output) ?? 0
            reasoning = try container.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
        }

        init() {
            freshInput = 0
            cacheWrite = 0
            cacheRead = 0
            output = 0
            reasoning = 0
        }

        private enum CodingKeys: String, CodingKey {
            case freshInput, cacheWrite, cacheRead, output, reasoning
        }
    }

    struct Cost: Decodable {
        let nanoUsd: Int64
        let calls: Int64
        let pricedCalls: Int64
        let unmeasuredProviders: [String]
        let unpricedModels: [String]
        let byBucket: BucketCost

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nanoUsd = try container.decodeIfPresent(Int64.self, forKey: .nanoUsd) ?? 0
            calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
            pricedCalls = try container.decodeIfPresent(Int64.self, forKey: .pricedCalls) ?? 0
            unmeasuredProviders =
                try container.decodeIfPresent([String].self, forKey: .unmeasuredProviders) ?? []
            unpricedModels =
                try container.decodeIfPresent([String].self, forKey: .unpricedModels) ?? []
            byBucket = try container.decodeIfPresent(BucketCost.self, forKey: .byBucket) ?? BucketCost()
        }

        init() {
            nanoUsd = 0
            calls = 0
            pricedCalls = 0
            unmeasuredProviders = []
            unpricedModels = []
            byBucket = BucketCost()
        }

        private enum CodingKeys: String, CodingKey {
            case nanoUsd, calls, pricedCalls, unmeasuredProviders, unpricedModels, byBucket
        }
    }

    struct Day: Decodable {
        let day: String
        let buckets: Buckets
        let cost: Cost

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
            buckets = try container.decodeIfPresent(Buckets.self, forKey: .buckets) ?? Buckets()
            cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        }

        private enum CodingKeys: String, CodingKey {
            case day, buckets, cost
        }
    }

    struct Interval: Decodable {
        let day: String
        let minute: Int
        let provider: String
        let model: String
        let buckets: Buckets
        let cost: Cost

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
            minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
            provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
            model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
            buckets = try container.decodeIfPresent(Buckets.self, forKey: .buckets) ?? Buckets()
            cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        }

        private enum CodingKeys: String, CodingKey {
            case day, minute, provider, model, buckets, cost
        }
    }

    struct BucketCost: Decodable {
        let freshInput: Int64
        let cacheWrite: Int64
        let cacheRead: Int64
        let output: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            freshInput = try container.decodeIfPresent(Int64.self, forKey: .freshInput) ?? 0
            cacheWrite = try container.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0
            cacheRead = try container.decodeIfPresent(Int64.self, forKey: .cacheRead) ?? 0
            output = try container.decodeIfPresent(Int64.self, forKey: .output) ?? 0
        }

        init() {
            freshInput = 0
            cacheWrite = 0
            cacheRead = 0
            output = 0
        }

        private enum CodingKeys: String, CodingKey {
            case freshInput, cacheWrite, cacheRead, output
        }
    }

    struct Group: Decodable {
        let key: String
        let label: String
        let buckets: Buckets
        let cost: Cost

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
            buckets = try container.decodeIfPresent(Buckets.self, forKey: .buckets) ?? Buckets()
            cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        }

        private enum CodingKeys: String, CodingKey {
            case key, label, buckets, cost
        }
    }

    let fromDay: String
    let toDay: String
    let total: Buckets
    let cost: Cost
    let days: [Day]
    let intervals: [Interval]
    let intervalBucketMinutes: Int
    let providers: [Group]
    let models: [Group]
    let projects: [Group]
    let detailDay: String?
    let dayProviders: [Group]
    let dayModels: [Group]
    let dayProjects: [Group]
    let pricesFetchedAt: String?
    let lastRebuild: RebuildStamp?

    struct RebuildStamp: Decodable {
        let completedAt: String
        let providers: [String]
        let calls: Int64

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt) ?? ""
            providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
            calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        }

        private enum CodingKeys: String, CodingKey {
            case completedAt, providers, calls
        }

        /// Nil when the Host sent a stamp whose time cannot be read: the figures
        /// it describes are still correct, only their age is unknown.
        var model: WarrenUsageRebuildStamp? {
            WarrenUsageStatsResponse.parseTimestamp(completedAt).map {
                WarrenUsageRebuildStamp(completedAt: $0, providers: providers, calls: calls)
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fromDay = try container.decodeIfPresent(String.self, forKey: .fromDay) ?? ""
        toDay = try container.decodeIfPresent(String.self, forKey: .toDay) ?? ""
        total = try container.decodeIfPresent(Buckets.self, forKey: .total) ?? Buckets()
        cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        days = try container.decodeIfPresent([Day].self, forKey: .days) ?? []
        intervals = try container.decodeIfPresent([Interval].self, forKey: .intervals) ?? []
        intervalBucketMinutes =
            try container.decodeIfPresent(Int.self, forKey: .intervalBucketMinutes) ?? 5
        providers = try container.decodeIfPresent([Group].self, forKey: .providers) ?? []
        models = try container.decodeIfPresent([Group].self, forKey: .models) ?? []
        projects = try container.decodeIfPresent([Group].self, forKey: .projects) ?? []
        detailDay = try container.decodeIfPresent(String.self, forKey: .detailDay)
        dayProviders = try container.decodeIfPresent([Group].self, forKey: .dayProviders) ?? []
        dayModels = try container.decodeIfPresent([Group].self, forKey: .dayModels) ?? []
        dayProjects = try container.decodeIfPresent([Group].self, forKey: .dayProjects) ?? []
        pricesFetchedAt = try container.decodeIfPresent(String.self, forKey: .pricesFetchedAt)
        lastRebuild = try container.decodeIfPresent(RebuildStamp.self, forKey: .lastRebuild)
    }

    private enum CodingKeys: String, CodingKey {
        case fromDay, toDay, total, cost, days, intervals, intervalBucketMinutes
        case providers, models, projects, detailDay
        case dayProviders, dayModels, dayProjects, pricesFetchedAt, lastRebuild
    }
}

/// Wire shape of `usage.rebuild`.
///
/// Decoded rather than discarded so the settings surface can say what the
/// rebuild replaced. Every field is optional for the same reason as the stats
/// payload: Go omits zero values, so a rebuild that found nothing arrives as an
/// almost empty object.
struct WarrenUsageRebuildResponse: Decodable {
    let rebuilt: Bool
    let providers: [String]
    let observations: Int64
    let calls: Int64
    let days: Int64
    let completedAt: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rebuilt = try container.decodeIfPresent(Bool.self, forKey: .rebuilt) ?? false
        providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
        observations = try container.decodeIfPresent(Int64.self, forKey: .observations) ?? 0
        calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
        days = try container.decodeIfPresent(Int64.self, forKey: .days) ?? 0
        completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case rebuilt, providers, observations, calls, days, completedAt
    }

    var model: WarrenUsageRebuildSummary {
        WarrenUsageRebuildSummary(
            providers: providers,
            observations: observations,
            calls: calls,
            days: days,
            completedAt: completedAt.flatMap(WarrenUsageStatsResponse.parseTimestamp)
        )
    }
}

extension WarrenUsageStatsResponse.Buckets {
    var model: WarrenUsageBuckets {
        WarrenUsageBuckets(
            freshInput: freshInput,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead,
            output: output,
            reasoning: reasoning
        )
    }
}

extension WarrenUsageStatsResponse.Cost {
    var model: WarrenUsageCost {
        WarrenUsageCost(
            nanoUSD: nanoUsd,
            calls: calls,
            pricedCalls: pricedCalls,
            unmeasuredProviders: unmeasuredProviders,
            unpricedModels: unpricedModels,
            byBucket: WarrenUsageBucketCost(
                freshInput: byBucket.freshInput,
                cacheWrite: byBucket.cacheWrite,
                cacheRead: byBucket.cacheRead,
                output: byBucket.output
            )
        )
    }
}

extension WarrenUsageStatsResponse.Group {
    var model: WarrenUsageGroup {
        WarrenUsageGroup(key: key, label: label, buckets: buckets.model, cost: cost.model)
    }
}

extension WarrenUsageStatsResponse {
    var model: WarrenUsageStats {
        WarrenUsageStats(
            fromDay: fromDay,
            toDay: toDay,
            total: total.model,
            cost: cost.model,
            days: days.map {
                WarrenUsageDay(day: $0.day, buckets: $0.buckets.model, cost: $0.cost.model)
            },
            intervals: intervals.map {
                WarrenUsageInterval(
                    day: $0.day,
                    minute: $0.minute,
                    provider: $0.provider,
                    model: $0.model,
                    buckets: $0.buckets.model,
                    cost: $0.cost.model
                )
            },
            intervalBucketMinutes: intervalBucketMinutes,
            providers: providers.map(\.model),
            models: models.map(\.model),
            projects: projects.map(\.model),
            detailDay: detailDay.flatMap { $0.isEmpty ? nil : $0 },
            dayProviders: dayProviders.map(\.model),
            dayModels: dayModels.map(\.model),
            dayProjects: dayProjects.map(\.model),
            pricesFetchedAt: pricesFetchedAt.flatMap(Self.parseTimestamp),
            lastRebuild: lastRebuild?.model
        )
    }

    /// Parses the Host's RFC 3339 timestamp, with and without fractional
    /// seconds, since Go emits either depending on the clock.
    static func parseTimestamp(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
