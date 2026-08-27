import Foundation

/// Aggregated Git projection for one workspace, mirroring the headless
/// `api.GitPanel` payload so desktop rendering never reformats the wire type.
public struct WarrenDesktopGitPanel: Codable, Hashable, Sendable {
    public let workspace: String
    public var branch: String
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var aheadOfMain: Int
    public var remote: String?
    public var mainBranch: String?
    public var merged: Bool
    public var operation: String?
    public var changes: [WarrenDesktopGitChange]
    public var commits: [WarrenDesktopGitCommit]
    public var unmergedCommits: [WarrenDesktopGitCommit]?
    public var branches: [WarrenDesktopGitBranch]
    public var pullRequest: WarrenDesktopGitPullRequest?
    public var pullRequestError: String?
    public var refreshing: Bool

    public init(
        workspace: String,
        branch: String = "",
        upstream: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        aheadOfMain: Int = 0,
        remote: String? = nil,
        mainBranch: String? = nil,
        merged: Bool = false,
        operation: String? = nil,
        changes: [WarrenDesktopGitChange] = [],
        commits: [WarrenDesktopGitCommit] = [],
        unmergedCommits: [WarrenDesktopGitCommit]? = nil,
        branches: [WarrenDesktopGitBranch] = [],
        pullRequest: WarrenDesktopGitPullRequest? = nil,
        pullRequestError: String? = nil,
        refreshing: Bool = false
    ) {
        self.workspace = workspace
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.aheadOfMain = aheadOfMain
        self.remote = remote
        self.mainBranch = mainBranch
        self.merged = merged
        self.operation = operation
        self.changes = changes
        self.commits = commits
        self.unmergedCommits = unmergedCommits
        self.branches = branches
        self.pullRequest = pullRequest
        self.pullRequestError = pullRequestError
        self.refreshing = refreshing
    }
}

public struct WarrenDesktopGitChange: Codable, Hashable, Sendable {
    public var path: String
    public var status: String
    public var staged: Bool
    public var renameFrom: String?
    public var added: Int
    public var deleted: Int

    public init(
        path: String,
        status: String,
        staged: Bool = false,
        renameFrom: String? = nil,
        added: Int = 0,
        deleted: Int = 0
    ) {
        self.path = path
        self.status = status
        self.staged = staged
        self.renameFrom = renameFrom
        self.added = added
        self.deleted = deleted
    }
}

public struct WarrenDesktopGitCommit: Codable, Hashable, Sendable {
    public var hash: String
    public var short: String
    public var subject: String
    public var author: String
    public var email: String?
    public var time: String
    public var files: [WarrenDesktopGitChange]

    public init(
        hash: String,
        short: String,
        subject: String,
        author: String,
        email: String? = nil,
        time: String = "",
        files: [WarrenDesktopGitChange] = []
    ) {
        self.hash = hash
        self.short = short
        self.subject = subject
        self.author = author
        self.email = email
        self.time = time
        self.files = files
    }
}

public struct WarrenDesktopGitBranch: Codable, Hashable, Sendable {
    public var name: String
    public var remote: Bool

    public init(name: String, remote: Bool = false) {
        self.name = name
        self.remote = remote
    }
}

public struct WarrenDesktopGitPullRequest: Codable, Hashable, Sendable {
    public var number: Int?
    public var title: String
    public var body: String?
    public var state: String?
    public var draft: Bool
    public var url: String?
    public var author: String?
    public var base: String?
    public var head: String?

    public init(
        number: Int? = nil,
        title: String,
        body: String? = nil,
        state: String? = nil,
        draft: Bool = false,
        url: String? = nil,
        author: String? = nil,
        base: String? = nil,
        head: String? = nil
    ) {
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.draft = draft
        self.url = url
        self.author = author
        self.base = base
        self.head = head
    }
}

public struct WarrenDesktopGitDiff: Codable, Hashable, Sendable {
    public var diff: String
    public var content: String

    public init(diff: String = "", content: String = "") {
        self.diff = diff
        self.content = content
    }
}

public struct WarrenDesktopGitCommandResult: Codable, Hashable, Sendable {
    public var message: String

    public init(message: String = "") {
        self.message = message
    }
}

