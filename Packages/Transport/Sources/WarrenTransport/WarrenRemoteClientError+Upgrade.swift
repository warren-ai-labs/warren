extension WarrenRemoteClientError {
    var requiresClientUpgrade: Bool {
        switch self {
        case .incompatibleProtocol, .upgradeRequired, .unsupportedTerminalStateFormat:
            true
        default:
            false
        }
    }
}
