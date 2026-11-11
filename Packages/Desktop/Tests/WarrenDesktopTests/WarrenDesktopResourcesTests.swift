import XCTest
@testable import WarrenDesktop

final class WarrenDesktopResourcesTests: XCTestCase {
    func testLocateFindsTheBundleInsideTheFirstRootThatHasIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleDirectory = root
            .appendingPathComponent(WarrenDesktopResources.bundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let bundle = WarrenDesktopResources.locate(in: [nil, root])

        XCTAssertEqual(bundle?.bundleURL.standardizedFileURL, bundleDirectory.standardizedFileURL)
    }

    func testLocateReturnsNilInsteadOfTrappingWhenNoRootHasTheBundle() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        XCTAssertNil(WarrenDesktopResources.locate(in: [empty, nil]))
    }

    /// The test process resolves the bundle the same way the app does, so the
    /// artwork assertions elsewhere in this target prove the layout works.
    func testTheRunningProcessResolvesTheBundledArtwork() {
        XCTAssertNotNil(WarrenDesktopResources.bundle)
    }
}
