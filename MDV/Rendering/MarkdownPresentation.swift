import Foundation
import Markdown

/// The immutable result of Markdown interpretation. It deliberately contains no
/// AppKit objects so it can be produced on a serial background executor.
nonisolated struct MarkdownPresentation: Sendable {
    nonisolated struct Run: Sendable, Equatable {
        let range: NSRange
        let style: SemanticStyle
    }

    nonisolated struct SemanticStyle: Sendable, Hashable {
        nonisolated enum FontRole: Sendable, Hashable { case body, heading(Int), code }
        nonisolated enum ForegroundRole: Sendable, Hashable { case text, heading, secondary, code, accent, clear }
        nonisolated enum ParagraphRole: Sendable, Hashable { case body, heading(Int), emptyLine, blockQuote, list(Int), codeBlock }

        var font: FontRole = .body
        var bold = false
        var italic = false
        var foreground: ForegroundRole = .text
        var paragraph: ParagraphRole = .body
        var linkDestination: String?
        var underline = false
        var strikethrough = false
    }

    nonisolated struct Table: Sendable, Equatable {
        let sourceRange: NSRange
        let numColumns: Int
        let headerCells: [String]
        let bodyRows: [[String]]
    }

    nonisolated struct Heading: Sendable, Equatable {
        let level: Int
        let title: String
        let range: NSRange
    }

    nonisolated struct Metadata: Sendable, Equatable {
        var syntaxRanges: [NSRange] = []
        var bulletRanges: [NSRange] = []
        var blockQuoteRanges: [NSRange] = []
        var codeBlockRanges: [NSRange] = []
        var horizontalRuleRanges: [NSRange] = []
        var inlineCodeRanges: [NSRange] = []
        var tables: [Table] = []
        var headings: [Heading] = []
    }

    let source: String
    let runs: [Run]
    let metadata: Metadata

    /// Returns the fresh semantic spans whose attributes must be installed.
    /// Run boundaries are not semantically significant: both presentations are
    /// swept as piecewise-constant style functions over UTF-16 source offsets.
    /// Explicit invalidations always win, including when old and fresh styles
    /// compare equal. Returned runs are ordered, disjoint, and coalesced.
    nonisolated func changedRuns(
        comparedTo old: MarkdownPresentation?,
        invalidatedRanges: [NSRange] = []
    ) -> [Run] {
        guard let old else { return runs }
        return MarkdownPresentationDiff.changedRuns(
            fresh: runs,
            cached: old.runs,
            sourceLength: (source as NSString).length,
            invalidatedRanges: invalidatedRanges
        )
    }
}

