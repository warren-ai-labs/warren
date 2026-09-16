import Foundation

/// Case- and diacritic-insensitive normalization shared by every Warren search
/// surface.
///
/// Scoring and highlighting must agree on one rule. A client that folds
/// diacritics while ranking but not while highlighting emboldens characters the
/// matcher never looked at, so both read the same normalized bytes here.
public enum WarrenSearchNormalization {
    /// The trimmed display text, its normalized lowercase UTF8 bytes, and
    /// whether the two align one-to-one. Alignment lets a caller map a match
    /// range straight back onto the text it displays.
    ///
    /// Text and bytes travel together because a caller needs both and trimming
    /// twice is pure waste at index-build scale.
    public struct Normalized: Hashable, Sendable {
        public let text: String
        public let bytes: [UInt8]
        public let isByteAligned: Bool

        public init(text: String, bytes: [UInt8], isByteAligned: Bool) {
            self.text = text
            self.bytes = bytes
            self.isByteAligned = isByteAligned
        }
    }

    /// The display form every search field and result agrees on.
    ///
    /// Almost every indexed value is already trimmed, so the common case
    /// returns the original string without allocating: `trimmingCharacters` runs
    /// a `CharacterSet` membership test per scalar and builds a new string even
    /// when it removes nothing.
    public static func text(_ value: String) -> String {
        let utf8 = value.utf8
        guard let first = utf8.first, let last = utf8.last else { return value }
        if first < 0x80, last < 0x80, !isASCIIWhitespace(first), !isASCIIWhitespace(last) {
            return value
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @inline(__always)
    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// Folds a value for matching.
    ///
    /// Session titles, branches, commands, and paths are overwhelmingly ASCII,
    /// so the ASCII path avoids `folding(options:locale:)` entirely: that call
    /// allocates and walks grapheme clusters, and it ran once per field per
    /// index build.
    public static func normalize(_ value: String) -> Normalized {
        let trimmed = text(value)
        guard !trimmed.isEmpty else {
            return Normalized(text: trimmed, bytes: [], isByteAligned: true)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.utf8.count)
        var isASCII = true
        for byte in trimmed.utf8 {
            guard byte < 0x80 else {
                isASCII = false
                break
            }
            bytes.append(byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte)
        }
        if isASCII { return Normalized(text: trimmed, bytes: bytes, isByteAligned: true) }
        let folded = trimmed.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return Normalized(
            text: trimmed,
            bytes: Array(folded.utf8),
            isByteAligned: folded.utf8.count == trimmed.utf8.count
        )
    }

    /// A 64-bit presence set over `byte & 63`.
    ///
    /// Every match tier requires each of a token's bytes to appear somewhere in
    /// the candidate, so a token whose mask is not covered by an entry's mask
    /// can be rejected before any byte comparison runs. This is the prefilter
    /// that keeps a rare token from touching the whole index.
    @inline(__always)
    public static func mask<Bytes: Sequence>(_ bytes: Bytes) -> UInt64
    where Bytes.Element == UInt8 {
        var mask: UInt64 = 0
        for byte in bytes { mask |= 1 << UInt64(byte & 63) }
        return mask
    }

    @inline(__always)
    static func isWordByte(_ byte: UInt8) -> Bool {
        if byte >= 0x80 { return true }
        if byte >= 0x61 && byte <= 0x7A { return true }
        return byte >= 0x30 && byte <= 0x39
    }
}

/// The resource classes every Warren client can navigate to.
///
/// A client only indexes the scopes it actually renders — searching for
/// something the surface cannot show is a dead end — but the ordering and the
/// query keywords are shared so muscle memory carries between Desktop, iOS, and
/// the web client.
public enum WarrenSearchScope: String, Hashable, Sendable, CaseIterable {
    case task
    case session
    case workspace
    case project
    case terminalGroup
    case tab

    /// Grouping order for rendered results. Tasks and Sessions lead because
    /// they are where work is actually resumed.
    public var sortPriority: Int {
        switch self {
        case .task: return 0
        case .session: return 1
        case .workspace: return 2
        case .project: return 3
        case .terminalGroup: return 4
        case .tab: return 5
        }
    }

    public var label: String {
        switch self {
        case .task: return "Task"
        case .session: return "Session"
        case .workspace: return "Workspace"
        case .project: return "Project"
        case .terminalGroup: return "Terminal Group"
        case .tab: return "Tab"
        }
    }

    public var pluralLabel: String {
        switch self {
        case .task: return "Tasks"
        case .session: return "Sessions"
        case .workspace: return "Workspaces"
        case .project: return "Projects"
        case .terminalGroup: return "Terminal Groups"
        case .tab: return "Tabs"
        }
    }

    /// Query prefixes that narrow the search to this scope, e.g. `w:review`.
    public var queryKeywords: [String] {
        switch self {
        case .task: return ["t", "task"]
        case .session: return ["s", "session"]
        case .workspace: return ["w", "workspace", "branch"]
        case .project: return ["p", "project"]
        case .terminalGroup: return ["g", "group"]
        case .tab: return ["tab"]
        }
    }

    static func scope(forKeyword keyword: String) -> WarrenSearchScope? {
        allCases.first { $0.queryKeywords.contains(keyword) }
    }
}

/// Where a matched value came from, which decides how much the match is worth
/// and how the row explains itself.
public enum WarrenSearchFieldRole: Int, Hashable, Sendable, CaseIterable {
    /// The row's own primary label.
    case title = 500
    /// Another name for the same resource: a branch, a custom title, a running
    /// command, a directory basename.
    case alias = 350
    /// An ancestor's name — matching here means the row is *inside* something
    /// the user named, not that the row is what they named.
    case context = 180
    /// The full filesystem path.
    case path = 80
    /// The scope label, so "session" narrows without special syntax.
    case kind = 20

    var weight: Int { rawValue }

    /// Whether a match on this role is worth showing as the row's explanation.
    /// A title match needs no explanation; the title is already on screen.
    public var explainsMatch: Bool {
        switch self {
        case .title: return false
        case .alias, .context, .path, .kind: return true
        }
    }
}

/// Why a row matched: the field that produced the best match and the byte
/// ranges inside it that the query covered.
///
/// Ranges are UTF8 byte offsets into `text`. They are empty when normalization
/// could not preserve alignment, in which case a caller should highlight by
/// searching `text` directly rather than trusting offsets.
public struct WarrenSearchEvidence: Hashable, Sendable {
    public let role: WarrenSearchFieldRole
    public let text: String
    public let ranges: [Range<Int>]

    public init(role: WarrenSearchFieldRole, text: String, ranges: [Range<Int>]) {
        self.role = role
        self.text = text
        self.ranges = ranges
    }
}

/// A parsed query: free text plus the scope and status narrowing the user typed.
///
/// The grammar is deliberately tiny and shared by every client: `w:review`
/// restricts to workspaces, `@blocked` restricts to a status, and everything
/// else is matched as text. Unknown prefixes stay literal text so a user
/// searching for `http://host` is not silently filtered to nothing.
public struct WarrenSearchQuery: Hashable, Sendable {
    /// Normalized search tokens, in the order typed.
    public let tokens: [String]
    /// The whole normalized free-text query, used for the contiguous-phrase
    /// bonus that separates an intentional phrase from scattered tokens.
    public let phrase: String
    public let scopes: Set<WarrenSearchScope>
    /// Normalized status labels, e.g. `working`. Compared by the caller, which
    /// owns what a status is called.
    public let statuses: Set<String>

    public var isEmpty: Bool { tokens.isEmpty && scopes.isEmpty && statuses.isEmpty }
    /// True when narrowing was typed but no text was: `@blocked` alone should
    /// list every blocked resource rather than fall back to suggestions.
    public var isFilterOnly: Bool { tokens.isEmpty && !(scopes.isEmpty && statuses.isEmpty) }

    public init(_ raw: String) {
        var tokens: [String] = []
        var scopes: Set<WarrenSearchScope> = []
        var statuses: Set<String> = []
        var phraseParts: [String] = []
        let normalized = WarrenSearchNormalization.normalize(raw)
        let flattened = String(decoding: normalized.bytes, as: UTF8.self)
        for rawToken in flattened.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            if token.hasPrefix("@"), token.count > 1 {
                statuses.insert(String(token.dropFirst()))
                continue
            }
            if let separator = token.firstIndex(of: ":"),
               separator != token.startIndex,
               let scope = WarrenSearchScope.scope(forKeyword: String(token[..<separator])) {
                scopes.insert(scope)
                let remainder = String(token[token.index(after: separator)...])
                if !remainder.isEmpty {
                    tokens.append(remainder)
                    phraseParts.append(remainder)
                }
                continue
            }
            tokens.append(token)
            phraseParts.append(token)
        }
        self.tokens = tokens
        self.phrase = phraseParts.joined(separator: " ")
        self.scopes = scopes
        self.statuses = statuses
    }
}

/// One searchable resource, described in plain strings by whichever client owns
/// it. The index owns all normalization so three clients cannot drift apart on
/// what counts as a word or how duplicates collapse.
public struct WarrenSearchDescriptor<Key: Hashable & Sendable>: Sendable {
    public let key: Key
    public let scope: WarrenSearchScope
    /// The row's primary label.
    public let title: String
    /// The row's ancestry, already formatted for display.
    public let subtitle: String
    public let path: String?
    public let aliases: [String]
    public let context: [String]
    /// Category names such as an Agent provider, matched at the lowest weight.
    ///
    /// A kind describes what a resource *is*, not what it is called: every
    /// unnamed shell answers to "shell", so a kind match must never outrank a
    /// resource the user actually named.
    public let kinds: [String]

