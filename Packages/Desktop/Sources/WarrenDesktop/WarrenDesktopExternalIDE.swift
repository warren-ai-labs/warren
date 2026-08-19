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
    typealias Launch = (URL, URL) async throws -> Void

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

enum WarrenDesktopExternalIDEError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "The IDE or workspace is no longer available."
    }
}

extension WarrenDesktopExternalIDEService {
    func open(_ option: WarrenDesktopExternalIDEOption) async throws {
        guard let workspaceURL = option.workspaceURL,
              let applicationURL = option.applicationURL else {
            throw WarrenDesktopExternalIDEError.unavailable
        }
        try await launch(workspaceURL, applicationURL)
    }

    static let live = Self(
        resolveApplicationURL: { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        directoryExists: { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        },
        launch: { workspaceURL, applicationURL in
            try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.open(
                    [workspaceURL],
                    withApplicationAt: applicationURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    )
}
