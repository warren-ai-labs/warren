import Foundation
import SwiftUI
import WarrenDesignSystem

/// Capabilities owned by the selected execution endpoint.
///
/// Local-only integrations are kept explicit here so views do not need to
/// infer availability from endpoint IDs or duplicate host-boundary checks.
public struct WarrenDesktopEndpointCapabilities: Hashable, Sendable {
    public let canAddProject: Bool
    public let canImportSuperset: Bool
    public let canUseEmbeddedEditor: Bool
    public let canOpenExternalIDE: Bool
    public let canCopyLocalWebURL: Bool

    public init(
        canAddProject: Bool,
        canImportSuperset: Bool,
        canUseEmbeddedEditor: Bool,
        canOpenExternalIDE: Bool,
        canCopyLocalWebURL: Bool
    ) {
        self.canAddProject = canAddProject
        self.canImportSuperset = canImportSuperset
        self.canUseEmbeddedEditor = canUseEmbeddedEditor
        self.canOpenExternalIDE = canOpenExternalIDE
        self.canCopyLocalWebURL = canCopyLocalWebURL
    }

    /// The endpoint backed by this Mac's local daemon.
    public static let local = Self(
        canAddProject: true,
        canImportSuperset: true,
        canUseEmbeddedEditor: true,
        canOpenExternalIDE: true,
        canCopyLocalWebURL: true
    )

    /// A remote endpoint owns its filesystem and editor integrations. Those
    /// integrations must be provided by the host rather than this client.
    public static let remote = Self(
        canAddProject: false,
        canImportSuperset: false,
        canUseEmbeddedEditor: false,
        canOpenExternalIDE: false,
        canCopyLocalWebURL: false
    )
}

/// Notification emitted by the application shell when the selected endpoint
/// changes. AppKit-owned menus can mirror the same capability boundary as the
/// SwiftUI workspace without depending on the root view's private state.
public enum WarrenDesktopEndpointCapabilitiesNotification {
    public static let didChange = Notification.Name(
        "WarrenDesktopEndpointCapabilities.didChange"
    )
}

public struct WarrenDesktopEndpointOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let isLocal: Bool
    public let detail: String?
    public let capabilities: WarrenDesktopEndpointCapabilities

    public init(
        id: String,
        label: String,
        isLocal: Bool = false,
        detail: String? = nil,
        capabilities: WarrenDesktopEndpointCapabilities? = nil
    ) {
        self.id = id
        self.label = label
        self.isLocal = isLocal
        self.detail = detail
        self.capabilities = capabilities ?? (isLocal ? .local : .remote)
    }
}

/// Presentation-only identity for execution endpoints. Colors are assigned by
/// the current catalog order so the top bar and endpoint picker use the same
/// accent for each endpoint.
enum WarrenDesktopEndpointAppearance {
    static func color(
        for endpointID: String,
        in endpoints: [WarrenDesktopEndpointOption],
        tokens: WarrenColorTokens
    ) -> Color {
        guard let index = endpoints.firstIndex(where: { $0.id == endpointID }) else {
            return tokens.mutedForeground
        }

        let palette = [
            tokens.highlight,
            tokens.info,
            tokens.success,
            tokens.warning,
            tokens.destructive,
            tokens.amber,
        ]
        return palette[index % palette.count]
    }
}
