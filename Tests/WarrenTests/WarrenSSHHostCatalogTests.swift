import Foundation
import XCTest
@testable import Warren

final class WarrenSSHHostCatalogTests: XCTestCase {
    func testLoadsConcreteHostsAndRelativeIncludes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let includeDirectory = directory.appendingPathComponent("config.d", isDirectory: true)
        try FileManager.default.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        try Data("""
        Host included
            HostName included.example
            User include-user
        """.utf8).write(to: includeDirectory.appendingPathComponent("10-included"))
        let config = directory.appendingPathComponent("config")
        try Data("""
        Host *
            User default-user
        Host staging
            Include config.d/*
            HostName staging.example # inline comments are ignored
            Port 2201
        Host [0-9]*
            HostName wildcard.example
        """.utf8).write(to: config)

        let hosts = WarrenSSHHostCatalog.load(from: config)

        XCTAssertEqual(hosts.map(\.name), ["included", "staging"])
        let staging = try XCTUnwrap(hosts.first { $0.name == "staging" })
        XCTAssertEqual(staging.host, "staging.example")
        XCTAssertEqual(staging.user, "default-user")
        XCTAssertEqual(staging.port, 2201)
        XCTAssertTrue(staging.supported)
    }

    func testMarksProxyRoutesUnsupportedWithoutHidingOtherHosts() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("""
        Host proxied
            ProxyJump bastion
        Host direct
            HostName direct.example
        """.utf8).write(to: config)

        let hosts = WarrenSSHHostCatalog.load(from: config)

        XCTAssertEqual(hosts.map(\.name), ["proxied", "direct"])
        XCTAssertFalse(hosts[0].supported)
        XCTAssertEqual(hosts[0].message, "ProxyJump is not supported by the embedded client.")
        XCTAssertTrue(hosts[1].supported)
    }

    func testIncludesBareAliasesWithDefaultConnectionValues() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("Host bare\n".utf8).write(to: config)

        let hosts = WarrenSSHHostCatalog.load(from: config)

        let bare = try XCTUnwrap(hosts.first)
        XCTAssertEqual(bare.name, "bare")
        XCTAssertEqual(bare.host, "bare")
        XCTAssertEqual(bare.port, 22)
        XCTAssertTrue(bare.supported)
    }

    func testAcceptsEqualsSyntax() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("Host=staging\nHostName = staging.example\nUser=deploy\nPort=2201\n".utf8)
            .write(to: config)

        let staging = try XCTUnwrap(WarrenSSHHostCatalog.load(from: config).first)

        XCTAssertEqual(staging.name, "staging")
        XCTAssertEqual(staging.host, "staging.example")
        XCTAssertEqual(staging.user, "deploy")
        XCTAssertEqual(staging.port, 2201)
    }

    func testQuotedValuesAndNegatedPatternsAreResolved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("""
        Host * !excluded
            User "quoted-user"
        Host selected excluded
            HostName "host.example"
        """.utf8).write(to: config)

        let hosts = WarrenSSHHostCatalog.load(from: config)

        XCTAssertEqual(hosts.map(\.name), ["selected", "excluded"])
        let selected = try XCTUnwrap(hosts.first { $0.name == "selected" })
        XCTAssertEqual(selected.user, "quoted-user")
        XCTAssertEqual(selected.host, "host.example")
        let excluded = try XCTUnwrap(hosts.first { $0.name == "excluded" })
        XCTAssertEqual(excluded.user, NSUserName())
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-ssh-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
