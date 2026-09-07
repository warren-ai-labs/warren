import Foundation

public struct WarrenTerminalLinkTarget: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let column: Int?

    public init(path: String, line: Int? = nil, column: Int? = nil) {
        self.path = path
        self.line = line
        self.column = column
    }
}

public enum WarrenTerminalLinkParser {
    /// Parses a raw clicked terminal link/path into a valid local file target with optional line and column.
    /// Returns `nil` if the target is a web/external URL, if it points to a directory, or if the file does not exist.
    public static func parse(
        _ raw: String,
        workingDirectory: String? = nil,
        workspacePath: String? = nil,
        fileManager: FileManager = .default
    ) -> WarrenTerminalLinkTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Ignore web, mail, and other non-local schemes
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") ||
           lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") ||
           lower.hasPrefix("warren://") || lower.hasPrefix("vscode://") {
            return nil
        }

        // Clean outer punctuation and quotes
        var cleaned = trimmed
        if cleaned.hasSuffix(",") || cleaned.hasSuffix(";") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = cleanWrappingQuotes(cleaned)
        if cleaned.hasSuffix(",") || cleaned.hasSuffix(";") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Clean file:// scheme
        if cleaned.lowercased().hasPrefix("file://") {
            if let fileURL = URL(string: cleaned) {
                cleaned = fileURL.path
            } else {
                cleaned = String(cleaned.dropFirst("file://".count))
                if cleaned.hasPrefix("localhost/") {
                    cleaned = String(cleaned.dropFirst("localhost".count))
                }
                cleaned = cleaned.removingPercentEncoding ?? cleaned
            }
        }

        let candidates = extractLineAndColumnCandidates(from: cleaned)

        for candidate in candidates {
            if let resolved = resolveExistingFile(
                candidate.path,
                workingDirectory: workingDirectory,
                workspacePath: workspacePath,
                fileManager: fileManager
            ) {
                return WarrenTerminalLinkTarget(
                    path: resolved,
                    line: candidate.line,
                    column: candidate.column
                )
            }
        }

        return nil
    }

    private struct RawCandidate {
        let path: String
        let line: Int?
        let column: Int?
    }

    private static func cleanWrappingQuotes(_ str: String) -> String {
        var result = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if (result.hasPrefix("\"") && result.hasSuffix("\"")) ||
           (result.hasPrefix("'") && result.hasSuffix("'")) ||
           (result.hasPrefix("`") && result.hasSuffix("`")) {
            result = String(result.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func extractLineAndColumnCandidates(from input: String) -> [RawCandidate] {
        var results: [RawCandidate] = []

        // Strip trailing punctuation like comma, period, or semicolon if present
        let strippedPunctuation: String
        if input.hasSuffix(",") || input.hasSuffix(";") || input.hasSuffix(".") {
            strippedPunctuation = String(input.dropLast())
        } else {
            strippedPunctuation = input
        }

        let sources = input == strippedPunctuation ? [input] : [input, strippedPunctuation]

        for source in sources {
            let cleanedSource = cleanWrappingQuotes(source)
            // Pattern 1: path:line:col
            // Pattern 2: path:line
            let colonParts = cleanedSource.split(separator: ":", omittingEmptySubsequences: false)
            if colonParts.count >= 3,
               let line = Int(colonParts[colonParts.count - 2]),
               let col = Int(colonParts[colonParts.count - 1]) {
                let path = cleanWrappingQuotes(colonParts.dropLast(2).joined(separator: ":"))
                if !path.isEmpty {
                    results.append(RawCandidate(path: path, line: line, column: col))
                }
            }
            if colonParts.count >= 2,
               let line = Int(colonParts[colonParts.count - 1]) {
                let path = cleanWrappingQuotes(colonParts.dropLast(1).joined(separator: ":"))
                if !path.isEmpty {
                    results.append(RawCandidate(path: path, line: line, column: nil))
                }
            }

            // Pattern 3: path(line, col) or path(line)
            if let openParen = cleanedSource.lastIndex(of: "("),
               cleanedSource.hasSuffix(")") {
                let path = cleanWrappingQuotes(String(cleanedSource[..<openParen]))
                let inside = cleanedSource[cleanedSource.index(after: openParen)..<cleanedSource.index(before: cleanedSource.endIndex)]
                let commaParts = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if commaParts.count == 2,
                   let line = Int(commaParts[0]),
                   let col = Int(commaParts[1]),
                   !path.isEmpty {
                    results.append(RawCandidate(path: path, line: line, column: col))
                } else if commaParts.count == 1,
                          let line = Int(commaParts[0]),
                          !path.isEmpty {
                    results.append(RawCandidate(path: path, line: line, column: nil))
                }
            }

            // Pattern 4: raw path with no line/col
            let rawPath = cleanWrappingQuotes(cleanedSource)
            if !rawPath.isEmpty {
                results.append(RawCandidate(path: rawPath, line: nil, column: nil))
            }
        }

        return results
    }

    private static func resolveExistingFile(
        _ candidatePath: String,
        workingDirectory: String?,
        workspacePath: String?,
        fileManager: FileManager
    ) -> String? {
        let trimmed = candidatePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var potentialPaths: [String] = []

        if trimmed.hasPrefix("/") {
            potentialPaths.append((trimmed as NSString).standardizingPath)
        } else if trimmed.hasPrefix("~") {
            potentialPaths.append(((trimmed as NSString).expandingTildeInPath as NSString).standardizingPath)
        } else {
            // Relative path: try working directory first, then workspacePath
            if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workingDirectory.isEmpty {
                let combined = URL(fileURLWithPath: workingDirectory).appendingPathComponent(trimmed).standardized.path
                potentialPaths.append(combined)
            }
            if let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspacePath.isEmpty {
                let combined = URL(fileURLWithPath: workspacePath).appendingPathComponent(trimmed).standardized.path
                potentialPaths.append(combined)
            }
        }

        for path in potentialPaths {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return path
            }
        }

        return nil
    }
}
