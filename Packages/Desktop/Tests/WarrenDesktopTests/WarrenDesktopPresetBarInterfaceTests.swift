import AppKit
import SwiftUI
import XCTest

import WarrenDomain
import WarrenObservation
@testable import WarrenDesktop

/// The preset bar reads the Settings interface choice: "Ask each time" opens
/// a Terminal/Chat popover on ACP-capable presets, the other two launch
/// straight away.
@MainActor
final class WarrenDesktopPresetBarInterfaceTests: XCTestCase {
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

    private final class Launches {
        var requests: [TerminalSessionLaunchRequest] = []
    }

    private func mount(
        interface: WarrenAgentInterface
    ) -> (NSHostingView<some View>, WarrenSemanticRecorder, Launches) {
        UserDefaults.standard.set(interface.rawValue, forKey: WarrenPreferenceKey.agentInterface)
        let recorder = WarrenSemanticRecorder()
        let launches = Launches()
        let bar = WarrenDesktopPresetBar(
            workspace: Workspace(projectID: ProjectID(), name: "demo", path: "/tmp/demo"),
            terminalGroup: nil,
            isBusy: false,
            canUseEmbeddedBrowser: true,
            onLaunch: { launches.requests.append($0) }
        )
        .warrenSemanticObservationRoot(recorder: recorder)
        .environment(\.warrenSemanticRecorder, recorder)
        .frame(width: 1_400, height: 40)
        let host = NSHostingView(rootView: bar)
        host.frame = NSRect(x: 0, y: 0, width: 1_400, height: 40)
        // The Terminal/Chat choice is a popover, which only presents from a
        // view that is in a window.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        settle()
        return (host, recorder, launches)
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }

    /// The choice rows live in a popover, a separate hierarchy the recorder
    /// cannot see, so this pins the open state and the real popover window.
    func testAskEachTimeOpensTheChoiceInsteadOfLaunching() throws {
        let (host, recorder, launches) = mount(interface: .ask)
        XCTAssertEqual(recorder.snapshot().node(id: "preset.claude")?.isSelected, false)

        try recorder.perform(.press, on: "preset.claude")
        host.layoutSubtreeIfNeeded()
        settle()
        XCTAssertTrue(launches.requests.isEmpty, "The first click only opens the choice")
        XCTAssertEqual(recorder.snapshot().node(id: "preset.claude")?.isSelected, true)
        XCTAssertTrue(
            NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("Popover") },
            "The Terminal/Chat choice opens as a popover"
        )

        try recorder.perform(.press, on: "preset.claude")
        settle()
        XCTAssertEqual(recorder.snapshot().node(id: "preset.claude")?.isSelected, false, "A second click folds it")
        XCTAssertTrue(launches.requests.isEmpty)
    }

    func testAskEachTimeLaunchesPresetsWithoutACPDirectly() throws {
        let (_, recorder, launches) = mount(interface: .ask)
        try recorder.perform(.press, on: "preset.pi")
        XCTAssertEqual(launches.requests.map(\.kind), [.pi])
        XCTAssertNil(launches.requests.first?.agentHandler)
    }

    func testFixedInterfaceLaunchesWithoutAChoice() throws {
        let (_, acpRecorder, acpLaunches) = mount(interface: .acp)
        try acpRecorder.perform(.press, on: "preset.codex")
        XCTAssertEqual(acpLaunches.requests, [TerminalSessionLaunchRequest(kind: .codex, agentHandler: "acp")])

        let (_, cliRecorder, cliLaunches) = mount(interface: .cli)
        try cliRecorder.perform(.press, on: "preset.codex")
        XCTAssertEqual(cliLaunches.requests.map(\.kind), [.codex])
        XCTAssertEqual(cliLaunches.requests.map(\.agentHandler), [nil])
    }
}
