import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The subset of CommonMark/GFM that occurs most often in Agent replies.
/// Keeping block structure explicit lets the clients render lists and tables with
/// real layout instead of flattening Foundation presentation intents into one
/// paragraph. Inline emphasis, links, and code spans are still delegated to
/// Foundation's native Markdown parser.
public enum WarrenMarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([WarrenMarkdownListItem])
    case orderedList([WarrenMarkdownListItem])
    case quote(String)
    case alert(WarrenMarkdownAlert)
    case table(WarrenMarkdownTable)
    case code(language: String?, value: String)
    case divider
}

public enum WarrenMarkdownAlertKind: String, Equatable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution

    public var title: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    public var symbol: String {
        switch self {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }

}

public struct WarrenMarkdownAlert: Equatable, Sendable {
    public let kind: WarrenMarkdownAlertKind
    public let title: String
    public let content: String

    public init(kind: WarrenMarkdownAlertKind, title: String? = nil, content: String) {
        self.kind = kind
        let clean = title?.trimmingCharacters(in: .whitespaces)
        self.title = (clean?.isEmpty == false) ? clean! : kind.title
        self.content = content
    }
}

public struct WarrenMarkdownListItem: Equatable, Sendable {
    public let depth: Int
    public let marker: String
    public let text: String
    public let taskState: Bool?
}

public enum WarrenMarkdownTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing


}

public struct WarrenMarkdownTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]
    public let alignments: [WarrenMarkdownTableAlignment]
}

/// A deliberately bounded GFM parser. It is not intended to replace the Web
/// A deliberately bounded GFM parser. It is shared by the Desktop and iOS
/// Conversation surfaces and not intended to replace the Web renderer; it covers the stable transcript grammar while failing softly to
/// a normal paragraph for syntax it does not recognize.
public enum WarrenMarkdown {
    public static func parse(_ value: String) -> [WarrenMarkdownBlock] {
        WarrenMarkdownCache.shared.blocks(for: value)
    }

