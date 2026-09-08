enum WarrenDesktopConnectionTone: Equatable, Sendable {
    case success
    case info
    case warning
    case destructive
}

struct WarrenDesktopConnectionPresentation: Equatable, Sendable {
    let label: String
    let tone: WarrenDesktopConnectionTone
    let isActive: Bool

    init(
        _ state: WarrenDesktopConnectionState,
        migratingRuntimeSessions: Bool = false
    ) {
        if migratingRuntimeSessions,
           state == .connecting || state == .reconnecting {
            self.init(label: "Migrating runtime sessions…", tone: .info, isActive: true)
            return
        }
        switch state {
        case .disconnected:
            self.init(label: "Disconnected", tone: .warning, isActive: false)
        case .connecting:
            self.init(label: "Connecting…", tone: .info, isActive: true)
        case .attached:
            self.init(label: "Connected", tone: .success, isActive: false)
        case .reconnecting:
            self.init(label: "Reconnecting…", tone: .warning, isActive: true)
        case .failed:
            self.init(label: "Connection failed", tone: .destructive, isActive: false)
        }
    }

    private init(label: String, tone: WarrenDesktopConnectionTone, isActive: Bool) {
        self.label = label
        self.tone = tone
        self.isActive = isActive
    }
}
