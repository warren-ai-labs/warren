import XCTest
@testable import WarrenDomain

final class WarrenSearchTests: XCTestCase {
    private typealias Index = WarrenSearchIndex<String>
    private typealias Descriptor = WarrenSearchDescriptor<String>

    // MARK: - Normalization

    func testNormalizationFoldsCaseAndDiacriticsAndReportsAlignment() {
        let ascii = WarrenSearchNormalization.normalize("  Feature/Search  ")
        XCTAssertEqual(String(decoding: ascii.bytes, as: UTF8.self), "feature/search")
        XCTAssertTrue(ascii.isByteAligned)

        let accented = WarrenSearchNormalization.normalize("Café")
        XCTAssertEqual(String(decoding: accented.bytes, as: UTF8.self), "cafe")
        XCTAssertFalse(accented.isByteAligned)
    }

    func testDiacriticInsensitiveQueryMatchesAccentedTitle() {
        let index = Index([Descriptor(key: "a", scope: .project, title: "Café Server")])
        XCTAssertEqual(index.results(for: WarrenSearchQuery("cafe")).map(\.key), ["a"])
    }

    // MARK: - Ranking

    func testTitleMatchOutranksContextMatch() {
        let index = Index([
            Descriptor(key: "project", scope: .project, title: "Warren", path: "/tmp/warren"),
            Descriptor(
                key: "workspace",
                scope: .workspace,
                title: "feature/palette",
                aliases: ["warren-search"],
                context: ["Warren"]
            ),
        ])

        XCTAssertEqual(index.results(for: WarrenSearchQuery("warren")).first?.key, "project")
    }

    func testWordPrefixOutranksMidWordSubstring() {
        let index = Index([
            Descriptor(key: "mid", scope: .session, title: "unreviewed notes"),
            Descriptor(key: "word", scope: .session, title: "code review"),
        ])

        XCTAssertEqual(index.results(for: WarrenSearchQuery("review")).first?.key, "word")
    }

    func testEveryTokenMustMatchButTokensMaySpanDifferentFields() {
        let index = Index([
            Descriptor(
                key: "hit",
                scope: .session,
                title: "Deploy API",
                context: ["Warren"]
            ),
            Descriptor(key: "miss", scope: .session, title: "Deploy Worker"),
        ])

        XCTAssertEqual(index.results(for: WarrenSearchQuery("warren deploy")).map(\.key), ["hit"])
    }

    func testContiguousPhraseOutranksScatteredTokens() {
        let index = Index([
            Descriptor(key: "phrase", scope: .session, title: "run dev server"),
            Descriptor(key: "scattered", scope: .session, title: "run", context: ["dev"]),
        ])

        XCTAssertEqual(index.results(for: WarrenSearchQuery("run dev")).first?.key, "phrase")
    }

    // MARK: - Subsequence

    func testAbbreviationMatchesAsSubsequence() {
        let index = Index([Descriptor(key: "a", scope: .session, title: "warren desktop command")])
        XCTAssertEqual(index.results(for: WarrenSearchQuery("wdc")).map(\.key), ["a"])
    }

    func testSubsequenceRequiresThreeCharactersAndWordBoundaries() {
        let index = Index([Descriptor(key: "a", scope: .session, title: "warren desktop command")])

        // Two characters would match almost anything.
        XCTAssertTrue(index.results(for: WarrenSearchQuery("wc")).isEmpty)
        // Characters present but spread far past the token's own length.
        XCTAssertTrue(index.results(for: WarrenSearchQuery("wnd")).isEmpty)
    }

    func testSubsequenceRanksBelowSubstring() {
        let index = Index([
            Descriptor(key: "loose", scope: .session, title: "warren desktop command"),
            Descriptor(key: "tight", scope: .session, title: "wdc"),
        ])

        XCTAssertEqual(index.results(for: WarrenSearchQuery("wdc")).first?.key, "tight")
    }

    // MARK: - Query grammar

