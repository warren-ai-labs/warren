import AppKit
import SwiftUI
import WarrenDesignSystem
import WarrenTransport

// The Inspector's Files tab: the checkout's tracked and untracked files as a
// tree (ignored files stay out, as `git ls-files` leaves them out), a filter,
// and a native editor for quick reads and light edits. Heavy work belongs in
// the person's IDE; this is for looking at what an Agent just touched.

// MARK: - Tree

struct WarrenFileNode: Identifiable, Hashable {
    let id: String
    let name: String
    let isDirectory: Bool
    var children: [WarrenFileNode]

    /// Builds a sorted tree (folders first) from relative paths.
    static func tree(from paths: [String]) -> [WarrenFileNode] {
        final class Box {
            var files: [String: Box] = [:]
            var isFile = false
        }
        let root = Box()
        for path in paths {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                let next = node.files[part] ?? Box()
                if index == parts.count - 1 { next.isFile = true }
                node.files[part] = next
                node = next
            }
        }
        func build(_ box: Box, prefix: String) -> [WarrenFileNode] {
            box.files.map { name, child in
                let id = prefix.isEmpty ? name : "\(prefix)/\(name)"
                let isDirectory = !child.files.isEmpty
                return WarrenFileNode(id: id, name: name, isDirectory: isDirectory, children: isDirectory ? build(child, prefix: id) : [])
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        return build(root, prefix: "")
    }
}

enum WarrenWorkspaceFiles {
    /// Tracked and untracked, not ignored, as Git sees the checkout.
    static func list(at path: String) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            return Array(Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))).sorted()
        }.value
    }
}

struct WarrenInspectorFiles: View {
    @ObservedObject var inspector: WarrenInspectorModel
    @State private var paths: [String] = []
    @State private var tree: [WarrenFileNode] = []
    @State private var loaded = false
    @State private var filter = ""
    @State private var open: Set<String> = []
    @Environment(\.colorScheme) private var colorScheme

    private var changed: [String: String] {
        Dictionary((inspector.panel?.changes ?? []).map { ($0.path, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        // Built once per render: every row reads it, and a directory row scans
        // its keys, so rebuilding it per read made the tree quadratic.
        let changed = changed
        Group {
            if let file = inspector.openFile {
                WarrenFileEditor(root: inspector.path, relativePath: file, status: changed[file]) {
                    inspector.openFile = nil
                }
                .id(file)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: WarrenSpacing.small) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                        TextField("Filter files", text: $filter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                        if !filter.isEmpty {
                            Button { filter = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(tokens.mutedForeground)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, WarrenSpacing.compact)
                    .frame(height: 28)
                    .background(tokens.inputSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tokens.border, lineWidth: WarrenSpacing.hairline))
                    .padding(WarrenSpacing.compact)
                    if !loaded {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if paths.isEmpty {
                        WarrenInspectorEmpty(symbol: "folder", title: "No files", detail: "This checkout has no files Git can see.")
                    } else if !filter.isEmpty {
                        filtered(tokens: tokens)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(flattened(tree, depth: 0), id: \.node.id) { item in
                                    row(item.node, depth: item.depth, changed: changed, tokens: tokens)
                                }
                            }
                            .padding(.bottom, WarrenSpacing.medium)
                        }
                    }
                }
            }
        }
        .task(id: inspector.path) {
            let listed = await WarrenWorkspaceFiles.list(at: inspector.path)
            paths = listed
            tree = WarrenFileNode.tree(from: listed)
            loaded = true
        }
    }

    private struct Item {
        let node: WarrenFileNode
        let depth: Int
    }

    private func flattened(_ nodes: [WarrenFileNode], depth: Int) -> [Item] {
        nodes.flatMap { node -> [Item] in
            var items = [Item(node: node, depth: depth)]
            if node.isDirectory, open.contains(node.id) {
                items += flattened(node.children, depth: depth + 1)
            }
            return items
        }
    }

    private func row(_ node: WarrenFileNode, depth: Int, changed: [String: String], tokens: WarrenColorTokens) -> some View {
        let isOpen = open.contains(node.id)
        let status = node.isDirectory ? nil : changed[node.id]
        let containsChange = node.isDirectory && changed.keys.contains { $0.hasPrefix(node.id + "/") }
        return Button {
            if node.isDirectory {
                if isOpen { open.remove(node.id) } else { open.insert(node.id) }
            } else {
                inspector.openFile = node.id
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tokens.mutedForeground.opacity(node.isDirectory ? 0.7 : 0))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 10)
                WarrenFileIcon(name: node.name, isDirectory: node.isDirectory, open: isOpen)
                Text(node.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(status != nil ? statusTint(status!, tokens: tokens) : tokens.foreground.opacity(0.9))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let status {
                    Text(status == "?" ? "U" : String(status.prefix(1)))
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(statusTint(status, tokens: tokens))
                } else if containsChange {
                    Circle().fill(tokens.warning.opacity(0.8)).frame(width: 5, height: 5)
                }
            }
            .padding(.leading, WarrenSpacing.compact + CGFloat(depth) * 14)
            .padding(.trailing, WarrenSpacing.medium)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(WarrenFileRowStyle())
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.id, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: inspector.path).appendingPathComponent(node.id)])
            }
        }
    }

    private func filtered(tokens: WarrenColorTokens) -> some View {
        let needle = filter.lowercased()
        let matches = paths.filter { $0.lowercased().contains(needle) }
            .sorted { ($0 as NSString).lastPathComponent.count < ($1 as NSString).lastPathComponent.count }
            .prefix(300)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(matches), id: \.self) { path in
                    Button {
                        inspector.openFile = path
                    } label: {
                        HStack(spacing: 6) {
                            WarrenFileIcon(name: (path as NSString).lastPathComponent, isDirectory: false)
                            Text((path as NSString).lastPathComponent)
                                .font(.system(size: 12.5))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            Text((path as NSString).deletingLastPathComponent)
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.mutedForeground)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, WarrenSpacing.medium)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(WarrenFileRowStyle())
                }
            }
        }
    }

    private func statusTint(_ status: String, tokens: WarrenColorTokens) -> Color {
        switch status.prefix(1) {
        case "A", "?", "U": tokens.success
        case "D": tokens.destructive
        default: tokens.warning
        }
    }
}