    public init(
        key: Key,
        scope: WarrenSearchScope,
        title: String,
        subtitle: String = "",
        path: String? = nil,
        aliases: [String] = [],
        context: [String] = [],
        kinds: [String] = []
    ) {
        self.key = key
        self.scope = scope
        self.title = title
        self.subtitle = subtitle
        self.path = path
        self.aliases = aliases
        self.context = context
        self.kinds = kinds
    }
}

public struct WarrenSearchResult<Key: Hashable & Sendable>: Hashable, Sendable {
    public let key: Key
    public let scope: WarrenSearchScope
    public let title: String
    /// Which UTF8 byte ranges of `title` the query covered.
    ///
    /// Computed here because the index has already folded the title, so a view
    /// can highlight without normalizing a string per row per frame — that work
    /// lands directly on keystroke latency.
    public let titleRanges: [Range<Int>]
    public let subtitle: String
    /// Absent when the query was empty, or when the match landed on the title
    /// and therefore needs no explanation.
    public let evidence: WarrenSearchEvidence?
    public let score: Int
    /// Index-build order, the final tiebreak that keeps ranking deterministic.
    public let ordinal: Int
}

/// A pre-normalized, flat search index.
///
/// All field bytes live in one contiguous buffer and every field is a slice into
/// it. The alternative — a `[UInt8]` per field — allocates once per field, and a
/// Host with a few hundred workspaces has tens of thousands of fields, so the
/// flat layout removes both the allocation traffic and the pointer chasing from
/// the matching loop.
///
/// The index holds no mutable state: agent activity and pin state arrive as
/// closures at query time. A Host that streams status deltas while the palette
/// is open therefore never rebuilds the index, which was the dominant cost.
public struct WarrenSearchIndex<Key: Hashable & Sendable>: Sendable {
    private struct FieldRecord: Sendable {
        let start: Int
        let end: Int
        let wordStart: Int
        let wordEnd: Int
        let mask: UInt64
        let role: WarrenSearchFieldRole
        let textIndex: Int
        let isByteAligned: Bool
    }

