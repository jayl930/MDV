import AppKit

final class MarkdownTextView: NSTextView {

    var onTextChange: ((String) -> Void)?
    var onSelectionChange: ((NSRange) -> Void)?

    private var currentTheme: MDVTheme?
    private let horizontalPadding: CGFloat = 32
    private let verticalPadding: CGFloat = 16

    let glyphManager = GlyphManager()

    override var insertionPointColor: NSColor? {
        get { currentTheme?.cursor ?? .systemOrange }
        set {}
    }

    init() {
        let textStorage = NSTextStorage()
        let lm = NSLayoutManager()
        let container = NSTextContainer()

        container.widthTracksTextView = true
        container.heightTracksTextView = false
        lm.addTextContainer(container)
        textStorage.addLayoutManager(lm)

        super.init(frame: .zero, textContainer: container)
        lm.delegate = glyphManager

        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ theme: MDVTheme) {
        currentTheme = theme
        backgroundColor = theme.background
        insertionPointColor = theme.cursor
        selectedTextAttributes = [.backgroundColor: theme.selection]
        needsDisplay = true
    }

    func updateTextContainerInset(for scrollViewWidth: CGFloat) {
        let maxContentWidth = currentTheme?.contentWidth ?? 720
        let totalHorizontal = max(horizontalPadding, (scrollViewWidth - maxContentWidth) / 2)
        textContainerInset = NSSize(width: totalHorizontal, height: verticalPadding)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting {
            onSelectionChange?(charRange)
        }
    }

    // MARK: - Drawing Ranges

    struct BlockQuoteRange {
        let characterRange: NSRange
        let barColor: NSColor
        let backgroundColor: NSColor
    }

    var blockQuoteRanges: [BlockQuoteRange] = []
    var codeBlockRanges: [(range: NSRange, bgColor: NSColor)] = []
    var horizontalRuleRanges: [(range: NSRange, color: NSColor)] = []
    var inlineCodeRanges: [(range: NSRange, bgColor: NSColor)] = []
    // Tables are rendered via NSTextAttachment with TableAttachmentView — no custom drawing needed.

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = layoutManager, textContainer != nil else { return }

