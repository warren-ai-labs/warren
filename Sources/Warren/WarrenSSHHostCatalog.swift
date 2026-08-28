import Foundation

struct WarrenSSHHost: Identifiable, Hashable, Sendable {
    let name: String
    let host: String
    let user: String
    let port: Int
    let supported: Bool
    let message: String?

    var id: String { name }
}

enum WarrenSSHHostCatalog {
    private struct Block {
        var patterns: [String]
        var values: [String: [String]]
    }

    static func load() -> [WarrenSSHHost] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        return load(from: path)
    }

    static func load(from url: URL) -> [WarrenSSHHost] {
        var seenFiles = Set<String>()
        let blocks = parseFile(url.standardizedFileURL, seenFiles: &seenFiles)
        var names: [String] = []
        var seenNames = Set<String>()
        for block in blocks {
            for pattern in block.patterns where isConcrete(pattern) && seenNames.insert(pattern).inserted {
                names.append(pattern)
            }
        }
        return names.map { resolve(name: $0, blocks: blocks) }
    }

    private static func parseFile(_ url: URL, seenFiles: inout Set<String>) -> [Block] {
        let normalized = url.standardizedFileURL.path
        guard seenFiles.insert(normalized).inserted,
              let data = try? Data(contentsOf: URL(fileURLWithPath: normalized)),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        defer { seenFiles.remove(normalized) }

        var blocks: [Block] = []
        var current = Block(patterns: ["*"], values: [:])
        var hasHostBlock = false
        func flush() {
            guard hasHostBlock || !current.values.isEmpty else { return }
            blocks.append(current)
            current.values.removeAll(keepingCapacity: true)
            hasHostBlock = false
        }

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let fields = normalizeFields(parseFields(line))
            guard fields.count >= 2 else { continue }
            let option = fields[0].lowercased()
            switch option {
            case "host":
                flush()
                current = Block(patterns: Array(fields.dropFirst()), values: [:])
                hasHostBlock = true
            case "include":
                // Keep an option-less Host block pending around an Include so
                // included aliases retain their existing order. The pending
                // block is still emitted at EOF, which keeps bare aliases
                // selectable.
                if !current.values.isEmpty {
                    flush()
                }
                for pattern in fields.dropFirst() {
                    for includedURL in includeURLs(pattern, relativeTo: url.deletingLastPathComponent()) {
                        blocks.append(contentsOf: parseFile(includedURL, seenFiles: &seenFiles))
                    }
                }
            default:
                current.values[option, default: []].append(contentsOf: fields.dropFirst())
            }
        }
        flush()
        return blocks
    }

    private static func resolve(name: String, blocks: [Block]) -> WarrenSSHHost {
        var host = name
        var user: String?
        var port = 22
        var portConfigured = false
        var invalidPort: String?
        var proxy: (kind: String, value: String)?
        for block in blocks where matches(block.patterns, name: name) {
            if let value = block.values["hostname"]?.first,
               host == name,
               !value.isEmpty {
                host = value
            }
            if user == nil, let value = block.values["user"]?.first, !value.isEmpty {
                user = value
            }
            if !portConfigured, let value = block.values["port"]?.first {
                portConfigured = true
                if let parsed = Int(value), (1...65535).contains(parsed) {
                    port = parsed
                } else {
                    invalidPort = value
                }
            }
            if proxy == nil {
                if let value = block.values["proxyjump"]?.first {
                    proxy = ("ProxyJump", value)
                } else if let value = block.values["proxycommand"]?.first {
                    proxy = ("ProxyCommand", value)
                }
            }
        }
        if let invalidPort {
            return WarrenSSHHost(
                name: name,
                host: host,
                user: user ?? NSUserName(),
                port: port,
                supported: false,
                message: "Invalid SSH port \(invalidPort)."
            )
        }
        if let proxy, proxy.value.lowercased() != "none" {
            return WarrenSSHHost(
                name: name,
                host: host,
                user: user ?? NSUserName(),
                port: port,
                supported: false,
                message: "\(proxy.kind) is not supported by the embedded client. Use a direct host or an external tunnel (ssh -J/-W) and add it via warren endpoint add."
            )
        }
        return WarrenSSHHost(
            name: name,
            host: host,
            user: user ?? NSUserName(),
            port: port,
            supported: true,
            message: nil
        )
    }

    private static func includeURLs(_ pattern: String, relativeTo directory: URL) -> [URL] {
        var path = expandHome(pattern)
        if !path.hasPrefix("/") {
            path = directory.appendingPathComponent(path).path
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var roots: [URL] = [URL(fileURLWithPath: "/")]
        for component in components {
            let wildcard = component.contains(where: { "*?[".contains($0) })
            var next: [URL] = []
            for root in roots {
                if wildcard {
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: root,
                        includingPropertiesForKeys: nil,
                        options: []
                    ) else { continue }
                    next.append(contentsOf: children.filter {
                        wildcardMatch(component, $0.lastPathComponent)
                    })
                } else {
                    next.append(root.appendingPathComponent(component))
                }
            }
            roots = next
            if roots.isEmpty { break }
        }
        return roots.sorted { $0.path < $1.path }
    }

    private static func expandHome(_ value: String) -> String {
        guard value == "~" || value.hasPrefix("~/") else { return value }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return value == "~" ? home : home + String(value.dropFirst())
    }

    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!") && !pattern.contains(where: { "*?[".contains($0) })
    }

    private static func matches(_ patterns: [String], name: String) -> Bool {
        var matched = false
        for pattern in patterns {
            let negated = pattern.hasPrefix("!")
            let value = negated ? String(pattern.dropFirst()) : pattern
            guard wildcardMatch(value, name) else { continue }
            if negated { return false }
            matched = true
        }
        return matched
    }

    private static func wildcardMatch(_ pattern: String, _ value: String) -> Bool {
        let pattern = Array(pattern)
        let value = Array(value)
        var memo: [String: Bool] = [:]
        func match(_ patternIndex: Int, _ valueIndex: Int) -> Bool {
            let key = "\(patternIndex):\(valueIndex)"
            if let cached = memo[key] { return cached }
            let result: Bool
            if patternIndex == pattern.count {
                result = valueIndex == value.count
            } else if pattern[patternIndex] == "*" {
                result = match(patternIndex + 1, valueIndex)
                    || (valueIndex < value.count && match(patternIndex, valueIndex + 1))
            } else if valueIndex >= value.count {
                result = false
            } else if pattern[patternIndex] == "?" {
                result = match(patternIndex + 1, valueIndex + 1)
            } else if pattern[patternIndex] == "[" {
                var end = patternIndex + 1
                while end < pattern.count, pattern[end] != "]" { end += 1 }
                guard end < pattern.count else {
                    result = pattern[patternIndex] == value[valueIndex]
                        && match(patternIndex + 1, valueIndex + 1)
                    memo[key] = result
                    return result
                }
                let contents = pattern[(patternIndex + 1)..<end]
                let negated = contents.first == "!" || contents.first == "^"
                let candidates = negated ? contents.dropFirst() : contents[...]
                var contains = false
                var index = candidates.startIndex
                while index < candidates.endIndex {
                    if index + 2 < candidates.endIndex, candidates[index + 1] == "-" {
                        let lower = candidates[index].asciiValue ?? 0
                        let upper = candidates[index + 2].asciiValue ?? 0
                        let current = value[valueIndex].asciiValue ?? 0
                        if lower <= current, current <= upper { contains = true }
                        index += 3
                    } else {
                        if candidates[index] == value[valueIndex] { contains = true }
                        index += 1
                    }
                }
                result = (negated ? !contains : contains)
                    && match(end + 1, valueIndex + 1)
            } else {
                result = pattern[patternIndex] == value[valueIndex]
                    && match(patternIndex + 1, valueIndex + 1)
            }
            memo[key] = result
            return result
        }
        return match(0, 0)
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if escaped {
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "'" || character == "\"" {
                quote = character
            } else if character == "#", previous == nil || previous.map({ $0.isWhitespace }) == true {
                return String(line[..<index])
            }
            previous = character
        }
        return line
    }

    private static func parseFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var hasValue = false
        func flush() {
            guard hasValue else { return }
            fields.append(current)
            current.removeAll(keepingCapacity: true)
            hasValue = false
        }
        for character in line {
            if escaped {
                current.append(character)
                hasValue = true
                escaped = false
            } else if character == "\\" {
                escaped = true
                hasValue = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                    hasValue = true
                }
            } else if character == "'" || character == "\"" {
                quote = character
                hasValue = true
            } else if character.isWhitespace {
                flush()
            } else {
                current.append(character)
                hasValue = true
            }
        }
        if escaped { current.append("\\") }
        flush()
        return fields
    }

    /// Accept both OpenSSH spellings, such as "Port 22" and "Port=22".
    /// Generated configurations occasionally put whitespace around the equals
    /// sign, so that form is accepted as well.
    private static func normalizeFields(_ fields: [String]) -> [String] {
        guard !fields.isEmpty else { return fields }
        var normalized = fields
        if let index = normalized[0].firstIndex(of: "="), index != normalized[0].startIndex {
            let option = String(normalized[0][..<index])
            let valueStart = normalized[0].index(after: index)
            let value = valueStart < normalized[0].endIndex
                ? String(normalized[0][valueStart...])
                : ""
            normalized[0] = option
            if !value.isEmpty {
                normalized.insert(value, at: 1)
            }
        }
        if normalized.count > 1, normalized[1] == "=" {
            normalized.remove(at: 1)
        }
        return normalized
    }
}