    private struct EntryRecord: Sendable {
        let key: Key
        let scope: WarrenSearchScope
        let title: String
        let subtitle: String
        let fieldStart: Int
        let fieldEnd: Int
        let mask: UInt64
        let ordinal: Int
    }

    private let storage: [UInt8]
    private let wordStarts: [Int]
    private let fieldTexts: [String]
    private let fields: [FieldRecord]
    private let entries: [EntryRecord]

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public init(_ descriptors: [WarrenSearchDescriptor<Key>]) {
        var storage: [UInt8] = []
        var wordStarts: [Int] = []
        var fieldTexts: [String] = []
        var fields: [FieldRecord] = []
        var entries: [EntryRecord] = []
        storage.reserveCapacity(descriptors.count * 192)
        fields.reserveCapacity(descriptors.count * 8)
        fieldTexts.reserveCapacity(descriptors.count * 8)
        entries.reserveCapacity(descriptors.count)

        for descriptor in descriptors {
            let title = WarrenSearchNormalization.text(descriptor.title)
            guard !title.isEmpty else { continue }
            let fieldStart = fields.count
            var entryMask: UInt64 = 0

            func append(_ value: String, role: WarrenSearchFieldRole) {
                let normalized = WarrenSearchNormalization.normalize(value)
                guard !normalized.bytes.isEmpty else { return }
                let start = storage.count
                storage.append(contentsOf: normalized.bytes)
                let end = storage.count
                // Duplicate facets are common: a workspace whose name equals
                // its branch, a session whose title equals its command. Keeping
                // both would double the match work and double-count the score.
                //
                // An entry has at most a handful of fields, so comparing against
                // its own is cheaper than hashing every field into a set — and
                // nearly all comparisons stop at the length check.
                guard !Self.contains(
                    storage,
                    range: start..<end,
                    in: fields,
                    from: fieldStart
                ) else {
                    storage.removeLast(end - start)
                    return
                }
                let wordBegin = wordStarts.count
                var previousWasWord = false
                for offset in start..<end {
                    let isWord = WarrenSearchNormalization.isWordByte(storage[offset])
                    if isWord && !previousWasWord { wordStarts.append(offset) }
                    previousWasWord = isWord
                }
                let mask = WarrenSearchNormalization.mask(storage[start..<end])
                entryMask |= mask
                fieldTexts.append(normalized.text)
                fields.append(FieldRecord(
                    start: start,
                    end: end,
                    wordStart: wordBegin,
                    wordEnd: wordStarts.count,
                    mask: mask,
                    role: role,
                    textIndex: fieldTexts.count - 1,
                    isByteAligned: normalized.isByteAligned
                ))
            }

            append(title, role: .title)
            for alias in descriptor.aliases { append(alias, role: .alias) }
            for context in descriptor.context { append(context, role: .context) }
            if let path = descriptor.path { append(path, role: .path) }
            for kind in descriptor.kinds { append(kind, role: .kind) }
            append(descriptor.scope.label, role: .kind)

            entries.append(EntryRecord(
                key: descriptor.key,
                scope: descriptor.scope,
                title: title,
                subtitle: WarrenSearchNormalization.text(descriptor.subtitle),
                fieldStart: fieldStart,
                fieldEnd: fields.count,
                mask: entryMask,
                ordinal: entries.count
            ))
        }

        self.storage = storage
        self.wordStarts = wordStarts
        self.fieldTexts = fieldTexts
        self.fields = fields
        self.entries = entries
    }

