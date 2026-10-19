import CoreGraphics
import SwiftUI
import WarrenDesignSystem

/// How wide a Tab is in the track.
///
/// The design gives a Tab a 200pt ceiling and a 96pt floor: a few Tabs get the
/// room their titles need, and as more arrive every one of them narrows evenly
/// until the floor, after which the track scrolls instead of shrinking further.
/// Even narrowing is what lets the track keep its `index * width` origin math.
enum WarrenDesktopTabTrack {
    static let maximumWidth = WarrenLayoutMetrics.tabWidthMax
    static let minimumWidth = WarrenLayoutMetrics.tabWidthMin

    /// The width every Tab takes at `count` Tabs inside `viewport`.
    static func tabWidth(count: Int, viewport: CGFloat, groupMarkTotalWidth: CGFloat = 0) -> CGFloat {
        guard count > 0, viewport > 0 else { return maximumWidth }
        let usable = max(0, viewport - groupMarkTotalWidth)
        let even = usable / CGFloat(count)
        return min(maximumWidth, max(minimumWidth, even.rounded(.down)))
    }

    /// Whether the selection plate travels from `from` to `to`.
    ///
    /// It travels between neighbours, and stops travelling once the Tab it is
    /// going to is more than a viewport away — a plate sweeping across several
    /// screens of track reads as a stray highlight, so that Tab gets the plate
    /// already on it instead.
    static func plateTravels(
        from: Int?,
        to: Int,
        tabWidth: CGFloat,
        viewport: CGFloat
    ) -> Bool {
        guard let from, viewport > 0 else { return true }
        return CGFloat(abs(to - from)) * tabWidth <= viewport
    }

    /// Whether the Tabs no longer fit at the floor width, so the track must
    /// scroll and offer its overflow menu.
    static func overflows(
        count: Int,
        tabWidth: CGFloat,
        viewport: CGFloat,
        groupMarkTotalWidth: CGFloat = 0
    ) -> Bool {
        guard count > 0, viewport > 0 else { return false }
        return CGFloat(count) * tabWidth + groupMarkTotalWidth > viewport + 0.5
    }
}

/// Reports the track's viewport width, so every Tab can be sized to fill it.
struct WarrenDesktopTabTrackWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
