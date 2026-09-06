import AppKit
import Markdown

extension NSAttributedString.Key {
    static let syntaxToken = NSAttributedString.Key("mdv.syntaxToken")
    static let bulletMarker = NSAttributedString.Key("mdv.bulletMarker")
}

/// Parsed table data for attachment rendering
struct TableData {
    let sourceRange: NSRange          // Range in source text
    let numColumns: Int
    let headerCells: [String]
    let bodyRows: [[String]]
}

struct RenderResult {
    let attributedString: NSAttributedString
    let syntaxRanges: [NSRange]
    let bulletRanges: [NSRange]
    let blockQuoteRanges: [NSRange]
    let codeBlockRanges: [NSRange]
    let horizontalRuleRanges: [NSRange]
    let inlineCodeRanges: [NSRange]
    let tables: [TableData]
    let headings: [ToCEntry]
}

/// Main-actor adapter from semantic values to AppKit attributes. A palette is
/// cheap to retain for one theme/typography generation and amortizes dictionary
/// and font-trait construction across budgeted run application.
final class MarkdownPresentationPalette {
    private let theme: MDVTheme
    private let typography: Typography
    private var cache: [MarkdownPresentation.SemanticStyle: [NSAttributedString.Key: Any]] = [:]

    init(theme: MDVTheme, typography: Typography) {
        self.theme = theme
        self.typography = typography
    }

    func attributes(for style: MarkdownPresentation.SemanticStyle) -> [NSAttributedString.Key: Any] {
        if let cached = cache[style] { return cached }
        var font: NSFont
        switch style.font {
        case .body: font = typography.body
        case let .heading(level): font = typography.heading(level: level)
        case .code: font = typography.code
        }
        var traits: NSFontTraitMask = []
        if style.bold { traits.insert(.boldFontMask) }
        if style.italic { traits.insert(.italicFontMask) }
        if !traits.isEmpty { font = NSFontManager.shared.convert(font, toHaveTrait: traits) }

        let foreground: NSColor
        switch style.foreground {
        case .text: foreground = theme.text
        case .heading: foreground = theme.headingText
        case .secondary: foreground = theme.secondaryText
        case .code: foreground = theme.codeText
        case .accent: foreground = theme.accent
        case .clear: foreground = .clear
        }
        let paragraph: NSParagraphStyle
        switch style.paragraph {
        case .body: paragraph = typography.bodyParagraphStyle
        case let .heading(level): paragraph = typography.headingParagraphStyle(level: level)
        case .emptyLine: paragraph = typography.emptyLineParagraphStyle
        case .blockQuote: paragraph = typography.blockQuoteParagraphStyle
        case let .list(level): paragraph = typography.listParagraphStyle(level: level)
        case .codeBlock: paragraph = typography.codeBlockParagraphStyle
        }
        var result: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: foreground, .paragraphStyle: paragraph
        ]
        if style.underline {
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            result[.underlineColor] = theme.accent.withAlphaComponent(0.4)
        }
        if style.strikethrough {
            result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            result[.strikethroughColor] = theme.secondaryText
        }
        if let destination = style.linkDestination { result[.link] = destination }
        cache[style] = result
        return result
    }

    func materialize(presentation: MarkdownPresentation) -> RenderResult {
        let attributed = NSMutableAttributedString(string: presentation.source)
        for run in presentation.runs {
            attributed.setAttributes(attributes(for: run.style), range: run.range)
        }
        let metadata = presentation.metadata
        return RenderResult(
            attributedString: attributed,
            syntaxRanges: metadata.syntaxRanges,
            bulletRanges: metadata.bulletRanges,
            blockQuoteRanges: metadata.blockQuoteRanges,
            codeBlockRanges: metadata.codeBlockRanges,
            horizontalRuleRanges: metadata.horizontalRuleRanges,
            inlineCodeRanges: metadata.inlineCodeRanges,
            tables: metadata.tables.map {
                TableData(sourceRange: $0.sourceRange, numColumns: $0.numColumns, headerCells: $0.headerCells, bodyRows: $0.bodyRows)
            },
            headings: metadata.headings.map { ToCEntry(level: $0.level, title: $0.title, range: $0.range) }
        )
    }
}