    private static func contains(
        _ storage: [UInt8],
        range: Range<Int>,
        in fields: [FieldRecord],
        from fieldStart: Int
    ) -> Bool {
        let length = range.count
        var index = fieldStart
        while index < fields.count {
            let other = fields[index]
            index += 1
            guard other.end - other.start == length else { continue }
            var offset = 0
            while offset < length, storage[other.start + offset] == storage[range.lowerBound + offset] {
                offset += 1
            }
            if offset == length { return true }
        }
        return false
    }
}

// MARK: - Matching

/// Tier bonuses added to a field's role weight. An exact hit on a low-value
/// field must still lose to a prefix hit on the title, which is why the tiers
/// are spaced below the gap between adjacent roles.
private enum WarrenSearchTier {
    static let exact = 400
    static let prefix = 300
    static let wordPrefix = 220
    static let substring = 100
    static let subsequence = 40

    /// The shortest token allowed to match as a subsequence. Below three
    /// characters nearly everything matches something, which buries real hits.
    static let minimumSubsequenceLength = 3
}

extension WarrenSearchIndex {
    @inline(__always)
    private static func equal(
        _ haystack: UnsafePointer<UInt8>,
        _ offset: Int,
        _ token: UnsafePointer<UInt8>,
        _ count: Int
    ) -> Bool {
        var index = 0
        while index < count {
            if haystack[offset + index] != token[index] { return false }
            index += 1
        }
        return true
    }

    /// Scores one token against one field, returning the best tier it reaches.
    ///
    /// Tiers are tested in descending value and the first hit wins, so a title
    /// prefix never pays for a substring scan it cannot lose to.
    @inline(__always)
    private static func hit(
        token: UnsafePointer<UInt8>,
        tokenCount: Int,
        tokenMask: UInt64,
        haystack: UnsafePointer<UInt8>,
        words: UnsafePointer<Int>,
        field: FieldRecord
    ) -> Int? {
        guard field.mask & tokenMask == tokenMask else { return nil }
        let length = field.end - field.start
        guard tokenCount <= length else { return nil }
        let weight = field.role.weight

        if equal(haystack, field.start, token, tokenCount) {
            return weight + (tokenCount == length ? WarrenSearchTier.exact : WarrenSearchTier.prefix)
        }
        var wordIndex = field.wordStart
        while wordIndex < field.wordEnd {
            let offset = words[wordIndex]
            wordIndex += 1
            guard offset != field.start, offset + tokenCount <= field.end else { continue }
            if equal(haystack, offset, token, tokenCount) {
                return weight + WarrenSearchTier.wordPrefix
            }
        }
        let last = field.end - tokenCount
        var offset = field.start
        while offset <= last {
            if haystack[offset] == token[0], equal(haystack, offset, token, tokenCount) {
                return weight + WarrenSearchTier.substring
            }
            offset += 1
        }
        return subsequenceScore(
            token: token,
            tokenCount: tokenCount,
            haystack: haystack,
            field: field,
            weight: weight
        )
    }

