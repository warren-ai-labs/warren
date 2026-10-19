import SwiftUI

/// The rest-then-lift rhythm shared by the controls that open under the
/// pointer: the pane-group pill and the sidebar's host stack.
///
/// A short rest lifts the control as a hint, a longer one opens it, and a
/// brief grace on leaving keeps a pointer that slips off for a moment from
/// dropping it. Both controls used to carry their own copy of these numbers.
enum WarrenDesktopHoverIntent {
    static let liftDelay: TimeInterval = 0.08
    static let pullDelay: TimeInterval = 0.7
    static let dropDelay: TimeInterval = 0.15

    /// The spring a lift travels on: quick, with a little overshoot.
    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.62)

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : spring
    }
}
