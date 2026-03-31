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

final class InlineRenderer {
    private var lineStartIndices: [String.Index] = []

    func render(text: String, theme: MDVTheme, typography: Typography) -> RenderResult {
        guard !text.isEmpty else {
            let empty = NSAttributedString(string: "", attributes: [
                .font: typography.body,
                .foregroundColor: theme.text,
                .paragraphStyle: typography.bodyParagraphStyle
            ])
            return RenderResult(attributedString: empty, syntaxRanges: [], bulletRanges: [],
                              blockQuoteRanges: [], codeBlockRanges: [], horizontalRuleRanges: [],
                              inlineCodeRanges: [], tables: [], headings: [])
        }

        buildLineStartIndices(for: text)

        let document = Document(parsing: text)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: typography.body,
            .foregroundColor: theme.text,
            .paragraphStyle: typography.bodyParagraphStyle
        ])

        var ctx = RenderContext()

        for child in document.children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography,
                       ctx: &ctx, sourceText: text)
        }

        // Compact empty lines: reduce height of blank lines between blocks
        let nsString = text as NSString
        var scanPos = 0
        while scanPos < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: scanPos, length: 0))
            let lineText = nsString.substring(with: lineRange)
            let stripped = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

            if stripped.isEmpty && lineRange.length > 0 {
                let isInCodeBlock = ctx.codeBlockRanges.contains { codeRange in
                    lineRange.location >= codeRange.location &&
                    NSMaxRange(lineRange) <= NSMaxRange(codeRange)
                }
                if !isInCodeBlock {
                    attributed.addAttribute(.paragraphStyle, value: typography.emptyLineParagraphStyle, range: lineRange)
                }
            }

            let next = NSMaxRange(lineRange)
            if next == scanPos { break }
            scanPos = next
        }

        // No string replacement — attributed string IS the source text with styles applied.
        // Tables are rendered as overlays, not by modifying the string.
        return RenderResult(
            attributedString: attributed,
            syntaxRanges: ctx.syntaxRanges,
            bulletRanges: ctx.bulletRanges,
            blockQuoteRanges: ctx.blockQuoteRanges,
            codeBlockRanges: ctx.codeBlockRanges,
            horizontalRuleRanges: ctx.horizontalRuleRanges,
            inlineCodeRanges: ctx.inlineCodeRanges,
            tables: ctx.tables,
            headings: ctx.headings
        )
    }

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
        let nsString = text as NSString
        var end = range.location + range.length
        while end > range.location && nsString.character(at: end - 1) == 0x0A /* \n */ {
            end -= 1
        }
        return NSRange(location: range.location, length: end - range.location)
    }

    // MARK: - Range Conversion

    private func buildLineStartIndices(for text: String) {
        lineStartIndices = [text.startIndex]
        for i in text.indices where text[i] == "\n" {
            lineStartIndices.append(text.index(after: i))
        }
    }

    private func stringIndex(for location: SourceLocation, in text: String) -> String.Index? {
        let line = location.line - 1
        let col = location.column - 1
        guard line >= 0, line < lineStartIndices.count, col >= 0 else { return nil }
        let lineStart = lineStartIndices[line]
        let utf8View = text.utf8
        guard let lineStartUTF8 = lineStart.samePosition(in: utf8View) else { return nil }
        guard let target = utf8View.index(lineStartUTF8, offsetBy: col, limitedBy: utf8View.endIndex) else { return nil }
        return target
    }

    private func nsRange(from sourceRange: SourceRange, in text: String) -> NSRange? {
        guard let start = stringIndex(for: sourceRange.lowerBound, in: text),
              let end = stringIndex(for: sourceRange.upperBound, in: text),
              start <= end, start >= text.startIndex, end <= text.endIndex
        else { return nil }
        return NSRange(start..<end, in: text)
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
        let syntaxLength = min(heading.level + 1, trimmed.length)
        ctx.syntaxRanges.append(NSRange(location: trimmed.location, length: syntaxLength))

        // Extract heading title for TOC
        let nsString = sourceText as NSString
        let headingText = nsString.substring(with: trimmed)
        let title = String(headingText.drop(while: { $0 == "#" }).drop(while: { $0 == " " }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            ctx.headings.append(ToCEntry(level: heading.level, title: title, range: trimmed))
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
        let fullText = (attributed.string as NSString).substring(with: range)
        if let closeBracket = fullText.firstIndex(of: "]") {
            let textLength = fullText.distance(from: fullText.startIndex, to: closeBracket)
            ctx.syntaxRanges.append(NSRange(location: range.location, length: 1))
            let urlStart = range.location + textLength
            let urlLen = range.length - textLength
            if urlLen > 0 { ctx.syntaxRanges.append(NSRange(location: urlStart, length: urlLen)) }
            let textRange = NSRange(location: range.location + 1, length: max(0, textLength - 1))
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

        let quoteText = (sourceText as NSString).substring(with: trimmed)
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

        // Parse cells from the raw markdown lines
        let tableText = (sourceText as NSString).substring(with: trimmed)
        let lines = tableText.components(separatedBy: "\n")

        var headerCells: [String] = []
        var bodyRows: [[String]] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            if trimmedLine.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            var cells = trimmedLine.components(separatedBy: "|")
            if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
            if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
            let trimmedCells = cells.map { $0.trimmingCharacters(in: .whitespaces) }

            if headerCells.isEmpty {
                headerCells = trimmedCells
            } else {
                bodyRows.append(trimmedCells)
            }
        }

        guard !headerCells.isEmpty else { return }

        ctx.tables.append(TableData(
            sourceRange: trimmed,
            numColumns: headerCells.count,
            headerCells: headerCells,
            bodyRows: bodyRows
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
        let lineText = (sourceText as NSString).substring(with: NSRange(location: range.location, length: maxScan))
        let leading = lineText.prefix(while: { $0 == " " }).count

        if lineText.dropFirst(leading).hasPrefix("- ") || lineText.dropFirst(leading).hasPrefix("* ") || lineText.dropFirst(leading).hasPrefix("+ ") {
            let dashRange = NSRange(location: range.location + leading, length: 1)
            ctx.bulletRanges.append(dashRange)
            // Space after bullet stays visible for proper spacing
        } else {
            let rest = lineText.dropFirst(leading)
            // Ordered list: keep "1. " fully visible (number, dot, and space)

        }

        for child in listItem.children {
            applyMarkup(child, to: attributed, theme: theme, typography: typography,
                       ctx: &ctx, sourceText: sourceText, listDepth: listDepth)
        }
    }
}

private extension UInt16 {
    init(ascii: Character) {
        self = UInt16(ascii.asciiValue!)
    }
}