    /// Matches an abbreviation like `wdc` against `warren-desktop-command`.
    ///
    /// Every matched character must either continue the previous one or start a
    /// word. That single rule is what separates a real abbreviation from noise:
    /// a plain subsequence scan lets `wnd` match `warren desktop` through the
    /// middle of a word, and at that point almost every long path matches almost
    /// every short token.
    @inline(__always)
    private static func subsequenceScore(
        token: UnsafePointer<UInt8>,
        tokenCount: Int,
        haystack: UnsafePointer<UInt8>,
        field: FieldRecord,
        weight: Int
    ) -> Int? {
        guard tokenCount >= WarrenSearchTier.minimumSubsequenceLength else { return nil }
        var matched = 0
        var runs = 0
        var previous = -2
        var offset = field.start
        while offset < field.end && matched < tokenCount {
            if haystack[offset] == token[matched] {
                let continues = offset == previous + 1
                let startsWord = offset == field.start
                    || !WarrenSearchNormalization.isWordByte(haystack[offset - 1])
                if continues || startsWord {
                    if !continues { runs += 1 }
                    previous = offset
                    matched += 1
                }
            }
            offset += 1
        }
        guard matched == tokenCount else { return nil }
        // Fewer runs means the query read more like a real abbreviation than a
        // scatter of characters that happened to line up.
        return weight + WarrenSearchTier.subsequence + max(0, 60 - (runs - 1) * 15)
    }
}

// MARK: - Querying

extension WarrenSearchIndex {
    private struct Candidate {
        let entryIndex: Int
        let score: Int
        let fieldIndex: Int
    }

    /// Ranks the index against a query.
    ///
    /// `boost` and `accepts` are read at query time rather than baked into the
    /// index so live status can reorder and filter results without a rebuild.
    public func results(
        for query: WarrenSearchQuery,
        limit: Int = 60,
        boost: (Key) -> Int = { _ in 0 },
        accepts: (Key) -> Bool = { _ in true }
    ) -> [WarrenSearchResult<Key>] {
        guard limit > 0, !query.isEmpty, !entries.isEmpty else { return [] }
        guard !query.isFilterOnly else {
            return unscored(query: query, limit: limit, boost: boost, accepts: accepts)
        }

        var tokenStorage: [UInt8] = []
        var tokenSlices: [(start: Int, count: Int, mask: UInt64)] = []
        var queryMask: UInt64 = 0
        for token in query.tokens {
            let bytes = Array(token.utf8)
            guard !bytes.isEmpty else { continue }
            let mask = WarrenSearchNormalization.mask(bytes)
            queryMask |= mask
            tokenSlices.append((tokenStorage.count, bytes.count, mask))
            tokenStorage.append(contentsOf: bytes)
        }
        guard !tokenSlices.isEmpty else { return [] }
        // A multi-token query also scores the contiguous phrase, so tokens that
        // happen to be scattered across unrelated metadata lose to the row that
        // actually contains the whole thing.
        var phraseSlice: (start: Int, count: Int, mask: UInt64)?
        if tokenSlices.count > 1 {
            let bytes = Array(query.phrase.utf8)
            phraseSlice = (tokenStorage.count, bytes.count, WarrenSearchNormalization.mask(bytes))
            tokenStorage.append(contentsOf: bytes)
        }

        let heapLimit = min(limit * 2, limit + 20)
        var heap: [Candidate] = []
        heap.reserveCapacity(heapLimit)
        let words = wordStarts.isEmpty ? [0] : wordStarts

        storage.withUnsafeBufferPointer { haystackBuffer in
            words.withUnsafeBufferPointer { wordBuffer in
                tokenStorage.withUnsafeBufferPointer { tokenBuffer in
                    guard let haystack = haystackBuffer.baseAddress,
                          let wordBase = wordBuffer.baseAddress,
                          let tokenBase = tokenBuffer.baseAddress else { return }
                    collect(
                        into: &heap,
                        limit: heapLimit,
                        query: query,
                        queryMask: queryMask,
                        tokenSlices: tokenSlices,
                        phraseSlice: phraseSlice,
                        haystack: haystack,
                        words: wordBase,
                        tokens: tokenBase,
                        boost: boost,
                        accepts: accepts
                    )
                }
            }
        }
        return finish(heap: heap, limit: limit, query: query)
    }

