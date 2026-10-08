import AppKit
import SwiftUI
import XCTest
@testable import Warren

final class WarrenCodeTextViewRenderTests: XCTestCase {
    /// The clip view runs under the line-number ruler, so code scrolled
    /// sideways must not show through the gutter.
    @MainActor
    func testGutterHidesCodeScrolledBeneathIt() async throws {
        let line = String(repeating: "W", count: 200)
        let text = (1...30).map { _ in line }.joined(separator: "\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: WarrenCodeTextView(text: .constant(text), language: .plain, editable: false, dark: true))
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func find(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap(find).first
        }
        let scroll = try XCTUnwrap(find(hosting))
        scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        // The left part of the gutter carries no numbers: it is ground only.
        let ground = try XCTUnwrap(bitmap.colorAt(x: 2, y: 150)?.usingColorSpace(.sRGB))
        for y in stride(from: 20, to: Int(bitmap.pixelsHigh) - 20, by: 3) {
            for x in 0..<(bitmap.pixelsWide * 12 / 360) {
                let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertEqual(pixel.brightnessComponent, ground.brightnessComponent, accuracy: 0.05, "code shows through the gutter at \(x),\(y)")
                if abs(pixel.brightnessComponent - ground.brightnessComponent) > 0.05 { return }
            }
        }
    }
}
