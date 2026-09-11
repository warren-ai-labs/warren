import Foundation
import WarrenDesktop

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

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            nanoUsd = try container.decodeIfPresent(Int64.self, forKey: .nanoUsd) ?? 0
            calls = try container.decodeIfPresent(Int64.self, forKey: .calls) ?? 0
            pricedCalls = try container.decodeIfPresent(Int64.self, forKey: .pricedCalls) ?? 0
            unmeasuredProviders =
                try container.decodeIfPresent([String].self, forKey: .unmeasuredProviders) ?? []
        }

        init() {
            nanoUsd = 0
            calls = 0
            pricedCalls = 0
            unmeasuredProviders = []
        }

        private enum CodingKeys: String, CodingKey {
            case nanoUsd, calls, pricedCalls, unmeasuredProviders
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
        let buckets: Buckets
        let cost: Cost

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            day = try container.decodeIfPresent(String.self, forKey: .day) ?? ""
            minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
            buckets = try container.decodeIfPresent(Buckets.self, forKey: .buckets) ?? Buckets()
            cost = try container.decodeIfPresent(Cost.self, forKey: .cost) ?? Cost()
        }

        private enum CodingKeys: String, CodingKey {
            case day, minute, buckets, cost
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
    let pricesFetchedAt: String?

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
        pricesFetchedAt = try container.decodeIfPresent(String.self, forKey: .pricesFetchedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case fromDay, toDay, total, cost, days, intervals, intervalBucketMinutes
        case providers, models, projects, pricesFetchedAt
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
            unmeasuredProviders: unmeasuredProviders
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
                    buckets: $0.buckets.model,
                    cost: $0.cost.model
                )
            },
            intervalBucketMinutes: intervalBucketMinutes,
            providers: providers.map(\.model),
            models: models.map(\.model),
            projects: projects.map(\.model),
            pricesFetchedAt: pricesFetchedAt.flatMap(Self.parseTimestamp)
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
