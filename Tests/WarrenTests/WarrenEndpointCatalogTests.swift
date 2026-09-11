import Foundation
import XCTest
@testable import Warren

final class WarrenEndpointCatalogTests: XCTestCase {
    func testLocalDaemonUsesCanonicalLowercaseAlias() {
        XCTAssertEqual(WarrenRemoteEndpointConfiguration.localDaemon().name, "local")
    }

    func testRejectsRemovedSSHRuntimeFields() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let config = """
        {
          "current": "vps",
          "endpoints": {
            "local": {
              "name": "local",
              "url": "http://127.0.0.1:8789",
              "token": "local-token"
            },
            "vps": {
              "name": "vps",
              "url": "http://vps.example:8789",
              "token": "remote-token",
              "ssh": "root@vps.example"
            }
          }
        }
        """
        try Data(config.utf8).write(to: url)

        XCTAssertThrowsError(try WarrenEndpointCatalog.loadThrowing(from: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("state_reset_required"))
        }
    }

    func testMissingConfigurationReturnsEmptyCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalog = WarrenEndpointCatalog.load(
            from: directory.appendingPathComponent("missing.json")
        )

        XCTAssertNil(catalog.current)
        XCTAssertTrue(catalog.endpoints.isEmpty)
    }

    func testRejectsIncompleteConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data("{\"current\":\"local\"}".utf8).write(to: url)

        XCTAssertThrowsError(try WarrenEndpointCatalog.loadThrowing(from: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unable to decode endpoint catalog"))
        }
    }

    func testSavesSSHEndpointWithPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "tenc_sh",
            url: "",
            token: "",
            ssh: "tenc_sh"
        )

        try WarrenEndpointCatalog.save(endpoints: [endpoint], current: endpoint.name, to: url)

        let catalog = WarrenEndpointCatalog.load(from: url)
        XCTAssertEqual(catalog.current, "tenc_sh")
        XCTAssertEqual(catalog.endpoints, [endpoint])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    func testSSHEndpointNamesDoNotOverwriteExistingEndpoints() {
        let direct = WarrenRemoteEndpointConfiguration(
            name: "tenc_sh",
            url: "https://example.test",
            token: "token",
            ssh: nil
        )
        let existingSSH = WarrenRemoteEndpointConfiguration(
            name: "ssh-tenc_sh",
            url: "http://127.0.0.1:0",
            token: "",
            ssh: "other-host"
        )

        XCTAssertEqual(
            WarrenCompositionRoot.endpointName(
                for: "tenc_sh",
                endpoints: [direct, existingSSH]
            ),
            "ssh-tenc_sh-2"
        )
    }

    func testSSHEndpointNameReservesSyntheticLocalEndpoint() {
        let endpointName = WarrenCompositionRoot.endpointName(
            for: "local",
            endpoints: []
        )

        XCTAssertEqual(endpointName, "ssh-local")
    }

    func testSSHEndpointRemotePortRoundTripsWithoutRuntimeCredentials() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "vps",
            url: "",
            token: "",
            ssh: "root@vps.example",
            sshRemote: "127.0.0.1:9000"
        )

        try WarrenEndpointCatalog.upsert(endpoint, current: endpoint.name, to: url)

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, endpoint.name)
        XCTAssertEqual(catalog.endpoints, [endpoint])
    }

    func testSetCurrentKeepsTheNewestEndpointSet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "vps",
            url: "https://vps.example",
            token: "token",
            ssh: nil
        )
        try WarrenEndpointCatalog.upsert(endpoint, to: url)
        try WarrenEndpointCatalog.setCurrent(endpoint.name, to: url)

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, endpoint.name)
        XCTAssertEqual(catalog.endpoints, [endpoint])
    }

    func testRelayClientIdentityRoundTripsThroughCatalog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "relay",
            url: "https://relay.example",
            token: "access-token",
            type: "relay",
            hostID: "00000000-0000-4000-8000-000000000001",
            clientID: "desktop-client-1"
        )

        try WarrenEndpointCatalog.save(endpoints: [endpoint], current: endpoint.name, to: url)

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.endpoints.first?.clientID, "desktop-client-1")
    }

    func testDisplayRoundTripsAndPreservesEndpointMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "prod",
            url: "https://prod.example",
            token: "prod-secret",
            type: "relay",
            hostID: "host-1",
            routeID: "route-1",
            clientID: "client-1"
        )

        try WarrenEndpointCatalog.save(
            endpoints: [endpoint],
            current: endpoint.name,
            display: WarrenDisplayConfiguration(
                endpoints: ["local", "prod"],
                names: ["local": "My Mac", "prod": "Production"]
            ),
            to: url
        )

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, "prod")
        XCTAssertEqual(
            catalog.display,
            WarrenDisplayConfiguration(
                endpoints: ["local", "prod"],
                names: ["local": "My Mac", "prod": "Production"]
            )
        )
        XCTAssertEqual(catalog.endpoints, [endpoint])
        XCTAssertEqual(
            try WarrenEndpointCatalog.effectiveDisplay(from: catalog),
            ["local", "prod"]
        )
    }

    func testSetDisplayNamePreservesAliasesAndCurrentEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "prod",
            url: "https://prod.example",
            token: "prod-secret"
        )
        try WarrenEndpointCatalog.save(
            endpoints: [endpoint],
            current: endpoint.name,
            display: WarrenDisplayConfiguration(endpoints: ["local", "prod"]),
            to: url
        )

        try WarrenEndpointCatalog.setDisplayName("local", name: "Office Mac", to: url)
        var catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, "prod")
        XCTAssertEqual(catalog.display?.endpoints, ["local", "prod"])
        XCTAssertEqual(catalog.display?.names, ["local": "Office Mac"])

        try WarrenEndpointCatalog.setDisplayName("local", name: nil, to: url)
        catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.display?.names, [:])
    }

    func testLegacySidebarMigratesToDisplayOnWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let legacy = """
        {
          "current": "dev",
          "endpoints": {
            "dev": {"name": "dev", "url": "https://dev.example", "token": "secret"}
          },
          "sidebar": {"version": 1, "endpoints": ["local", "dev"]}
        }
        """
        try Data(legacy.utf8).write(to: url)

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(
            catalog.display,
            WarrenDisplayConfiguration(endpoints: ["local", "dev"])
        )

        try WarrenEndpointCatalog.setCurrent("dev", to: url)
        let data = try Data(contentsOf: url)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(object["display"])
        XCTAssertNil(object["sidebar"])
    }

    func testSetCurrentPreservesAnExplicitDisplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let dev = WarrenRemoteEndpointConfiguration(
            name: "dev",
            url: "https://dev.example",
            token: "dev-secret"
        )
        let prod = WarrenRemoteEndpointConfiguration(
            name: "prod",
            url: "https://prod.example",
            token: "prod-secret"
        )
        try WarrenEndpointCatalog.save(
            endpoints: [dev, prod],
            current: "dev",
            display: WarrenDisplayConfiguration(endpoints: ["dev"]),
            to: url
        )

        try WarrenEndpointCatalog.setCurrent("prod", to: url)

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, "prod")
        XCTAssertEqual(catalog.display?.endpoints, ["dev"])
        XCTAssertEqual(try WarrenEndpointCatalog.effectiveDisplay(from: catalog), ["dev"])
    }

    func testDisplayMembershipIsExplicitAndKeepsCurrentEndpoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let dev = WarrenRemoteEndpointConfiguration(
            name: "dev",
            url: "https://dev.example",
            token: "dev-secret"
        )
        let prod = WarrenRemoteEndpointConfiguration(
            name: "prod",
            url: "https://prod.example",
            token: "prod-secret"
        )
        try WarrenEndpointCatalog.save(
            endpoints: [dev, prod],
            current: "dev",
            to: url
        )

        try WarrenEndpointCatalog.setDisplayMembership("prod", isDisplayed: true, to: url)
        var catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, "dev")
        XCTAssertEqual(catalog.display?.endpoints, ["dev", "prod"])

        try WarrenEndpointCatalog.setDisplayMembership("prod", isDisplayed: false, to: url)
        catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.current, "dev")
        XCTAssertEqual(catalog.display?.endpoints, ["dev"])

        try WarrenEndpointCatalog.setDisplayMembership("dev", isDisplayed: false, to: url)
        catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertNil(catalog.display)
    }

    func testUpsertPreservesDisplayAndResetRestoresLegacyRepresentation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let dev = WarrenRemoteEndpointConfiguration(
            name: "dev",
            url: "https://dev.example",
            token: "dev-secret"
        )
        try WarrenEndpointCatalog.save(
            endpoints: [dev],
            current: "dev",
            display: WarrenDisplayConfiguration(endpoints: ["local", "dev"]),
            to: url
        )

        let updated = WarrenRemoteEndpointConfiguration(
            name: "dev",
            url: "https://dev-new.example",
            token: "new-secret"
        )
        try WarrenEndpointCatalog.upsert(updated, to: url)
        var catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertEqual(catalog.display?.endpoints, ["local", "dev"])
        XCTAssertEqual(catalog.endpoints.first?.url, "https://dev-new.example")

        try WarrenEndpointCatalog.resetDisplay(to: url)
        catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertNil(catalog.display)
        XCTAssertEqual(try WarrenEndpointCatalog.effectiveDisplay(from: catalog), ["dev"])
    }

    func testDisplayCatalogRejectsEmptyUnknownAndFutureVersions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let endpoint = WarrenRemoteEndpointConfiguration(
            name: "dev",
            url: "https://dev.example",
            token: "secret"
        )
        try WarrenEndpointCatalog.save(endpoints: [endpoint], current: "dev", to: url)

        XCTAssertThrowsError(try WarrenEndpointCatalog.setDisplay([], to: url))
        XCTAssertThrowsError(try WarrenEndpointCatalog.setDisplay(["missing"], to: url))

        let future = """
        {
          "current": "dev",
          "endpoints": {
            "dev": {"name": "dev", "url": "https://dev.example", "token": "secret"}
          },
          "display": {"version": 99, "endpoints": ["dev"]}
        }
        """
        try Data(future.utf8).write(to: url)
        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)
        XCTAssertThrowsError(try WarrenEndpointCatalog.effectiveDisplay(from: catalog))
    }
}
