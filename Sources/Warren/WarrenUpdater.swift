import AppKit
import Foundation

struct WarrenReleaseAsset: Codable, Equatable, Sendable {
    let name: String
    let browserDownloadURL: String
    let size: Int64?
    var downloadURL: URL? { URL(string: browserDownloadURL) }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct WarrenRelease: Codable, Equatable, Sendable {
    let tagName: String
    let htmlURL: URL?
    let body: String?
    let assets: [WarrenReleaseAsset]

    var version: WarrenVersion? { WarrenVersion(tagName) }
    var displayVersion: String { version.map { "v\($0)" } ?? tagName }
    var applicationAsset: WarrenReleaseAsset? {
        assets.first { asset in
            asset.name.range(
                of: #"^Warren-[^/]+\.zip$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }
    var isInstallable: Bool {
        guard let url = applicationAsset?.downloadURL else { return false }
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "objects.githubusercontent.com"
    }
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

struct WarrenVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    enum Identifier: Equatable, Sendable {
        case numeric(Int)
        case text(String)
    }

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        guard !value.isEmpty else { return nil }
        let components = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: true)
        guard let coreAndPrerelease = components.first else { return nil }
        let coreParts = coreAndPrerelease.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numericParts = coreParts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numericParts.count) else { return nil }
        let numbers = numericParts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        major = numbers[0] ?? 0
        minor = numbers.count > 1 ? (numbers[1] ?? 0) : 0
        patch = numbers.count > 2 ? (numbers[2] ?? 0) : 0
        if coreParts.count == 2 {
            let identifiers = coreParts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, !identifiers.contains(where: \.isEmpty) else { return nil }
            prerelease = identifiers.map { identifier in
                if let number = Int(identifier), String(number) == identifier { return .numeric(number) }
                return .text(String(identifier))
            }
        } else {
            prerelease = []
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        guard !prerelease.isEmpty else { return core }
        let suffix = prerelease.map { identifier in
            switch identifier {
            case .numeric(let value): String(value)
            case .text(let value): value
            }
        }.joined(separator: ".")
        return "\(core)-\(suffix)"
    }

    static func < (lhs: WarrenVersion, rhs: WarrenVersion) -> Bool {
        for (left, right) in zip([lhs.major, lhs.minor, lhs.patch], [rhs.major, rhs.minor, rhs.patch]) where left != right {
            return left < right
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false):
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
                switch (left, right) {
                case let (.numeric(left), .numeric(right)) where left != right: return left < right
                case (.numeric, .text): return true
                case (.text, .numeric): return false
                case let (.text(left), .text(right)) where left != right: return left < right
                default: continue
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }
}

enum WarrenUpdaterError: LocalizedError, Equatable, Sendable {
    case invalidRelease
    case unsupportedAsset
    case invalidResponse
    case downloadFailed(String)
    case extractionFailed(String)
    case invalidApplication
    case destinationNotWritable
    case unableToLaunchInstaller(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease:
            "The latest Warren release has an invalid version."
        case .unsupportedAsset:
            "The latest Warren release does not include a trusted Warren application archive."
        case .invalidResponse:
            "The Warren release service returned an invalid response."
        case .downloadFailed(let message):
            "Could not download the Warren update: \(message)"
        case .extractionFailed(let message):
            "Could not unpack the Warren update: \(message)"
        case .invalidApplication:
            "The downloaded file is not a valid Warren application."
        case .destinationNotWritable:
            "Warren cannot write to its current application folder. Move Warren to a writable location and try again."
        case .unableToLaunchInstaller(let message):
            "Could not start the Warren installer: \(message)"
        }
    }
}

/// Notifications used by the desktop banner and the application delegate.
enum WarrenUpdateNotification {
    static let available = Notification.Name("Warren.updateAvailable")
    static let installRequested = Notification.Name("Warren.installUpdateRequested")
    static let dismiss = Notification.Name("Warren.dismissUpdate")
    static let installing = Notification.Name("Warren.installingUpdate")
    static let failed = Notification.Name("Warren.updateFailed")
    static let keyRelease = "release"
    static let keyError = "error"
}

/// Fetches Warren releases through the release service and stages a verified
/// Warren.app for installation.
@MainActor
final class WarrenUpdater {
    /// The release proxy keeps GitHub API credentials and caching at the edge.
    static let latestReleaseURL = URL(string: "https://warrenai.xyz/api/update/latest")!
    static let checkInterval: TimeInterval = 3 * 60 * 60
    static let maximumArchiveSize: Int64 = 512 * 1024 * 1024
    static let lastCheckDateKey = "Warren.Updater.lastCheckDate"

    private let session: URLSession
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let currentVersion: WarrenVersion?
    private let cacheDirectory: URL

    init(
        currentVersion: WarrenVersion? = WarrenUpdater.installedVersion,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        cacheDirectory: URL? = nil
    ) {
        self.currentVersion = currentVersion
        self.session = session
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.now = now
        self.cacheDirectory = cacheDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Warren/Updates", isDirectory: true)
    }

    static var installedVersion: WarrenVersion? {
        guard let rawValue = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else { return nil }
        return WarrenVersion(rawValue)
    }

    var shouldCheckAutomatically: Bool {
        guard let lastCheck = userDefaults.object(forKey: Self.lastCheckDateKey) as? Date else {
            return true
        }
        return now().timeIntervalSince(lastCheck) >= Self.checkInterval
    }

    /// Returns a newer release, or nil when the installed version is current.
    /// Automatic checks are throttled; manual checks always reach the release service.
    func checkForUpdates(force: Bool = false) async throws -> WarrenRelease? {
        if !force, !shouldCheckAutomatically {
            return nil
        }

        let release = try await fetchLatestRelease(force: force)
        userDefaults.set(now(), forKey: Self.lastCheckDateKey)
        guard let latestVersion = release.version, let currentVersion else {
            return nil
        }
        return latestVersion > currentVersion ? release : nil
    }

    /// Downloads and unpacks an official Warren archive without touching the
    /// running application. The returned bundle is consumed by the detached
    /// installer after the current process exits.
    func downloadAndPrepare(
        _ release: WarrenRelease,
        replacing destinationURL: URL = Bundle.main.bundleURL
    ) async throws -> URL {
        guard let asset = release.applicationAsset, release.isInstallable,
              let downloadURL = asset.downloadURL else {
            throw WarrenUpdaterError.unsupportedAsset
        }
        if let size = asset.size, size > Self.maximumArchiveSize {
            throw WarrenUpdaterError.downloadFailed("the archive is larger than the 512 MB safety limit")
        }
        guard let latestVersion = release.version,
              let currentVersion,
              latestVersion > currentVersion else {
            throw WarrenUpdaterError.invalidRelease
        }
        guard destinationURL.pathExtension.lowercased() == "app" else {
            throw WarrenUpdaterError.invalidApplication
        }

        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let updateDirectory = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extractionDirectory = updateDirectory.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        let archiveURL = updateDirectory.appendingPathComponent(asset.name)

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 120
        request.setValue("Warren-Updater/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        do {
            let (temporaryURL, response) = try await session.download(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw WarrenUpdaterError.invalidResponse
            }
            let expectedSize = httpResponse.expectedContentLength
            if expectedSize > Self.maximumArchiveSize {
                throw WarrenUpdaterError.downloadFailed("the archive is larger than the 512 MB safety limit")
            }
            try fileManager.moveItem(at: temporaryURL, to: archiveURL)
        } catch let error as WarrenUpdaterError {
            throw error
        } catch {
            throw WarrenUpdaterError.downloadFailed(error.localizedDescription)
        }

        do {
            try await Task.detached(priority: .userInitiated) {
                try WarrenUpdateArchive.extract(archiveURL: archiveURL, to: extractionDirectory)
            }.value
        } catch let error as WarrenUpdaterError {
            throw error
        } catch {
            throw WarrenUpdaterError.extractionFailed(error.localizedDescription)
        }

        guard let applicationURL = WarrenUpdateArchive.findApplication(in: extractionDirectory),
              WarrenUpdateArchive.isValidWarrenApplication(
                  at: applicationURL,
                  expectedVersion: latestVersion
              ) else {
            throw WarrenUpdaterError.invalidApplication
        }

        guard fileManager.isWritableFile(atPath: destinationURL.deletingLastPathComponent().path) else {
            throw WarrenUpdaterError.destinationNotWritable
        }
        return applicationURL
    }

    /// Starts a helper process that waits for Warren to quit, replaces the app
    /// bundle, restarts Warren, and leaves the detached ghostline owner alive.
    func launchInstaller(
        stagedApplicationURL: URL,
        replacing destinationURL: URL = Bundle.main.bundleURL
    ) throws {
        do {
            try WarrenUpdateInstaller.launch(
                stagedApplicationURL: stagedApplicationURL,
                destinationURL: destinationURL,
                currentProcessID: ProcessInfo.processInfo.processIdentifier,
                cacheDirectory: cacheDirectory,
                fileManager: fileManager
            )
        } catch let error as WarrenUpdaterError {
            throw error
        } catch {
            throw WarrenUpdaterError.unableToLaunchInstaller(error.localizedDescription)
        }
    }

    private func fetchLatestRelease(force: Bool) async throws -> WarrenRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Warren-Updater", forHTTPHeaderField: "User-Agent")
        if force {
            // Manual checks must not reuse a stale URLSession response from
            // before a release was published. The Worker remains responsible
            // for its short edge cache; this bypass only the local client cache.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw WarrenUpdaterError.invalidResponse
            }
            let decoder = JSONDecoder()
            let release = try decoder.decode(WarrenRelease.self, from: data)
            guard release.version != nil else { throw WarrenUpdaterError.invalidRelease }
            return release
        } catch let error as WarrenUpdaterError {
            throw error
        } catch {
            throw WarrenUpdaterError.downloadFailed(error.localizedDescription)
        }
    }
}

