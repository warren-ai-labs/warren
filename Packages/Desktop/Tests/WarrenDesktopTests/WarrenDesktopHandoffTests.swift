import AppKit
import SwiftUI
import XCTest

import WarrenDomain
import WarrenObservation
@testable import WarrenDesktop

@MainActor
final class WarrenDesktopHandoffTests: XCTestCase {
    private var savedInterface: Any?
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        savedInterface = UserDefaults.standard.object(forKey: WarrenPreferenceKey.agentInterface)
    }

    override func tearDown() {
        UserDefaults.standard.set(savedInterface, forKey: WarrenPreferenceKey.agentInterface)
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func status(secondsAgo: TimeInterval?, canAsk: Bool = true, estimated: Bool = false) -> WarrenDesktopHandoffStatus {
        WarrenDesktopHandoffStatus(
            provider: "claude",
            lastResponseAt: secondsAgo.map { now.addingTimeInterval(-$0) },
            cacheTTL: 300,
            estimated: estimated,
            contextTokens: 92_010,
            canAsk: canAsk
        )
    }

    func testCacheCountsDownFromTheLastResponse() {
        XCTAssertEqual(status(secondsAgo: 108).cache(at: now), .warm(remaining: 192))
        XCTAssertEqual(status(secondsAgo: 108).cacheLabel(at: now), "Cache warm · 3:12 left")
        XCTAssertEqual(status(secondsAgo: 108).compactCacheLabel(at: now), "Warm · 3:12")
        XCTAssertEqual(status(secondsAgo: 301).cache(at: now), .cold)
        XCTAssertEqual(status(secondsAgo: 301).compactCacheLabel(at: now), "Cold")
        XCTAssertEqual(status(secondsAgo: 301, estimated: true).cacheLabel(at: now), "Cache likely cold")
        XCTAssertEqual(status(secondsAgo: nil).cache(at: now), .unknown)
        XCTAssertNil(status(secondsAgo: nil).cacheLabel(at: now))
        XCTAssertEqual(status(secondsAgo: 0).contextLabel, "~92k tokens")
    }

    /// A warm cache makes the Agent's own brief cheap; anything else falls
    /// back to the extracted one.
    func testRecommendedBriefFollowsTheCache() {
        XCTAssertEqual(status(secondsAgo: 10).recommendedMode(at: now), .agent)
        XCTAssertEqual(status(secondsAgo: 400).recommendedMode(at: now), .extract)
        XCTAssertEqual(status(secondsAgo: 10, canAsk: false).recommendedMode(at: now), .extract)
        XCTAssertEqual(status(secondsAgo: nil).recommendedMode(at: now), .extract)
    }

    private final class Handoffs {
        var requests: [(TerminalSessionLaunchRequest, WarrenDesktopHandoffMode)] = []
    }

    private func mount(
        source: TerminalSessionID?,
        status: WarrenDesktopHandoffStatus?
    ) -> (NSHostingView<some View>, WarrenSemanticRecorder, Handoffs) {
        UserDefaults.standard.set(WarrenAgentInterface.cli.rawValue, forKey: WarrenPreferenceKey.agentInterface)
        let recorder = WarrenSemanticRecorder()
        let handoffs = Handoffs()
        let bar = WarrenDesktopPresetBar(
            workspace: Workspace(projectID: ProjectID(), name: "demo", path: "/tmp/demo"),
            isBusy: false,
            canUseEmbeddedBrowser: true,
            onLaunch: { _ in XCTFail("A handoff must not launch a plain Session") },
            handoffSource: source,
            handoffSourceName: "Claude",
            loadHandoffStatus: { _ in status },
            onHandoff: { handoffs.requests.append(($0, $1)) }
        )
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 400, height: 500)
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        settle()
        return (host, recorder, handoffs)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    func testHandoffRowOnlyAppearsForAnAgentSource() {
        let (_, recorder, _) = mount(source: nil, status: nil)
        XCTAssertNil(recorder.snapshot().node(id: "preset.handoff"))
    }

    func testHandoffOpensAgentsAndHandsOffWithTheRecommendedBrief() throws {
        let warm = WarrenDesktopHandoffStatus(
            provider: "claude",
            lastResponseAt: Date().addingTimeInterval(-30),
            cacheTTL: 300,
            estimated: false,
            canAsk: true
        )
        let (host, recorder, handoffs) = mount(source: TerminalSessionID(), status: warm)
        try recorder.perform(.press, on: "preset.handoff")
        host.layoutSubtreeIfNeeded()
        settle()

        let snapshot = recorder.snapshot()
        XCTAssertEqual(snapshot.node(id: "handoff.mode.agent")?.isSelected, true, "A warm cache offers the Agent's brief")
        XCTAssertEqual(snapshot.node(id: "handoff.mode.extract")?.isSelected, false)
        XCTAssertNotNil(snapshot.node(id: "handoff.pi"))
        XCTAssertNil(snapshot.node(id: "handoff.shell"), "Only Agents can take a handoff")

        try recorder.perform(.press, on: "handoff.mode.extract")
        settle()
        try recorder.perform(.press, on: "handoff.codex")
        settle()
        XCTAssertEqual(handoffs.requests.map(\.0.kind), [.codex])
        XCTAssertEqual(handoffs.requests.map(\.1), [.extract])
        XCTAssertNil(handoffs.requests.first?.0.agentHandler, "The CLI interface starts the terminal Agent")
    }
}
