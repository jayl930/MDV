import AppKit

extension NSAttributedString.Key {
    static let previewHorizontalRule = NSAttributedString.Key("mdv.previewHorizontalRule")
}

/// Produces the read-only representation used by Quick Look from the same parse
/// and styling result as the editor.
final class MarkdownPreviewRenderer {
    private let inlineRenderer = InlineRenderer()

    func render(text: String, theme: MDVTheme, typography: Typography) -> NSAttributedString {
        let result = inlineRenderer.render(text: text, theme: theme, typography: typography)
        let output = NSMutableAttributedString(attributedString: result.attributedString)

        applyBackground(theme.codeBackground, to: result.codeBlockRanges, in: output)
        applyBackground(theme.codeBackground, to: result.inlineCodeRanges, in: output)
        applyBackground(theme.blockQuoteBackground, to: result.blockQuoteRanges, in: output)

        enum Replacement {
            case text(NSAttributedString)
            case delete
        }

        let source = text as NSString
        var replacements: [(NSRange, Replacement)] = result.tables.map {
            let markdown = source.substring(with: $0.sourceRange)
            let model = MarkdownTable(markdown: markdown)
            return ($0.sourceRange, .text(tableString(for: $0, model: model, theme: theme, typography: typography)))
        }
        let tableRanges = result.tables.map(\.sourceRange)

        for range in result.bulletRanges where !tableRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
            let attributes = output.attributes(at: range.location, effectiveRange: nil)
            replacements.append((range, .text(NSAttributedString(string: "•", attributes: attributes))))
        }

        let syntaxRanges = result.syntaxRanges + codeFenceRanges(in: text, codeBlocks: result.codeBlockRanges)
        let deletions = Self.mergedRanges(syntaxRanges.filter { syntaxRange in
            !tableRanges.contains { NSIntersectionRange($0, syntaxRange).length > 0 }
        })
        replacements.append(contentsOf: deletions.map { ($0, .delete) })

        for range in result.horizontalRuleRanges where !tableRanges.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
            let attachment = NSTextAttachment()
            attachment.attachmentCell = PreviewHorizontalRuleCell(color: theme.divider)
            let value = NSMutableAttributedString(attachment: attachment)
            value.addAttribute(.previewHorizontalRule, value: true, range: NSRange(location: 0, length: value.length))
            value.append(NSAttributedString(string: "\n"))
            replacements.append((range, .text(value)))
        }

        for (range, replacement) in replacements.sorted(by: { $0.0.location > $1.0.location }) {
            guard range.location >= 0, NSMaxRange(range) <= output.length else { continue }
            switch replacement {
            case .text(let value): output.replaceCharacters(in: range, with: value)
            case .delete: output.deleteCharacters(in: range)
            }
        }

        return output
    }

    static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        guard var current = sorted.first else { return [] }
        var merged: [NSRange] = []
        for range in sorted.dropFirst() {
            if range.location <= NSMaxRange(current) {
                current.length = max(NSMaxRange(current), NSMaxRange(range)) - current.location
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)
        return merged
    }

    private func applyBackground(_ color: NSColor, to ranges: [NSRange], in output: NSMutableAttributedString) {
        for range in ranges where range.location >= 0 && NSMaxRange(range) <= output.length {
            output.addAttribute(.backgroundColor, value: color, range: range)
        }
    }

    private func codeFenceRanges(in text: String, codeBlocks: [NSRange]) -> [NSRange] {
        let source = text as NSString
        return codeBlocks.flatMap { range -> [NSRange] in
            guard range.location >= 0, NSMaxRange(range) <= source.length else { return [] }
            let block = source.substring(with: range) as NSString
            let firstLine = block.lineRange(for: NSRange(location: 0, length: 0))
            let openingText = block.substring(with: firstLine).trimmingCharacters(in: .newlines)
            guard let opening = Self.fence(in: openingText, permitsInfo: true) else { return [] }
            var ranges = [NSRange(location: range.location, length: firstLine.length)]
            let trimmedLength = block.length - (block.hasSuffix("\n") ? 1 : 0)
            if trimmedLength > firstLine.length {
                let lastLine = block.lineRange(for: NSRange(location: max(0, trimmedLength - 1), length: 0))
                let lastText = block.substring(with: lastLine).trimmingCharacters(in: .newlines)
                if let closing = Self.fence(in: lastText, permitsInfo: false),
                   closing.marker == opening.marker, closing.length >= opening.length {
                    ranges.append(NSRange(location: range.location + lastLine.location, length: lastLine.length))
                }
            }
            return ranges
        }
    }

    private static func fence(in line: String, permitsInfo: Bool) -> (marker: Character, length: Int)? {
        let indentation = line.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return nil }
        let content = line.dropFirst(indentation)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let count = content.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let suffix = content.dropFirst(count)
        guard permitsInfo || suffix.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        return (marker, count)
    }

    private func tableString(
        for data: TableData,
        model: MarkdownTable?,
        theme: MDVTheme,
        typography: Typography
    ) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = max(1, data.numColumns)
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)

        let rows = [data.headerCells] + data.bodyRows
        let rendered = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<table.numberOfColumns {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1
                )
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setWidth(7, type: .absoluteValueType, for: .padding)
                block.setBorderColor(theme.tableBorder)
                if rowIndex == 0 { block.backgroundColor = theme.tableHeaderBackground }

                let cell = row.indices.contains(columnIndex) ? row[columnIndex] : ""
                let cellResult = inlineRenderer.render(text: cell, theme: theme, typography: typography)
                let cellText = NSMutableAttributedString(attributedString: cellResult.attributedString)
                for range in Self.mergedRanges(cellResult.syntaxRanges).reversed()
                    where NSMaxRange(range) <= cellText.length {
                    cellText.deleteCharacters(in: range)
                }
                if rowIndex == 0, cellText.length > 0 {
                    cellText.addAttribute(.font, value: typography.bodyBold, range: NSRange(location: 0, length: cellText.length))
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                if let model, model.alignments.indices.contains(columnIndex) {
                    switch model.alignments[columnIndex] {
                    case .none, .left: paragraph.alignment = .left
                    case .center: paragraph.alignment = .center
                    case .right: paragraph.alignment = .right
                    }
                }
                cellText.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cellText.length))
                rendered.append(cellText)
                rendered.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: paragraph]))
            }
        }
        return rendered
    }

}

private final class PreviewHorizontalRuleCell: NSTextAttachmentCell {
    private let color: NSColor
    private var lastWidth: CGFloat = 600

    init(color: NSColor) {
        self.color = color
        super.init()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override func cellSize() -> NSSize {
        MainActor.assumeIsolated {
            NSSize(width: lastWidth, height: 12)
        }
    }

    nonisolated override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -3)
    }

    nonisolated override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        MainActor.assumeIsolated {
            lastWidth = lineFrag.width
            return NSRect(x: 0, y: 0, width: lineFrag.width, height: 12)
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        color.setFill()
        NSRect(x: cellFrame.minX, y: floor(cellFrame.midY), width: cellFrame.width, height: 1).fill()
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex charIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        draw(withFrame: cellFrame, in: controlView)
    }
}
