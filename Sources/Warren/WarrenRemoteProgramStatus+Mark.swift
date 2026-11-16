import WarrenDesignSystem
import WarrenTransport

/// Maps the Host's OSC 7501 projection onto the shared activity mark.
///
/// The Design System is a leaf package and cannot see the wire model, so this
/// bridge lives where both are visible — the same reason `WarrenActivityMark` is
/// bridged from the domain status next to the Desktop.
extension WarrenRemoteProgramStatus {
    /// The mark a row draws, or `nil` for a state that draws nothing.
    var mark: WarrenActivityMark? {
        WarrenActivityMark.resolve(
            program: WarrenProgramLifecycle(rawValue: state.rawValue) ?? .unknown,
            blockedKind: WarrenProgramBlockedKind(protocolKind: kind)
        )
    }
}

/// The lighter roster shape the multi-host sidebar decodes carries the same
/// summary, so it maps through the same table.
extension RemoteRoster.ProgramStatus {
    var mark: WarrenActivityMark? {
        WarrenActivityMark.resolve(
            program: WarrenProgramLifecycle(rawValue: state) ?? .unknown,
            blockedKind: WarrenProgramBlockedKind(protocolKind: kind)
        )
    }
}