    /// Every token must match some field, and each token scores against its own
    /// best field. Requiring one field to satisfy the whole query would break
    /// the common `warren review` shape, where the project and the branch live
    /// in different fields.
    private func collect(
        into heap: inout [Candidate],
        limit: Int,
        query: WarrenSearchQuery,
        queryMask: UInt64,
        tokenSlices: [(start: Int, count: Int, mask: UInt64)],
        phraseSlice: (start: Int, count: Int, mask: UInt64)?,
        haystack: UnsafePointer<UInt8>,
        words: UnsafePointer<Int>,
        tokens: UnsafePointer<UInt8>,
        boost: (Key) -> Int,
        accepts: (Key) -> Bool
    ) {
        let isScoped = !query.scopes.isEmpty
        for entryIndex in entries.indices {
            let entry = entries[entryIndex]
            if isScoped && !query.scopes.contains(entry.scope) { continue }
            guard entry.mask & queryMask == queryMask else { continue }
            guard accepts(entry.key) else { continue }

            var total = 0
            var bestScore = -1
            var bestFieldIndex = entry.fieldStart
            var lastTokenScore = 0
            var matchedEveryToken = true
            for slice in tokenSlices {
                var tokenBest = -1
                var tokenField = entry.fieldStart
                for fieldIndex in entry.fieldStart..<entry.fieldEnd {
                    guard let hit = Self.hit(
                        token: tokens + slice.start,
                        tokenCount: slice.count,
                        tokenMask: slice.mask,
                        haystack: haystack,
                        words: words,
                        field: fields[fieldIndex]
                    ), hit > tokenBest else { continue }
                    tokenBest = hit
                    tokenField = fieldIndex
                }
                guard tokenBest >= 0 else {
                    matchedEveryToken = false
                    break
                }
                total += tokenBest
                lastTokenScore = tokenBest
                if tokenBest > bestScore {
                    bestScore = tokenBest
                    bestFieldIndex = tokenField
                }
            }
            guard matchedEveryToken else { continue }

            if let phraseSlice {
                var phraseBest = 0
                for fieldIndex in entry.fieldStart..<entry.fieldEnd {
                    guard let hit = Self.hit(
                        token: tokens + phraseSlice.start,
                        tokenCount: phraseSlice.count,
                        tokenMask: phraseSlice.mask,
                        haystack: haystack,
                        words: words,
                        field: fields[fieldIndex]
                    ), hit > phraseBest else { continue }
                    phraseBest = hit
                }
                total += phraseBest
            } else {
                total += lastTokenScore
            }

            insert(
                Candidate(
                    entryIndex: entryIndex,
                    score: total + boost(entry.key),
                    fieldIndex: bestFieldIndex
                ),
                into: &heap,
                limit: limit
            )
        }
    }

    /// A query that narrowed by scope or status but typed no text. Everything
    /// that survives the filter is a result, ordered only by live priority.
    private func unscored(
        query: WarrenSearchQuery,
        limit: Int,
        boost: (Key) -> Int,
        accepts: (Key) -> Bool
    ) -> [WarrenSearchResult<Key>] {
        var heap: [Candidate] = []
        heap.reserveCapacity(limit)
        let isScoped = !query.scopes.isEmpty
        for entryIndex in entries.indices {
            let entry = entries[entryIndex]
            if isScoped && !query.scopes.contains(entry.scope) { continue }
            guard accepts(entry.key) else { continue }
            insert(
                Candidate(
                    entryIndex: entryIndex,
                    score: boost(entry.key),
                    fieldIndex: entry.fieldStart
                ),
                into: &heap,
                limit: limit
            )
        }
        return finish(heap: heap, limit: limit, query: query)
    }

    /// Resources worth offering before anything is typed: only those the live
    /// state has singled out. Listing the whole resource tree here would just
    /// be a second, unranked sidebar.
    public func suggestions(
        limit: Int = 8,
        boost: (Key) -> Int,
        accepts: (Key) -> Bool = { _ in true }
    ) -> [WarrenSearchResult<Key>] {
        guard limit > 0 else { return [] }
        var heap: [Candidate] = []
        heap.reserveCapacity(limit)
        for entryIndex in entries.indices {
            let entry = entries[entryIndex]
            let priority = boost(entry.key)
            guard priority > 0, accepts(entry.key) else { continue }
            insert(
                Candidate(entryIndex: entryIndex, score: priority, fieldIndex: entry.fieldStart),
                into: &heap,
                limit: limit
            )
        }
        return finish(heap: heap, limit: limit, query: WarrenSearchQuery(""))
    }

