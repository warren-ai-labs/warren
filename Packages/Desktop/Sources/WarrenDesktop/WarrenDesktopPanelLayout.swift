import CoreGraphics
import WarrenDesignSystem

public enum WarrenDesktopPanelLayoutMode: Equatable, Sendable {
    case wide
    case constrained
    case ultraNarrow
}

public enum WarrenDesktopPanelPlacement: Equatable, Sendable {
    case none
    case side
    case drawer
    case overlay
}

public struct WarrenDesktopPanelLayoutResolution: Equatable, Sendable {
    public let mode: WarrenDesktopPanelLayoutMode
    public let centerWidth: CGFloat
    public let panelWidth: CGFloat
    public let panelPlacement: WarrenDesktopPanelPlacement

    public init(
        mode: WarrenDesktopPanelLayoutMode,
        centerWidth: CGFloat,
        panelWidth: CGFloat,
        panelPlacement: WarrenDesktopPanelPlacement
    ) {
        self.mode = mode
        self.centerWidth = centerWidth
        self.panelWidth = panelWidth
        self.panelPlacement = panelPlacement
    }
}

/// Pure geometry policy for the three-region Desktop body. Navigation lives
/// outside this container; the body resolves Center + Panel placement.
public enum WarrenDesktopPanelLayout {
    public static func resolvedWidth(
        requestedWidth: CGFloat,
        containerCap: CGFloat,
        minimum: CGFloat = WarrenLayoutMetrics.panelMinimumWidth,
        maximum: CGFloat = WarrenLayoutMetrics.panelMaximumWidth
    ) -> CGFloat {
        let safeMinimum = minimum.isFinite ? max(0, minimum) : 0
        let safeMaximum = maximum.isFinite ? max(safeMinimum, maximum) : safeMinimum
        let safeCap = containerCap.isFinite ? max(0, containerCap) : 0
        let effectiveMaximum = min(safeMaximum, safeCap)
        guard effectiveMaximum >= safeMinimum else { return effectiveMaximum }
        let requested = requestedWidth.isFinite
            ? requestedWidth
            : WarrenLayoutMetrics.panelDefaultWidth
        return min(max(requested, safeMinimum), effectiveMaximum)
    }

    public static func sideBySideThreshold() -> CGFloat {
        WarrenLayoutMetrics.centerMinimumWidth + WarrenLayoutMetrics.panelMinimumWidth
    }

    public static func mode(containerWidth: CGFloat, panelOpen: Bool) -> WarrenDesktopPanelLayoutMode {
        let width = containerWidth.isFinite ? max(0, containerWidth) : 0
        guard panelOpen else { return .constrained }
        if width >= sideBySideThreshold() { return .wide }
        if width >= WarrenLayoutMetrics.centerMinimumWidth { return .constrained }
        return .ultraNarrow
    }

    public static func resolve(
        containerWidth: CGFloat,
        panelOpen: Bool,
        requestedPanelWidth: CGFloat = WarrenLayoutMetrics.panelDefaultWidth
    ) -> WarrenDesktopPanelLayoutResolution {
        let width = containerWidth.isFinite ? max(0, containerWidth) : 0
        let layoutMode = mode(containerWidth: width, panelOpen: panelOpen)
        switch layoutMode {
        case .wide:
            let panelWidth = resolvedWidth(
                requestedWidth: requestedPanelWidth,
                containerCap: max(0, width - WarrenLayoutMetrics.centerMinimumWidth)
            )
            return .init(
                mode: .wide,
                centerWidth: max(0, width - panelWidth),
                panelWidth: panelWidth,
                panelPlacement: .side
            )
        case .constrained:
            return .init(
                mode: .constrained,
                centerWidth: width,
                panelWidth: resolvedWidth(requestedWidth: requestedPanelWidth, containerCap: width),
                panelPlacement: panelOpen ? .drawer : .none
            )
        case .ultraNarrow:
            return .init(
                mode: .ultraNarrow,
                centerWidth: width,
                panelWidth: panelOpen ? resolvedWidth(requestedWidth: requestedPanelWidth, containerCap: width) : 0,
                panelPlacement: panelOpen ? .overlay : .none
            )
        }
    }
}
