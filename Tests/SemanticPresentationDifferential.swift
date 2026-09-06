import AppKit
import Foundation

@main
struct SemanticPresentationDifferential {
    @MainActor
    static func main() {
        let theme = MDVTheme()
        theme.appearanceMode = AppearanceMode.light.rawValue
        let typography = Typography(baseFontSize: 16)
        let fixtures = [
            "# Heading *emphasis* and **strong**\n\nBody with [link](https://example.com), `code`, and ~~strike~~.\n",
            "> quoted **bold**\n> second line\n\n- bullet\n  - nested\n1. ordered\n",
            "```swift\nlet value = \"~~~\"\n```\n\n---\n",
            "| Name | Value |\n| --- | ---: |\n| 한국어 | 😀 |\n",
            "Setext heading\n===\n\n**outer `code` tail**\n"
        ]
        let renderer = InlineRenderer()
        for (index, fixture) in fixtures.enumerated() {
            let legacy = renderer.renderLegacyForDifferential(text: fixture, theme: theme, typography: typography)
            let semantic = renderer.render(text: fixture, theme: theme, typography: typography)
            require(legacy.attributedString.isEqual(to: semantic.attributedString), "fixture \(index): attributed output differs")
            compareMetadata(legacy, semantic, fixture: index)
        }

        // The legacy reference intentionally remains red for this known bug:
        // Character counts place the second marker one UTF-16 unit too early.
        let unicodeQuote = "> 😀 first\n> second\n"
        let marker = (unicodeQuote as NSString).range(of: "\n> second").location + 1
        let legacy = renderer.renderLegacyForDifferential(text: unicodeQuote, theme: theme, typography: typography)
        let semantic = MarkdownPresentationParser.parse(text: unicodeQuote)
        require(legacy.syntaxRanges.contains(NSRange(location: marker - 1, length: 2)), "Unicode probe did not reproduce legacy shift")
        require(semantic.metadata.syntaxRanges.contains(NSRange(location: marker, length: 2)), "semantic marker is not UTF-16 aligned")
        require(!semantic.metadata.syntaxRanges.contains(NSRange(location: marker - 1, length: 2)), "semantic parser retained legacy shifted marker")

        assertNestedFences("> ```swift\n> quotedCode\n> ```\n", label: "quote")
        assertNestedFences("- item\n  ```swift\n  listCode\n  ```\n", label: "list")
        assertLiteralQuoteFenceInsideCode()
        assertSemanticDiffCache()

        let stressUnit = fixtures.joined(separator: "\n")
        let stress = String(repeating: stressUnit, count: 800)
        let start = ContinuousClock.now
        let presentation = MarkdownPresentationParser.parse(text: stress)
        let parseElapsed = start.duration(to: .now)
        let materializeStart = ContinuousClock.now
        let materialized = MarkdownPresentationPalette(theme: theme, typography: typography)
            .materialize(presentation: presentation)
        let materializeElapsed = materializeStart.duration(to: .now)
        require(presentation.source.utf16.count == (stress as NSString).length, "stress source changed")
        require(!presentation.runs.isEmpty, "stress parse produced no runs")
        require(materialized.attributedString.string == stress, "stress materialization changed source")
        print("SemanticPresentationDifferential: PASS fixtures=\(fixtures.count) unicodeMarker=\(marker) stressUTF16=\((stress as NSString).length) runs=\(presentation.runs.count) parse=\(parseElapsed) materialize=\(materializeElapsed)")
    }

    @MainActor
    private static func compareMetadata(_ lhs: RenderResult, _ rhs: RenderResult, fixture: Int) {
        require(sorted(lhs.syntaxRanges) == sorted(rhs.syntaxRanges), "fixture \(fixture): syntax ranges differ")
        require(sorted(lhs.bulletRanges) == sorted(rhs.bulletRanges), "fixture \(fixture): bullets differ")
        require(lhs.blockQuoteRanges == rhs.blockQuoteRanges, "fixture \(fixture): quotes differ")
        require(lhs.codeBlockRanges == rhs.codeBlockRanges, "fixture \(fixture): code blocks differ")
        require(lhs.horizontalRuleRanges == rhs.horizontalRuleRanges, "fixture \(fixture): rules differ")
        require(lhs.inlineCodeRanges == rhs.inlineCodeRanges, "fixture \(fixture): inline code differs")
        require(lhs.tables.map(\.sourceRange) == rhs.tables.map(\.sourceRange), "fixture \(fixture): tables differ")
        require(lhs.headings.count == rhs.headings.count, "fixture \(fixture): heading count differs")
        for (left, right) in zip(lhs.headings, rhs.headings) {
            require(left.level == right.level && left.title == right.title && left.range == right.range,
                    "fixture \(fixture): headings differ")
        }
    }

