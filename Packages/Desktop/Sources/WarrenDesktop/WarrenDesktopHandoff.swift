import Foundation
import WarrenDomain

/// Who writes the brief a handed-off Session starts from.
public enum WarrenDesktopHandoffMode: String, Sendable, Hashable {
    /// The source Agent writes it in a turn of its own. Cheap while its
    /// prompt cache is warm; a cold cache reads the whole context again.
    case agent
    /// The Host assembles it from the recorded conversation, with no model
    /// call.
    case extract
}

/// What the Host knows about a Session a handoff would start from.
///
/// The Host does not see the provider's cache. It reports the last model
/// response it recorded and the cache lifetime to count it against.
public struct WarrenDesktopHandoffStatus: Equatable, Sendable {
    public var provider: String
    public var model: String?
    public var lastResponseAt: Date?
    public var cacheTTL: TimeInterval
    /// The lifetime is not a documented fixed value for this provider.
    public var estimated: Bool
    /// Input tokens of the last model call: what a cold brief reads again.
    public var contextTokens: Int
    /// The source Agent can take a turn now.
    public var canAsk: Bool

    public init(
        provider: String,
        model: String? = nil,
        lastResponseAt: Date? = nil,
        cacheTTL: TimeInterval,
        estimated: Bool,
        contextTokens: Int = 0,
        canAsk: Bool
    ) {
        self.provider = provider
        self.model = model
        self.lastResponseAt = lastResponseAt
        self.cacheTTL = cacheTTL
        self.estimated = estimated
        self.contextTokens = contextTokens
        self.canAsk = canAsk
    }

    public enum Cache: Equatable, Sendable {
        case unknown
        case warm(remaining: TimeInterval)
        case cold
    }

    public func cache(at now: Date) -> Cache {
        guard let lastResponseAt else { return .unknown }
        let remaining = lastResponseAt.addingTimeInterval(cacheTTL).timeIntervalSince(now)
        return remaining > 0 ? .warm(remaining: remaining) : .cold
    }

    /// The brief to offer first: the Agent's own while its cache is warm,
    /// the extracted one otherwise.
    public func recommendedMode(at now: Date) -> WarrenDesktopHandoffMode {
        guard canAsk, case .warm = cache(at: now) else { return .extract }
        return .agent
    }

    /// "Cache warm · 3:12 left", "Cache likely cold", or nil when nothing
    /// was recorded.
    public func cacheLabel(at now: Date) -> String? {
        let qualifier = estimated ? "likely " : ""
        switch cache(at: now) {
        case .unknown:
            return nil
        case .warm(let remaining):
            let seconds = Int(remaining.rounded(.up))
            return "Cache \(qualifier)warm · \(seconds / 60):\(String(format: "%02d", seconds % 60)) left"
        case .cold:
            return "Cache \(qualifier)cold"
        }
    }

    /// "Warm · 3:12" or "Cold", for the narrow end of a menu row.
    public func compactCacheLabel(at now: Date) -> String? {
        switch cache(at: now) {
        case .unknown:
            return nil
        case .warm(let remaining):
            let seconds = Int(remaining.rounded(.up))
            return "Warm · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
        case .cold:
            return "Cold"
        }
    }

    /// "~92k tokens" for the context a brief from the Agent reads.
    public var contextLabel: String? {
        guard contextTokens > 0 else { return nil }
        if contextTokens >= 1_000 {
            return "~\(Int((Double(contextTokens) / 1_000).rounded()))k tokens"
        }
        return "~\(contextTokens) tokens"
    }
}

/// Starts a fresh Agent Session from a long one.
public struct WarrenDesktopHandoffRequest: Hashable, Sendable {
    public var source: TerminalSessionID
    public var workspace: WorkspaceID
    public var launch: TerminalSessionLaunchRequest
    public var mode: WarrenDesktopHandoffMode

    public init(
        source: TerminalSessionID,
        workspace: WorkspaceID,
        launch: TerminalSessionLaunchRequest,
        mode: WarrenDesktopHandoffMode
    ) {
        self.source = source
        self.workspace = workspace
        self.launch = launch
        self.mode = mode
    }
}
