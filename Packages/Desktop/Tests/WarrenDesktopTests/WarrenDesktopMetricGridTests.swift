import XCTest
import WarrenDesignSystem

/// The window's spacing grid, enforced over the Desktop sources.
///
/// The design system already owned the values; what it could not do was notice
/// when a view ignored them. This test reads the view code and fails on an
/// off-grid padding or spacing, so the rule lives where the code is written
/// rather than in a comment a new view never reads.
///
/// A corner radius is out of scope on purpose: a curve follows the radius
/// scale, not the spacing steps. So is a 1pt stroke, which is the thinnest line
/// macOS draws.
final class WarrenDesktopMetricGridTests: XCTestCase {
    /// `Packages/Desktop/Tests/WarrenDesktopTests/<this file>` → repository root.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WarrenDesktopTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Desktop
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // repository root
    }

    private var desktopSources: URL {
        repositoryRoot
            .appendingPathComponent("Packages/Desktop/Sources/WarrenDesktop", isDirectory: true)
    }

    /// `.padding(.horizontal, 5)`, `.padding(6)`, `spacing: 7`, and their
    /// multiline spellings.
    private static let patterns: [(String, NSRegularExpression)] = [
        ("padding", try! NSRegularExpression(pattern: #"\.padding\(\s*(?:\.\w+\s*,\s*)?(\d+)\s*\)"#)),
        ("spacing", try! NSRegularExpression(pattern: #"spacing:\s*(\d+)\b"#)),
    ]

    func testChromeSpacingSitsOnTheWindowGrid() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: desktopSources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "The Desktop sources were not found where this test expects them.")

        var offGrid: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                for (kind, pattern) in Self.patterns {
                    let range = NSRange(text.startIndex..<text.endIndex, in: text)
                    for match in pattern.matches(in: text, range: range) {
                        guard let valueRange = Range(match.range(at: 1), in: text),
                              let value = Double(text[valueRange]) else { continue }
                        guard !WarrenWindowGrid.contains(CGFloat(value)) else { continue }
                        offGrid.append("\(file.lastPathComponent):\(lineNumber + 1) \(kind) \(Int(value))")
                    }
                }
            }
        }

        XCTAssertTrue(
            offGrid.isEmpty,
            """
            Chrome spacing is even points (WarrenWindowGrid.unit = \(Int(WarrenWindowGrid.unit))); \
            a 1pt hairline is the only exception. Off-grid:
            \(offGrid.joined(separator: "\n"))
            """
        )
    }

    /// Corner radii come from the radius scale, not from the spacing grid.
    ///
    /// A curve is not a step: a 20pt control wants 7 the way a card wants 12,
    /// and no arithmetic on a 2pt unit produces either. The scale is
    /// `WarrenRadius`, and a mark smaller than the smallest step (a 6pt status
    /// dot, a heat-map cell) may still round at 1-2pt, because there the radius
    /// is a cap rather than a corner.
    func testCornerRadiiComeFromTheRadiusScale() throws {
        let scale: Set<Double> = [4, 7, 8, 10, 12, 16]
        let marks: Set<Double> = [1, 1.5, 2]
        let pattern = try NSRegularExpression(pattern: #"cornerRadius:\s*(\d+(?:\.\d+)?)"#)

        var offScale: [String] = []
        for file in try FileManager.default
            .contentsOfDirectory(at: desktopSources, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "swift" }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (lineNumber, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in pattern.matches(in: text, range: range) {
                    guard let valueRange = Range(match.range(at: 1), in: text),
                          let value = Double(text[valueRange]) else { continue }
                    guard !scale.contains(value), !marks.contains(value) else { continue }
                    offScale.append("\(file.lastPathComponent):\(lineNumber + 1) cornerRadius \(value)")
                }
            }
        }

        XCTAssertTrue(
            offScale.isEmpty,
            "Corner radii must come from WarrenRadius (4/7/8/10/12/16), or 1-2 for a mark.\n\(offScale.joined(separator: "\n"))"
        )
    }

    /// The measurements the window itself is built from have to satisfy the
    /// same rule, or the grid only constrains the views and not the frame.
    func testPublishedChromeMetricsSitOnTheGrid() {
        let measures: [(String, CGFloat)] = [
            ("windowInset", WarrenLayoutMetrics.windowInset),
            ("cardGap", WarrenLayoutMetrics.cardGap),
            ("cardRadius", WarrenLayoutMetrics.cardRadius),
            ("tabBarHeight", WarrenLayoutMetrics.tabBarHeight),
            ("paneHeaderHeight", WarrenLayoutMetrics.paneHeaderHeight),
            ("paneMinimumWidth", WarrenLayoutMetrics.paneMinimumWidth),
            ("paneMinimumHeight", WarrenLayoutMetrics.paneMinimumHeight),
            ("sidebarExpandedWidth", WarrenLayoutMetrics.sidebarExpandedWidth),
        ]
        for (name, value) in measures {
            XCTAssertTrue(
                WarrenWindowGrid.contains(value),
                "\(name) = \(value) is off the \(Int(WarrenWindowGrid.unit))pt grid"
            )
        }
    }

    /// The edge inset and the gutter are one value: the margin around a card and
    /// the space between two cards have to match, or the cards stop reading as
    /// one grid.
    func testCardInsetAndGutterAreTheSameMargin() {
        XCTAssertEqual(WarrenLayoutMetrics.windowInset, WarrenLayoutMetrics.cardGap)
        XCTAssertEqual(WarrenLayoutMetrics.windowInset, WarrenWindowGrid.inset)
        XCTAssertEqual(WarrenWindowGrid.hairline, 1)
    }
}