    private static func sorted(_ ranges: [NSRange]) -> [NSRange] {
        ranges.sorted { $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location }
    }

    private static func assertNestedFences(_ source: String, label: String) {
        let ns = source as NSString
        let opener = ns.range(of: "```swift")
        let closer = ns.range(of: "```", options: .backwards)
        let metadata = MarkdownPresentationParser.parse(text: source).metadata
        let syntax = metadata.syntaxRanges
        require(syntax.contains(opener), "\(label) code opener was not masked at its AST-relative UTF-16 range")
        require(syntax.contains(closer), "\(label) code closer was not masked at its AST-relative UTF-16 range")
    }

    private static func assertSemanticDiffCache() {
        typealias Run = MarkdownPresentation.Run
        let body = MarkdownPresentation.SemanticStyle()
        var bold = body
        bold.bold = true

        let fresh = [Run(range: NSRange(location: 0, length: 8), style: body)]
        let equivalentSplit = [
            Run(range: NSRange(location: 0, length: 3), style: body),
            Run(range: NSRange(location: 3, length: 5), style: body)
        ]
        require(MarkdownPresentationDiff.changedRuns(fresh: fresh, cached: equivalentSplit, sourceLength: 8).isEmpty,
                "equal styles with different boundaries produced writes")

        let gap = [Run(range: NSRange(location: 0, length: 3), style: body)]
        let gapChanges = MarkdownPresentationDiff.changedRuns(fresh: fresh, cached: gap, sourceLength: 8)
        require(gapChanges == [Run(range: NSRange(location: 3, length: 5), style: body)],
                "unknown cache gap did not emit fresh default styling")

        let removal = MarkdownPresentationDiff.changedRuns(
            fresh: fresh, cached: [Run(range: NSRange(location: 0, length: 8), style: bold)], sourceLength: 8
        )
        require(removal == fresh, "style removal did not emit a default body run")
        let invalidated = MarkdownPresentationDiff.changedRuns(
            fresh: fresh, cached: fresh, sourceLength: 8,
            invalidatedRanges: [NSRange(location: 2, length: 3)]
        )
        require(invalidated == [Run(range: NSRange(location: 2, length: 3), style: body)],
                "explicit invalidation was not clipped to its current-coordinate span")

        // replacementLength=2 models insertion of one emoji in UTF-16. A long
        // body run must retain both sides and leave only the inserted gap unknown.
        let inserted = MarkdownPresentationDiff.translateCachedRuns(
            fresh, through: .init(range: NSRange(location: 3, length: 0), replacementLength: 2)
        )
        require(inserted == [
            Run(range: NSRange(location: 0, length: 3), style: body),
            Run(range: NSRange(location: 5, length: 5), style: body)
        ], "UTF-16 insertion did not preserve translated prefix/suffix cache spans")

        let deleted = MarkdownPresentationDiff.translateCachedRuns(
            [Run(range: NSRange(location: 0, length: 4), style: body),
             Run(range: NSRange(location: 4, length: 4), style: bold)],
            through: .init(range: NSRange(location: 2, length: 3), replacementLength: 0)
        )
        require(deleted == [
            Run(range: NSRange(location: 0, length: 2), style: body),
            Run(range: NSRange(location: 2, length: 3), style: bold)
        ], "deletion did not clip touched spans and translate the known suffix")

        let paragraphClipped = MarkdownPresentationDiff.translateCachedRuns(
            fresh,
            through: .init(range: NSRange(location: 3, length: 0), replacementLength: 1),
            invalidatedOldRanges: [NSRange(location: 2, length: 3)]
        )
        require(paragraphClipped == [
            Run(range: NSRange(location: 0, length: 2), style: body),
            Run(range: NSRange(location: 6, length: 3), style: body)
        ], "paragraph invalidation discarded more than the affected span")
    }

    private static func assertLiteralQuoteFenceInsideCode() {
        let source = "```swift\n> ```\nbody\n"
        let ns = source as NSString
        let literal = ns.range(of: "```", options: [], range: NSRange(location: 3, length: ns.length - 3))
        let syntax = MarkdownPresentationParser.parse(text: source).metadata.syntaxRanges
        require(!syntax.contains(literal), "literal quote-prefixed ticks inside top-level code were treated as a closing fence")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
