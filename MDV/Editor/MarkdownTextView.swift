import AppKit

final class MarkdownTextView: NSTextView {

    var onTextChange: (() -> Void)?
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
        lm.allowsNonContiguousLayout = true
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

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let scrollView = enclosingScrollView {
            updateTextContainerInset(for: scrollView.frame.width)
        }
    }

    func updateTextContainerInset(for scrollViewWidth: CGFloat) {
        let maxContentWidth = currentTheme?.contentWidth ?? 720
        let totalHorizontal = max(horizontalPadding, (scrollViewWidth - maxContentWidth) / 2)
        let newInset = NSSize(width: totalHorizontal, height: verticalPadding)
        // Skip if inset barely changed — avoids expensive layout recalc during sidebar animation
        guard abs(textContainerInset.width - newInset.width) > 1
           || abs(textContainerInset.height - newInset.height) > 1 else { return }
        textContainerInset = newInset
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?()
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting {
            onSelectionChange?(charRange)
        }
    }

    // MARK: - Cursor Drawing

    // Tracks where we actually drew the cursor so blink erase covers it.
    private var cursorDrawnRect: NSRect = .zero

    // Expand blink invalidation to include our corrected cursor area.
    // NSTextView's blink timer only invalidates its internal cached rect,
    // which doesn't match our corrected position. Without this, the erase
    // phase never redraws where we actually drew the cursor.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if cursorDrawnRect != .zero {
            super.setNeedsDisplay(invalidRect.union(cursorDrawnRect))
        } else {
            super.setNeedsDisplay(invalidRect)
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        let correctedRect = correctedInsertionRect(fallback: rect)
        cursorDrawnRect = correctedRect
        if flag {
            color.set()
            correctedRect.fill()
        }
        // Erase (flag=false): do nothing — background+text redraw covers the
        // area because setNeedsDisplay expanded the dirty rect to include it.
    }

    private func correctedInsertionRect(fallback rect: NSRect) -> NSRect {
        let sel = selectedRange()
        guard sel.length == 0,
              let lm = layoutManager,
              let tc = textContainer,
              (textStorage?.length ?? 0) > 0 else { return rect }

        let textLen = textStorage?.length ?? 0
        let atEndOfDoc = sel.location >= textLen
        let safeCharIdx = min(sel.location, max(0, textLen - 1))
        let atNewline = atEndOfDoc && textLen > 0 &&
            (textStorage?.string as NSString?)?.character(at: safeCharIdx) == 0x0A

        if atNewline {
            let extraFrag = lm.extraLineFragmentRect
            return NSRect(
                x: extraFrag.origin.x + textContainerInset.width,
                y: extraFrag.origin.y + textContainerInset.height,
                width: rect.width,
                height: max(extraFrag.height, rect.height)
            )
        }

        let gi = lm.glyphIndexForCharacter(at: safeCharIdx)
        let frag = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
        let loc = lm.location(forGlyphAt: gi)
        var x = frag.origin.x + loc.x + textContainerInset.width
        if atEndOfDoc {
            let glyphBounds = lm.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: tc)
            x = glyphBounds.maxX + textContainerInset.width
        }
        return NSRect(
            x: x,
            y: frag.origin.y + textContainerInset.height,
            width: rect.width,
            height: frag.height
        )
    }

    // MARK: - Drawing Ranges

    struct BlockQuoteRange {
        let characterRange: NSRange
        let backgroundColor: NSColor
    }

    var blockQuoteRanges: [BlockQuoteRange] = []
    var codeBlockRanges: [(range: NSRange, bgColor: NSColor)] = []
    var horizontalRuleRanges: [(range: NSRange, color: NSColor)] = []
    var inlineCodeRanges: [(range: NSRange, bgColor: NSColor)] = []
    // Tables are rendered via NSTextAttachment with TableAttachmentView — no custom drawing needed.

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return }

        // Converting an offscreen character range to glyphs can make TextKit lay
        // out everything leading up to it. Resolve the dirty viewport once, then
        // reject decorations by their cheap character ranges before touching glyphs.
        let containerRect = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let dirtyGlyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        guard dirtyGlyphRange.length > 0 else { return }
        let dirtyCharacterRange = layoutManager.characterRange(
            forGlyphRange: dirtyGlyphRange,
            actualGlyphRange: nil
        )

        drawCodeBlockBackgrounds(layoutManager: layoutManager, visibleRange: dirtyCharacterRange)
        drawInlineCodeBackgrounds(layoutManager: layoutManager, visibleRange: dirtyCharacterRange)
        drawBlockQuoteBackgrounds(layoutManager: layoutManager, visibleRange: dirtyCharacterRange)
        drawHorizontalRules(layoutManager: layoutManager, visibleRange: dirtyCharacterRange)
    }

    private func drawCodeBlockBackgrounds(layoutManager: NSLayoutManager, visibleRange: NSRange) {
        for codeBlock in codeBlockRanges {
            let characterRange = NSIntersectionRange(codeBlock.range, visibleRange)
            guard characterRange.length > 0 else { continue }
            if var blockRect = blockSurfaceRect(
                for: characterRange,
                layoutManager: layoutManager,
                horizontalPadding: 0
            ) {
                // Put rounded ends outside the clip when this dirty slice is in
                // the middle of a block, preserving a continuous background.
                if characterRange.location > codeBlock.range.location {
                    blockRect.origin.y -= 8
                    blockRect.size.height += 8
                }
                if NSMaxRange(characterRange) < NSMaxRange(codeBlock.range) {
                    blockRect.size.height += 8
                }
                let path = NSBezierPath(roundedRect: blockRect, xRadius: 8, yRadius: 8)
                codeBlock.bgColor.setFill()
                path.fill()
            }
        }
    }

    private func drawBlockQuoteBackgrounds(layoutManager: NSLayoutManager, visibleRange: NSRange) {
        for (index, quoteRange) in blockQuoteRanges.enumerated() {
            let characterRange = NSIntersectionRange(quoteRange.characterRange, visibleRange)
            guard characterRange.length > 0 else { continue }
            let nestingDepth = blockQuoteRanges[..<index].reduce(into: 0) { depth, candidate in
                if candidate.characterRange.location <= quoteRange.characterRange.location,
                   NSMaxRange(candidate.characterRange) >= NSMaxRange(quoteRange.characterRange),
                   candidate.characterRange != quoteRange.characterRange {
                    depth += 1
                }
            }
            // Nesting is already communicated by paragraph indentation. A second
            // box creates a false shared edge when the nested quote ends last.
            guard nestingDepth == 0 else { continue }
            if var bgRect = blockSurfaceRect(
                for: characterRange,
                layoutManager: layoutManager,
                horizontalPadding: 0
            ) {
                // Keep clipped portions continuous without asking TextKit to lay
                // out either end of an offscreen quotation.
                if characterRange.location > quoteRange.characterRange.location {
                    bgRect.origin.y -= 8
                    bgRect.size.height += 8
                }
                if NSMaxRange(characterRange) < NSMaxRange(quoteRange.characterRange) {
                    bgRect.size.height += 8
                }
                let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 8, yRadius: 8)
                quoteRange.backgroundColor.setFill()
                bgPath.fill()
            }
        }
    }

    /// Returns one restrained surface for a block. Vertical edges are derived
    /// from baselines and font metrics, not paragraph-spacing-heavy fragment
    /// rectangles, so the first and last lines receive equal visual padding.
    /// The caller must pass a viewport-clipped range.
    func blockSurfaceRect(
        for characterRange: NSRange,
        layoutManager: NSLayoutManager,
        horizontalPadding: CGFloat
    ) -> NSRect? {
        guard let storage = textStorage, characterRange.length > 0 else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else { return nil }

        var horizontalBounds = NSRect.null
        var typographicTop = CGFloat.greatestFiniteMagnitude
        var typographicBottom = -CGFloat.greatestFiniteMagnitude
        var edgeFontSize: CGFloat = 0

        let hiddenIndices = glyphManager.hiddenIndices
        let source = storage.string as NSString
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, _, lineGlyphRange, _ in
            let overlap = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard overlap.length > 0 else { return }
            let lineCharacters = NSIntersectionRange(
                layoutManager.characterRange(forGlyphRange: overlap, actualGlyphRange: nil),
                characterRange
            )
            guard let characterIndex = (lineCharacters.location..<NSMaxRange(lineCharacters)).first(where: {
                !hiddenIndices.contains($0) && source.character(at: $0) != 0x0A && source.character(at: $0) != 0x0D
            }) else { return }
            let referenceGlyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let font = storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont
                ?? NSFont.systemFont(ofSize: 13)
            let baseline = lineRect.minY + layoutManager.location(forGlyphAt: referenceGlyph).y
            typographicTop = min(typographicTop, baseline - font.ascender)
            typographicBottom = max(typographicBottom, baseline - font.descender)
            edgeFontSize = max(edgeFontSize, font.pointSize)
            horizontalBounds = horizontalBounds.union(lineRect)
        }

        guard !horizontalBounds.isNull,
              typographicTop.isFinite,
              typographicBottom.isFinite else { return nil }
        let verticalPadding = min(8, max(5, (edgeFontSize * 0.32).rounded()))
        return NSRect(
            x: horizontalBounds.minX + textContainerInset.width - horizontalPadding,
            y: typographicTop + textContainerInset.height - verticalPadding,
            width: horizontalBounds.width + horizontalPadding * 2,
            height: typographicBottom - typographicTop + verticalPadding * 2
        )
    }

    private func drawHorizontalRules(layoutManager: NSLayoutManager, visibleRange: NSRange) {
        for hr in horizontalRuleRanges {
            let characterRange = NSIntersectionRange(hr.range, visibleRange)
            guard characterRange.length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
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

    private func drawInlineCodeBackgrounds(layoutManager: NSLayoutManager, visibleRange: NSRange) {
        guard let textContainer = textContainer, let textStorage = textStorage else { return }
        for code in inlineCodeRanges {
            guard code.range.location < textStorage.length else { continue }

            // Use content range (excluding backtick delimiters) to avoid phantom
            // background rects from hidden zero-width backtick glyphs
            var contentRange = code.range
            if contentRange.length >= 2 {
                contentRange = NSRange(location: contentRange.location + 1, length: contentRange.length - 2)
            }
            contentRange = NSIntersectionRange(contentRange, visibleRange)
            guard contentRange.length > 0 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: contentRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }

            // Get the actual font to compute proper height (not line fragment height)
            let font = textStorage.attribute(.font, at: contentRange.location, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let fontHeight = font.ascender - font.descender + font.leading
            let hPad: CGFloat = 2
            let vPad: CGFloat = 1.5

            // Use line fragment enumeration with precise glyph positions instead of
            // enumerateEnclosingRects, which can produce oversized rects when zero-width
            // (hidden) glyphs shift text positions.
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { (lineRect, _, _, effectiveRange, _) in
                // Intersect with the code's glyph range to get only code glyphs on this line
                let overlap = NSIntersectionRange(effectiveRange, glyphRange)
                guard overlap.length > 0 else { return }

                let startPoint = layoutManager.location(forGlyphAt: overlap.location)

                // The delimiters are excluded above, so the glyph bounds provide
                // the content width without asking TextKit for the document-wide
                // glyph count or probing the next (possibly unlaid) glyph.
                let codeWidth = layoutManager.boundingRect(forGlyphRange: overlap, in: textContainer).width

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
        let markerLength = (marker as NSString).length
        let selectedLength = (selected as NSString).length
        if selected.hasPrefix(marker) && selected.hasSuffix(marker) && selectedLength > markerLength * 2 {
            let start = selected.index(selected.startIndex, offsetBy: marker.count)
            let end = selected.index(selected.endIndex, offsetBy: -marker.count)
            let unwrapped = String(selected[start..<end])
            insertText(unwrapped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location, length: (unwrapped as NSString).length))
        } else {
            let wrapped = "\(marker)\(selected)\(marker)"
            insertText(wrapped, replacementRange: range)
            setSelectedRange(NSRange(location: range.location + markerLength, length: selectedLength))
        }
    }

    private func insertLink() {
        let range = selectedRange()
        let selected = range.length > 0 ? (string as NSString).substring(with: range) : ""
        let link = "[\(selected)](url)"
        insertText(link, replacementRange: range)
        if selected.isEmpty {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
        } else {
            setSelectedRange(NSRange(location: range.location + (selected as NSString).length + 3, length: 3))
        }
    }
}