private struct WarrenFileRowStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        configuration.label
            .background(
                (configuration.isPressed || hovering) ? tokens.fillHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .padding(.horizontal, WarrenSpacing.xs)
            .onHover { hovering = $0 }
    }
}

// MARK: - Editor

/// One file, open for reading and light edits. ⌘S writes it back; a file
/// larger than the editor is meant for opens read-only.
struct WarrenFileEditor: View {
    let root: String
    let relativePath: String
    let status: String?
    let onClose: () -> Void

    @State private var text = ""
    @State private var saved = ""
    @State private var loadError: String?
    @State private var readOnly = false
    @State private var saveError: String?
    @State private var loaded = false
    @Environment(\.colorScheme) private var colorScheme

    static let editableLimit = 1_000_000

    private var url: URL { URL(fileURLWithPath: root).appendingPathComponent(relativePath) }
    private var dirty: Bool { loaded && text != saved }

    var body: some View {
        let tokens = WarrenColorTokens.resolved(for: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: WarrenSpacing.small) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to files")
                WarrenFileIcon(name: (relativePath as NSString).lastPathComponent, isDirectory: false)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text((relativePath as NSString).lastPathComponent)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                        if dirty {
                            Circle().fill(tokens.foreground.opacity(0.7)).frame(width: 6, height: 6).help("Unsaved changes")
                        }
                        if readOnly {
                            Text("Read-only").font(.system(size: 10.5)).foregroundStyle(tokens.mutedForeground)
                        }
                    }
                    let directory = (relativePath as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(directory)
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                Button("Revert") { text = saved }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(dirty ? tokens.mutedForeground : .clear)
                    .disabled(!dirty)
                Button {
                    save()
                } label: {
                    Text("Save")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(dirty ? tokens.background : tokens.mutedForeground)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(dirty ? tokens.foreground : tokens.tertiaryWash, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!dirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save (⌘S)")
            }
            .padding(.horizontal, WarrenSpacing.compact)
            .frame(height: 44)
            if let saveError {
                Text(saveError)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.destructive)
                    .padding(.horizontal, WarrenSpacing.medium)
                    .padding(.bottom, WarrenSpacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Rectangle().fill(tokens.border).frame(height: WarrenSpacing.hairline)
            if let loadError {
                WarrenInspectorEmpty(symbol: "doc.questionmark", title: "Can't open this file", detail: loadError)
            } else if loaded {
                WarrenCodeTextView(
                    text: $text,
                    language: WarrenCodeHighlighter.language(for: relativePath),
                    editable: !readOnly,
                    dark: colorScheme == .dark
                )
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { load() }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: url)
            if data.prefix(8000).contains(0) {
                loadError = "It looks like a binary file."
                return
            }
            guard let value = String(data: data, encoding: .utf8) else {
                loadError = "It is not UTF-8 text."
                return
            }
            readOnly = data.count > Self.editableLimit
            text = value
            saved = value
            loaded = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() {
        guard dirty, !readOnly else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            saved = text
            saveError = nil
        } catch {
            saveError = "Not saved: \(error.localizedDescription)"
        }
    }
}

// MARK: - Code text view

struct WarrenCodeTextView: NSViewRepresentable {
    @Binding var text: String
    let language: WarrenCodeHighlighter.Language
    let editable: Bool
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = WarrenCodeHighlighter.font
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // No wrapping: code keeps its columns and scrolls sideways.
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.18
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: WarrenCodeHighlighter.font, .paragraphStyle: paragraph]
        textView.string = text
        textView.isEditable = editable
        let ruler = WarrenLineNumberRuler(textView: textView)
        ruler.dark = dark
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.highlight(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = editable
        if let ruler = scrollView.verticalRulerView as? WarrenLineNumberRuler, ruler.dark != dark {
            ruler.dark = dark
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView)
        }
        if context.coordinator.dark != dark {
            context.coordinator.highlight(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WarrenCodeTextView
        var dark: Bool
        private var pending: DispatchWorkItem?

        init(_ parent: WarrenCodeTextView) {
            self.parent = parent
            self.dark = parent.dark
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlight(textView)
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func highlight(_ textView: NSTextView) {
            dark = parent.dark
            guard let storage = textView.textStorage else { return }
            let selection = textView.selectedRanges
            WarrenCodeHighlighter.apply(to: storage, language: parent.language, dark: parent.dark)
            textView.selectedRanges = selection
        }
    }
}

/// Line numbers in the gutter, drawn for the visible lines only.
final class WarrenLineNumberRuler: NSRulerView {
    private weak var codeView: NSTextView?
    /// Where each line starts, rebuilt only after an edit so a scroll does not
    /// recount the file from the top on every frame.
    private var lineStarts: [Int]?
    var dark = false {
        didSet { needsDisplay = true }
    }

    init(textView: NSTextView) {
        codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textChanged),
            name: NSText.didChangeNotification,
            object: textView
        )
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func refresh() { needsDisplay = true }

    @objc private func textChanged() {
        lineStarts = nil
        needsDisplay = true
    }

    /// Numbers on the editor's own ground: the default ruler paints a light
    /// band with a rule that reads as a separate control. The ground has to be
    /// opaque, because the clip view runs under the ruler and code scrolled
    /// sideways passes beneath it.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(WarrenColorTokens.resolved(for: dark ? .dark : .light).background).setFill()
        // The ruler does not clip, so a dirty rect can reach past it.
        bounds.intersection(dirtyRect).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    private func starts(of string: NSString) -> [Int] {
        if let lineStarts { return lineStarts }
        var starts = [0]
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            let next = NSMaxRange(enclosing)
            if next < string.length { starts.append(next) }
        }
        lineStarts = starts
        return starts
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let string = textView.string as NSString
        let visible = textView.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // The 1-based number of the line holding the first visible character.
        let starts = starts(of: string)
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= characters.location { low = mid + 1 } else { high = mid }
        }
        var line = max(1, low)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.55),
        ]
        let inset = textView.textContainerInset.height
        let relative = convert(NSPoint.zero, from: textView)
        var index = characters.location
        while index < NSMaxRange(characters) || (index == string.length && index == characters.location) {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: min(lineRange.location, max(0, string.length - 1)))
            var fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if string.length == 0 { fragment = NSRect(x: 0, y: 0, width: 0, height: 16) }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + inset + relative.y + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
            line += 1
            let next = NSMaxRange(lineRange)
            if next <= index || next >= string.length { break }
            index = next
        }
    }
}

