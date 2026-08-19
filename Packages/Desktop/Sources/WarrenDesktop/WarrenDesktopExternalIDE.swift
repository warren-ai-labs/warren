import AppKit
import Foundation
import WarrenDomain

struct WarrenDesktopExternalIDE: Identifiable, Hashable, Sendable {
    enum ID: String, Hashable, Sendable {
        case visualStudioCode
        case goLand
        case androidStudio
    }

    let id: ID
    let name: String
    let bundleIdentifier: String
    let systemImage: String

    static let supported = [
        Self(
            id: .visualStudioCode,
            name: "Visual Studio Code",
            bundleIdentifier: "com.microsoft.VSCode",
            systemImage: "chevron.left.forwardslash.chevron.right"
        ),
        Self(
            id: .goLand,
            name: "GoLand",
            bundleIdentifier: "com.jetbrains.goland",
            systemImage: "g.square"
        ),
        Self(
            id: .androidStudio,
            name: "Android Studio",
            bundleIdentifier: "com.google.android.studio",
            systemImage: "a.square"
        ),
    ]
}

struct WarrenDesktopExternalIDEOption: Identifiable, Equatable {
    let ide: WarrenDesktopExternalIDE
    let workspaceURL: URL?
    let applicationURL: URL?

    var id: WarrenDesktopExternalIDE.ID { ide.id }
    var isEnabled: Bool { workspaceURL != nil && applicationURL != nil }
}

@MainActor
struct WarrenDesktopExternalIDEService {
    typealias Launch = (URL, URL, @escaping (Error?) -> Void) -> Void

    let resolveApplicationURL: (String) -> URL?
    let directoryExists: (URL) -> Bool
    let launch: Launch

    func options(
        for workspace: Workspace?,
        isLocalEndpoint: Bool
    ) -> [WarrenDesktopExternalIDEOption] {
        let workspaceURL = workspace.map {
            URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL
        }
        let availableWorkspaceURL = workspaceURL.flatMap { url in
            isLocalEndpoint && directoryExists(url) ? url : nil
        }

        return WarrenDesktopExternalIDE.supported.map { ide in
            WarrenDesktopExternalIDEOption(
                ide: ide,
                workspaceURL: availableWorkspaceURL,
                applicationURL: resolveApplicationURL(ide.bundleIdentifier)
            )
        }
    }
}