    /// Sorts the retained candidates, collapses rows a user cannot tell apart,
    /// and attaches each row's match explanation.
    private func finish(
        heap: [Candidate],
        limit: Int,
        query: WarrenSearchQuery
    ) -> [WarrenSearchResult<Key>] {
        var seenKeys = Set<Key>()
        var seenRows = Set<String>()
        var results: [WarrenSearchResult<Key>] = []
        results.reserveCapacity(min(limit, heap.count))
        for candidate in heap.sorted(by: precedes) {
            let entry = entries[candidate.entryIndex]
            guard seenKeys.insert(entry.key).inserted else { continue }
            // Two rows with the same title, ancestry, and kind read as one
            // duplicated row no matter which resource each points at.
            let row = "\(entry.title)\u{1}\(entry.subtitle)\u{1}\(entry.scope.rawValue)"
            guard seenRows.insert(row).inserted else { continue }
            results.append(WarrenSearchResult(
                key: entry.key,
                scope: entry.scope,
                title: entry.title,
                titleRanges: matchRanges(fieldIndex: entry.fieldStart, query: query),
                subtitle: entry.subtitle,
                evidence: evidence(fieldIndex: candidate.fieldIndex, query: query),
                score: candidate.score,
                ordinal: entry.ordinal
            ))
            if results.count >= limit { break }
        }
        return results
    }

    private func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        let left = entries[lhs.entryIndex]
        let right = entries[rhs.entryIndex]
        if left.scope.sortPriority != right.scope.sortPriority {
            return left.scope.sortPriority < right.scope.sortPriority
        }
        let order = left.title.localizedStandardCompare(right.title)
        if order != .orderedSame { return order == .orderedAscending }
        return left.ordinal < right.ordinal
    }

    /// Retains only the best `limit` candidates in a heap rooted at the worst of
    /// them. A bounded list is all any client renders, so fully sorting every
    /// match would buy nothing the user can see.
    private func insert(_ candidate: Candidate, into heap: inout [Candidate], limit: Int) {
        if heap.count < limit {
            heap.append(candidate)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
            return
        }
        guard let worst = heap.first, precedes(candidate, worst) else { return }
        heap[0] = candidate
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { return }
            let right = left + 1
            var worseChild = left
            if right < heap.count, precedes(heap[left], heap[right]) { worseChild = right }
            guard precedes(heap[parent], heap[worseChild]) else { return }
            heap.swapAt(parent, worseChild)
            parent = worseChild
        }
    }

    /// The row's reason for being here. A title match returns nothing: the title
    /// is already the loudest thing in the row, so repeating it wastes the one
    /// line a compact result has for new information.
    private func evidence(
        fieldIndex: Int,
        query: WarrenSearchQuery
    ) -> WarrenSearchEvidence? {
        guard fields.indices.contains(fieldIndex) else { return nil }
        let field = fields[fieldIndex]
        guard field.role.explainsMatch else { return nil }
        return WarrenSearchEvidence(
            role: field.role,
            text: fieldTexts[field.textIndex],
            ranges: matchRanges(fieldIndex: fieldIndex, query: query)
        )
    }

    /// Locates each token inside one already-folded field, as UTF8 offsets from
    /// the field's own start.
    ///
    /// The index folded this text at build time, so finding a token here is a
    /// byte scan rather than another normalization pass.
    private func matchRanges(
        fieldIndex: Int,
        query: WarrenSearchQuery
    ) -> [Range<Int>] {
        guard fields.indices.contains(fieldIndex), !query.tokens.isEmpty else { return [] }
        let field = fields[fieldIndex]
        // Folding away a diacritic loses the one-to-one mapping, so offsets from
        // the folded form cannot be trusted; fall back to the display text.
        guard field.isByteAligned else {
            return WarrenSearchHighlight.unalignedRanges(
                in: fieldTexts[field.textIndex],
                tokens: query.tokens
            )
        }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(query.tokens.count)
        storage.withUnsafeBufferPointer { buffer in
            guard let haystack = buffer.baseAddress else { return }
            for token in query.tokens {
                let bytes = Array(token.utf8)
                guard !bytes.isEmpty, bytes.count <= field.end - field.start else { continue }
                bytes.withUnsafeBufferPointer { needle in
                    guard let needleBase = needle.baseAddress else { return }
                    var offset = field.start
                    let last = field.end - bytes.count
                    while offset <= last {
                        if haystack[offset] == needleBase[0],
                           Self.equal(haystack, offset, needleBase, bytes.count) {
                            let start = offset - field.start
                            ranges.append(start..<(start + bytes.count))
                            return
                        }
                        offset += 1
                    }
                }
            }
        }
        return WarrenSearchHighlight.merge(ranges)
    }
}