public enum WarrenDesktopGitStatusLabel {
    public static func label(for status: String) -> String {
        switch status {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "C": "Copied"
        case "U": "Unmerged"
        case "T": "Type change"
        case "?": "Untracked"
        default: status
        }
    }

    public static func symbol(for status: String) -> String {
        status == "?" ? "??" : status
    }
}

public enum WarrenDesktopGitRelativeTime {
    public static func string(from iso: String, now: Date = Date()) -> String {
        guard !iso.isEmpty, let date = date(from: iso) else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        let units: [(size: Int, name: String)] = [
            (60, "minute"), (3600, "hour"), (86400, "day"),
            (604800, "week"), (2592000, "month"), (31536000, "year"),
        ]
        for (size, name) in units.reversed() where seconds >= size {
            let count = seconds / size
            return "\(count) \(name)\(count == 1 ? "" : "s") ago"
        }
        return ""
    }

    public static func date(from iso: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: iso) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: iso)
    }
}

public enum WarrenDesktopGitDiffSummary {
    public static func summary(of changes: [WarrenDesktopGitChange]) -> (added: Int, deleted: Int) {
        changes.reduce(into: (added: 0, deleted: 0)) { total, change in
            total.added += change.added
            total.deleted += change.deleted
        }
    }
}

public enum WarrenDesktopGitDiffLineKind: Hashable, Sendable {
    case hunk
    case meta
    case add
    case del
    case context
}

public struct WarrenDesktopGitDiffLine: Hashable, Sendable {
    public let kind: WarrenDesktopGitDiffLineKind
    public let oldLine: Int?
    public let newLine: Int?
    public let text: String

    public init(kind: WarrenDesktopGitDiffLineKind, oldLine: Int?, newLine: Int?, text: String) {
        self.kind = kind
        self.oldLine = oldLine
        self.newLine = newLine
        self.text = text
    }
}

public enum WarrenDesktopGitDiffParser {
    public static func parse(_ text: String) -> [WarrenDesktopGitDiffLine] {
        var rawLines = text.components(separatedBy: "\n")
        if rawLines.last == "" { rawLines.removeLast() }
        var lines: [WarrenDesktopGitDiffLine] = []
        var oldLine = 0
        var newLine = 0
        for raw in rawLines {
            if raw.hasPrefix("@@") {
                if let match = hunkRange(raw) {
                    oldLine = match.old
                    newLine = match.new
                }
                lines.append(WarrenDesktopGitDiffLine(kind: .hunk, oldLine: nil, newLine: nil, text: raw))
            } else if isMeta(raw) {
                lines.append(WarrenDesktopGitDiffLine(kind: .meta, oldLine: nil, newLine: nil, text: raw))
            } else if raw.hasPrefix("+") {
                lines.append(WarrenDesktopGitDiffLine(kind: .add, oldLine: nil, newLine: newLine, text: String(raw.dropFirst())))
                newLine += 1
            } else if raw.hasPrefix("-") {
                lines.append(WarrenDesktopGitDiffLine(kind: .del, oldLine: oldLine, newLine: nil, text: String(raw.dropFirst())))
                oldLine += 1
            } else {
                lines.append(WarrenDesktopGitDiffLine(kind: .context, oldLine: oldLine, newLine: newLine, text: String(raw.dropFirst())))
                oldLine += 1
                newLine += 1
            }
        }
        return lines
    }

    private static func hunkRange(_ raw: String) -> (old: Int, new: Int)? {
        // @@ -old(,count)? +new(,count)? @@
        let pattern = #/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/#
        guard let match = raw.firstMatch(of: pattern),
              let old = Int(match.1),
              let new = Int(match.2) else { return nil }
        return (old, new)
    }

    private static func isMeta(_ raw: String) -> Bool {
        raw.hasPrefix("diff --git")
            || raw.hasPrefix("index ")
            || raw.hasPrefix("--- ")
            || raw.hasPrefix("+++ ")
            || raw.hasPrefix("new file mode")
            || raw.hasPrefix("deleted file mode")
            || raw.hasPrefix("\\ No newline")
            || raw.hasPrefix("Binary files")
    }
}