    func testScopePrefixNarrowsResults() {
        let index = Index([
            Descriptor(key: "project", scope: .project, title: "Review"),
            Descriptor(key: "workspace", scope: .workspace, title: "Review"),
        ])

        XCTAssertEqual(
            index.results(for: WarrenSearchQuery("w:review")).map(\.key),
            ["workspace"]
        )
        XCTAssertEqual(
            Set(index.results(for: WarrenSearchQuery("review")).map(\.key)),
            ["project", "workspace"]
        )
    }

    func testFilterOnlyQueryListsEverythingThatSurvivesTheFilter() {
        let index = Index([
            Descriptor(key: "a", scope: .workspace, title: "Alpha"),
            Descriptor(key: "b", scope: .workspace, title: "Beta"),
            Descriptor(key: "c", scope: .project, title: "Gamma"),
        ])

        let query = WarrenSearchQuery("w:")
        XCTAssertTrue(query.isFilterOnly)
        XCTAssertEqual(Set(index.results(for: query).map(\.key)), ["a", "b"])
    }

    func testStatusFilterIsParsedAndAppliedByTheCaller() {
        let query = WarrenSearchQuery("@blocked deploy")
        XCTAssertEqual(query.statuses, ["blocked"])
        XCTAssertEqual(query.tokens, ["deploy"])

        let index = Index([
            Descriptor(key: "blocked", scope: .session, title: "Deploy API"),
            Descriptor(key: "ready", scope: .session, title: "Deploy Worker"),
        ])
        let results = index.results(for: query, accepts: { $0 == "blocked" })
        XCTAssertEqual(results.map(\.key), ["blocked"])
    }

    func testUnknownPrefixStaysLiteralText() {
        let index = Index([Descriptor(key: "a", scope: .project, title: "http://host:8080")])
        let query = WarrenSearchQuery("http://host")
        XCTAssertTrue(query.scopes.isEmpty)
        XCTAssertEqual(index.results(for: query).map(\.key), ["a"])
    }

    // MARK: - Evidence

    func testEvidenceNamesTheFieldThatExplainsTheMatch() {
        let index = Index([
            Descriptor(
                key: "session",
                scope: .session,
                title: "Shell",
                aliases: ["npm run dev"]
            ),
        ])

        let evidence = index.results(for: WarrenSearchQuery("npm")).first?.evidence
        XCTAssertEqual(evidence?.role, .alias)
        XCTAssertEqual(evidence?.text, "npm run dev")
        XCTAssertEqual(evidence?.ranges, [0..<3])
    }

    func testTitleMatchCarriesNoEvidenceBecauseTheTitleIsAlreadyVisible() {
        let index = Index([Descriptor(key: "a", scope: .session, title: "Deploy API")])
        let result = index.results(for: WarrenSearchQuery("deploy")).first
        XCTAssertNil(result?.evidence)
        // The title still reports where it matched, so a view never has to
        // re-derive it while rendering.
        XCTAssertEqual(result?.titleRanges, [0..<6])
    }

    func testTitleRangesCoverEveryTokenAndSurviveDiacriticFolding() {
        let index = Index([
            Descriptor(key: "a", scope: .session, title: "Deploy staging API"),
            Descriptor(key: "b", scope: .session, title: "Café runner"),
        ])

        XCTAssertEqual(
            index.results(for: WarrenSearchQuery("deploy api")).first?.titleRanges,
            [0..<6, 15..<18]
        )

        let accented = index.results(for: WarrenSearchQuery("cafe")).first
        XCTAssertEqual(
            WarrenSearchHighlight
                .segments(text: accented?.title ?? "", ranges: accented?.titleRanges ?? [])
                .filter(\.isMatch)
                .map(\.text),
            ["Café"]
        )
    }

    func testRowMatchedOnlyThroughAnAliasHasNoTitleRanges() {
        let index = Index([
            Descriptor(key: "a", scope: .session, title: "Deploy API", aliases: ["npm run dev"]),
        ])

        XCTAssertEqual(
            index.results(for: WarrenSearchQuery("npm")).first?.titleRanges,
            []
        )
    }

