import CoreGraphics
import Foundation
import Observation
import WarrenDesignSystem
import WarrenDomain

@MainActor
@Observable
public final class WarrenDesktopPanelHost {
    public private(set) var activePanelID: String?
    public private(set) var isPanelOpen = false
    public var isOpen: Bool { isPanelOpen }
    /// The requested presentation width. The actual width is resolved against
    /// the measured container at render time and is never persisted.
    public private(set) var rightPanelWidth: CGFloat

    private let defaults: UserDefaults?

    public init(
        activePanelID: String? = nil,
        isPanelOpen: Bool = false,
        rightPanelWidth: CGFloat? = nil,
        defaults: UserDefaults? = .standard
    ) {
        self.activePanelID = activePanelID
        self.isPanelOpen = isPanelOpen
        self.defaults = defaults
        let stored = defaults?.double(forKey: WarrenPreferenceKey.rightPanelWidth) ?? 0
        let initial = rightPanelWidth ?? (stored > 0 ? CGFloat(stored) : WarrenLayoutMetrics.panelDefaultWidth)
        self.rightPanelWidth = initial.isFinite && initial > 0
            ? initial
            : WarrenLayoutMetrics.panelDefaultWidth
    }

    public func open(panelID: String) {
        activePanelID = panelID
        isPanelOpen = true
    }

    @discardableResult
    public func open(
        panelID: String,
        context: WarrenDesktopPanelContext,
        registry: WarrenDesktopPanelRegistry
    ) -> Bool {
        guard let contribution = registry.contribution(panelID: panelID),
              contribution.isAvailable(in: context) else {
            activePanelID = panelID
            isPanelOpen = false
            return false
        }
        if activePanelID != panelID, let previous = activePanelID,
           let previousContribution = registry.contribution(panelID: previous) {
            previousContribution.deactivate()
        }
        activePanelID = panelID
        isPanelOpen = true
        contribution.activate(in: context)
        return true
    }

    public func close() {
        isPanelOpen = false
    }

    public func close(context: WarrenDesktopPanelContext, registry: WarrenDesktopPanelRegistry) {
        if let activePanelID,
           let contribution = registry.contribution(panelID: activePanelID) {
            contribution.closeDetail()
            contribution.deactivate()
        }
        isPanelOpen = false
    }

    public func toggle(panelID: String) {
        if isPanelOpen, activePanelID == panelID {
            close()
        } else {
            open(panelID: panelID)
        }
    }

    public func setActivePanelID(_ panelID: String?) {
        activePanelID = panelID
    }

    @discardableResult
    public func resize(to requestedWidth: CGFloat) -> CGFloat {
        rightPanelWidth = requestedWidth.isFinite && requestedWidth > 0
            ? requestedWidth
            : WarrenLayoutMetrics.panelDefaultWidth
        defaults?.set(Double(rightPanelWidth), forKey: WarrenPreferenceKey.rightPanelWidth)
        return rightPanelWidth
    }

    public func resolvedWidth(containerCap: CGFloat) -> CGFloat {
        WarrenDesktopPanelLayout.resolvedWidth(
            requestedWidth: rightPanelWidth,
            containerCap: containerCap
        )
    }
}
