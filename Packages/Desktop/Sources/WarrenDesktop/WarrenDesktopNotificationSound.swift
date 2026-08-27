import AppKit
import Foundation
import WarrenDomain

/// Plays the short system cue used for completed Agent turns. The preference
/// is client-local, so one desktop can stay quiet without changing another
/// client connected to the same Host.
@MainActor
public enum WarrenDesktopNotificationSound {
    public static func isAgentCompletionSoundEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let value = defaults.object(forKey: WarrenPreferenceKey.agentCompletionSoundEnabled)
            as? Bool else {
            return true
        }
        return value
    }

    public static func playAgentCompletionSoundIfEnabled(
        defaults: UserDefaults = .standard,
        play: () -> Void = { NSSound.beep() }
    ) {
        guard isAgentCompletionSoundEnabled(defaults: defaults) else { return }
        play()
    }
}