    func testEvidenceHighlightsEveryTokenInTheWinningField() {
        let index = Index([
            Descriptor(key: "a", scope: .session, title: "Shell", aliases: ["npm run dev"]),
        ])

        let evidence = index.results(for: WarrenSearchQuery("npm dev")).first?.evidence
        XCTAssertEqual(evidence?.ranges, [0..<3, 8..<11])
    }

    // MARK: - Live status

    func testBoostReordersWithoutRebuildingTheIndex() {
        let index = Index([
            Descriptor(key: "quiet", scope: .workspace, title: "review one"),
            Descriptor(key: "blocked", scope: .workspace, title: "review two"),
        ])

        XCTAssertEqual(index.results(for: WarrenSearchQuery("review")).first?.key, "quiet")
        XCTAssertEqual(
            index.results(for: WarrenSearchQuery("review"), boost: { $0 == "blocked" ? 500 : 0 })
                .first?.key,
            "blocked"
        )
    }

    func testSuggestionsOnlyIncludeBoostedEntries() {
        let index = Index([
            Descriptor(key: "pinned", scope: .workspace, title: "Pinned"),
            Descriptor(key: "idle", scope: .workspace, title: "Idle"),
        ])

        XCTAssertEqual(
            index.suggestions(boost: { $0 == "pinned" ? 30 : 0 }).map(\.key),
            ["pinned"]
        )
    }

    // MARK: - Bounding and dedupe

    func testBoundedResultsEqualThePrefixOfTheFullRanking() {
        let index = Index((0..<500).map { position in
            Descriptor(
                key: "entry-\(position)",
                scope: .workspace,
                title: "feature/\(position)",
                subtitle: "Project \(position)"
            )
        })

        let bounded = index.results(for: WarrenSearchQuery("feature"), limit: 20)
        let full = index.results(for: WarrenSearchQuery("feature"), limit: 5_000)

        XCTAssertEqual(bounded, Array(full.prefix(20)))
        XCTAssertTrue(index.results(for: WarrenSearchQuery("feature"), limit: 0).isEmpty)
    }