/// Pure value helper for maintaining and comparing the semantic-style cache.
/// All coordinates and lengths use source UTF-16 units.
nonisolated enum MarkdownPresentationDiff {
    typealias Run = MarkdownPresentation.Run
    typealias Style = MarkdownPresentation.SemanticStyle

    nonisolated struct SourceEdit: Sendable, Equatable {
        let range: NSRange
        let replacementLength: Int

        init(range: NSRange, replacementLength: Int) {
            self.range = range
            self.replacementLength = replacementLength
        }
    }

    /// Translates known-installed cache spans through one native source edit.
    /// Spans touched by the edit or an old-coordinate invalidation are discarded;
    /// callers then diff using invalidations expressed in current coordinates.
    nonisolated static func translateCachedRuns(
        _ cached: [Run],
        through edit: SourceEdit,
        invalidatedOldRanges: [NSRange] = []
    ) -> [Run] {
        let oldEnd = NSMaxRange(edit.range)
        let delta = max(0, edit.replacementLength) - edit.range.length
        var cuts = invalidatedOldRanges
        if edit.range.length > 0 { cuts.append(edit.range) }
        cuts = normalized(ranges: cuts)
        var result: [Run] = []
        var cutIndex = 0
        for run in cached {
            var cursor = run.range.location
            let runEnd = NSMaxRange(run.range)
            while cutIndex < cuts.count, NSMaxRange(cuts[cutIndex]) <= cursor { cutIndex += 1 }
            var localCutIndex = cutIndex
            while localCutIndex < cuts.count, cuts[localCutIndex].location < runEnd {
                let cut = cuts[localCutIndex]
                if cursor < cut.location {
                    appendTranslated(
                        range: NSRange(location: cursor, length: min(runEnd, cut.location) - cursor),
                        style: run.style, editStart: edit.range.location, oldEnd: oldEnd,
                        delta: delta, to: &result
                    )
                }
                cursor = max(cursor, NSMaxRange(cut))
                if cursor >= runEnd { break }
                localCutIndex += 1
            }
            if cursor < runEnd {
                appendTranslated(
                    range: NSRange(location: cursor, length: runEnd - cursor), style: run.style,
                    editStart: edit.range.location, oldEnd: oldEnd, delta: delta,
                    to: &result
                )
            }
        }
        return result
    }

    private nonisolated static func appendTranslated(
        range: NSRange, style: Style, editStart: Int, oldEnd: Int,
        delta: Int, to result: inout [Run]
    ) {
        guard range.length > 0 else { return }
        let rangeEnd = NSMaxRange(range)
        if range.location < editStart {
            let prefixEnd = min(rangeEnd, editStart)
            append(run: Run(range: NSRange(location: range.location, length: prefixEnd - range.location), style: style), to: &result)
        }
        if rangeEnd > oldEnd {
            let suffixStart = max(range.location, oldEnd)
            let newStart = suffixStart + delta
            append(run: Run(range: NSRange(location: newStart, length: rangeEnd - suffixStart), style: style), to: &result)
        }
    }

    /// Linear two-pointer semantic comparison. Missing cached coverage is
    /// unknown and therefore emitted, including fresh default/body styling.
    nonisolated static func changedRuns(
        fresh: [Run],
        cached: [Run],
        sourceLength: Int,
        invalidatedRanges: [NSRange] = []
    ) -> [Run] {
        guard !fresh.isEmpty, sourceLength > 0 else { return [] }
        let invalidations = normalized(ranges: invalidatedRanges, sourceLength: sourceLength)
        var cachedIndex = 0, invalidationIndex = 0
        var result: [Run] = []

        for freshRun in fresh {
            var cursor = max(0, freshRun.range.location)
            let freshEnd = min(sourceLength, NSMaxRange(freshRun.range))
            while cursor < freshEnd {
                while cachedIndex < cached.count, NSMaxRange(cached[cachedIndex].range) <= cursor { cachedIndex += 1 }
                while invalidationIndex < invalidations.count, NSMaxRange(invalidations[invalidationIndex]) <= cursor {
                    invalidationIndex += 1
                }

                var next = freshEnd
                var cachedStyle: Style?
                if cachedIndex < cached.count {
                    let cachedRun = cached[cachedIndex]
                    if cachedRun.range.location <= cursor, NSMaxRange(cachedRun.range) > cursor {
                        cachedStyle = cachedRun.style
                        next = min(next, NSMaxRange(cachedRun.range))
                    } else if cachedRun.range.location > cursor {
                        next = min(next, cachedRun.range.location)
                    }
                }

                var invalidated = false
                if invalidationIndex < invalidations.count {
                    let invalidation = invalidations[invalidationIndex]
                    if invalidation.location <= cursor, NSMaxRange(invalidation) > cursor {
                        invalidated = true
                        next = min(next, NSMaxRange(invalidation))
                    } else if invalidation.location > cursor {
                        next = min(next, invalidation.location)
                    }
                }

                guard next > cursor else { break }
                if invalidated || cachedStyle != freshRun.style {
                    append(run: Run(range: NSRange(location: cursor, length: next - cursor), style: freshRun.style), to: &result)
                }
                cursor = next
            }
        }
        return result
    }

    private nonisolated static func append(run: Run, to result: inout [Run]) {
        guard run.range.length > 0 else { return }
        if let last = result.last, last.style == run.style, NSMaxRange(last.range) == run.range.location {
            result[result.count - 1] = Run(range: NSUnionRange(last.range, run.range), style: run.style)
        } else {
            result.append(run)
        }
    }

    private nonisolated static func normalized(ranges: [NSRange], sourceLength: Int? = nil) -> [NSRange] {
        let clipped = ranges.compactMap { range -> NSRange? in
            let lower = max(0, range.location)
            let rawUpper = max(lower, NSMaxRange(range))
            let upper = sourceLength.map { min(rawUpper, $0) } ?? rawUpper
            let boundedLower = sourceLength.map { min(lower, $0) } ?? lower
            return upper > boundedLower ? NSRange(location: boundedLower, length: upper - boundedLower) : nil
        }.sorted { lhs, rhs in
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
        var result: [NSRange] = []
        for range in clipped {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else { result.append(range) }
        }
        return result
    }
}

/// Authoritative Markdown-to-semantic-value parser. All source locations and
/// ranges crossing this seam are UTF-16, matching NSTextStorage/NSRange.
nonisolated enum MarkdownPresentationParser {
    nonisolated static func parse(text: String) -> MarkdownPresentation {
        var parser = Parser(source: text)
        return parser.parse()
    }

    private struct Parser {
        private enum Change {
            case font(MarkdownPresentation.SemanticStyle.FontRole)
            case bold, italic
            case foreground(MarkdownPresentation.SemanticStyle.ForegroundRole)
            case paragraph(MarkdownPresentation.SemanticStyle.ParagraphRole)
            case link(String?), underline, strike
        }

        private struct Operation {
            let range: NSRange
            let change: Change
            let order: Int
        }

        let source: String
        let nsSource: NSString
        let sourceUTF8: [UInt8]
        let lineStartUTF8Offsets: [Int]
        let unicodeCorrectionEnds: [Int]
        let unicodeCumulativeReductions: [Int]
        private var operations: [Operation] = []
        var metadata = MarkdownPresentation.Metadata()
        private var nextOrder = 0

        init(source: String) {
            self.source = source
            self.nsSource = source as NSString
            let index = Self.makeOffsetIndex(source)
            self.sourceUTF8 = index.bytes
            self.lineStartUTF8Offsets = index.lines
            self.unicodeCorrectionEnds = index.ends
            self.unicodeCumulativeReductions = index.reductions
        }

        mutating func parse() -> MarkdownPresentation {
            guard !source.isEmpty else {
                return MarkdownPresentation(source: source, runs: [], metadata: metadata)
            }
            let document = Document(parsing: source)
            for child in document.children { visit(child) }
            applyEmptyLineParagraphs()
            metadata.syntaxRanges.sort(by: Self.rangeOrder)
            metadata.bulletRanges.sort(by: Self.rangeOrder)
            return MarkdownPresentation(source: source, runs: resolvedRuns(), metadata: metadata)
        }

        private static func makeOffsetIndex(_ source: String) -> (bytes: [UInt8], lines: [Int], ends: [Int], reductions: [Int]) {
            let bytes = Array(source.utf8)
            var lines = [0], ends: [Int] = [], reductions: [Int] = []
            var offset = 0, reduction = 0
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte < 0x80 {
                    offset += 1
                    if byte == 0x0A || (byte == 0x0D && (offset == bytes.count || bytes[offset] != 0x0A)) { lines.append(offset) }
                } else if byte < 0xE0 {
                    offset += 2; reduction += 1; ends.append(offset); reductions.append(reduction)
                } else if byte < 0xF0 {
                    offset += 3; reduction += 2; ends.append(offset); reductions.append(reduction)
                } else {
                    offset += 4; reduction += 2; ends.append(offset); reductions.append(reduction)
                }
            }
            return (bytes, lines, ends, reductions)
        }

        private func utf16Offset(for location: SourceLocation) -> Int? {
            let line = location.line - 1, column = location.column - 1
            guard lineStartUTF8Offsets.indices.contains(line), column >= 0 else { return nil }
            let target = lineStartUTF8Offsets[line] + column
            guard target <= sourceUTF8.count,
                  target == sourceUTF8.count || sourceUTF8[target] & 0xC0 != 0x80 else { return nil }
            var low = 0, high = unicodeCorrectionEnds.count
            while low < high {
                let middle = low + (high - low) / 2
                if unicodeCorrectionEnds[middle] <= target { low = middle + 1 } else { high = middle }
            }
            return target - (low > 0 ? unicodeCumulativeReductions[low - 1] : 0)
        }

        private func range(of markup: any Markup) -> NSRange? {
            guard let sourceRange = markup.range,
                  let start = utf16Offset(for: sourceRange.lowerBound),
                  let end = utf16Offset(for: sourceRange.upperBound), start <= end else { return nil }
            return NSRange(location: start, length: end - start)
        }

        private func trimmed(_ range: NSRange) -> NSRange {
            var end = NSMaxRange(range)
            while end > range.location && nsSource.character(at: end - 1) == 0x0A { end -= 1 }
            return NSRange(location: range.location, length: end - range.location)
        }

        private mutating func add(_ change: Change, _ range: NSRange) {
            guard range.length > 0, range.location >= 0, NSMaxRange(range) <= nsSource.length else { return }
            operations.append(Operation(range: range, change: change, order: nextOrder)); nextOrder += 1
        }

        private mutating func visit(_ markup: any Markup, listDepth: Int = 0) {
            let sourceRange = range(of: markup)
            switch markup {
            case let heading as Heading:
                if let sourceRange { applyHeading(heading, range: sourceRange) }
            case let strong as Strong:
                if let sourceRange { add(.bold, sourceRange); addInlineMarkers(sourceRange, length: 2) }
                for child in strong.children { visit(child, listDepth: listDepth) }
            case let emphasis as Emphasis:
                if let sourceRange { add(.italic, sourceRange); addInlineMarkers(sourceRange, length: 1) }
                for child in emphasis.children { visit(child, listDepth: listDepth) }
            case is InlineCode:
                if let sourceRange {
                    add(.font(.code), sourceRange); add(.foreground(.code), sourceRange)
                    metadata.inlineCodeRanges.append(sourceRange); addInlineMarkers(sourceRange, length: 1)
                }
            case is CodeBlock:
                if let sourceRange {
                    let r = trimmed(sourceRange)
                    add(.font(.code), r); add(.foreground(.code), r); add(.paragraph(.codeBlock), r)
                    metadata.codeBlockRanges.append(r); metadata.syntaxRanges.append(contentsOf: fencedCodeSyntaxRanges(in: r))
                }
            case let link as Link:
                for child in link.children { visit(child, listDepth: listDepth) }
                if let sourceRange { applyLink(link, range: sourceRange) }
            case let quote as BlockQuote:
                if let sourceRange { applyBlockQuote(quote, range: sourceRange) }
            case is ThematicBreak:
                if let sourceRange { add(.foreground(.clear), sourceRange); metadata.horizontalRuleRanges.append(sourceRange) }
            case let table as Table:
                if let sourceRange { applyTable(table, range: sourceRange) }
            case let item as ListItem:
                if let sourceRange { applyListItem(item, range: sourceRange, depth: listDepth) }
            case is OrderedList, is UnorderedList:
                for child in markup.children { visit(child, listDepth: listDepth + 1) }
            case let strike as Strikethrough:
                for child in strike.children { visit(child, listDepth: listDepth) }
                if let sourceRange {
                    add(.strike, sourceRange); add(.foreground(.secondary), sourceRange)
                    addInlineMarkers(sourceRange, length: 2)
                }
            default:
                for child in markup.children { visit(child, listDepth: listDepth) }
            }
        }

        private mutating func applyHeading(_ heading: Heading, range: NSRange) {
            let r = trimmed(range)
            add(.font(.heading(heading.level)), r); add(.foreground(.heading), r); add(.paragraph(.heading(heading.level)), r)
            let headingSource = nsSource.substring(with: r) as NSString
            if headingSource.hasPrefix("#") {
                var length = 0
                while length < headingSource.length, headingSource.character(at: length) == 0x23 { length += 1 }
                if length < headingSource.length, headingSource.character(at: length) == 0x20 { length += 1 }
                if length > 0 { metadata.syntaxRanges.append(NSRange(location: r.location, length: length)) }
            } else {
                let newline = headingSource.range(of: "\n", options: .backwards)
                if newline.location != NSNotFound {
                    metadata.syntaxRanges.append(NSRange(location: r.location + NSMaxRange(newline), length: r.length - NSMaxRange(newline)))
                }
            }
            let raw = headingSource as String
            let firstLine = raw.components(separatedBy: "\n").first ?? raw
            let title = String(firstLine.drop(while: { $0 == "#" }).drop(while: { $0 == " " })).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { metadata.headings.append(.init(level: heading.level, title: title, range: r)) }
            for child in heading.children { visit(child) }
        }

        private mutating func applyLink(_ link: Link, range: NSRange) {
            let childRanges = link.children.compactMap { self.range(of: $0) }
            guard let first = childRanges.first, let last = childRanges.last else { return }
            let label = NSUnionRange(first, last)
            let prefixLength = label.location - range.location
            if prefixLength > 0 { metadata.syntaxRanges.append(NSRange(location: range.location, length: prefixLength)) }
            if NSMaxRange(label) < NSMaxRange(range) { metadata.syntaxRanges.append(NSRange(location: NSMaxRange(label), length: NSMaxRange(range) - NSMaxRange(label))) }
            add(.foreground(.accent), label); add(.underline, label); add(.link(link.destination), label)
        }

        private mutating func applyBlockQuote(_ quote: BlockQuote, range: NSRange) {
            let r = trimmed(range)
            add(.paragraph(.blockQuote), r); add(.foreground(.secondary), r); metadata.blockQuoteRanges.append(r)

            // NSString line ranges keep every offset in UTF-16. Swift Character
            // counts here shift all following quote markers after emoji/CJK.
            var location = r.location
            while location < NSMaxRange(r) {
                let fullLine = nsSource.lineRange(for: NSRange(location: location, length: 0))
                let line = NSIntersectionRange(fullLine, r)
                var cursor = line.location
                while cursor < NSMaxRange(line), nsSource.character(at: cursor) == 0x20 { cursor += 1 }
                if cursor < NSMaxRange(line), nsSource.character(at: cursor) == 0x3E {
                    var length = 1
                    if cursor + 1 < NSMaxRange(line), nsSource.character(at: cursor + 1) == 0x20 { length = 2 }
                    metadata.syntaxRanges.append(NSRange(location: cursor, length: length))
                }
                let next = NSMaxRange(fullLine)
                if next <= location { break }; location = next
            }
            for child in quote.children { visit(child) }
        }

        private mutating func applyTable(_ table: Table, range: NSRange) {
            let r = trimmed(range), text = nsSource.substring(with: r)
            guard let model = MarkdownTable(markdown: text), !model.header.isEmpty else { return }
            metadata.tables.append(.init(sourceRange: r, numColumns: model.columnCount, headerCells: model.header, bodyRows: model.body))
        }

        private mutating func applyListItem(_ item: ListItem, range: NSRange, depth: Int) {
            add(.paragraph(.list(depth - 1)), range)
            let length = min(10, range.length), line = nsSource.substring(with: NSRange(location: range.location, length: length)) as NSString
            var leading = 0
            while leading < line.length, line.character(at: leading) == 0x20 { leading += 1 }
            if leading + 1 < line.length,
               [UInt16(0x2D), UInt16(0x2A), UInt16(0x2B)].contains(line.character(at: leading)),
               line.character(at: leading + 1) == 0x20 {
                metadata.bulletRanges.append(NSRange(location: range.location + leading, length: 1))
            }
            for child in item.children { visit(child, listDepth: depth) }
        }

        private mutating func addInlineMarkers(_ range: NSRange, length: Int) {
            guard range.length >= length * 2 else { return }
            metadata.syntaxRanges.append(NSRange(location: range.location, length: length))
            metadata.syntaxRanges.append(NSRange(location: NSMaxRange(range) - length, length: length))
        }

        private func fencedCodeSyntaxRanges(in range: NSRange) -> [NSRange] {
            guard range.length > 0, NSMaxRange(range) <= nsSource.length else { return [] }
            let firstLine = nsSource.lineRange(for: NSRange(location: range.location, length: 0))
            let firstBounded = NSIntersectionRange(firstLine, range)
            guard firstBounded.length > 0 else { return [] }
            let containerPrefixRange = NSRange(
                location: firstLine.location,
                length: max(0, firstBounded.location - firstLine.location)
            )
            let containerPrefix = nsSource.substring(with: containerPrefixRange)
            let opener = nsSource.substring(with: firstBounded).trimmingCharacters(in: .newlines) as NSString
            var indent = 0
            while indent < min(3, opener.length), opener.character(at: indent) == 0x20 { indent += 1 }
            guard indent < opener.length else { return [] }
            let marker = opener.character(at: indent)
            guard marker == 0x60 || marker == 0x7E else { return [] }
            var fenceLength = 0
            while indent + fenceLength < opener.length, opener.character(at: indent + fenceLength) == marker { fenceLength += 1 }
            guard fenceLength >= 3 else { return [] }
            var result = [NSRange(location: firstBounded.location + indent, length: opener.length - indent)]
            var location = NSMaxRange(firstLine), closing: NSRange?
            while location < NSMaxRange(range) {
                let fullLine = nsSource.lineRange(for: NSRange(location: location, length: 0))
                let bounded = NSIntersectionRange(fullLine, range)
                guard bounded.length > 0 else { break }
                let line = nsSource.substring(with: bounded).trimmingCharacters(in: .newlines) as NSString
                guard let space = codeContentOffset(in: line, containerPrefix: containerPrefix) else {
                    let next = NSMaxRange(fullLine); if next <= location { break }; location = next
                    continue
                }
                var count = 0
                while space + count < line.length, line.character(at: space + count) == marker { count += 1 }
                if count >= fenceLength,
                   line.substring(from: space + count).trimmingCharacters(in: .whitespaces).isEmpty {
                    closing = NSRange(location: bounded.location + space, length: line.length - space)
                }
                let next = NSMaxRange(fullLine); if next <= location { break }; location = next
            }
            if let closing { result.append(closing) }; return result
        }

        /// swift-markdown may exclude the opener's container prefix from the
        /// CodeBlock lower bound but include that same prefix on its closing line.
        /// Only peel the exact physical prefix observed before the AST opener;
        /// a `> ``` ` sequence inside top-level code must remain literal content.
        private func codeContentOffset(in line: NSString, containerPrefix: String) -> Int? {
            var cursor = 0
            if !containerPrefix.isEmpty {
                guard line.hasPrefix(containerPrefix) else { return nil }
                cursor = (containerPrefix as NSString).length
            }
            var spaces = 0
            while cursor < line.length, spaces < 3, line.character(at: cursor) == 0x20 {
                cursor += 1; spaces += 1
            }
            return cursor
        }

        private mutating func applyEmptyLineParagraphs() {
            let code = metadata.codeBlockRanges.sorted(by: Self.rangeOrder)
            var codeIndex = 0, location = 0
            while location < nsSource.length {
                let line = nsSource.lineRange(for: NSRange(location: location, length: 0))
                let stripped = nsSource.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                while codeIndex < code.count, NSMaxRange(code[codeIndex]) <= line.location { codeIndex += 1 }
                let inCode = codeIndex < code.count && line.location >= code[codeIndex].location && NSMaxRange(line) <= NSMaxRange(code[codeIndex])
                if stripped.isEmpty && line.length > 0 && !inCode { add(.paragraph(.emptyLine), line) }
                let next = NSMaxRange(line); if next <= location { break }; location = next
            }
        }

        private func resolvedRuns() -> [MarkdownPresentation.Run] {
            var starts: [Int: [Operation]] = [:], endingOrders: [Int: [Int]] = [:]
            var boundaries = Set([0, nsSource.length])
            for operation in operations {
                let end = NSMaxRange(operation.range)
                boundaries.insert(operation.range.location); boundaries.insert(end)
                starts[operation.range.location, default: []].append(operation)
                endingOrders[end, default: []].append(operation.order)
            }
            let sortedBoundaries = boundaries.sorted()
            var active: [Int: Operation] = [:]
            var result: [MarkdownPresentation.Run] = []
            for pair in zip(sortedBoundaries, sortedBoundaries.dropFirst()) where pair.0 < pair.1 {
                for order in endingOrders[pair.0] ?? [] { active.removeValue(forKey: order) }
                for operation in starts[pair.0] ?? [] { active[operation.order] = operation }
                let range = NSRange(location: pair.0, length: pair.1 - pair.0)
                var style = MarkdownPresentation.SemanticStyle()
                for order in active.keys.sorted() {
                    if let operation = active[order] { Self.apply(operation.change, to: &style) }
                }
                if let last = result.last, last.style == style, NSMaxRange(last.range) == range.location {
                    result[result.count - 1] = .init(range: NSUnionRange(last.range, range), style: style)
                } else { result.append(.init(range: range, style: style)) }
            }
            return result
        }

        private static func apply(_ change: Change, to style: inout MarkdownPresentation.SemanticStyle) {
            switch change {
            case let .font(value):
                style.font = value
                style.bold = false
                style.italic = false
            case .bold: style.bold = true
            case .italic: style.italic = true
            case let .foreground(value): style.foreground = value
            case let .paragraph(value): style.paragraph = value
            case let .link(value): style.linkDestination = value
            case .underline: style.underline = true
            case .strike: style.strikethrough = true
            }
        }

        private static func rangeOrder(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
            lhs.location == rhs.location ? lhs.length < rhs.length : lhs.location < rhs.location
        }
    }
}
