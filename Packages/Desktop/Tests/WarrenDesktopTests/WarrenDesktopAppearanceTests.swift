import AppKit
import WarrenDomain
import XCTest
@testable import WarrenDesktop

/// The appearance preference's contract: what it defaults to, what it tolerates
/// reading back, and what it hands AppKit.
final class WarrenDesktopAppearanceTests: XCTestCase {
    /// Warren shipped dark-only. Defaulting to System would repaint every
    /// existing install the first time it launched on a light Mac, which is a
    /// change of appearance nobody asked for.
    func testDefaultModeIsDarkRatherThanFollowingTheSystem() {
        XCTAssertEqual(WarrenAppearanceMode.defaultValue, .dark)
        XCTAssertEqual(WarrenAppearanceMode(storedValue: nil), .dark)
    }

    /// A preference file is user-writable, so a hand-edited or stale value has
    /// to fall back rather than trap.
    func testUnreadableStoredValuesFallBackToTheDefault() {
        XCTAssertEqual(WarrenAppearanceMode(storedValue: "sepia"), .dark)
        XCTAssertEqual(WarrenAppearanceMode(storedValue: ""), .dark)
        XCTAssertEqual(WarrenAppearanceMode(storedValue: "Light"), .dark, "Raw values are lowercase")
    }

    func testEveryModeRoundTripsThroughItsStoredValue() {
        for mode in WarrenAppearanceMode.allCases {
            XCTAssertEqual(WarrenAppearanceMode(storedValue: mode.rawValue), mode)
            XCTAssertFalse(mode.displayName.isEmpty)
        }
        XCTAssertEqual(WarrenAppearanceMode.allCases, [.system, .light, .dark])
    }

    /// System has to mean "no override" rather than "whatever the system is
    /// right now": only a nil appearance keeps following macOS through a mid-
    /// session change or its Auto schedule.
    func testSystemModeClearsTheOverrideInsteadOfSnapshottingIt() {
        XCTAssertNil(WarrenDesktopAppearance.appearance(for: .system))
        XCTAssertEqual(WarrenDesktopAppearance.appearance(for: .light)?.name, .aqua)
        XCTAssertEqual(WarrenDesktopAppearance.appearance(for: .dark)?.name, .darkAqua)
    }

    func testStoredModeReadsTheSharedPreferenceKey() {
        let defaults = UserDefaults(suiteName: "WarrenDesktopAppearanceTests")!
        defaults.removePersistentDomain(forName: "WarrenDesktopAppearanceTests")
        XCTAssertEqual(WarrenDesktopAppearance.storedMode(defaults: defaults), .dark)

        defaults.set("light", forKey: WarrenPreferenceKey.appearanceMode)
        XCTAssertEqual(WarrenDesktopAppearance.storedMode(defaults: defaults), .light)

        defaults.set("system", forKey: WarrenPreferenceKey.appearanceMode)
        XCTAssertEqual(WarrenDesktopAppearance.storedMode(defaults: defaults), .system)

        defaults.removePersistentDomain(forName: "WarrenDesktopAppearanceTests")
    }

    /// The settings page is reachable by link, so the section needs a stable
    /// address and the aliases someone would actually type.
    func testAppearanceSectionIsAddressableByItsCommonNames() {
        XCTAssertEqual(WarrenDesktopSettingsSection.appearance.deepLinkValue, "appearance")
        for value in ["appearance", "theme", "light", "dark"] {
            XCTAssertEqual(WarrenDesktopSettingsSection(deepLinkValue: value), .appearance, value)
        }
        XCTAssertEqual(
            WarrenDesktopSettingsSection(deepLinkValue: "APPEARANCE"),
            .appearance,
            "Deep link values are matched case-insensitively"
        )
    }

    /// Every section round-trips, so adding one cannot silently leave it
    /// unlinkable.
    func testEverySettingsSectionRoundTripsThroughItsDeepLinkValue() {
        for section in WarrenDesktopSettingsSection.allCases {
            XCTAssertEqual(
                WarrenDesktopSettingsSection(deepLinkValue: section.deepLinkValue),
                section,
                section.rawValue
            )
        }
    }
}
