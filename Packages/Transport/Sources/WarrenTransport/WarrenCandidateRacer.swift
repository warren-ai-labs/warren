import Foundation

/// A direct URL advertised by a Host or retained from a previous connection.
/// Higher priorities are started first and break latency ties during a race.
public struct WarrenHostCandidate: Codable, Equatable, Hashable, Sendable {
    public let url: String
    public let priority: Int

    public init(url: String, priority: Int = 0) {
        self.url = url
        self.priority = priority
    }
}

/// The result of probing one advertised path. A probe is deliberately
/// credential-free; `/healthz` only proves that the path reaches the expected
/// Warren Host and does not grant access to its workspace.
public struct WarrenCandidateProbeResult: Codable, Equatable, Hashable, Sendable {
    public let candidate: WarrenHostCandidate
    public let reachable: Bool
    public let latencyMilliseconds: Int?
    public let message: String
    public let hostID: String?

    public init(
        candidate: WarrenHostCandidate,
        reachable: Bool,
        latencyMilliseconds: Int? = nil,
        message: String = "",
        hostID: String? = nil
    ) {
        self.candidate = candidate
        self.reachable = reachable
        self.latencyMilliseconds = latencyMilliseconds
        self.message = message
        self.hostID = hostID
    }
}

/// A complete probe pass over every candidate for one Host identity.
public struct WarrenCandidateRaceResult: Codable, Equatable, Hashable, Sendable {
    public let winner: WarrenHostCandidate?
    public let probes: [WarrenCandidateProbeResult]

    public init(winner: WarrenHostCandidate?, probes: [WarrenCandidateProbeResult]) {
        self.winner = winner
        self.probes = probes
    }
}

/// Implements RFC 0019's Happy-Eyeballs-style direct Host race. Probes never
/// carry endpoint credentials; the public `/healthz` response is checked for
/// the expected Host identity before a candidate can win.
public enum WarrenCandidateRacer {
    public static let defaultStagger: Duration = .milliseconds(50)
    public static let defaultTimeout: TimeInterval = 0.8

    public static func race(
        candidates: [WarrenHostCandidate],
        expectedHostID: String? = nil,
        session: URLSession = .shared,
        stagger: Duration = defaultStagger,
        timeout: TimeInterval = defaultTimeout,
        clientID: String? = nil
    ) async -> WarrenHostCandidate? {
        await raceDetailed(
            candidates: candidates,
            expectedHostID: expectedHostID,
            session: session,
            stagger: stagger,
            timeout: timeout,
            clientID: clientID
        ).winner
    }

    /// Probes every unique candidate and selects the reachable path with the
    /// lowest observed latency. Priority remains the deterministic tie-breaker
    /// and controls launch order, so a preferred interface still gets a small
    /// head start without masking a faster path on another network.
    public static func raceDetailed(
        candidates: [WarrenHostCandidate],
        expectedHostID: String? = nil,
        session: URLSession = .shared,
        stagger: Duration = defaultStagger,
        timeout: TimeInterval = defaultTimeout,
        clientID: String? = nil
    ) async -> WarrenCandidateRaceResult {
        let ordered = uniqueCandidates(candidates)
        guard !ordered.isEmpty else {
            return WarrenCandidateRaceResult(winner: nil, probes: [])
        }

        let probes = await withTaskGroup(of: WarrenCandidateProbeResult.self, returning: [WarrenCandidateProbeResult].self) { group in
            for (index, candidate) in ordered.enumerated() {
                group.addTask {
                    let delay = staggerNanoseconds(stagger, index: index)
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    guard !Task.isCancelled else {
                        return WarrenCandidateProbeResult(
                            candidate: candidate,
                            reachable: false,
                            message: "Probe cancelled"
                        )
                    }

                    let endpoint = WarrenRemoteEndpointConfiguration(
                        name: "Discovered Host",
                        url: candidate.url
                    )
                    let started = Date()
                    let probe = await WarrenHostProbe.check(
                        endpoint,
                        session: session,
                        expectedHostID: expectedHostID,
                        timeout: timeout,
                        clientID: clientID
                    )
                    let elapsed = max(0, Int((Date().timeIntervalSince(started) * 1_000).rounded()))
                    return WarrenCandidateProbeResult(
                        candidate: candidate,
                        reachable: !probe.isFailure,
                        latencyMilliseconds: elapsed,
                        message: probe.message,
                        hostID: probe.hostID
                    )
                }
            }

            var values: [WarrenCandidateProbeResult] = []
            values.reserveCapacity(ordered.count)
            for await result in group {
                values.append(result)
            }
            return values
        }

        let winner = probes
            .filter(\.reachable)
            .sorted { lhs, rhs in
                let leftLatency = lhs.latencyMilliseconds ?? .max
                let rightLatency = rhs.latencyMilliseconds ?? .max
                if leftLatency != rightLatency { return leftLatency < rightLatency }
                if lhs.candidate.priority != rhs.candidate.priority {
                    return lhs.candidate.priority > rhs.candidate.priority
                }
                return lhs.candidate.url < rhs.candidate.url
            }
            .first?
            .candidate
        return WarrenCandidateRaceResult(winner: winner, probes: probes.sorted {
            if $0.candidate.priority != $1.candidate.priority {
                return $0.candidate.priority > $1.candidate.priority
            }
            return $0.candidate.url < $1.candidate.url
        })
    }

    private static func uniqueCandidates(_ candidates: [WarrenHostCandidate]) -> [WarrenHostCandidate] {
        var seen = Set<String>()
        return candidates
            .compactMap { candidate in
                let url = candidate.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                return WarrenHostCandidate(url: url, priority: candidate.priority)
            }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.url < $1.url
            }
            .filter { seen.insert($0.url).inserted }
    }

    private static func staggerNanoseconds(_ duration: Duration, index: Int) -> UInt64 {
        guard index > 0, duration > .zero else { return 0 }
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 0 }
        let seconds = max(0, components.seconds)
        let attoseconds = max(0, components.attoseconds)
        let nanoseconds = UInt64(seconds) &* 1_000_000_000
            &+ UInt64(attoseconds / 1_000_000_000)
        return nanoseconds.multipliedReportingOverflow(by: UInt64(index)).partialValue
    }
}
