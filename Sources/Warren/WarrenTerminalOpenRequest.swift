import Foundation

/// Commands sent to the running Warren desktop application by launchers such
/// as Raycast. Selectors are deliberately strings: Warren resolves either a
/// UUID or the current display name against the live Host roster, so links do
/// not embed a second resource database.
struct WarrenTerminalOpenRequest: Equatable, Sendable {
    static let scheme = "warren"
    static let terminalHost = "terminal"

    let group: String?
    let project: String?
    let workspace: String?
    let session: String?

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else {
            return nil
        }

        let host = url.host?.lowercased() ?? ""
        let allowedHosts = [Self.terminalHost, "project", "workspace", "session", "group"]
        guard allowedHosts.contains(host) else {
            return nil
        }

        let queryItems = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []
        var selectors: [String: String] = [:]
        for item in queryItems {
            let key = item.name.lowercased()
            guard ["group", "project", "workspace", "session"].contains(key),
                  let rawValue = item.value else { continue }
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, selectors[key] == nil else { continue }
            selectors[key] = value
        }

        // `warren://project/<selector>` is a compact spelling for callers
        // that prefer a resource-shaped URL. The query spelling remains the
        // canonical form and supports all three levels in one link.
        var pathParts = url.path.split(separator: "/").map(String.init)
        if host != Self.terminalHost, pathParts.count == 1,
           selectors[host] == nil {
            selectors[host] = pathParts.removeFirst()
        } else if host == Self.terminalHost, !pathParts.isEmpty {
            var index = 0
            while index + 1 < pathParts.count {
                let key = pathParts[index].lowercased()
                let value = pathParts[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard ["group", "project", "workspace", "session"].contains(key), !value.isEmpty else {
                    index += 1
                    continue
                }
                selectors[key] = selectors[key] ?? value
                index += 2
            }
        }

        if host != Self.terminalHost, selectors[host] == nil {
            return nil
        }

        group = selectors["group"]
        project = selectors["project"]
        workspace = selectors["workspace"]
        session = selectors["session"]
    }

    var hasResourceTarget: Bool {
        project != nil || workspace != nil || session != nil
    }
}

enum WarrenAppCommand {
    static let openTerminal = Notification.Name("WarrenAppCommand.openTerminal")
}
