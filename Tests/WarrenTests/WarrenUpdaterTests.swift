import Foundation
import XCTest
@testable import Warren

final class WarrenUpdaterTests: XCTestCase {
    func testSemanticVersionsCompareNumericAndPrereleaseParts() throws {
        let version09 = try XCTUnwrap(WarrenVersion("0.9.0"))
        let version010 = try XCTUnwrap(WarrenVersion("0.10.0"))
        let release = try XCTUnwrap(WarrenVersion("1.0.0"))
        let candidate = try XCTUnwrap(WarrenVersion("1.0.0-rc.1"))
        let nextCandidate = try XCTUnwrap(WarrenVersion("1.0.0-rc.2"))

        XCTAssertTrue(version010 > version09)
        XCTAssertTrue(release > candidate)
        XCTAssertTrue(nextCandidate > candidate)
        XCTAssertEqual(WarrenVersion("v1.2"), WarrenVersion("1.2.0"))
    }

    func testSemanticVersionRejectsMalformedValues() {
        XCTAssertNil(WarrenVersion(""))
        XCTAssertNil(WarrenVersion("warren"))
        XCTAssertNil(WarrenVersion("1.2.3.4"))
        XCTAssertNil(WarrenVersion("1.2-"))
    }

    func testReleaseSelectsOnlyTrustedWarrenZipAsset() throws {
        let release = try JSONDecoder().decode(
            WarrenRelease.self,
            from: Data(
                """
                {
                  "tag_name": "v0.5.0",
                  "html_url": "https://github.com/abcdlsj/warren/releases/tag/v0.5.0",
                  "body": "Update",
                  "assets": [
                    {
                      "name": "checksums.txt",
                      "browser_download_url": "https://github.com/abcdlsj/warren/releases/download/v0.5.0/checksums.txt",
                      "size": 12
                    },
                    {
                      "name": "Warren-0.5.0.zip",
                      "browser_download_url": "https://github.com/abcdlsj/warren/releases/download/v0.5.0/Warren-0.5.0.zip",
                      "size": 42
                    }
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(release.displayVersion, "v0.5.0")
        XCTAssertEqual(release.applicationAsset?.name, "Warren-0.5.0.zip")
        XCTAssertTrue(release.isInstallable)
    }

    func testReleaseInstallsZipWhenProxyAlsoListsDiskImage() throws {
        let release = try JSONDecoder().decode(
            WarrenRelease.self,
            from: Data(
                """
                {
                  "tag_name": "v0.32.0",
                  "assets": [
                    {
                      "name": "Warren-0.32.0.dmg",
                      "browser_download_url": "https://github.com/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.dmg",
                      "size": 50
                    },
                    {
                      "name": "Warren-0.32.0.zip",
                      "browser_download_url": "https://github.com/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.zip",
                      "size": 40
                    }
                  ],
                  "name": "Warren-0.32.0.dmg",
                  "url": "https://github.com/warren-ai-labs/warren/releases/download/v0.32.0/Warren-0.32.0.dmg"
                }
                """.utf8
            )
        )

        XCTAssertEqual(release.applicationAsset?.name, "Warren-0.32.0.zip")
        XCTAssertTrue(release.isInstallable)
    }

    func testReleaseProxyPayloadDecodesWithGitHubCompatibleFields() throws {
        let release = try JSONDecoder().decode(
            WarrenRelease.self,
            from: Data(
                """
                {
                  "tag": "v0.5.1",
                  "tag_name": "v0.5.1",
                  "html_url": "https://github.com/abcdlsj/warren/releases/tag/v0.5.1",
                  "assets": [
                    {
                      "name": "Warren-0.5.1.zip",
                      "browser_download_url": "https://github.com/abcdlsj/warren/releases/download/v0.5.1/Warren-0.5.1.zip",
                      "size": 20847018
                    }
                  ],
                  "name": "Warren-0.5.1.zip",
                  "size": 20847018,
                  "url": "https://github.com/abcdlsj/warren/releases/download/v0.5.1/Warren-0.5.1.zip"
                }
                """.utf8
            )
        )

        XCTAssertEqual(release.version, WarrenVersion("0.5.1"))
        XCTAssertEqual(release.applicationAsset?.size, 20_847_018)
        XCTAssertTrue(release.isInstallable)
    }

    @MainActor
    func testReleaseChecksUseTheCloudflareProxy() {
        XCTAssertEqual(
            WarrenUpdater.latestReleaseURL.absoluteString,
            "https://warrenai.xyz/api/update/latest"
        )
    }

    @MainActor
    func testAutomaticCheckCadenceUsesThreeHourIntervalAfterSuccessfulCheck() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        var now = Date(timeIntervalSince1970: 10_000)
        let updater = WarrenUpdater(
            currentVersion: WarrenVersion("0.4.0"),
            userDefaults: defaults,
            now: { now },
            cacheDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )

        XCTAssertEqual(WarrenUpdater.checkInterval, 3 * 60 * 60)
        XCTAssertTrue(updater.shouldCheckAutomatically)
        defaults.set(now, forKey: WarrenUpdater.lastCheckDateKey)
        XCTAssertFalse(updater.shouldCheckAutomatically)
        now.addTimeInterval(WarrenUpdater.checkInterval - 1)
        XCTAssertFalse(updater.shouldCheckAutomatically)
        now.addTimeInterval(1)
        XCTAssertTrue(updater.shouldCheckAutomatically)
    }

    @MainActor
    func testDiskImageUpdateAcceptsOnlyNewerWarrenAtVolumeRoot() throws {
        let volume = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: volume) }
        let updater = WarrenUpdater(currentVersion: WarrenVersion("0.31.0"), cacheDirectory: volume)

        try makeApplication(at: volume.appendingPathComponent("Warren.app"), version: "0.31.0")
        XCTAssertNil(updater.diskImageUpdate(onVolume: volume))

        try FileManager.default.removeItem(at: volume.appendingPathComponent("Warren.app"))
        try makeApplication(
            at: volume.appendingPathComponent("Warren.app"),
            version: "0.32.0",
            bundleIdentifier: "com.example.other"
        )
        XCTAssertNil(updater.diskImageUpdate(onVolume: volume))

        try FileManager.default.removeItem(at: volume.appendingPathComponent("Warren.app"))
        try makeApplication(at: volume.appendingPathComponent("Warren.app"), version: "0.32.0")
        let update = try XCTUnwrap(updater.diskImageUpdate(onVolume: volume))
        XCTAssertEqual(update.version, WarrenVersion("0.32.0"))
        XCTAssertEqual(update.displayVersion, "v0.32.0")
    }

    @MainActor
    func testDiskImageUpdateRejectsAppWithoutTheRunningTeamSignature() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let volume = root.appendingPathComponent("volume", isDirectory: true)
        let applicationURL = volume.appendingPathComponent("Warren.app")
        try makeApplication(at: applicationURL, version: "0.32.0")
        // Nested code is signed before the bundle, as scripts/sign-app.sh does.
        try run("/usr/bin/codesign", [
            "--force", "--sign", "-",
            applicationURL.appendingPathComponent("Contents/MacOS/warren-ssh-tunnel").path,
        ])
        try run("/usr/bin/codesign", ["--force", "--sign", "-", applicationURL.path])

        for teamIdentifier in [nil, "2PX99VFWSU"] {
            let updater = WarrenUpdater(
                currentVersion: WarrenVersion("0.31.0"),
                cacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
                signingTeamIdentifier: teamIdentifier
            )
            let update = try XCTUnwrap(updater.diskImageUpdate(onVolume: volume))
            do {
                _ = try await updater.prepareDiskImageUpdate(
                    update,
                    replacing: root.appendingPathComponent("Installed/Warren.app")
                )
                XCTFail("An ad-hoc signed app must not be installed")
            } catch let error as WarrenUpdaterError {
                guard case .untrustedSignature = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testRemoveQuarantineClearsEveryFileInTheBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root.appendingPathComponent("Warren.app")
        try makeApplication(at: applicationURL, version: "0.32.0")
        let executable = applicationURL.appendingPathComponent("Contents/MacOS/Warren")
        try run("/usr/bin/xattr", ["-w", "-r", "com.apple.quarantine", "0081;00000000;Chrome;", applicationURL.path])
        XCTAssertGreaterThan(getxattr(executable.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), 0)

        try WarrenUpdateArchive.removeQuarantine(from: applicationURL)

        for path in [applicationURL.path, executable.path] {
            XCTAssertEqual(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), -1)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WarrenUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApplication(
        at applicationURL: URL,
        version: String,
        bundleIdentifier: String = "com.abcdlsj.warren"
    ) throws {
        let executables = applicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Warren",
            "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: applicationURL.appendingPathComponent("Contents/Info.plist"))
        for name in ["Warren", "warren-ssh-tunnel"] {
            let url = executables.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
    }
}
