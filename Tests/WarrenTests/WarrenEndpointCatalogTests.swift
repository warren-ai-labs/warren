import Foundation
import XCTest
@testable import Warren

final class WarrenEndpointCatalogTests: XCTestCase {
    func testLoadsCLIConfigurationEndpoints() throws {
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

        let catalog = WarrenEndpointCatalog.load(from: url)

        XCTAssertEqual(catalog.current, "vps")
        XCTAssertEqual(catalog.endpoints.map(\.name), ["local", "vps"])
        let vps = try XCTUnwrap(catalog.endpoints.first { $0.name == "vps" })
        XCTAssertEqual(vps.url, "")
        XCTAssertEqual(vps.token, "")
        XCTAssertEqual(vps.ssh, "root@vps.example")
        let rewritten = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(rewritten.contains("remote-token"))
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

    func testIncompleteConfigurationDefaultsToEmptyEndpointMap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("warren-endpoint-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data("{\"current\":\"local\"}".utf8).write(to: url)

        let catalog = try WarrenEndpointCatalog.loadThrowing(from: url)

        XCTAssertEqual(catalog.current, "local")
        XCTAssertTrue(catalog.endpoints.isEmpty)
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

    func testSSHEndpointRemotePortRoundTripsAndRuntimeCredentialsAreScrubbed() throws {
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
}