final class InlineRenderer {
#if MDV_SEMANTIC_DIFFERENTIAL
    private var lineStartUTF8Offsets: [Int] = []
    private var unicodeCorrectionEnds: [Int] = []
    private var unicodeCumulativeReductions: [Int] = []
    private var sourceUTF8: [UInt8] = []
    private var sourceNSString = "" as NSString
#endif

    func render(text: String, theme: MDVTheme, typography: Typography) -> RenderResult {
        MarkdownPresentationPalette(theme: theme, typography: typography)
            .materialize(presentation: MarkdownPresentationParser.parse(text: text))
    }

#if MDV_SEMANTIC_DIFFERENTIAL
    /// Test-only reference path retained while the semantic seam is validated.
    /// Production builds have exactly one Markdown grammar traversal.
    func renderLegacyForDifferential(text: String, theme: MDVTheme, typography: Typography) -> RenderResult {
        guard !text.isEmpty else {
            let empty = NSAttributedString(string: "", attributes: [
                .font: typography.body, .foregroundColor: theme.text,
                .paragraphStyle: typography.bodyParagraphStyle
            ])
            return RenderResult(attributedString: empty, syntaxRanges: [], bulletRanges: [],
                                blockQuoteRanges: [], codeBlockRanges: [], horizontalRuleRanges: [],
                                inlineCodeRanges: [], tables: [], headings: [])
        }
        sourceNSString = text as NSString
        buildSourceOffsetIndex(for: text)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: typography.body, .foregroundColor: theme.text,
            .paragraphStyle: typography.bodyParagraphStyle
        ])
        var ctx = RenderContext()
        for child in Document(parsing: text).children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography, ctx: &ctx, sourceText: text)
        }
        let sortedCode = ctx.codeBlockRanges.sorted { $0.location < $1.location }
        var codeIndex = 0, scanPosition = 0
        while scanPosition < sourceNSString.length {
            let line = sourceNSString.lineRange(for: NSRange(location: scanPosition, length: 0))
            let stripped = sourceNSString.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            while codeIndex < sortedCode.count, NSMaxRange(sortedCode[codeIndex]) <= line.location { codeIndex += 1 }
            let inCode = codeIndex < sortedCode.count && line.location >= sortedCode[codeIndex].location && NSMaxRange(line) <= NSMaxRange(sortedCode[codeIndex])
            if stripped.isEmpty && line.length > 0 && !inCode {
                attributed.addAttribute(.paragraphStyle, value: typography.emptyLineParagraphStyle, range: line)
            }
            let next = NSMaxRange(line); if next <= scanPosition { break }; scanPosition = next
        }
        return RenderResult(
            attributedString: attributed, syntaxRanges: ctx.syntaxRanges, bulletRanges: ctx.bulletRanges,
            blockQuoteRanges: ctx.blockQuoteRanges, codeBlockRanges: ctx.codeBlockRanges,
            horizontalRuleRanges: ctx.horizontalRuleRanges, inlineCodeRanges: ctx.inlineCodeRanges,
            tables: ctx.tables, headings: ctx.headings
        )
    }
#endif

