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

public enum WarrenDesktopOverlayOwner: Equatable, Sendable {
    case inspector
    case panel
}

public struct WarrenDesktopPanelLayoutResolution: Equatable, Sendable {
    public let mode: WarrenDesktopPanelLayoutMode
    public let centerWidth: CGFloat
    public let inspectorWidth: CGFloat
    public let panelWidth: CGFloat
    public let inspectorPlacement: WarrenDesktopPanelPlacement
    public let panelPlacement: WarrenDesktopPanelPlacement

    public init(
        mode: WarrenDesktopPanelLayoutMode,
        centerWidth: CGFloat,
        inspectorWidth: CGFloat,
        panelWidth: CGFloat,
        inspectorPlacement: WarrenDesktopPanelPlacement,
        panelPlacement: WarrenDesktopPanelPlacement
    ) {
        self.mode = mode
        self.centerWidth = centerWidth
        self.inspectorWidth = inspectorWidth
        self.panelWidth = panelWidth
        self.inspectorPlacement = inspectorPlacement
        self.panelPlacement = panelPlacement
    }
}

/// Pure geometry policy for the desktop body. Views, drag gestures, keyboard
/// adjustments, and drawers all use `resolvedWidth` for their width decision.
public enum WarrenDesktopPanelLayout {
    /// Applies the container-first rule:
    /// `effectiveMax = min(maximum, max(0, containerCap))`.
    public static func resolvedWidth(
        requestedWidth: CGFloat,
        containerCap: CGFloat,
        minimum: CGFloat = WarrenLayoutMetrics.panelMinimumWidth,
        maximum: CGFloat = WarrenLayoutMetrics.panelMaximumWidth
    ) -> CGFloat {
        let safeMinimum = minimum.isFinite ? max(0, minimum) : 0
        let safeMaximum = maximum.isFinite ? max(safeMinimum, maximum) : safeMinimum
        let safeCap = containerCap.isNaN ? 0 : max(0, containerCap)
        let effectiveMax = min(safeMaximum, safeCap)
        guard effectiveMax >= safeMinimum else { return effectiveMax }
        let requested = requestedWidth.isFinite ? requestedWidth : WarrenLayoutMetrics.panelDefaultWidth
        return min(max(requested, safeMinimum), effectiveMax)
    }

    public static func sideBySideThreshold(inspectorOpen: Bool, panelOpen: Bool) -> CGFloat {
        guard panelOpen else { return constrainedThreshold(inspectorOpen: inspectorOpen) }
        let inspector = inspectorOpen ? WarrenLayoutMetrics.inspectorDefaultWidth : 0
        return WarrenLayoutMetrics.centerMinimumWidth + inspector + WarrenLayoutMetrics.panelMinimumWidth
    }

    public static func constrainedThreshold(inspectorOpen: Bool) -> CGFloat {
        WarrenLayoutMetrics.centerMinimumWidth
            + (inspectorOpen ? WarrenLayoutMetrics.inspectorDefaultWidth : 0)
    }

    public static func mode(
        containerWidth: CGFloat,
        inspectorOpen: Bool,
        panelOpen: Bool
    ) -> WarrenDesktopPanelLayoutMode {
        let width = containerWidth.isFinite ? max(0, containerWidth) : 0
        if panelOpen && width >= sideBySideThreshold(inspectorOpen: inspectorOpen, panelOpen: true) {
            return .wide
        }
        if width >= constrainedThreshold(inspectorOpen: inspectorOpen) {
            return .constrained
        }
        return .ultraNarrow
    }

    public static func resolve(
        containerWidth: CGFloat,
        inspectorOpen: Bool,
        panelOpen: Bool,
        requestedPanelWidth: CGFloat = WarrenLayoutMetrics.panelDefaultWidth,
        requestedInspectorWidth: CGFloat = WarrenLayoutMetrics.inspectorDefaultWidth,
        lastOpened: WarrenDesktopOverlayOwner = .panel
    ) -> WarrenDesktopPanelLayoutResolution {
        let width = containerWidth.isFinite ? max(0, containerWidth) : 0
        let layoutMode = mode(containerWidth: width, inspectorOpen: inspectorOpen, panelOpen: panelOpen)
        let inspectorWidth = inspectorOpen
            ? resolvedWidth(
                requestedWidth: requestedInspectorWidth,
                containerCap: width,
                minimum: WarrenLayoutMetrics.inspectorMinimumWidth,
                maximum: WarrenLayoutMetrics.inspectorMaximumWidth
            )
            : 0

        switch layoutMode {
        case .wide:
            let panelCap = max(0, width - inspectorWidth - WarrenLayoutMetrics.centerMinimumWidth)
            let panelWidth = resolvedWidth(requestedWidth: requestedPanelWidth, containerCap: panelCap)
            return .init(
                mode: .wide,
                centerWidth: max(0, width - inspectorWidth - panelWidth),
                inspectorWidth: inspectorWidth,
                panelWidth: panelWidth,
                inspectorPlacement: inspectorOpen ? .side : .none,
                panelPlacement: panelOpen ? .side : .none
            )
        case .constrained:
            return .init(
                mode: .constrained,
                centerWidth: max(0, width - inspectorWidth),
                inspectorWidth: inspectorWidth,
                panelWidth: panelOpen ? resolvedWidth(requestedWidth: requestedPanelWidth, containerCap: width) : 0,
                inspectorPlacement: inspectorOpen ? .side : .none,
                panelPlacement: panelOpen ? .drawer : .none
            )
        case .ultraNarrow:
            let showInspector = inspectorOpen && (!panelOpen || lastOpened == .inspector)
            let showPanel = panelOpen && (!inspectorOpen || lastOpened == .panel)
            return .init(
                mode: .ultraNarrow,
                centerWidth: width,
                inspectorWidth: showInspector ? inspectorWidth : 0,
                panelWidth: showPanel ? resolvedWidth(requestedWidth: requestedPanelWidth, containerCap: width) : 0,
                inspectorPlacement: showInspector ? .overlay : .none,
                panelPlacement: showPanel ? .overlay : .none
            )
        }
    }
}
