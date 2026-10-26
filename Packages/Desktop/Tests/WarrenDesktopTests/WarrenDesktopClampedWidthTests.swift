import AppKit
import SwiftUI
import XCTest

@testable import WarrenDesktop

/// The solo pane's title area is a `ViewThatFits` inside
/// `WarrenDesktopClampedWidth`, and a `ViewThatFits` answers an alignment
/// query by building its candidates' subgraphs again. The pill's stack asks
/// every child for its centre on every layout of the window — during a
/// sidebar scroll, every frame — so the clamp must answer from its own bounds
/// and never pass the query down.
@MainActor
final class WarrenDesktopClampedWidthTests: XCTestCase {
    private final class Counter {
        var queries = 0
    }

    private final class Width: ObservableObject {
        @Published var value: CGFloat = 600
    }

    private struct Probe: View {
        @ObservedObject var width: Width
        let counter: Counter

        var body: some View {
            HStack(spacing: 0) {
                WarrenDesktopClampedWidth(maxWidth: 200) {
                    Text("Title")
                        .alignmentGuide(VerticalAlignment.center) { dimensions in
                            counter.queries += 1
                            return dimensions.height / 2
                        }
                }
                Color.gray.frame(width: 20, height: 30)
                Spacer(minLength: 0)
            }
            .frame(width: width.value)
        }
    }

    func testAlignmentIsAnsweredWithoutAskingTheContent() {
        let counter = Counter()
        let width = Width()
        let hosting = NSHostingView(rootView: Probe(width: width, counter: counter))
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 40)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        for value in [600, 590, 580] as [CGFloat] {
            width.value = value
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(counter.queries, 0)
    }
}
