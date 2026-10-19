import Foundation

/// An activity line as the sidebar can afford to draw it.
///
/// The row has one line about 250pt wide and the command it reports was written
/// for a terminal, so the sidebar keeps the verb and the object a person would
/// name and drops the argument syntax in between. A path keeps its last segment,
/// because that is the part someone recognizes; a `--flag value` pair that only
/// configures the run goes away, while one that names the object being worked on
/// becomes the object.
///
/// This is a display rule and nothing else. The command itself is unchanged in
/// the Session's model, so the row's tooltip, the Conversation surface, and the
/// Agent transcript all still have it as it was run.
enum WarrenDesktopActivityText {
    static func shortened(_ line: String) -> String {
        let collapsed = collapsingCompoundCommand(line)
        return withoutVerbedLaunchPrefix(collapsed)
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { String($0) }
            .reduce(into: [String]()) { tokens, token in
                append(token, to: &tokens)
            }
            .joined(separator: " ")
    }

    /// `sudo` and `FOO=1` prefixes say how a command was launched, not what it
    /// does, so the line drops them. Only leading tokens are stripped: an
    /// assignment later in the line is an argument.
    ///
    /// Exposed because a shell command is prefixed with a verb (`Running`)
    /// before it reaches the line, and the verb would otherwise hide the
    /// prefix from this rule.
    static func withoutLaunchPrefix(_ line: String) -> String {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var head = 0
        while head < tokens.count {
            let token = tokens[head]
            if token == "sudo" {
                head += 1
                continue
            }
            if isEnvironmentAssignment(token) {
                head += 1
                continue
            }
            break
        }
        guard head > 0 else { return line }
        return tokens[head...].joined(separator: " ")
    }

    /// The verbs an Agent's activity puts in front of a command it ran.
    private static let commandVerbs: Set<String> = ["Ran", "Running"]

    /// An Agent reports `Ran T=1 go test`, so the launch prefix sits behind
    /// the verb and has to be stripped from there, with the verb kept.
    private static func withoutVerbedLaunchPrefix(_ line: String) -> String {
        guard let space = line.firstIndex(of: " "),
              commandVerbs.contains(String(line[..<space])) else {
            return withoutLaunchPrefix(line)
        }
        let command = withoutLaunchPrefix(String(line[line.index(after: space)...]))
        return command.isEmpty ? line : String(line[...space]) + command
    }

    /// `NAME=value`, where `NAME` is a shell identifier. A path or a flag that
    /// merely contains `=` is not an assignment.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "="), separator != token.startIndex else {
            return false
        }
        let name = token[..<separator]
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
            && !name.allSatisfy(\.isNumber)
            && !name.hasPrefix("-")
    }

    /// A compound command keeps its first command and the shape of what
    /// followed: what a person needs from `uptime; for … done` is that a loop
    /// ran, not what was in it.
    private static func collapsingCompoundCommand(_ line: String) -> String {
        guard let breakIndex = firstCompoundSeparator(in: line) else { return line }
        let head = String(line[..<breakIndex])
        let tail = line[breakIndex...]
        guard let lastWord = tail.split(separator: " ").last else { return head }
        let keyword = tail.split(separator: " ").first.map(String.init) ?? ""
        let lead = ["for", "while", "until", "if"].contains(keyword) ? " \(keyword)" : ""
        return "\(head)\(lead) … \(lastWord)"
    }

    /// The index just past the first `;`, `&`, or `|` in the line.
    private static func firstCompoundSeparator(in line: String) -> String.Index? {
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == ";" {
                return line.index(after: index)
            }
            if character == "&" || character == "|" {
                // `&&` and `||` are the same break; `&` alone backgrounds the
                // command before it, which is also a break.
                let next = line.index(after: index)
                let end = next < line.endIndex && line[next] == character
                    ? line.index(after: next)
                    : next
                return end
            }
            index = line.index(after: index)
        }
        return nil
    }

    /// Appends one token, folding the two it may belong with.
    ///
    /// Option values arrive one token later than their flag, so this carries the
    /// pending flag across calls rather than looking ahead: a value that names a
    /// path becomes the object of the line, and any other value is dropped with
    /// the flag that introduced it.
    private static func append(_ token: String, to tokens: inout [String]) {
        if let pending = tokens.last,
           pending.hasPrefix("--"),
           pending.count > 2,
           !token.hasPrefix("-") {
            // The previous token was a long option and this is its value. A
            // token that starts with a dash is another option, so the pending
            // one takes no value and stays as it is.
            tokens.removeLast()
            if let name = lastPathSegment(token) {
                if tokens.last != "·" { tokens.append("·") }
                tokens.append(name)
            }
            return
        }
        if token.hasPrefix("--"), token.contains("=") {
            // `--flag=value` carries its value in the same token.
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2, let name = lastPathSegment(String(parts[1])) {
                if tokens.last != "·" { tokens.append("·") }
                tokens.append(name)
            }
            return
        }
        if let name = lastPathSegment(token) {
            tokens.append("…/\(name)")
            return
        }
        tokens.append(token)
    }

    /// The last segment of a token that names a path, or nil when the token is
    /// not one.
    ///
    /// A URL is left alone: shortening `https://host/a/b` to `…/b` would throw
    /// away the host, which is the part of a URL that names something.
    private static func lastPathSegment(_ token: String) -> String? {
        guard token.contains("/"), !token.contains("://"), token != "…" else { return nil }
        let segment = token.split(separator: "/").last.map(String.init) ?? ""
        guard !segment.isEmpty else { return nil }
        return segment
    }
}
