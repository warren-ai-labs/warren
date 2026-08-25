import Foundation

/// Immutable build metadata embedded by `scripts/build-app.sh`.
///
/// Marketing and bundle versions are release identifiers; they are not enough
/// to distinguish local packages built between releases. The Git revision and
/// dirty flag make diagnostics attributable to the exact source snapshot.
struct WarrenBuildIdentity: Equatable, Sendable {
    let bundleVersion: String
    let bundleBuild: String
    let buildVersion: String
    let revision: String
    let isDirty: Bool

    static var current: WarrenBuildIdentity {
        WarrenBuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        bundleVersion = Self.string(
            infoDictionary["CFBundleShortVersionString"],
            fallback: "development"
        )
        bundleBuild = Self.string(
            infoDictionary["CFBundleVersion"],
            fallback: "development"
        )
        buildVersion = Self.string(
            infoDictionary["WarrenBuildVersion"],
            fallback: "development"
        )
        revision = Self.string(
            infoDictionary["WarrenBuildRevision"],
            fallback: "unknown"
        )
        isDirty = (infoDictionary["WarrenBuildDirty"] as? NSNumber)?.boolValue
            ?? (infoDictionary["WarrenBuildDirty"] as? Bool)
            ?? false
    }

    var diagnosticFields: [String: String] {
        [
            "bundleVersion": bundleVersion,
            "bundleBuild": bundleBuild,
            "buildVersion": buildVersion,
            "revision": revision,
            "dirty": isDirty ? "true" : "false",
        ]
    }

    private static func string(_ value: Any?, fallback: String) -> String {
        guard let value = value as? String, !value.isEmpty else { return fallback }
        return value
    }
}
