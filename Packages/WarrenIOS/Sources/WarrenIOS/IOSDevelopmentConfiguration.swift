import Foundation
import WarrenTransport

/// Defaults used by the local device build. The LAN address is explicit for
/// the current development Host; both the URL and token can be overridden at
/// build time through Info.plist keys so `scripts/install-ios.sh` can inject
/// the caller's LAN IP without editing source. Neither value is checked into
/// the repository.
public enum IOSDevelopmentEndpoint {
    public static let name = "Warren LAN"
    private static let defaultURL = "http://192.168.1.117:8789"

    public static var url: String {
        if let value = Bundle.main.object(forInfoDictionaryKey: "WarrenDevelopmentURL") as? String,
           !value.hasPrefix("$("),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return defaultURL
    }

    public static var token: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "WarrenDevelopmentToken") as? String,
              !value.hasPrefix("$("),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ""
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static var configuration: WarrenRemoteEndpointConfiguration {
        WarrenRemoteEndpointConfiguration(name: name, url: url, token: token)
    }
}
