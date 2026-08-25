import XCTest
@testable import Warren

final class WarrenBuildIdentityTests: XCTestCase {
    func testReadsEmbeddedBuildMetadata() {
        let identity = WarrenBuildIdentity(infoDictionary: [
            "CFBundleShortVersionString": "0.8.2",
            "CFBundleVersion": "17",
            "WarrenBuildVersion": "v0.8.2",
            "WarrenBuildRevision": "abc1234def5678",
            "WarrenBuildDirty": true,
        ])

        XCTAssertEqual(identity.bundleVersion, "0.8.2")
        XCTAssertEqual(identity.bundleBuild, "17")
        XCTAssertEqual(identity.buildVersion, "v0.8.2")
        XCTAssertEqual(identity.revision, "abc1234def5678")
        XCTAssertTrue(identity.isDirty)
        XCTAssertEqual(identity.diagnosticFields["dirty"], "true")
    }

    func testUsesStableFallbacksForSourceRuns() {
        let identity = WarrenBuildIdentity(infoDictionary: [:])

        XCTAssertEqual(identity.bundleVersion, "development")
        XCTAssertEqual(identity.bundleBuild, "development")
        XCTAssertEqual(identity.buildVersion, "development")
        XCTAssertEqual(identity.revision, "unknown")
        XCTAssertFalse(identity.isDirty)
    }
}
