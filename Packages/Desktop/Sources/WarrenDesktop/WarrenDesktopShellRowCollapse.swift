import Foundation
import SwiftUI

/// Which failed commands a person has already looked at.
///
/// A failed shell row stays two lines until the Session has been selected once
/// after the failure; only then does the ten-minute rest apply. The instant is
/// remembered per Session and per command end, so running the same command
/// again after fixing it starts a fresh, unseen failure.
@MainActor
final class WarrenDesktopShellAttention: ObservableObject {
    @Published private var seenAt: [String: Date] = [:]

    func markSeen(_ key: String, at date: Date) {
        guard seenAt[key] == nil else { return }
        seenAt[key] = date
    }

    func seen(_ key: String) -> Date? {
        seenAt[key]
    }
}

private struct WarrenDesktopShellAttentionKey: EnvironmentKey {
    static let defaultValue: WarrenDesktopShellAttention? = nil
}

/// Whether the pointer is over the rail. The idle collapse waits for it to
/// leave: a row must not shrink under the pointer that is reading it.
private struct WarrenDesktopPointerInsideSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var warrenShellAttention: WarrenDesktopShellAttention? {
        get { self[WarrenDesktopShellAttentionKey.self] }
        set { self[WarrenDesktopShellAttentionKey.self] = newValue }
    }

    var warrenPointerInsideSidebar: Bool {
        get { self[WarrenDesktopPointerInsideSidebarKey.self] }
        set { self[WarrenDesktopPointerInsideSidebarKey.self] = newValue }
    }
}