// MARK: - Highlighting

/// Keyword, string, comment, and number colouring by regular expression: not
/// a parser, but enough to read a diff's surroundings at a glance.
@MainActor
enum WarrenCodeHighlighter {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    enum Language: Sendable {
        case go, swift, rust, typescript, python, shell, json, yaml, markdown, css, html, c, plain
    }

    nonisolated static func language(for path: String) -> Language {
        switch (path as NSString).pathExtension.lowercased() {
        case "go": .go
        case "swift": .swift
        case "rs": .rust
        case "ts", "tsx", "js", "jsx", "mjs", "cjs": .typescript
        case "py": .python
        case "sh", "bash", "zsh", "fish": .shell
        case "json": .json
        case "yml", "yaml", "toml": .yaml
        case "md", "markdown": .markdown
        case "css", "scss": .css
        case "html", "xml", "svg": .html
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "cs": .c
        default: .plain
        }
    }

    private static let keywords: [Language: [String]] = [
        .go: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var", "nil", "true", "false", "error", "string", "int", "bool", "byte"],
        .swift: ["actor", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "protocol", "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while", "some", "any", "final", "internal", "fileprivate", "override", "mutating"],
        .rust: ["as", "async", "await", "break", "const", "continue", "crate", "else", "enum", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "trait", "true", "type", "use", "where", "while"],
        .typescript: ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "else", "export", "extends", "false", "for", "from", "function", "if", "import", "in", "interface", "let", "new", "null", "of", "return", "switch", "this", "throw", "true", "try", "type", "undefined", "var", "while", "yield"],
        .python: ["and", "as", "async", "await", "break", "class", "continue", "def", "elif", "else", "except", "False", "finally", "for", "from", "if", "import", "in", "is", "lambda", "None", "not", "or", "pass", "raise", "return", "self", "True", "try", "while", "with", "yield"],
        .shell: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "local", "export", "set", "echo"],
        .c: ["auto", "break", "case", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extern", "false", "float", "for", "if", "int", "long", "new", "null", "nullptr", "private", "public", "return", "short", "static", "struct", "switch", "this", "true", "typedef", "void", "while"],
    ]

    private static var cache: [String: NSRegularExpression] = [:]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)"
        if let hit = cache[key] { return hit }
        let made = try? NSRegularExpression(pattern: pattern, options: options)
        cache[key] = made
        return made
    }

    @MainActor
    static func apply(to storage: NSTextStorage, language: Language, dark: Bool) {
        let text = storage.string
        let whole = NSRange(location: 0, length: (text as NSString).length)
        let base: NSColor = dark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.16, alpha: 1)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.18
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: base, .paragraphStyle: paragraph], range: whole)
        // Past a size where colouring would stall typing, the text stays plain.
        guard whole.length < 400_000, language != .plain else {
            storage.endEditing()
            return
        }
        let palette = dark
            ? (keyword: NSColor(red: 0.85, green: 0.55, blue: 0.43, alpha: 1), string: NSColor(red: 0.62, green: 0.78, blue: 0.52, alpha: 1),
               comment: NSColor(white: 0.52, alpha: 1), number: NSColor(red: 0.82, green: 0.68, blue: 0.45, alpha: 1),
               type: NSColor(red: 0.55, green: 0.72, blue: 0.88, alpha: 1))
            : (keyword: NSColor(red: 0.66, green: 0.25, blue: 0.13, alpha: 1), string: NSColor(red: 0.20, green: 0.48, blue: 0.20, alpha: 1),
               comment: NSColor(white: 0.52, alpha: 1), number: NSColor(red: 0.58, green: 0.40, blue: 0.08, alpha: 1),
               type: NSColor(red: 0.16, green: 0.38, blue: 0.62, alpha: 1))
        func paint(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            regex(pattern, options)?.enumerateMatches(in: text, range: whole) { match, _, _ in
                if let range = match?.range { storage.addAttribute(.foregroundColor, value: color, range: range) }
            }
        }
        switch language {
        case .json:
            paint(#"-?\b\d+(\.\d+)?([eE][+-]?\d+)?\b|\btrue\b|\bfalse\b|\bnull\b"#, palette.number)
            paint(#""(\\.|[^"\\])*""#, palette.string)
            paint(#""(\\.|[^"\\])*"(?=\s*:)"#, palette.type)
        case .yaml:
            paint(#"^\s*[\w.-]+(?=\s*[:=])"#, palette.type, options: .anchorsMatchLines)
            paint(#""(\\.|[^"\\])*"|'[^']*'"#, palette.string)
            paint(#"#.*$"#, palette.comment, options: .anchorsMatchLines)
        case .markdown:
            paint(#"^#{1,6} .*$"#, palette.keyword, options: .anchorsMatchLines)
            paint(#"`[^`\n]+`"#, palette.string)
            paint(#"^```.*$"#, palette.comment, options: .anchorsMatchLines)
        case .html:
            paint(#"</?[\w-]+|/?>"#, palette.keyword)
            paint(#""[^"]*"|'[^']*'"#, palette.string)
            paint(#"<!--[\s\S]*?-->"#, palette.comment)
        case .css:
            paint(#"[\w-]+(?=\s*:)"#, palette.type)
            paint(#"#[0-9a-fA-F]{3,8}\b|\b\d+(\.\d+)?(px|em|rem|%)?\b"#, palette.number)
            paint(#""[^"]*"|'[^']*'"#, palette.string)
            paint(#"/\*[\s\S]*?\*/"#, palette.comment)
        default:
            if let words = keywords[language], !words.isEmpty {
                paint("\\b(" + words.joined(separator: "|") + ")\\b", palette.keyword)
            }
            paint(#"\b[A-Z][A-Za-z0-9_]*\b"#, palette.type)
            paint(#"\b\d+(\.\d+)?\b"#, palette.number)
            paint(#""(\\.|[^"\\\n])*"|'(\\.|[^'\\\n])*'|`[^`]*`"#, palette.string)
            switch language {
            case .python, .shell:
                paint(#"#.*$"#, palette.comment, options: .anchorsMatchLines)
            default:
                paint(#"//.*$"#, palette.comment, options: .anchorsMatchLines)
                paint(#"/\*[\s\S]*?\*/"#, palette.comment)
            }
        }
        storage.endEditing()
    }
}
