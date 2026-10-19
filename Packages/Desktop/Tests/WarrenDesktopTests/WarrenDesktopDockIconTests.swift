import AppKit
import WarrenDomain
import XCTest
@testable import WarrenDesktop

/// The app icon colorway preference: what it defaults to, what it tolerates
/// reading back, and that every colorway has an image to hand the Dock.
final class WarrenDesktopDockIconTests: XCTestCase {
    /// Caramel is the icon the bundle ships, so an unwritten preference must
    /// leave the Dock showing exactly that.
    func testDefaultColorwayIsTheBundledCaramelIcon() {
        XCTAssertEqual(WarrenAppIconColorway.defaultValue, .caramel)
        XCTAssertEqual(WarrenAppIconColorway(storedValue: nil), .caramel)
    }

    func testUnreadableStoredValuesFallBackToTheDefault() {
        XCTAssertEqual(WarrenAppIconColorway(storedValue: "neon"), .caramel)
        XCTAssertEqual(WarrenAppIconColorway(storedValue: ""), .caramel)
        XCTAssertEqual(WarrenAppIconColorway(storedValue: "Ember"), .caramel, "Raw values are lowercase")
    }

    func testEveryColorwayRoundTripsAndShipsADockImage() {
        for colorway in WarrenAppIconColorway.allCases {
            XCTAssertEqual(WarrenAppIconColorway(storedValue: colorway.rawValue), colorway)
            XCTAssertFalse(colorway.displayName.isEmpty)
            XCTAssertNotNil(
                WarrenDesktopDockIcon.image(for: colorway),
                "\(WarrenDesktopDockIcon.resourceName(for: colorway)).png is missing from the bundle"
            )
        }
    }

    func testStoredColorwayReadsTheSharedPreferenceKey() {
        let suite = "WarrenDesktopDockIconTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(WarrenDesktopDockIcon.storedColorway(defaults: defaults), .caramel)
        defaults.set("paper", forKey: WarrenPreferenceKey.appearanceAppIcon)
        XCTAssertEqual(WarrenDesktopDockIcon.storedColorway(defaults: defaults), .paper)
        defaults.removePersistentDomain(forName: suite)
    }
}