    public static func uncachedParse(_ value: String) -> [WarrenMarkdownBlock] {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [WarrenMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let opening = fenceInfo(lines[index]) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if let closing = fenceInfo(lines[index]),
                       closing.marker == opening.marker,
                       closing.length >= opening.length,
                       closing.info.isEmpty {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                // An unfinished fence is common while an Agent is streaming;
                // it remains a code block until the closing fence arrives.
                blocks.append(.code(
                    language: opening.info.isEmpty ? nil : opening.info,
                    value: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = headingInfo(lines[index]) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(lines[index]) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if let table = tableInfo(lines: lines, at: index) {
                blocks.append(.table(table.table))
                index = table.nextIndex
                continue
            }

            if let firstItem = listItemInfo(lines[index]) {
                let parsed = listBlock(lines: lines, at: index, first: firstItem)
                if firstItem.ordered {
                    blocks.append(.orderedList(parsed.items))
                } else {
                    blocks.append(.unorderedList(parsed.items))
                }
                index = parsed.nextIndex
                continue
            }

            if isQuoteLine(lines[index]) {
                let quote = quoteBlock(lines: lines, at: index)
                if let alert = parseAlert(from: quote.value) {
                    blocks.append(.alert(alert))
                } else {
                    blocks.append(.quote(quote.value))
                }
                index = quote.nextIndex
                continue
            }

            var paragraphLines = [lines[index]]
            index += 1
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                if isBlockStart(lines: lines, at: index) {
                    break
                }
                paragraphLines.append(line)
                index += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
        }

        return blocks
    }

    private struct FenceInfo {
        let marker: Character
        let length: Int
        let info: String
    }

    private struct HeadingInfo {
        let level: Int
        let text: String
    }

    private struct ListItemInfo {
        let ordered: Bool
        let indent: Int
        let marker: String
        let text: String
        let taskState: Bool?
    }

    private struct ListBlockResult {
        let items: [WarrenMarkdownListItem]
        let nextIndex: Int
    }

    private struct TableResult {
        let table: WarrenMarkdownTable
        let nextIndex: Int
    }

    private static func fenceInfo(_ line: String) -> FenceInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let marker = trimmed.first, marker == "`" || marker == "~" else {
            return nil
        }
        let length = trimmed.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        let info = String(trimmed.dropFirst(length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FenceInfo(marker: marker, length: length, info: info)
    }

    private static func headingInfo(_ line: String) -> HeadingInfo? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let remainder = String(trimmed.dropFirst(level))
        guard remainder.isEmpty || remainder.first?.isWhitespace == true else {
            return nil
        }
        var text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip optional closing ATX markers without touching a literal '#'
        // in the body.
        while text.hasSuffix("#") {
            text.removeLast()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return HeadingInfo(level: level, text: text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard value.count >= 3 else { return false }
        for marker in ["-", "*", "_"] {
            if value.allSatisfy({ String($0) == marker || $0.isWhitespace }) {
                return true
            }
        }
        return false
    }

    private static func listItemInfo(_ line: String) -> (ordered: Bool, item: ListItemInfo)? {
        let characters = Array(line)
        var cursor = 0
        var indent = 0
        while cursor < characters.count {
            if characters[cursor] == " " {
                indent += 1
            } else if characters[cursor] == "\t" {
                indent += 4
            } else {
                break
            }
            cursor += 1
        }
        guard cursor < characters.count else { return nil }

        let remainder = String(characters[cursor...])
        if let first = remainder.first, first == "-" || first == "*" || first == "+" {
            let suffix = String(remainder.dropFirst())
            guard suffix.first?.isWhitespace == true else { return nil }
            let content = suffix.trimmingCharacters(in: .whitespaces)
            return (false, makeListItem(
                ordered: false,
                indent: indent,
                marker: "•",
                content: content
            ))
        }

        var digitCount = 0
        while digitCount < remainder.count,
              remainder[remainder.index(remainder.startIndex, offsetBy: digitCount)].isNumber {
            digitCount += 1
        }
        guard digitCount > 0, digitCount < remainder.count else { return nil }
        let punctuationIndex = remainder.index(remainder.startIndex, offsetBy: digitCount)
        guard remainder[punctuationIndex] == "." || remainder[punctuationIndex] == ")" else {
            return nil
        }
        let suffix = String(remainder[remainder.index(after: punctuationIndex)...])
        guard suffix.first?.isWhitespace == true else { return nil }
        let marker = String(remainder[...punctuationIndex])
        return (true, makeListItem(
            ordered: true,
            indent: indent,
            marker: marker,
            content: suffix.trimmingCharacters(in: .whitespaces)
        ))
    }

    private static func makeListItem(
        ordered: Bool,
        indent: Int,
        marker: String,
        content: String
    ) -> ListItemInfo {
        var text = content
        var taskState: Bool?
        if text.count >= 3,
           text.first == "[",
           let closing = text.firstIndex(of: "]"),
           closing == text.index(text.startIndex, offsetBy: 2) {
            let state = text[text.index(after: text.startIndex)]
            if state == " " || state == "x" || state == "X" {
                taskState = state != " "
                text = String(text[text.index(after: closing)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return ListItemInfo(
            ordered: ordered,
            indent: indent,
            marker: marker,
            text: text,
            taskState: taskState
        )
    }

    private static func listBlock(
        lines: [String],
        at start: Int,
        first: (ordered: Bool, item: ListItemInfo)
    ) -> ListBlockResult {
        let baseIndent = first.item.indent
        var items: [WarrenMarkdownListItem] = []
        var index = start

        while index < lines.count {
            if let parsed = listItemInfo(lines[index]) {
                guard parsed.item.indent >= baseIndent else { break }
                // A new top-level marker type starts a separate list. Nested
                // markers may still switch between ordered and unordered
                // forms inside the current item.
                if parsed.item.indent == baseIndent, parsed.ordered != first.ordered {
                    break
                }
                let relativeIndent = parsed.item.indent - baseIndent
                let depth = relativeIndent == 0 ? 0 : max(1, (relativeIndent + 3) / 4)
                items.append(WarrenMarkdownListItem(
                    depth: depth,
                    marker: parsed.item.marker,
                    text: parsed.item.text,
                    taskState: parsed.item.taskState
                ))
                index += 1
                continue
            }

            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                var lookahead = index + 1
                while lookahead < lines.count,
                      lines[lookahead].trimmingCharacters(in: .whitespaces).isEmpty {
                    lookahead += 1
                }
                if lookahead < lines.count,
                   let next = listItemInfo(lines[lookahead]),
                   next.item.indent >= baseIndent {
                    index = lookahead
                    continue
                }
                break
            }

            let leading = leadingIndent(lines[index])
            guard leading > baseIndent, !items.isEmpty else { break }
            let continuation = lines[index].trimmingCharacters(in: .whitespaces)
            if !continuation.isEmpty {
                let last = items.removeLast()
                items.append(WarrenMarkdownListItem(
                    depth: last.depth,
                    marker: last.marker,
                    text: last.text + "\n" + continuation,
                    taskState: last.taskState
                ))
            }
            index += 1
        }

        // The first item is added in the same path as every subsequent item;
        // this fallback only handles a malformed one-line list defensively.
        if items.isEmpty {
            items.append(WarrenMarkdownListItem(
                depth: 0,
                marker: first.item.marker,
                text: first.item.text,
                taskState: first.item.taskState
            ))
            index = max(index, start + 1)
        }
        return ListBlockResult(items: items, nextIndex: index)
    }

    private static func quoteBlock(lines: [String], at start: Int) -> (value: String, nextIndex: Int) {
        var values: [String] = []
        var index = start
        while index < lines.count {
            guard let value = quoteContent(lines[index]) else { break }
            values.append(value)
            index += 1
        }
        return (values.joined(separator: "\n"), index)
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        quoteContent(line) != nil
    }

    private static func quoteContent(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    private static func parseAlert(from quote: String) -> WarrenMarkdownAlert? {
        var lines = quote.components(separatedBy: "\n")
        guard !lines.isEmpty else { return nil }
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("[!") else { return nil }
        guard let closeBracket = first.firstIndex(of: "]") else { return nil }
        let kindStartIndex = first.index(first.startIndex, offsetBy: 2)
        guard kindStartIndex < closeBracket else { return nil }
        let rawKind = String(first[kindStartIndex..<closeBracket])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard let kind = alertKind(for: rawKind) else { return nil }

        let afterBracket = String(first[first.index(after: closeBracket)...])
            .trimmingCharacters(in: .whitespaces)
        let title = afterBracket.isEmpty ? kind.title : afterBracket

        lines.removeFirst()
        while let leading = lines.first, leading.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let trailing = lines.last, trailing.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        let content = lines.joined(separator: "\n")
        return WarrenMarkdownAlert(kind: kind, title: title, content: content)
    }

    private static func alertKind(for raw: String) -> WarrenMarkdownAlertKind? {
        switch raw {
        case "note", "info": return .note
        case "tip", "hint": return .tip
        case "important": return .important
        case "warning": return .warning
        case "caution", "danger": return .caution
        default: return nil
        }
    }

    private static func tableInfo(lines: [String], at start: Int) -> TableResult? {
        guard start + 1 < lines.count,
              let headers = tableCells(lines[start]),
              let delimiters = tableCells(lines[start + 1]),
              headers.count >= 2,
              delimiters.count >= 2,
              let alignments = tableAlignments(delimiters) else {
            return nil
        }

        let columnCount = max(headers.count, alignments.count)
        var normalizedHeaders = headers
        normalizedHeaders.append(contentsOf: repeatElement("", count: columnCount - headers.count))
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || isBlockStart(lines: lines, at: index) {
                break
            }
            guard let cells = tableCells(line), cells.count >= 1 else { break }
            var row = Array(cells.prefix(columnCount))
            row.append(contentsOf: repeatElement("", count: columnCount - row.count))
            rows.append(row)
            index += 1
        }

        var normalizedAlignments = alignments
        normalizedAlignments.append(contentsOf: repeatElement(.leading, count: columnCount - alignments.count))
        return TableResult(
            table: WarrenMarkdownTable(
                headers: normalizedHeaders,
                rows: rows,
                alignments: normalizedAlignments
            ),
            nextIndex: index
        )
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        let characters = Array(line)
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false

        for character in characters {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                current.append(character)
                escaped = true
                continue
            }
            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }
            if character == "|" && !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if trimmed.hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func tableAlignments(_ delimiters: [String]) -> [WarrenMarkdownTableAlignment]? {
        var result: [WarrenMarkdownTableAlignment] = []
        for delimiter in delimiters {
            var value = delimiter.trimmingCharacters(in: .whitespaces)
            let leading = value.hasPrefix(":")
            let trailing = value.hasSuffix(":")
            if leading { value.removeFirst() }
            if trailing, !value.isEmpty { value.removeLast() }
            guard value.count >= 3, value.allSatisfy({ $0 == "-" }) else { return nil }
            if leading && trailing {
                result.append(.center)
            } else if trailing {
                result.append(.trailing)
            } else {
                result.append(.leading)
            }
        }
        return result
    }

    private static func isBlockStart(lines: [String], at index: Int) -> Bool {
        guard index < lines.count else { return true }
        if fenceInfo(lines[index]) != nil
            || headingInfo(lines[index]) != nil
            || isDivider(lines[index])
            || listItemInfo(lines[index]) != nil
            || isQuoteLine(lines[index]) {
            return true
        }
        return tableInfo(lines: lines, at: index) != nil
    }

    private static func leadingIndent(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(into: 0) { count, character in
            count += character == "\t" ? 4 : 1
        }
    }
}

/// Bounded memoization for parsed Markdown blocks, keyed by exact source text.
public final class WarrenMarkdownCache: @unchecked Sendable {
    public static let shared = WarrenMarkdownCache()

    private final class BlockBox {
        let blocks: [WarrenMarkdownBlock]
        init(_ blocks: [WarrenMarkdownBlock]) { self.blocks = blocks }
    }


    private let blocksCache = NSCache<NSString, BlockBox>()
    private let lineBreaksCache = NSCache<NSString, NSString>()

    private init() {
        blocksCache.countLimit = 512
        blocksCache.totalCostLimit = 8 * 1024 * 1024
        lineBreaksCache.countLimit = 512
        lineBreaksCache.totalCostLimit = 4 * 1024 * 1024

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clear()
        }
        #endif
    }

    public func clear() {
        blocksCache.removeAllObjects()
        lineBreaksCache.removeAllObjects()
    }

    public func preservedLineBreaks(for value: String) -> String {
        guard value.contains("\n") else { return value }
        let key = value as NSString
        if let cached = lineBreaksCache.object(forKey: key) {
            return cached as String
        }
        let preserved = rawPreservingLineBreaks(value)
        lineBreaksCache.setObject(preserved as NSString, forKey: key, cost: value.utf8.count)
        return preserved
    }

    private func rawPreservingLineBreaks(_ value: String) -> String {
        let lines = value.components(separatedBy: "\n")
        guard lines.count > 1 else { return value }
        var result = ""
        for index in lines.indices {
            result += lines[index]
            guard index < lines.index(before: lines.endIndex) else { continue }
            let current = lines[index]
            let next = lines[index + 1]
            if current.isEmpty || next.isEmpty || current.hasSuffix("  ") || current.hasSuffix("\\") {
                result += "\n"
            } else {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                let isSoftWrap = trimmed.count > 50
                    && !trimmed.hasSuffix(".")
                    && !trimmed.hasSuffix("。")
                    && !trimmed.hasSuffix(":")
                    && !trimmed.hasSuffix("：")
                    && !trimmed.hasSuffix("!")
                    && !trimmed.hasSuffix("！")
                    && !trimmed.hasSuffix("?")
                    && !trimmed.hasSuffix("？")
                    && !trimmed.hasSuffix(";")
                    && !trimmed.hasSuffix("；")
                if isSoftWrap {
                    result += " "
                } else {
                    result += "  \n"
                }
            }
        }
        return result
    }

    public func blocks(for value: String) -> [WarrenMarkdownBlock] {
        let key = value as NSString
        if let cached = blocksCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = WarrenMarkdown.uncachedParse(value)
        blocksCache.setObject(BlockBox(parsed), forKey: key, cost: value.utf8.count)
        return parsed
    }
}