private enum WarrenUpdateArchive {
    static func extract(archiveURL: URL, to extractionDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, extractionDirectory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw WarrenUpdaterError.extractionFailed(message ?? "ditto exited with status \(process.terminationStatus)")
        }
    }

    static func findApplication(in directory: URL) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "app",
                  url.lastPathComponent == "Warren.app" else { continue }
            return url
        }
        return nil
    }

    static func isValidWarrenApplication(
        at applicationURL: URL,
        expectedVersion: WarrenVersion
    ) -> Bool {
        guard let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == "com.abcdlsj.warren",
              let rawVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = WarrenVersion(rawVersion),
              version == expectedVersion,
              FileManager.default.isExecutableFile(
                  atPath: applicationURL.appendingPathComponent("Contents/MacOS/Warren").path
              ) else {
            return false
        }
        return true
    }
}

private enum WarrenUpdateInstaller {
    static func launch(
        stagedApplicationURL: URL,
        destinationURL: URL,
        currentProcessID: Int32,
        cacheDirectory: URL,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: stagedApplicationURL.path),
              destinationURL.pathExtension.lowercased() == "app" else {
            throw WarrenUpdaterError.invalidApplication
        }
        guard fileManager.isWritableFile(atPath: destinationURL.deletingLastPathComponent().path) else {
            throw WarrenUpdaterError.destinationNotWritable
        }