// MARK: - Highlighting

/// Splits display text into matched and unmatched runs.
///
/// Every client renders highlights differently, but they must all agree on
/// *which* characters matched, so the segmentation lives beside the matcher that
/// produced the ranges.
public enum WarrenSearchHighlight {
    public struct Segment: Hashable, Sendable {
        public let text: String
        public let isMatch: Bool

        public init(text: String, isMatch: Bool) {
            self.text = text
            self.isMatch = isMatch
        }
    }

    /// Locates each token inside arbitrary display text.
    ///
    /// Used for the row title, which the index does not report evidence for:
    /// the title is always visible, so it is highlighted directly instead of
    /// being carried through the result.
    public static func ranges(in text: String, tokens: [String]) -> [Range<Int>] {
        let normalized = WarrenSearchNormalization.normalize(text)
        guard !normalized.bytes.isEmpty else { return [] }
        guard normalized.isByteAligned else {
            return unalignedRanges(in: normalized.text, tokens: tokens)
        }
        var ranges: [Range<Int>] = []
        for token in tokens {
            let needle = Array(token.utf8)
            guard !needle.isEmpty, needle.count <= normalized.bytes.count else { continue }
            let last = normalized.bytes.count - needle.count
            var offset = 0
            while offset <= last {
                if normalized.bytes[offset] == needle[0],
                   Array(normalized.bytes[offset..<(offset + needle.count)]) == needle {
                    ranges.append(offset..<(offset + needle.count))
                    break
                }
                offset += 1
            }
        }
        return merge(ranges)
    }

    /// Locates tokens in text whose folded form does not line up byte for byte,
    /// which is what happens whenever a diacritic is folded away.
    ///
    /// Byte offsets cannot be carried across that fold, so the token is found in
    /// the original text under the same insensitivity the matcher used and the
    /// result is converted back to UTF8 offsets. Accented names highlight the way
    /// plain ASCII ones do rather than silently losing their emphasis.
    static func unalignedRanges(in text: String, tokens: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        for token in tokens where !token.isEmpty {
            guard let found = text.range(
                of: token,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) else { continue }
            let start = text.utf8.distance(from: text.utf8.startIndex, to: found.lowerBound.samePosition(in: text.utf8) ?? text.utf8.startIndex)
            let end = text.utf8.distance(from: text.utf8.startIndex, to: found.upperBound.samePosition(in: text.utf8) ?? text.utf8.startIndex)
            guard end > start else { continue }
            ranges.append(start..<end)
        }
        return merge(ranges)
    }

    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        guard ranges.count > 1 else { return ranges }
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Splits `text` on UTF8 byte ranges. Ranges that do not land on character
    /// boundaries are dropped rather than rendered as mojibake.
    public static func segments(text: String, ranges: [Range<Int>]) -> [Segment] {
        guard !ranges.isEmpty, !text.isEmpty else {
            return text.isEmpty ? [] : [Segment(text: text, isMatch: false)]
        }
        let utf8 = Array(text.utf8)
        var segments: [Segment] = []
        var cursor = 0
        for range in merge(ranges) {
            guard range.lowerBound >= cursor, range.upperBound <= utf8.count else { continue }
            guard let matched = String(bytes: utf8[range], encoding: .utf8) else { continue }
            if range.lowerBound > cursor,
               let plain = String(bytes: utf8[cursor..<range.lowerBound], encoding: .utf8) {
                segments.append(Segment(text: plain, isMatch: false))
            }
            segments.append(Segment(text: matched, isMatch: true))
            cursor = range.upperBound
        }
        if cursor < utf8.count,
           let tail = String(bytes: utf8[cursor...], encoding: .utf8) {
            segments.append(Segment(text: tail, isMatch: false))
        }
        return segments.isEmpty ? [Segment(text: text, isMatch: false)] : segments
    }
}
