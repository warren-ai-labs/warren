import AppKit
import SwiftUI

/// Reports the pointer for a view whose own rows cannot.
///
/// SwiftUI cannot answer "is the pointer anywhere inside this group": the rows
/// inside it are Buttons, and a Button's hover tracking takes the pointer from
/// any container above it, so a container's `.onHover` is told the pointer left
/// the moment it lands on the row the user is pointing at. An AppKit tracking
/// area does not go through hit testing, so this view keeps one over its whole
/// frame and lets every click pass through to the rows underneath.
///
/// Only a pointer that moved lights the group. An enter answers where the
/// pointer is, not how it got there, and AppKit re-sends one whenever the area
/// is rebuilt or slides under a resting pointer — which is what a sidebar
/// scroll does. Answering enters lit whole rails nobody had pointed at, so
/// `mouseMoved` is the only thing that lights and `mouseExited` is the only
/// thing that clears. The exit stays live on purpose: a lit rail that the
/// scroll carries away has to go dark with the group, not travel with it.
struct WarrenDesktopHoverSensor: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SensorView {
        let view = SensorView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: SensorView, context: Context) {
        view.onHover = onHover
    }

    final class SensorView: NSView {
        var onHover: ((Bool) -> Void)?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [
                    .mouseEnteredAndExited,
                    // See the type comment: the move is the pointer's own
                    // answer, and the enter is not.
                    .mouseMoved,
                    .activeAlways,
                    .inVisibleRect,
                ],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }

        /// The sensor sits over the rows to watch the pointer, not to take it.
        /// AppKit keeps delivering tracking-area events to a view that is not
        /// the hit-tested one, so returning nil hands the click to the row.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
