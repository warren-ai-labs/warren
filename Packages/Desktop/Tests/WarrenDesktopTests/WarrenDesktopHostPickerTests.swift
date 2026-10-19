import XCTest
@testable import WarrenDesktop

final class WarrenDesktopHostPickerTests: XCTestCase {
    func testLocalEndpointIsNamedForTheMachine() {
        let local = WarrenDesktopEndpointOption(id: "local", label: "Local", isLocal: true, detail: "127.0.0.1:8789")
        XCTAssertEqual(
            WarrenDesktopHostPickerRow.name(for: local, machineName: "matebook-x-pro.local"),
            "matebook-x-pro"
        )
        XCTAssertEqual(WarrenDesktopHostPickerRow.route(for: local), "Local · 127.0.0.1:8789")
    }

    func testCustomLocalNameIsKept() {
        let local = WarrenDesktopEndpointOption(id: "local", label: "Studio", isLocal: true)
        XCTAssertEqual(WarrenDesktopHostPickerRow.name(for: local, machineName: "mac"), "Studio")
    }

    func testRemoteRouteIsItsDetail() {
        let ssh = WarrenDesktopEndpointOption(id: "beelink", label: "beelink", detail: "SSH · beelink")
        XCTAssertEqual(WarrenDesktopHostPickerRow.route(for: ssh), "SSH · beelink")
    }

    func testProbeStateFollowsTheResultWhenNotGiven() {
        XCTAssertEqual(WarrenDesktopEndpointOption(id: "a", label: "a").probeState, .unknown)
        XCTAssertEqual(
            WarrenDesktopEndpointOption(id: "a", label: "a", probeStatus: "Host reachable").probeState,
            .reachable
        )
        XCTAssertEqual(
            WarrenDesktopEndpointOption(id: "a", label: "a", probeStatus: "timed out", probeFailed: true).probeState,
            .failed
        )
    }

    func testConnectionErrorTurnsTheWindowHostRed() {
        let endpoint = WarrenDesktopEndpointOption(
            id: "dev",
            label: "dev",
            probeStatus: "Host reachable",
            probeState: .reachable,
            connectionError: "ssh: connection refused"
        )
        XCTAssertEqual(WarrenDesktopHostPickerRow(endpoint: endpoint, isSelected: true).state, .failed)
        XCTAssertEqual(WarrenDesktopHostPickerRow(endpoint: endpoint, isSelected: false).state, .reachable)
    }

    func testTooltipCarriesTheProbeTextTheRowLeavesOut() {
        let endpoint = WarrenDesktopEndpointOption(
            id: "local",
            label: "Local",
            isLocal: true,
            detail: "127.0.0.1:8789",
            probeStatus: "Host reachable · protocol 4.0\nHeadless a317e887"
        )
        let row = WarrenDesktopHostPickerRow(endpoint: endpoint, isSelected: true)
        XCTAssertTrue(row.tooltip.contains("Host reachable · protocol 4.0"))
        XCTAssertTrue(row.tooltip.contains("Headless a317e887"))
    }

    func testForcedProbeIsTheDefault() {
        let plain = Notification(name: WarrenDesktopEndpointOption.probeRequested)
        XCTAssertTrue(WarrenDesktopEndpointOption.isForcedProbe(plain))
        let lazy = Notification(
            name: WarrenDesktopEndpointOption.probeRequested,
            userInfo: [WarrenDesktopEndpointOption.forceProbeKey: false]
        )
        XCTAssertFalse(WarrenDesktopEndpointOption.isForcedProbe(lazy))
    }

    func testPublicAddressDropsTheScheme() {
        let url = URL(string: "https://mbp-7f3a.warren.link/")!
        XCTAssertEqual(WarrenDesktopHostPanelPublicAccess.displayAddress(url), "mbp-7f3a.warren.link")
    }
}