        let installerDirectory = cacheDirectory.appendingPathComponent("installers", isDirectory: true)
        try fileManager.createDirectory(at: installerDirectory, withIntermediateDirectories: true)
        let scriptURL = installerDirectory.appendingPathComponent("apply-\(UUID().uuidString).sh")
        guard let scriptData = installerScript.data(using: .utf8) else {
            throw WarrenUpdaterError.unableToLaunchInstaller("could not encode installer script")
        }
        try scriptData.write(to: scriptURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(currentProcessID),
            stagedApplicationURL.path,
            destinationURL.path,
        ]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw WarrenUpdaterError.unableToLaunchInstaller(error.localizedDescription)
        }
    }

    private static let installerScript = """
    #!/bin/sh
    set -eu

    current_pid="$1"
    staged_app="$2"
    destination_app="$3"
    backup_app="$destination_app.warren-backup-$current_pid"

    while kill -0 "$current_pid" 2>/dev/null; do
        sleep 0.1
    done

    # Keep ghostline session owners alive while replacing the GUI and control plane.
    for executable in \\
        "$destination_app/Contents/MacOS/WarrenDaemonMenuBar" \\
        "$destination_app/Contents/MacOS/warren-headless"; do
        ps -axo pid=,command= | awk -v exe="$executable" '$2 == exe && NF == 2 { print $1 }' |
            while read -r pid; do
                [ -n "$pid" ] || continue
                [ "$pid" = "$current_pid" ] && continue
                kill -TERM "$pid" 2>/dev/null || true
            done
    done

    for _ in $(seq 1 30); do
        still_running=0
        for executable in \\
            "$destination_app/Contents/MacOS/WarrenDaemonMenuBar" \\
            "$destination_app/Contents/MacOS/warren-headless"; do
            if ps -axo pid=,command= | awk -v exe="$executable" '$2 == exe && NF == 2 { found=1 } END { exit !found }'; then
                still_running=1
            fi
        done
        [ "$still_running" -eq 0 ] && break
        sleep 0.1
    done

    rm -rf "$backup_app"
    if [ -e "$destination_app" ]; then
        mv "$destination_app" "$backup_app"
    fi

    if ! ditto "$staged_app" "$destination_app"; then
        rm -rf "$destination_app"
        if [ -e "$backup_app" ]; then
            mv "$backup_app" "$destination_app"
            /usr/bin/open "$destination_app" || true
        fi
        exit 1
    fi

    if ! /usr/bin/open "$destination_app"; then
        rm -rf "$destination_app"
        if [ -e "$backup_app" ]; then
            mv "$backup_app" "$destination_app"
            /usr/bin/open "$destination_app" || true
        fi
        exit 1
    fi
    rm -rf "$backup_app" "$staged_app"
    rm -f "$0"
    """
}
