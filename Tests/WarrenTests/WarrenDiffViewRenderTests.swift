import AppKit
import SwiftUI
import XCTest
@testable import Warren

final class WarrenDiffViewRenderTests: XCTestCase {
    private func sampleDiff(lines count: Int) -> String {
        var lines = ["diff --git a/x.swift b/x.swift", "--- a/x.swift", "+++ b/x.swift", "@@ -1,\(count) +1,\(count) @@ struct X {"]
        for i in 0..<count {
            lines.append(i % 3 == 0 ? "+    let added\(i) = value(\(i))" : i % 3 == 1 ? "-    let removed\(i) = 1" : "     context \(i)")
            if i == count / 2 { lines.append("@@ -800,10 +800,10 @@ func later() {") }
        }
        return lines.joined(separator: "\n")
    }

    @MainActor
    private func host(_ diff: String) async throws -> (NSWindow, NSScrollView, WarrenDiffScrollView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Color.gray.frame(height: 40)
                WarrenDiffView(diff: diff)
            }
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find<T: NSView>(_ view: NSView, _ type: T.Type, where match: (T) -> Bool = { _ in true }) -> T? {
            if let found = view as? T, match(found) { return found }
            for child in view.subviews {
                if let found = find(child, type, where: match) { return found }
            }
            return nil
        }
        let outer = try XCTUnwrap(find(hosting, NSScrollView.self) { !($0 is WarrenDiffScrollView) })
        let inner = try XCTUnwrap(find(hosting, WarrenDiffScrollView.self))
        return (window, outer, inner)
    }

    /// Every row TextKit lays out sits on the band painted for it, down to
    /// the last line, and the view is exactly as tall as its rows: no gap.
    @MainActor
    func testTextStaysOnItsPaintedRows() async throws {
        let (window, outer, inner) = try await host(sampleDiff(lines: 1500))
        defer { window.orderOut(nil) }
        let text = inner.textView
        let layout = text.layout
        XCTAssertEqual(inner.frame.height, layout.height)
        XCTAssertEqual(outer.documentView?.frame.height ?? 0, 40 + layout.height, accuracy: 1)
        let manager = try XCTUnwrap(text.layoutManager)
        let string = text.string as NSString
        var row = 0
        var mismatches: [Int] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            let fragment = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            if row < layout.lines.count, fragment.minY != layout.offsets[row] { mismatches.append(row) }
            row += 1
        }
        XCTAssertEqual(row, layout.lines.count)
        XCTAssertEqual(mismatches.prefix(5), [])
    }

    /// A vertical swipe over a diff scrolls the Inspector, not the diff.
    @MainActor
    func testVerticalWheelScrollsTheList() async throws {
        let (window, outer, inner) = try await host(sampleDiff(lines: 200))
        defer { window.orderOut(nil) }
        let before = outer.contentView.bounds.origin.y
        let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -120, wheel2: 0, wheel3: 0))
        inner.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThan(outer.contentView.bounds.origin.y, before)
    }

    /// A copy takes the code alone; numbers and marks are painted, not text.
    @MainActor
    func testCopyTakesOnlyCode() async throws {
        let (window, _, inner) = try await host(sampleDiff(lines: 3))
        defer { window.orderOut(nil) }
        XCTAssertEqual(inner.textView.string, "struct X {\n    let added0 = value(0)\n    let removed1 = 1\nfunc later() {\n    context 2")
    }
}
