import Foundation

/// A command line reduced to the words a person would use to name it.
///
/// `/opt/homebrew/bin/tail -f /var/log/relay.log` reads as `tail relay.log`,
/// `git push -u origin feat/x` as `git push`. The summary is a display rule
/// only: the command itself stays untouched in the Session's model, so the
/// hover card and the copy action still have it as it was run.
public enum CommandSummary {
    /// Tools whose first word after the program is a subcommand. They keep the
    /// program and one subcommand; `run` and `exec` keep one word more.
    public static let subcommandTools: Set<String> = [
        "git", "npm", "pnpm", "yarn", "bun", "swift", "cargo", "docker",
        "kubectl", "go", "make", "brew", "gh", "mise", "uv", "pip", "deno",
    ]

    /// Subcommands that name the next word as their object.
    static let runSubcommands: Set<String> = ["run", "exec", "x"]

    public static func summarize(
        _ commandLine: String,
        subcommandTools: Set<String> = subcommandTools
    ) -> String {
        let (head, isCompound) = firstCommand(commandLine)
        var tokens = head.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = tokens.first, first == "sudo" || isEnvironmentAssignment(first) {
            tokens.removeFirst()
        }
        guard let program = tokens.first else { return "" }
        let name = lastPathSegment(program) ?? program
        // Everything after `--` belongs to the program the command launches,
        // not to the command a person would name.
        let rest = tokens.dropFirst().prefix { $0 != "--" }
        let words = positionals(Array(rest))
        var parts = [name]
        if subcommandTools.contains(name.lowercased()), let subcommand = words.first {
            parts.append(subcommand)
            if runSubcommands.contains(subcommand), words.count > 1 {
                parts.append(display(words[1]))
            }
        } else if let first = words.first {
            parts.append(display(first))
        }
        let summary = parts.joined(separator: " ")
        return isCompound ? "\(summary) …" : summary
    }

    /// The tokens that are not options or option values.
    ///
    /// Option values arrive one token after their flag, so a long option that
    /// is not followed by another option takes the next token with it. Short
    /// flags are assumed to be switches: `tail -f file` keeps `file`.
    private static func positionals(_ tokens: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--") {
                let takesValue = !token.contains("=")
                    && index + 1 < tokens.count
                    && !tokens[index + 1].hasPrefix("-")
                    && !looksLikePath(tokens[index + 1])
                index += takesValue ? 2 : 1
                continue
            }
            if token.hasPrefix("-"), token.count > 1 {
                index += 1
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }

    private static func display(_ token: String) -> String {
        lastPathSegment(token) ?? token
    }

    private static func looksLikePath(_ token: String) -> Bool {
        token.contains("/") && !token.contains("://")
    }

    /// The command before the first `;`, `&&`, `||`, `|`, or `&`, and whether
    /// anything followed it.
    private static func firstCommand(_ line: String) -> (String, Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = trimmed.firstIndex(where: { $0 == ";" || $0 == "&" || $0 == "|" }) else {
            return (trimmed, false)
        }
        let head = String(trimmed[..<index]).trimmingCharacters(in: .whitespaces)
        let tail = trimmed[index...].trimmingCharacters(in: CharacterSet(charactersIn: ";&| "))
        return (head, !tail.isEmpty)
    }

    /// `NAME=value`, where `NAME` is a shell identifier.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return false
        }
        let name = token[..<separator]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
            && !name.allSatisfy(\.isNumber)
    }

    /// The last segment of a token that names a path. A URL is left alone,
    /// because its host is the part that names something.
    private static func lastPathSegment(_ token: String) -> String? {
        guard looksLikePath(token) else { return nil }
        let segment = token.split(separator: "/").last.map(String.init) ?? ""
        return segment.isEmpty ? nil : segment
    }
}