        drawCodeBlockBackgrounds(layoutManager: layoutManager, in: rect)
        drawInlineCodeBackgrounds(layoutManager: layoutManager, in: rect)
        drawBlockQuoteBackgrounds(layoutManager: layoutManager, in: rect)
        drawHorizontalRules(layoutManager: layoutManager, in: rect)
    }

    private func drawCodeBlockBackgrounds(layoutManager: NSLayoutManager, in rect: NSRect) {
        for codeBlock in codeBlockRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: codeBlock.range, actualCharacterRange: nil)
            var blockRect = NSRect.zero

            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { (lineRect, _, _, _, _) in
                let adjusted = NSRect(
                    x: lineRect.origin.x + self.textContainerInset.width - 12,
                    y: lineRect.origin.y + self.textContainerInset.height,
                    width: lineRect.width + 24,
                    height: lineRect.height
                )
                if blockRect == .zero {
                    blockRect = adjusted
                } else {
                    blockRect = blockRect.union(adjusted)
                }
            }

            if blockRect != .zero {
                let path = NSBezierPath(roundedRect: blockRect, xRadius: 8, yRadius: 8)
                codeBlock.bgColor.setFill()
                path.fill()
            }
        }
    }

    private func drawBlockQuoteBackgrounds(layoutManager: NSLayoutManager, in rect: NSRect) {
        for quoteRange in blockQuoteRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: quoteRange.characterRange, actualCharacterRange: nil)

            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] (lineRect, _, _, _, _) in
                guard let self = self else { return }

                // Background
                let bgRect = NSRect(
                    x: self.textContainerInset.width - 4,
                    y: lineRect.origin.y + self.textContainerInset.height,
                    width: lineRect.width + 8,
                    height: lineRect.height
                )
                let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
                quoteRange.backgroundColor.setFill()
                bgPath.fill()

                // Left bar
                let barRect = NSRect(
                    x: self.textContainerInset.width - 4,
                    y: lineRect.origin.y + self.textContainerInset.height,
                    width: 3,
                    height: lineRect.height
                )
                quoteRange.barColor.setFill()
                barRect.fill()
            }
        }
    }

    private func drawHorizontalRules(layoutManager: NSLayoutManager, in rect: NSRect) {
        for hr in horizontalRuleRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: hr.range, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] (lineRect, _, _, _, _) in
                guard let self = self else { return }
                let y = lineRect.origin.y + self.textContainerInset.height + lineRect.height / 2
                let lineDrawRect = NSRect(
                    x: self.textContainerInset.width,
                    y: y,
                    width: lineRect.width,
                    height: 1
                )
                hr.color.setFill()
                lineDrawRect.fill()
            }
        }
    }

    private func drawInlineCodeBackgrounds(layoutManager: NSLayoutManager, in rect: NSRect) {
        guard let textContainer = textContainer, let textStorage = textStorage else { return }
        for code in inlineCodeRanges {
            guard code.range.location < textStorage.length else { continue }

            // Use content range (excluding backtick delimiters) to avoid phantom
            // background rects from hidden zero-width backtick glyphs
            var contentRange = code.range
            if contentRange.length >= 2 {
                contentRange = NSRange(location: contentRange.location + 1, length: contentRange.length - 2)
            }
            guard contentRange.length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: contentRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }

            // Get the actual font to compute proper height (not line fragment height)
            let font = textStorage.attribute(.font, at: contentRange.location, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let fontHeight = font.ascender - font.descender + font.leading
            let hPad: CGFloat = 2
            let vPad: CGFloat = 1.5
            let totalGlyphs = layoutManager.numberOfGlyphs

            // Use line fragment enumeration with precise glyph positions instead of
            // enumerateEnclosingRects, which can produce oversized rects when zero-width
            // (hidden) glyphs shift text positions.
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { (lineRect, _, _, effectiveRange, _) in
                // Intersect with the code's glyph range to get only code glyphs on this line
                let overlap = NSIntersectionRange(effectiveRange, glyphRange)
                guard overlap.length > 0 else { return }

                let startPoint = layoutManager.location(forGlyphAt: overlap.location)

                // Compute width using the next glyph's position (gives exact advance-based width)
                let afterGlyph = overlap.location + overlap.length
                var codeWidth: CGFloat
                if afterGlyph < totalGlyphs {
                    let afterPoint = layoutManager.location(forGlyphAt: afterGlyph)
                    // Check the next glyph is on the same line fragment
                    var nextEffective = NSRange()
                    layoutManager.lineFragmentRect(forGlyphAt: afterGlyph, effectiveRange: &nextEffective)
                    if NSIntersectionRange(nextEffective, effectiveRange).length > 0 {
                        codeWidth = afterPoint.x - startPoint.x
                    } else {
                        // Next glyph on different line — use line fragment used rect
                        let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: overlap.location, effectiveRange: nil)
                        codeWidth = usedRect.width - startPoint.x
                    }
                } else {
                    let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: overlap.location, effectiveRange: nil)
                    codeWidth = usedRect.width - startPoint.x
                }

                // Use baseline from glyph location for precise vertical alignment
                let baselineY = lineRect.origin.y + startPoint.y
                let textTop = baselineY - font.ascender
                let adjusted = NSRect(
                    x: lineRect.origin.x + startPoint.x + self.textContainerInset.width - hPad,
                    y: textTop + self.textContainerInset.height - vPad,
                    width: codeWidth + hPad * 2,
                    height: fontHeight + vPad * 2
                )
                let path = NSBezierPath(roundedRect: adjusted, xRadius: 3, yRadius: 3)
                code.bgColor.setFill()
                path.fill()
            }
        }
    }


    // MARK: - Keyboard Shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleWrap(with: "**"); return true
        case "i": toggleWrap(with: "*"); return true
        case "k": insertLink(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func toggleWrap(with marker: String) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let selected = (string as NSString).substring(with: range)
        if selected.hasPrefix(marker) && selected.hasSuffix(marker) && selected.count > marker.count * 2 {
            let start = selected.index(selected.startIndex, offsetBy: marker.count)
            let end = selected.index(selected.endIndex, offsetBy: -marker.count)
            let unwrapped = String(selected[start..<end])
            insertText(unwrapped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: unwrapped.count))
        } else {
            let wrapped = "\(marker)\(selected)\(marker)"
            insertText(wrapped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + marker.count, length: selected.count))
        }
    }

    // MARK: - Table Context Menu

    var onTableModify: ((NSRange, String) -> Void)?  // (tableRange, newTableText)

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)

        if let tableInfo = findTableAtIndex(charIndex) {
            return buildTableMenu(tableInfo: tableInfo, charIndex: charIndex)
        }
        return super.menu(for: event)
    }

    private func findTableAtIndex(_ charIndex: Int) -> TableData? {
        // Table context menu disabled — tables rendered as overlays
        return nil
    }

    private func buildTableMenu(tableInfo: TableData, charIndex: Int) -> NSMenu {
        let menu = NSMenu(title: "Table")
        let rowIndex = TableOperations.findRowIndex(at: charIndex, in: tableInfo) ?? 0

        let addBelow = NSMenuItem(title: "Add Row Below", action: #selector(tableAddRowBelow(_:)), keyEquivalent: "")
        addBelow.representedObject = (tableInfo, rowIndex)
        menu.addItem(addBelow)

        let addAbove = NSMenuItem(title: "Add Row Above", action: #selector(tableAddRowAbove(_:)), keyEquivalent: "")
        addAbove.representedObject = (tableInfo, rowIndex)
        menu.addItem(addAbove)

        if rowIndex > 0 {
            let deleteRow = NSMenuItem(title: "Delete Row", action: #selector(tableDeleteRow(_:)), keyEquivalent: "")
            deleteRow.representedObject = (tableInfo, rowIndex)
            menu.addItem(deleteRow)
        }

        menu.addItem(NSMenuItem.separator())

        let addCol = NSMenuItem(title: "Add Column", action: #selector(tableAddColumn(_:)), keyEquivalent: "")
        addCol.representedObject = tableInfo
        menu.addItem(addCol)

        let delCol = NSMenuItem(title: "Delete Last Column", action: #selector(tableDeleteColumn(_:)), keyEquivalent: "")
        delCol.representedObject = tableInfo
        menu.addItem(delCol)

        if rowIndex > 0 {
            menu.addItem(NSMenuItem.separator())

            let moveUp = NSMenuItem(title: "Move Row Up", action: #selector(tableMoveRowUp(_:)), keyEquivalent: "")
            moveUp.representedObject = (tableInfo, rowIndex)
            menu.addItem(moveUp)

            let moveDown = NSMenuItem(title: "Move Row Down", action: #selector(tableMoveRowDown(_:)), keyEquivalent: "")
            moveDown.representedObject = (tableInfo, rowIndex)
            menu.addItem(moveDown)
        }

        return menu
    }

    @objc private func tableAddRowBelow(_ sender: NSMenuItem) {
        guard let (info, rowIndex) = sender.representedObject as? (TableData, Int) else { return }
        modifyTable(info: info) { TableOperations.addRowBelow(tableText: $0, rowIndex: rowIndex) }
    }

    @objc private func tableAddRowAbove(_ sender: NSMenuItem) {
        guard let (info, rowIndex) = sender.representedObject as? (TableData, Int) else { return }
        modifyTable(info: info) { TableOperations.addRowBelow(tableText: $0, rowIndex: max(0, rowIndex - 1)) }
    }

    @objc private func tableDeleteRow(_ sender: NSMenuItem) {
        guard let (info, rowIndex) = sender.representedObject as? (TableData, Int) else { return }
        modifyTable(info: info) { TableOperations.deleteRow(tableText: $0, rowIndex: rowIndex) }
    }

    @objc private func tableAddColumn(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? TableData else { return }
        modifyTable(info: info) { TableOperations.addColumn(tableText: $0) }
    }

    @objc private func tableDeleteColumn(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? TableData else { return }
        modifyTable(info: info) { TableOperations.deleteLastColumn(tableText: $0) }
    }

    @objc private func tableMoveRowUp(_ sender: NSMenuItem) {
        guard let (info, rowIndex) = sender.representedObject as? (TableData, Int) else { return }
        modifyTable(info: info) { TableOperations.moveRowUp(tableText: $0, rowIndex: rowIndex) }
    }

    @objc private func tableMoveRowDown(_ sender: NSMenuItem) {
        guard let (info, rowIndex) = sender.representedObject as? (TableData, Int) else { return }
        modifyTable(info: info) { TableOperations.moveRowDown(tableText: $0, rowIndex: rowIndex) }
    }

    private func modifyTable(info: TableData, transform: (String) -> String) {
        let nsString = string as NSString
        guard info.sourceRange.location + info.sourceRange.length <= nsString.length else { return }
        let tableText = nsString.substring(with: info.sourceRange)
        let newText = transform(tableText)
        insertText(newText, replacementRange: info.sourceRange)
    }

    private func insertLink() {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : ""
        let link = "[\(selected)](url)"
        insertText(link, replacementRange: range)
        if selected.isEmpty {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location + selected.count + 3, length: 3))
        }
    }
}
