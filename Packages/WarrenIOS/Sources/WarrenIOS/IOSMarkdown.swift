import Foundation
import SwiftUI

/// The subset of CommonMark/GFM that occurs most often in Agent replies.
/// Keeping block structure explicit lets SwiftUI render lists and tables with
/// real layout instead of flattening Foundation presentation intents into one
/// paragraph. Inline emphasis, links, and code spans are still delegated to
/// Foundation's native Markdown parser.
enum IOSMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([IOSMarkdownListItem])
    case orderedList([IOSMarkdownListItem])
    case quote(String)
    case table(IOSMarkdownTable)
    case code(language: String?, value: String)
    case divider
}

struct IOSMarkdownListItem: Equatable {
    let depth: Int
    let marker: String
    let text: String
    let taskState: Bool?
}

enum IOSMarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

struct IOSMarkdownTable: Equatable {
    let headers: [String]
    let rows: [[String]]
    let alignments: [IOSMarkdownTableAlignment]
}

/// A deliberately bounded GFM parser. It is not intended to replace the Web
/// renderer; it covers the stable transcript grammar while failing softly to
/// a normal paragraph for syntax it does not recognize.
enum IOSMarkdownParser {
    static func parse(_ value: String) -> [IOSMarkdownBlock] {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [IOSMarkdownBlock] = []
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
                blocks.append(.quote(quote.value))
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
        let items: [IOSMarkdownListItem]
        let nextIndex: Int
    }

    private struct TableResult {
        let table: IOSMarkdownTable
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
        var items: [IOSMarkdownListItem] = []
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
                items.append(IOSMarkdownListItem(
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
                items.append(IOSMarkdownListItem(
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
            items.append(IOSMarkdownListItem(
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
            table: IOSMarkdownTable(
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

    private static func tableAlignments(_ delimiters: [String]) -> [IOSMarkdownTableAlignment]? {
        var result: [IOSMarkdownTableAlignment] = []
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

/// SwiftUI presentation for the parsed mobile Markdown document.
struct IOSMarkdownView: View {
    private let blocks: [IOSMarkdownBlock]
    private let font: Font

    init(value: String, font: Font = IOSTypography.body) {
        blocks = IOSMarkdownParser.parse(value)
        self.font = font
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.bottom, index == blocks.count - 1
                        ? 0
                        : blockSpacing(after: block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: IOSMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let value):
            IOSMarkdownInlineText(value: value, font: font)
        case .heading(let level, let text):
            IOSMarkdownInlineText(value: text, font: headingFont(level))
                .foregroundStyle(IOSTheme.text)
                .padding(.top, level <= 2 ? 4 : 1)
        case .unorderedList(let items), .orderedList(let items):
            IOSMarkdownListView(items: items, font: font)
        case .quote(let value):
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(IOSTheme.accent.opacity(0.66))
                    .frame(width: 3)
                IOSMarkdownInlineText(value: value, font: font)
                    .foregroundStyle(IOSTheme.secondaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
            }
            .background(IOSTheme.chrome.opacity(0.72), in: RoundedRectangle(
                cornerRadius: IOSTheme.smallRadius,
                style: .continuous
            ))
        case .table(let table):
            IOSMarkdownTableView(table: table, font: font)
        case .code(let language, let value):
            IOSMarkdownCodeBlock(language: language, value: value)
        case .divider:
            Rectangle()
                .fill(IOSTheme.separator)
                .frame(height: 1)
                .padding(.vertical, 3)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(.title3, weight: .semibold)
        case 2: return .system(.headline, weight: .semibold)
        case 3: return .system(.subheadline, weight: .semibold)
        case 4: return .system(.subheadline, weight: .semibold)
        default: return .system(.footnote, weight: .semibold)
        }
    }

    private func blockSpacing(after block: IOSMarkdownBlock) -> CGFloat {
        switch block {
        case .heading: return 8
        case .paragraph: return 9
        case .unorderedList, .orderedList: return 7
        case .quote: return 9
        case .table, .code: return 10
        case .divider: return 8
        }
    }
}

private struct IOSMarkdownInlineText: View {
    let value: String
    let font: Font

    var body: some View {
        let markdown = preservingLineBreaks(value)
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
                .font(font)
                .lineSpacing(3)
                .iosNaturalWrap()
                .frame(maxWidth: .infinity, alignment: .leading)
                .tint(IOSTheme.blue)
        } else {
            Text(value)
                .font(font)
                .lineSpacing(3)
                .iosNaturalWrap()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func preservingLineBreaks(_ value: String) -> String {
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
                // CommonMark treats a single newline as a soft break. Agent
                // transcripts are authored line-by-line, so retain that
                // intentional rhythm as a hard break on the phone.
                result += "  \n"
            }
        }
        return result
    }
}

private struct IOSMarkdownListView: View {
    let items: [IOSMarkdownListItem]
    let font: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    marker(item)
                        .frame(minWidth: item.taskState == nil && item.marker != "•" ? 25 : 18, alignment: .trailing)
                    IOSMarkdownInlineText(value: item.text, font: font)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func marker(_ item: IOSMarkdownListItem) -> some View {
        if let checked = item.taskState {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(checked ? IOSTheme.green : IOSTheme.secondaryText)
                .accessibilityLabel(checked ? "Completed" : "Not completed")
        } else if item.marker == "•" {
            Text(item.marker)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(IOSTheme.secondaryText)
        } else {
            Text(item.marker)
                .font(.system(.footnote, design: .monospaced, weight: .medium))
                .foregroundStyle(IOSTheme.secondaryText)
        }
    }
}

private struct IOSMarkdownTableView: View {
    let table: IOSMarkdownTable
    let font: Font
    private let columnWidth: CGFloat = 136

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(table.headers, header: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, values in
                    row(values, header: false)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IOSTheme.input, in: RoundedRectangle(
            cornerRadius: IOSTheme.smallRadius,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous)
                .stroke(IOSTheme.ring.opacity(0.84), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table")
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                let alignment = table.alignments.indices.contains(index)
                    ? table.alignments[index]
                    : .leading
                IOSMarkdownInlineText(
                    value: values[index],
                    font: header ? font.weight(.semibold) : font
                )
                .foregroundStyle(header ? IOSTheme.text : IOSTheme.secondaryText)
                .multilineTextAlignment(alignment.textAlignment)
                .frame(width: columnWidth, alignment: alignment.frameAlignment)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(header ? IOSTheme.muted.opacity(0.58) : IOSTheme.input)
                .overlay {
                    Rectangle()
                        .stroke(IOSTheme.ring.opacity(0.72), lineWidth: 1)
                }
            }
        }
    }
}

private struct IOSMarkdownCodeBlock: View {
    let language: String?
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(IOSTypography.eyebrow)
                    .foregroundStyle(IOSTheme.tertiaryText)
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value.isEmpty ? " " : value)
                    .font(IOSTypography.codeBlock)
                    .foregroundStyle(IOSTheme.text.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .iosMachineText()
                    .padding(10)
            }
        }
        .background(IOSTheme.input, in: RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: IOSTheme.smallRadius, style: .continuous)
                .stroke(IOSTheme.ring.opacity(0.84), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
