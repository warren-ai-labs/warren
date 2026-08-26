import Foundation
import SwiftUI
import WarrenDesignSystem

public struct WarrenDesktopEndpointOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let isLocal: Bool
    public let detail: String?

    public init(id: String, label: String, isLocal: Bool = false, detail: String? = nil) {
        self.id = id
        self.label = label
        self.isLocal = isLocal
        self.detail = detail
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