#if MDV_SEMANTIC_DIFFERENTIAL
    // MARK: - Context

    private struct RenderContext {
        var syntaxRanges: [NSRange] = []
        var bulletRanges: [NSRange] = []
        var blockQuoteRanges: [NSRange] = []
        var codeBlockRanges: [NSRange] = []
        var horizontalRuleRanges: [NSRange] = []
        var inlineCodeRanges: [NSRange] = []
        var tables: [TableData] = []
        var headings: [ToCEntry] = []
    }

    // MARK: - Range Helpers

    /// Strips trailing newlines from a range so empty lines after block elements
    /// don't inherit their styling (blockquote bg/bar, code block bg, etc.)
    private func trimmedRange(_ range: NSRange, in text: String) -> NSRange {
        let nsString = sourceNSString
        var end = range.location + range.length
        while end > range.location && nsString.character(at: end - 1) == 0x0A /* \n */ {
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    // MARK: - Range Conversion

    private func buildSourceOffsetIndex(for text: String) {
        let bytes = Array(text.utf8)
        var utf8LineStarts = [0]
        var correctionEnds: [Int] = []
        var cumulativeReductions: [Int] = []
        var utf8Offset = 0
        var reduction = 0

        while utf8Offset < bytes.count {
            let firstByte = bytes[utf8Offset]
            if firstByte < 0x80 {
                utf8Offset += 1
                if firstByte == 0x0A ||
                    (firstByte == 0x0D && (utf8Offset == bytes.count || bytes[utf8Offset] != 0x0A)) {
                    utf8LineStarts.append(utf8Offset)
                }
            } else if firstByte < 0xE0 {
                utf8Offset += 2
                reduction += 1
                correctionEnds.append(utf8Offset)
                cumulativeReductions.append(reduction)
            } else if firstByte < 0xF0 {
                utf8Offset += 3
                reduction += 2
                correctionEnds.append(utf8Offset)
                cumulativeReductions.append(reduction)
            } else {
                utf8Offset += 4
                reduction += 2
                correctionEnds.append(utf8Offset)
                cumulativeReductions.append(reduction)
            }
        }
        sourceUTF8 = bytes
        lineStartUTF8Offsets = utf8LineStarts
        unicodeCorrectionEnds = correctionEnds
        unicodeCumulativeReductions = cumulativeReductions
    }

    private func utf16Offset(for location: SourceLocation) -> Int? {
        let line = location.line - 1
        let col = location.column - 1
        guard line >= 0, line < lineStartUTF8Offsets.count, col >= 0 else { return nil }
        let lineStart = lineStartUTF8Offsets[line]
        let target = lineStart + col
        guard target <= sourceUTF8.count else { return nil }

        // A source location must fall on a Unicode-scalar boundary.
        if target < sourceUTF8.count, sourceUTF8[target] & 0xC0 == 0x80 {
            return nil
        }

        var low = 0
        var high = unicodeCorrectionEnds.count
        while low < high {
            let mid = low + (high - low) / 2
            if unicodeCorrectionEnds[mid] <= target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let reduction = low > 0 ? unicodeCumulativeReductions[low - 1] : 0
        return target - reduction
    }

    private func nsRange(from sourceRange: SourceRange, in text: String) -> NSRange? {
        guard let start = utf16Offset(for: sourceRange.lowerBound),
              let end = utf16Offset(for: sourceRange.upperBound),
              start <= end
        else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Visitor

    private func applyMarkup(
        _ markup: any Markup,
        to attributed: NSMutableAttributedString,
        theme: MDVTheme,
        typography: Typography,
        ctx: inout RenderContext,
        sourceText: String,
        listDepth: Int = 0
    ) {
        let range = markup.range.flatMap { nsRange(from: $0, in: sourceText) }

        switch markup {
        case let heading as Heading:
            applyHeading(heading, range: range, to: attributed, theme: theme, typography: typography,
                        ctx: &ctx, sourceText: sourceText)

        case let strong as Strong:
            applyInlineMarker(strong, range: range, to: attributed, theme: theme, typography: typography,
                             ctx: &ctx, sourceText: sourceText, listDepth: listDepth, markerLength: 2) { attr, r in
                attr.enumerateAttribute(.font, in: r) { value, subRange, _ in
                    if let font = value as? NSFont {
                        attr.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: subRange)
                    }
                }
            }

        case let emphasis as Emphasis:
            applyInlineMarker(emphasis, range: range, to: attributed, theme: theme, typography: typography,
                             ctx: &ctx, sourceText: sourceText, listDepth: listDepth, markerLength: 1) { attr, r in
                attr.enumerateAttribute(.font, in: r) { value, subRange, _ in
                    if let font = value as? NSFont {
                        attr.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: subRange)
                    }
                }
            }

        case let inlineCode as InlineCode:
            applyInlineCode(inlineCode, range: range, to: attributed, theme: theme, typography: typography, ctx: &ctx)

        case is CodeBlock:
            if let range = range {
                let trimmed = trimmedRange(range, in: sourceText)
                attributed.addAttributes([
                    .font: typography.code,
                    .foregroundColor: theme.codeText,
                    .paragraphStyle: typography.codeBlockParagraphStyle
                ], range: trimmed)
                ctx.codeBlockRanges.append(trimmed)
                ctx.syntaxRanges.append(contentsOf: fencedCodeSyntaxRanges(in: trimmed, sourceText: sourceText))
            }

        case let link as Link:
            applyLink(link, range: range, to: attributed, theme: theme, typography: typography,
                     ctx: &ctx, sourceText: sourceText, listDepth: listDepth)

        case let blockQuote as BlockQuote:
            applyBlockQuote(blockQuote, range: range, to: attributed, theme: theme, typography: typography,
                           ctx: &ctx, sourceText: sourceText)

        case is ThematicBreak:
            if let range = range {
                // Make the --- text invisible, we'll draw a line in drawBackground
                attributed.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                ctx.horizontalRuleRanges.append(range)
            }

        case let table as Table:
            applyTable(table, range: range, to: attributed, theme: theme, typography: typography,
                      ctx: &ctx, sourceText: sourceText)

        case let listItem as ListItem:
            applyListItem(listItem, range: range, to: attributed, theme: theme, typography: typography,
                         ctx: &ctx, sourceText: sourceText, listDepth: listDepth)

        case is OrderedList:
            for child in markup.children {
                applyMarkup(child, to: attributed, theme: theme, typography: typography,
                           ctx: &ctx, sourceText: sourceText, listDepth: listDepth + 1)
            }

        case is UnorderedList:
            for child in markup.children {
                applyMarkup(child, to: attributed, theme: theme, typography: typography,
                           ctx: &ctx, sourceText: sourceText, listDepth: listDepth + 1)
            }

        case let strikethrough as Strikethrough:
            if let range = range {
                // Recurse into children first so inner formatting is applied
                for child in strikethrough.children {
                    applyMarkup(child, to: attributed, theme: theme, typography: typography,
                               ctx: &ctx, sourceText: sourceText, listDepth: listDepth)
                }
                // Then apply strikethrough on top
                attributed.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: theme.secondaryText,
                    .foregroundColor: theme.secondaryText
                ], range: range)
                if range.length >= 4 {
                    ctx.syntaxRanges.append(NSRange(location: range.location, length: 2))
                    ctx.syntaxRanges.append(NSRange(location: range.location + range.length - 2, length: 2))
                }
            }

        default:
            for child in markup.children {
                applyMarkup(child, to: attributed, theme: theme, typography: typography,
                           ctx: &ctx, sourceText: sourceText, listDepth: listDepth)
            }
        }
    }

    // MARK: - Element Handlers

    /// The AST decides whether this span is a code block. Within that authoritative
    /// span, identify only its concrete fence lines so code containing fence-like
    /// text is never treated as syntax.
    private func fencedCodeSyntaxRanges(in range: NSRange, sourceText: String) -> [NSRange] {
        let source = sourceNSString
        guard range.length > 0, NSMaxRange(range) <= source.length else { return [] }

        let firstLine = source.lineRange(for: NSRange(location: range.location, length: 0))
        let openerContent = source.substring(with: firstLine)
            .trimmingCharacters(in: .newlines) as NSString
        var indent = 0
        while indent < min(3, openerContent.length), openerContent.character(at: indent) == 0x20 {
            indent += 1
        }
        guard indent < openerContent.length else { return [] }
        let marker = openerContent.character(at: indent)
        guard marker == 0x60 || marker == 0x7E else { return [] } // ` or ~
        var openerFenceLength = 0
        while indent + openerFenceLength < openerContent.length,
              openerContent.character(at: indent + openerFenceLength) == marker {
            openerFenceLength += 1
        }
        guard openerFenceLength >= 3 else { return [] }

        // Hide the delimiter and the complete info string, retaining indentation
        // and the newline that gives the code body its own line.
        var result = [NSRange(
            location: firstLine.location + indent,
            length: openerContent.length - indent
        )]

        var lineLocation = NSMaxRange(firstLine)
        var closingRange: NSRange?
        while lineLocation < NSMaxRange(range) {
            let lineRange = source.lineRange(for: NSRange(location: lineLocation, length: 0))
            let bounded = NSIntersectionRange(lineRange, range)
            guard bounded.length > 0 else { break }
            let line = source.substring(with: bounded).trimmingCharacters(in: .newlines) as NSString
            var closingIndent = 0
            while closingIndent < min(3, line.length), line.character(at: closingIndent) == 0x20 {
                closingIndent += 1
            }
            var closingLength = 0
            while closingIndent + closingLength < line.length,
                  line.character(at: closingIndent + closingLength) == marker {
                closingLength += 1
            }
            if closingLength >= openerFenceLength {
                let remainder = line.substring(from: closingIndent + closingLength)
                if remainder.trimmingCharacters(in: .whitespaces).isEmpty {
                    closingRange = NSRange(
                        location: bounded.location + closingIndent,
                        length: line.length - closingIndent
                    )
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= lineLocation { break }
            lineLocation = next
        }
        if let closingRange { result.append(closingRange) }
        return result
    }

    private func applyHeading(
        _ heading: Heading, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext, sourceText: String
    ) {
        guard let range = range else { return }
        let trimmed = trimmedRange(range, in: sourceText)
        attributed.addAttributes([
            .font: typography.heading(level: heading.level),
            .foregroundColor: theme.headingText,
            .paragraphStyle: typography.headingParagraphStyle(level: heading.level)
        ], range: trimmed)
        // ATX headings have a leading `### ` marker. Setext headings (`Title\n===`)
        // do not; their marker is the underline on the final line.
        let headingSource = sourceNSString.substring(with: trimmed) as NSString
        if headingSource.hasPrefix("#") {
            var markerLength = 0
            while markerLength < headingSource.length,
                  headingSource.character(at: markerLength) == 0x23 { markerLength += 1 }
            if markerLength < headingSource.length,
               headingSource.character(at: markerLength) == 0x20 { markerLength += 1 }
            if markerLength > 0 {
                ctx.syntaxRanges.append(NSRange(location: trimmed.location, length: markerLength))
            }
        } else {
            let newline = headingSource.range(of: "\n", options: .backwards)
            if newline.location != NSNotFound {
            ctx.syntaxRanges.append(NSRange(
                location: trimmed.location + newline.location + newline.length,
                length: trimmed.length - newline.location - newline.length
            ))
            }
        }

        // Extract heading title for TOC
        let rawHeading = headingSource as String
        let titleLine = rawHeading.components(separatedBy: "\n").first ?? rawHeading
        let title = String(titleLine.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            ctx.headings.append(ToCEntry(level: heading.level, title: title, range: trimmed))
        }
        for child in heading.children {
            applyMarkup(
                child,
                to: attributed,
                theme: theme,
                typography: typography,
                ctx: &ctx,
                sourceText: sourceText
            )
        }
    }

    private func applyInlineMarker(
        _ markup: any Markup, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext, sourceText: String, listDepth: Int,
        markerLength: Int, applyStyle: (NSMutableAttributedString, NSRange) -> Void
    ) {
        guard let range = range else { return }
        applyStyle(attributed, range)
        if range.length >= markerLength * 2 {
            ctx.syntaxRanges.append(NSRange(location: range.location, length: markerLength))
            ctx.syntaxRanges.append(NSRange(location: range.location + range.length - markerLength, length: markerLength))
        }
        for child in markup.children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography,
                       ctx: &ctx, sourceText: sourceText, listDepth: listDepth)
        }
    }

    private func applyInlineCode(
        _ inlineCode: InlineCode, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext
    ) {
        guard let range = range else { return }
        attributed.addAttributes([
            .font: typography.code,
            .foregroundColor: theme.codeText
        ], range: range)
        // Track for custom background drawing (not using .backgroundColor which bleeds)
        ctx.inlineCodeRanges.append(range)
        if range.length >= 2 {
            ctx.syntaxRanges.append(NSRange(location: range.location, length: 1))
            ctx.syntaxRanges.append(NSRange(location: range.location + range.length - 1, length: 1))
        }
    }

    private func applyLink(
        _ link: Link, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext, sourceText: String, listDepth: Int
    ) {
        guard let range = range else { return }
        for child in link.children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography,
                       ctx: &ctx, sourceText: sourceText, listDepth: listDepth)
        }
        // Child source ranges are already converted to UTF-16 and remain correct
        // for CJK, emoji, and escaped `]` characters in labels.
        let childRanges = link.children.compactMap { child in
            child.range.flatMap { nsRange(from: $0, in: sourceText) }
        }
        if let first = childRanges.first, let last = childRanges.last {
            let textRange = NSUnionRange(first, last)
            let prefixLength = textRange.location - range.location
            let suffixStart = NSMaxRange(textRange)
            if prefixLength > 0 {
                ctx.syntaxRanges.append(NSRange(location: range.location, length: prefixLength))
            }
            if suffixStart < NSMaxRange(range) {
                ctx.syntaxRanges.append(NSRange(location: suffixStart, length: NSMaxRange(range) - suffixStart))
            }
            if textRange.length > 0 {
                attributed.addAttributes([
                    .foregroundColor: theme.accent,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: theme.accent.withAlphaComponent(0.4)
                ], range: textRange)
                if let dest = link.destination { attributed.addAttribute(.link, value: dest, range: textRange) }
            }
        }
    }

    private func applyBlockQuote(
        _ blockQuote: BlockQuote, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext, sourceText: String
    ) {
        guard let range = range else { return }
        let trimmed = trimmedRange(range, in: sourceText)
        attributed.addAttributes([
            .paragraphStyle: typography.blockQuoteParagraphStyle,
            .foregroundColor: theme.secondaryText
        ], range: trimmed)
        ctx.blockQuoteRanges.append(trimmed)

        let quoteText = sourceNSString.substring(with: trimmed)
        var offset = 0
        for line in quoteText.components(separatedBy: "\n") {
            if line.isEmpty { offset += 1; continue }
            let stripped = line.drop(while: { $0 == " " })
            if stripped.hasPrefix(">") {
                let prefixOffset = line.count - stripped.count
                let syntaxLen = stripped.count > 1 && stripped.dropFirst().first == " " ? 2 : 1
                let syntaxRange = NSRange(location: trimmed.location + offset + prefixOffset, length: syntaxLen)
                if syntaxRange.location + syntaxRange.length <= trimmed.location + trimmed.length {
                    ctx.syntaxRanges.append(syntaxRange)
                }
            }
            offset += line.count + 1
        }
        for child in blockQuote.children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography,
                       ctx: &ctx, sourceText: sourceText)
        }
    }

    private func applyTable(
        _ table: Table, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext, sourceText: String
    ) {
        guard let range = range else { return }
        let trimmed = trimmedRange(range, in: sourceText)

        // Table source text will be replaced with an NSTextAttachment by the Coordinator.
        // Style it with code font so it has a consistent look if briefly visible.

        let tableText = sourceNSString.substring(with: trimmed)
        guard let model = MarkdownTable(markdown: tableText), !model.header.isEmpty else { return }

        ctx.tables.append(TableData(
            sourceRange: trimmed,
            numColumns: model.columnCount,
            headerCells: model.header,
            bodyRows: model.body
        ))
    }

    private func applyListItem(
        _ listItem: ListItem, range: NSRange?,
        to attributed: NSMutableAttributedString, theme: MDVTheme, typography: Typography,
        ctx: inout RenderContext, sourceText: String, listDepth: Int
    ) {
        guard let range = range else { return }
        attributed.addAttribute(.paragraphStyle, value: typography.listParagraphStyle(level: listDepth - 1), range: range)

        let maxScan = min(10, range.length)
        let lineText = sourceNSString.substring(with: NSRange(location: range.location, length: maxScan))
        let leading = lineText.prefix(while: { $0 == " " }).count

        if lineText.dropFirst(leading).hasPrefix("- ") || lineText.dropFirst(leading).hasPrefix("* ") || lineText.dropFirst(leading).hasPrefix("+ ") {
            let dashRange = NSRange(location: range.location + leading, length: 1)
            ctx.bulletRanges.append(dashRange)
            // Space after bullet stays visible for proper spacing
        } else {
            // Ordered list: keep "1. " fully visible (number, dot, and space)

        }

        for child in listItem.children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography,
                       ctx: &ctx, sourceText: sourceText, listDepth: listDepth)
        }
    }
#endif
}

#if MDV_SEMANTIC_DIFFERENTIAL
private extension UInt16 {
    init(ascii: Character) {
        self = UInt16(ascii.asciiValue!)
    }
}
#endif
