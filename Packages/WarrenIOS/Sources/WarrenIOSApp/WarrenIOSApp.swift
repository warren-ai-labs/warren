import SwiftUI
import WarrenIOS
import WarrenTransport

@main
struct WarrenIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: IOSApplicationModel

    init() {
        let store = IOSLocalStore()
        let developmentEndpoint = IOSDevelopmentEndpoint.configuration
        let storedEndpoint = store.endpoint
        let endpoint: WarrenRemoteEndpointConfiguration

        if Self.shouldSeedDevelopmentEndpoint(
            stored: storedEndpoint,
            development: developmentEndpoint
        ) {
            // The device build uses the current LAN Host by default. This
            // also repairs the old loopback default left by early builds.
            endpoint = developmentEndpoint
            store.endpoint = endpoint
        } else if let storedEndpoint {
            endpoint = storedEndpoint
        } else {
            endpoint = developmentEndpoint
            store.endpoint = endpoint
        }
        _model = StateObject(wrappedValue: IOSApplicationModel(configuration: endpoint, localStore: store))
    }

    private static func shouldSeedDevelopmentEndpoint(
        stored: WarrenRemoteEndpointConfiguration?,
        development: WarrenRemoteEndpointConfiguration
    ) -> Bool {
        guard let stored else { return true }
        guard !development.url.isEmpty else { return false }
        guard let storedURL = URL(string: stored.url),
              let developmentURL = URL(string: development.url) else {
            return true
        }

        let storedHost = storedURL.host?.lowercased()
        let isLoopback = storedHost == "localhost"
            || storedHost == "127.0.0.1"
            || storedHost == "::1"
        let isDevelopmentHost = storedURL.absoluteString == developmentURL.absoluteString
        // The install script injects the current LAN Host into the managed
        // "Warren LAN" endpoint. UserDefaults survives app updates, so an
        // older build can otherwise keep pointing at a stale home-network
        // address forever. Only refresh the endpoint that this development
        // build owns; named/typed user-configured endpoints remain intact.
        let isManagedDevelopmentEndpoint = stored.name == development.name
            && stored.type == development.type
            && stored.hostID == development.hostID
            && stored.routeID == development.routeID
        let hasStaleDevelopmentURL = isManagedDevelopmentEndpoint && !isDevelopmentHost
        let needsDevelopmentToken = isDevelopmentHost
            && stored.token.isEmpty
            && !development.token.isEmpty
        return isLoopback || hasStaleDevelopmentURL || needsDevelopmentToken
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: model.start()
                    case .background:
                        // A background scene is routinely produced by an
                        // interruption, lock/unlock cycle, or an app switch.
                        // Stopping here tears down the WebSocket and publishes
                        // a misleading Offline state. Keep the connection
                        // intent alive; iOS may suspend the socket, and the
                        // transport will reconnect when the scene is active.
                        break
                    case .inactive: break
                    @unknown default: break
                    }
                }
        }
    }
}