    func testVisuallyIdenticalRowsCollapse() {
        let index = Index([
            Descriptor(key: "one", scope: .session, title: "Shell", subtitle: "Warren › main"),
            Descriptor(key: "two", scope: .session, title: "Shell", subtitle: "Warren › main"),
            Descriptor(key: "three", scope: .session, title: "Shell", subtitle: "Warren › review"),
        ])

        let results = index.results(for: WarrenSearchQuery("shell"))
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results.map(\.subtitle)), ["Warren › main", "Warren › review"])
    }

    func testDuplicateFacetsDoNotInflateTheScore() {
        let repeated = Index([
            Descriptor(
                key: "a",
                scope: .workspace,
                title: "review",
                aliases: ["review", "Review", " review "]
            ),
        ])
        let single = Index([Descriptor(key: "a", scope: .workspace, title: "review")])

        XCTAssertEqual(
            repeated.results(for: WarrenSearchQuery("review")).first?.score,
            single.results(for: WarrenSearchQuery("review")).first?.score
        )
    }

    func testEmptyQueryYieldsNothing() {
        let index = Index([Descriptor(key: "a", scope: .project, title: "Warren")])
        XCTAssertTrue(index.results(for: WarrenSearchQuery("   ")).isEmpty)
    }

    // MARK: - Highlighting

    func testHighlightSegmentsSplitOnMatchedRuns() {
        let segments = WarrenSearchHighlight.segments(
            text: "Deploy API",
            ranges: WarrenSearchHighlight.ranges(in: "Deploy API", tokens: ["api"])
        )

        XCTAssertEqual(segments.map(\.text), ["Deploy ", "API"])
        XCTAssertEqual(segments.map(\.isMatch), [false, true])
    }

    func testHighlightMergesOverlappingRanges() {
        XCTAssertEqual(
            WarrenSearchHighlight.merge([0..<4, 2..<6, 8..<9]),
            [0..<6, 8..<9]
        )
    }

    func testHighlightSurvivesDiacriticFolding() {
        // "Café" is five UTF8 bytes and folds to four, so byte offsets cannot be
        // carried across the fold. The accented name still highlights.
        let ranges = WarrenSearchHighlight.ranges(in: "Café", tokens: ["cafe"])
        XCTAssertEqual(
            WarrenSearchHighlight.segments(text: "Café", ranges: ranges).map(\.text),
            ["Café"]
        )
        XCTAssertEqual(
            WarrenSearchHighlight.segments(text: "Café", ranges: ranges).map(\.isMatch),
            [true]
        )
    }

    func testEvidenceHighlightsAnAccentedField() {
        let index = Index([
            Descriptor(key: "a", scope: .session, title: "Shell", aliases: ["Café runner"]),
        ])

        let evidence = index.results(for: WarrenSearchQuery("cafe")).first?.evidence
        XCTAssertEqual(evidence?.text, "Café runner")
        XCTAssertEqual(
            WarrenSearchHighlight
                .segments(text: evidence?.text ?? "", ranges: evidence?.ranges ?? [])
                .filter(\.isMatch)
                .map(\.text),
            ["Café"]
        )
    }

    func testHighlightWithoutRangesLeavesTextIntact() {
        XCTAssertEqual(
            WarrenSearchHighlight.segments(text: "Café", ranges: []).map(\.text),
            ["Café"]
        )
    }

    // MARK: - Performance

    private func largeIndex() -> Index {
        var descriptors: [Descriptor] = []
        for project in 0..<200 {
            descriptors.append(Descriptor(
                key: "project-\(project)",
                scope: .project,
                title: "Project \(project)",
                path: "/tmp/project-\(project)"
            ))
            for workspace in 0..<20 {
                descriptors.append(Descriptor(
                    key: "workspace-\(project)-\(workspace)",
                    scope: .workspace,
                    title: "feature/\(project)-\(workspace)",
                    subtitle: "Project \(project)",
                    path: "/tmp/project-\(project)/workspace-\(workspace)",
                    aliases: ["Workspace \(workspace)", "workspace-\(workspace)"],
                    context: ["Project \(project)"]
                ))
            }
        }
        return Index(descriptors)
    }

    func testIndexBuildPerformanceAtScale() {
        let descriptors = (0..<4_000).map { position in
            Descriptor(
                key: "entry-\(position)",
                scope: .session,
                title: "session \(position)",
                subtitle: "Project \(position % 200)",
                path: "/tmp/project-\(position % 200)/workspace-\(position % 20)",
                aliases: ["npm run dev", "zsh", "feature/\(position)"],
                context: ["Project \(position % 200)", "feature/\(position % 20)"]
            )
        }
        measure { _ = Index(descriptors) }
    }

    /// What one keystroke costs: rank the query, then prepare every rendered row
    /// for display. The second half is what a view actually does per frame, so it
    /// belongs in the same measurement as the ranking.
    func testKeystrokePerformanceIncludingRowPreparation() {
        let index = largeIndex()
        measure {
            for raw in ["f", "fe", "fea", "feat", "featu", "feature"] {
                let query = WarrenSearchQuery(raw)
                for result in index.results(for: query, limit: 60) {
                    _ = WarrenSearchHighlight.segments(
                        text: result.title,
                        ranges: result.titleRanges
                    )
                    if let evidence = result.evidence {
                        _ = WarrenSearchHighlight.segments(
                            text: evidence.text,
                            ranges: evidence.ranges
                        )
                    }
                }
            }
        }
    }

    func testQueryPerformanceAtScale() {
        let index = largeIndex()
        XCTAssertEqual(
            index.results(for: WarrenSearchQuery("feature/199-19")).first?.title,
            "feature/199-19"
        )
        measure {
            _ = index.results(for: WarrenSearchQuery("feature/199-19"))
            _ = index.results(for: WarrenSearchQuery("feature"))
            _ = index.results(for: WarrenSearchQuery("wdc"))
        }
    }
}
