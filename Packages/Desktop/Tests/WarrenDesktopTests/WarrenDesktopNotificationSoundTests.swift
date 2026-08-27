import XCTest
@testable import WarrenDesktop
import WarrenDomain

@MainActor
final class WarrenDesktopNotificationSoundTests: XCTestCase {
    func testAgentCompletionSoundDefaultsToEnabled() {
        let defaults = makeDefaults()

        XCTAssertTrue(
            WarrenDesktopNotificationSound.isAgentCompletionSoundEnabled(defaults: defaults)
        )
    }

    func testAgentCompletionSoundRespectsTheLocalPreference() {
        let defaults = makeDefaults()
        var plays = 0

        defaults.set(false, forKey: WarrenPreferenceKey.agentCompletionSoundEnabled)
        WarrenDesktopNotificationSound.playAgentCompletionSoundIfEnabled(defaults: defaults) {
            plays += 1
        }
        XCTAssertEqual(plays, 0)

        defaults.set(true, forKey: WarrenPreferenceKey.agentCompletionSoundEnabled)
        WarrenDesktopNotificationSound.playAgentCompletionSoundIfEnabled(defaults: defaults) {
            plays += 1
        }
        XCTAssertEqual(plays, 1)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "WarrenDesktopNotificationSoundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
