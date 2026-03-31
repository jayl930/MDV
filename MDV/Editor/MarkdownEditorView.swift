import SwiftUI
import AppKit

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var document: MarkdownDocument
    var tocModel: ToCModel
    @Environment(MDVTheme.self) private var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.applyTheme(theme)
        textView.font = context.coordinator.typography.body
        textView.textColor = theme.text
        textView.string = document.text

        textView.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.handleTextChange(newText)
        }
        textView.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.handleSelectionChange(range)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.tocModel = tocModel

        // Wire TOC scroll callback
        tocModel.scrollToRange = { [weak coordinator = context.coordinator] sourceRange in
            coordinator?.scrollToHeading(sourceRange: sourceRange)
        }

        // Set up NSTextStorageDelegate for structural change detection
        textView.textStorage?.delegate = context.coordinator

        DispatchQueue.main.async {
            context.coordinator.renderMarkdown()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let coordinator = context.coordinator

        let themeChanged = coordinator.lastThemeIsDark != theme.isDark || coordinator.lastFontSize != theme.fontSize
        coordinator.theme = theme
        coordinator.typography = Typography(baseFontSize: theme.fontSize)
        textView.applyTheme(theme)

        if !coordinator.isUpdating {
            let textChanged = coordinator.sourceText != document.text
            if textChanged {
                coordinator.isUpdating = true
                let selectedRange = textView.selectedRange()
                coordinator.sourceText = document.text
                textView.string = document.text
                coordinator.renderMarkdown()
                let safeRange = NSRange(
                    location: min(selectedRange.location, textView.string.count),
                    length: 0
                )
                textView.setSelectedRange(safeRange)
                coordinator.isUpdating = false
            } else if themeChanged {
                coordinator.isUpdating = true
                // Restore source text before re-rendering — table attachments
                // shorten textStorage, causing renderMarkdown()'s length guard to fail
                textView.string = coordinator.sourceText
                coordinator.renderMarkdown()
                coordinator.isUpdating = false
            }
        }

        textView.updateTextContainerInset(for: scrollView.contentSize.width)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let parent: MarkdownEditorView
        var textView: MarkdownTextView?
        var scrollView: NSScrollView?
        var isUpdating = false
        var theme: MDVTheme
        var typography: Typography
        var tocModel: ToCModel
        private let renderer = InlineRenderer()
        private let syntaxHider = SyntaxHider()
        private let incrementalDetector = IncrementalDetector()
        private var lastSyntaxRanges: [NSRange] = []
        private var lastBulletRanges: [NSRange] = []
        var lastThemeIsDark: Bool?
        var lastFontSize: Double?

        /// The canonical markdown source text (always pure markdown)
        var sourceText: String

        /// Mapping from attachment positions in display text to source ranges
        private var tableAttachments: [(displayLocation: Int, attachment: TableAttachment)] = []

        /// Flag to prevent re-rendering during structural re-style
        private var isRestyling = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
            self.theme = parent.theme
            self.typography = Typography(baseFontSize: parent.theme.fontSize)
            self.sourceText = parent.document.text
            self.tocModel = parent.tocModel
        }

        // MARK: - Text Change Handling (no re-rendering, deferred save)

        private var syncWorkItem: DispatchWorkItem?

        func handleTextChange(_ newText: String) {
            guard !isUpdating, !isRestyling else { return }

            // Debounced sync: wait until typing pauses, then update document.text
            // This prevents SwiftUI re-render on every keystroke
            syncWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.syncSourceText()
            }
            syncWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }

        /// Reconstruct source markdown and update document.text, then reconcile
        private func syncSourceText() {
            guard let textView = textView else { return }

            // Don't sync while a table cell is being edited
            for (_, attachment) in tableAttachments {
                if attachment.embeddedView.isEditing { return }
            }

            isUpdating = true
            sourceText = reconstructSourceText(from: textView.string)
            parent.document.text = sourceText

            // Reconcile: compare incremental ranges with fresh parse
            let freshResult = renderer.render(text: sourceText, theme: theme, typography: typography)
            tocModel.entries = freshResult.headings
            let driftDetected =
                freshResult.syntaxRanges.count != lastSyntaxRanges.count ||
                freshResult.codeBlockRanges.count != textView.codeBlockRanges.count ||
                freshResult.blockQuoteRanges.count != textView.blockQuoteRanges.count ||
                freshResult.inlineCodeRanges.count != textView.inlineCodeRanges.count

            if driftDetected {
                renderMarkdown()
            }

            isUpdating = false
        }

        func handleSelectionChange(_ range: NSRange) {
            guard let textView = textView, let layoutManager = textView.layoutManager else { return }

            syntaxHider.updateVisibility(
                layoutManager: layoutManager,
                glyphManager: textView.glyphManager,
                string: textView.string,
                selectedRange: range,
                syntaxRanges: lastSyntaxRanges,
                bulletRanges: lastBulletRanges
            )

            updateTypingAttributes(at: range)
            textView.needsDisplay = true
        }

        // MARK: - TOC Scroll

        /// Scrolls to a heading given its source-text range, mapping through table attachments.
        func scrollToHeading(sourceRange: NSRange) {
            guard let textView = textView else { return }

            // Map source range to display range by accounting for table attachments
            var displayLocation = sourceRange.location
            for (_, attachment) in tableAttachments {
                let tableSourceRange = attachment.sourceMarkdownRange
                if tableSourceRange.location + tableSourceRange.length <= sourceRange.location {
                    // Table is before this heading — it replaced N chars with 1
                    displayLocation -= (tableSourceRange.length - 1)
                }
            }

            let nsString = textView.string as NSString
            let clampedLocation = min(displayLocation, max(0, nsString.length - 1))
            let lineRange = nsString.lineRange(for: NSRange(location: clampedLocation, length: 0))

            // Scroll to the heading line
            textView.scrollRangeToVisible(lineRange)

            // Brief themed highlight instead of yellow showFindIndicator
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = 0
            rect.size.width = textView.bounds.width
            let origin = textView.textContainerOrigin
            rect.origin.x += origin.x
            rect.origin.y += origin.y

            let highlight = NSView(frame: rect)
            highlight.wantsLayer = true
            highlight.layer?.backgroundColor = theme.accent.withAlphaComponent(0.15).cgColor
            highlight.layer?.cornerRadius = 3
            textView.addSubview(highlight)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.8
                highlight.animator().alphaValue = 0
            } completionHandler: {
                highlight.removeFromSuperview()
            }
        }

        // MARK: - Typing Attributes

        /// Sets typingAttributes based on the current line's markdown structure.
        /// Determines style from the line prefix, not from existing text storage attributes.
        private func updateTypingAttributes(at range: NSRange) {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            guard nsString.length > 0 else {
                textView.typingAttributes = [
                    .font: typography.body,
                    .foregroundColor: theme.text,
                    .paragraphStyle: typography.bodyParagraphStyle
                ]
                return
            }

            let clampedLoc = min(range.location, max(0, nsString.length - 1))
            let lineRange = nsString.lineRange(for: NSRange(location: clampedLoc, length: 0))
            let lineText = nsString.substring(with: lineRange).trimmingCharacters(in: .newlines)

            // After pressing Enter, check if we're on a NEW empty line
            if range.location > 0 {
                let prevChar = nsString.character(at: range.location - 1)
                if prevChar == 0x0A && lineText.isEmpty {
                    textView.typingAttributes = [
                        .font: typography.body,
                        .foregroundColor: theme.text,
                        .paragraphStyle: typography.emptyLineParagraphStyle
                    ]
                    return
                }
            }

            // Determine style from line prefix
            let type = incrementalDetector.structuralType(for: lineText)
            let font: NSFont
            let color: NSColor
            let paraStyle: NSParagraphStyle
            switch type {
            case .heading(let level):
                font = typography.heading(level: level)
                color = theme.headingText
                paraStyle = typography.headingParagraphStyle(level: level)
            case .blockQuote:
                font = typography.body
                color = theme.secondaryText
                paraStyle = typography.blockQuoteParagraphStyle
            case .body:
                font = typography.body
                color = theme.text
                paraStyle = typography.bodyParagraphStyle
            }
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paraStyle
            ]
        }

        // MARK: - NSTextStorageDelegate (structural change detection)

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }

            MainActor.assumeIsolated {
                guard !isUpdating, !isRestyling else { return }
                guard let textView = textView else { return }

                // Shift all stored ranges to account for inserted/deleted characters
                if delta != 0 {
                    shiftAllRanges(editLocation: editedRange.location, delta: delta)
                }

                // Incremental detection: purge + rescan affected lines
                isRestyling = true
                textStorage.beginEditing()
                incrementalDetector.detect(
                    editedRange: editedRange,
                    delta: delta,
                    textStorage: textStorage,
                    string: textView.string,
                    theme: theme,
                    typography: typography,
                    syntaxRanges: &lastSyntaxRanges,
                    bulletRanges: &lastBulletRanges,
                    textView: textView
                )
                // Fix CJK font cascade: resetLineAttributes sets .systemFont which
                // lacks CJK glyphs. We manually substitute fonts for characters the
                // current font can't render, using CTFontCreateForString.
                // We ONLY touch .font — never .foregroundColor or .paragraphStyle —
                // so blockquote, heading, and code block styling is preserved.
                let nsString = textView.string as NSString
                if nsString.length > 0 {
                    let safeEditLoc = min(editedRange.location, max(0, nsString.length - 1))
                    let safeEditLen = min(editedRange.length, nsString.length - safeEditLoc)
                    let lineRange = nsString.lineRange(for: NSRange(location: safeEditLoc, length: safeEditLen))
                    var fixStart = lineRange.location
                    var fixEnd = NSMaxRange(lineRange)
                    if fixStart > 0 {
                        fixStart = nsString.lineRange(for: NSRange(location: fixStart - 1, length: 0)).location
                    }
                    if fixEnd < nsString.length {
                        fixEnd = NSMaxRange(nsString.lineRange(for: NSRange(location: fixEnd, length: 0)))
                    }
                    let fixRange = NSRange(location: fixStart, length: fixEnd - fixStart)
                    self.fixCJKFontCascade(in: fixRange, textStorage: textStorage)
                }
                textStorage.endEditing()
                isRestyling = false
            }
        }

        /// Fixes font cascade for CJK characters by substituting fonts that can
        /// actually render each character. Only touches .font attribute — preserves
        /// foreground color, paragraph style, and all other attributes.
        private func fixCJKFontCascade(in range: NSRange, textStorage: NSTextStorage) {
            let nsStr = textStorage.string as NSString
            textStorage.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
                guard let font = value as? NSFont else { return }
                let ctFont = font as CTFont
                var runStart = attrRange.location
                let runEnd = NSMaxRange(attrRange)
                while runStart < runEnd {
                    let ch = nsStr.character(at: runStart)
                    if ch >= 0x80 {
                        // Non-ASCII — check if font can render this character
                        var glyph: CGGlyph = 0
                        var unichar = ch
                        if !CTFontGetGlyphsForCharacters(ctFont, &unichar, &glyph, 1) {
                            // Find the correct substitute font via Core Text
                            let charStr = nsStr.substring(with: NSRange(location: runStart, length: 1)) as CFString
                            let subFont = CTFontCreateForString(ctFont, charStr, CFRange(location: 0, length: 1))
                            // Batch consecutive characters that need the same substitute font
                            var batchEnd = runStart + 1
                            while batchEnd < runEnd {
                                let nextCh = nsStr.character(at: batchEnd)
                                if nextCh < 0x80 { break }
                                var nextGlyph: CGGlyph = 0
                                var nextUnichar = nextCh
                                if CTFontGetGlyphsForCharacters(ctFont, &nextUnichar, &nextGlyph, 1) { break }
                                // Verify same substitute font
                                let nextStr = nsStr.substring(with: NSRange(location: batchEnd, length: 1)) as CFString
                                let nextSubFont = CTFontCreateForString(ctFont, nextStr, CFRange(location: 0, length: 1))
                                if !CFEqual(subFont, nextSubFont) { break }
                                batchEnd += 1
                            }
                            textStorage.addAttribute(.font, value: subFont as NSFont,
                                                     range: NSRange(location: runStart, length: batchEnd - runStart))
                            runStart = batchEnd
                            continue
                        }
                    }
                    runStart += 1
                }
            }
        }

        /// Shifts all stored character ranges after an edit.
        /// editLocation: where the edit happened (in new text coordinates)
        /// delta: number of characters added (positive) or removed (negative)
        private func shiftAllRanges(editLocation: Int, delta: Int) {
            guard let textView = textView else { return }

            // Shift syntax/bullet ranges
            shiftRangeArray(&lastSyntaxRanges, editLocation: editLocation, delta: delta)
            shiftRangeArray(&lastBulletRanges, editLocation: editLocation, delta: delta)

            // Shift drawing ranges
            textView.blockQuoteRanges = textView.blockQuoteRanges.compactMap { bq in
                guard let shifted = shiftRange(bq.characterRange, editLocation: editLocation, delta: delta) else { return nil }
                return MarkdownTextView.BlockQuoteRange(characterRange: shifted, barColor: bq.barColor, backgroundColor: bq.backgroundColor)
            }
            textView.codeBlockRanges = textView.codeBlockRanges.compactMap { cb in
                guard let shifted = shiftRange(cb.range, editLocation: editLocation, delta: delta) else { return nil }
                return (range: shifted, bgColor: cb.bgColor)
            }
            textView.horizontalRuleRanges = textView.horizontalRuleRanges.compactMap { hr in
                guard let shifted = shiftRange(hr.range, editLocation: editLocation, delta: delta) else { return nil }
                return (range: shifted, color: hr.color)
            }
            textView.inlineCodeRanges = textView.inlineCodeRanges.compactMap { ic in
                guard let shifted = shiftRange(ic.range, editLocation: editLocation, delta: delta) else { return nil }
                return (range: shifted, bgColor: ic.bgColor)
            }
        }

        /// Shift a single range. Returns nil if the range was entirely deleted.
        private func shiftRange(_ range: NSRange, editLocation: Int, delta: Int) -> NSRange? {
            let rangeEnd = range.location + range.length

            if rangeEnd <= editLocation {
                // Entirely before edit — unchanged
                return range
            }
            if range.location >= editLocation - min(delta, 0) {
                // Entirely after the edited region — shift by delta
                let newLoc = max(0, range.location + delta)
                return NSRange(location: newLoc, length: range.length)
            }
            // Range contains the edit point — adjust length
            let newLength = range.length + delta
            return newLength > 0 ? NSRange(location: range.location, length: newLength) : nil
        }

        private func shiftRangeArray(_ ranges: inout [NSRange], editLocation: Int, delta: Int) {
            ranges = ranges.compactMap { shiftRange($0, editLocation: editLocation, delta: delta) }
        }

        // MARK: - One-Time Full Render (on load and theme change only)

        func renderMarkdown() {
            guard let textView = textView, let layoutManager = textView.layoutManager,
                  let textStorage = textView.textStorage else { return }

            let result = renderer.render(text: sourceText, theme: theme, typography: typography)
            let selectedRange = textView.selectedRange()

            let fullRange = NSRange(location: 0, length: textStorage.length)
            guard fullRange.length == result.attributedString.length else { return }

            // Apply all attributes at once
            isRestyling = true
            textStorage.beginEditing()
            result.attributedString.enumerateAttributes(in: fullRange) { attrs, range, _ in
                textStorage.setAttributes(attrs, range: range)
            }
            textStorage.endEditing()
            isRestyling = false

            lastSyntaxRanges = result.syntaxRanges
            lastBulletRanges = result.bulletRanges
            tocModel.entries = result.headings

            // Update custom drawing ranges
            textView.blockQuoteRanges = result.blockQuoteRanges.map { range in
                MarkdownTextView.BlockQuoteRange(
                    characterRange: range,
                    barColor: theme.blockQuoteBar,
                    backgroundColor: theme.blockQuoteBackground
                )
            }
            textView.codeBlockRanges = result.codeBlockRanges.map { (range: $0, bgColor: theme.codeBackground) }
            textView.horizontalRuleRanges = result.horizontalRuleRanges.map { (range: $0, color: theme.divider) }
            textView.inlineCodeRanges = result.inlineCodeRanges.map { (range: $0, bgColor: theme.codeBackground) }

            lastThemeIsDark = theme.isDark
            lastFontSize = theme.fontSize

            // Create table attachments and adjust all stored ranges
            // Must happen BEFORE fence state init so fenceState matches the display string
            insertTableAttachments(tables: result.tables, textView: textView)

            // Initialize fence state from the display string (post-table-attachment)
            // so line counts match what incremental detection will see during edits
            let displayCodeBlockRanges = textView.codeBlockRanges.map { $0.range }
            incrementalDetector.initializeFenceState(from: displayCodeBlockRanges, string: textView.string)

            // Restore cursor (after table insertion may have changed text length)
            let safeRange = NSRange(
                location: min(selectedRange.location, textView.string.count),
                length: min(selectedRange.length, max(0, textView.string.count - min(selectedRange.location, textView.string.count)))
            )
            textView.setSelectedRange(safeRange)

            // Apply glyph hiding (after range adjustment)
            syntaxHider.updateVisibility(
                layoutManager: layoutManager,
                glyphManager: textView.glyphManager,
                string: textView.string,
                selectedRange: safeRange,
                syntaxRanges: lastSyntaxRanges,
                bulletRanges: lastBulletRanges
            )

            textView.needsDisplay = true
        }

        // MARK: - Table Attachments

        private func insertTableAttachments(tables: [TableData], textView: MarkdownTextView) {
            guard let textStorage = textView.textStorage else { return }

            // Remove old table attachment views
            for (_, attachment) in tableAttachments {
                attachment.embeddedView.removeFromSuperview()
            }
            tableAttachments.removeAll()

            guard !tables.isEmpty else { return }

            // Insert attachments from end to start (so earlier ranges aren't shifted)
            // Track the cumulative offset changes for adjusting stored ranges
            isRestyling = true

            // Sort tables by location descending for safe replacement
            let sortedTables = tables.sorted { $0.sourceRange.location > $1.sourceRange.location }

            // Collect (location, lengthRemoved) pairs for range adjustment
            var replacements: [(location: Int, removed: Int)] = []  // ascending order

            let nsSource = sourceText as NSString
            for tableData in sortedTables {
                let originalMD = nsSource.substring(with: tableData.sourceRange)
                let attachment = TableAttachment(
                    tableData: tableData,
                    sourceRange: tableData.sourceRange,
                    originalMarkdown: originalMD,
                    theme: theme,
                    typography: typography
                )

                // Wire editing callbacks
                attachment.embeddedView.onTableEdited = { [weak self, weak attachment] in
                    guard let self = self, let attachment = attachment else { return }
                    attachment.originalMarkdown = attachment.embeddedView.markdownString()
                    self.handleTextChange("")
                }
                attachment.embeddedView.onStructuralChange = { [weak self, weak attachment] newMarkdown in
                    guard let self = self, let attachment = attachment else { return }
                    attachment.originalMarkdown = newMarkdown
                    self.handleTextChange("")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.renderMarkdown()
                    }
                }

                let attachmentString = NSAttributedString(attachment: attachment)
                textStorage.replaceCharacters(in: tableData.sourceRange, with: attachmentString)

                replacements.append((
                    location: tableData.sourceRange.location,
                    removed: tableData.sourceRange.length
                ))

                tableAttachments.append((
                    displayLocation: tableData.sourceRange.location,
                    attachment: attachment
                ))
            }
            isRestyling = false

            // Sort ascending for range adjustment
            replacements.sort { $0.location < $1.location }
            tableAttachments.sort { $0.displayLocation < $1.displayLocation }

            // Adjust all stored ranges to account for table text → single char replacements
            adjustRanges(&lastSyntaxRanges, for: replacements)
            adjustRanges(&lastBulletRanges, for: replacements)

            // Adjust drawing ranges
            textView.blockQuoteRanges = textView.blockQuoteRanges.compactMap { bq in
                guard let adjusted = adjustRange(bq.characterRange, for: replacements) else { return nil }
                return MarkdownTextView.BlockQuoteRange(
                    characterRange: adjusted,
                    barColor: bq.barColor,
                    backgroundColor: bq.backgroundColor
                )
            }
            textView.codeBlockRanges = textView.codeBlockRanges.compactMap { cb in
                guard let adjusted = adjustRange(cb.range, for: replacements) else { return nil }
                return (range: adjusted, bgColor: cb.bgColor)
            }
            textView.horizontalRuleRanges = textView.horizontalRuleRanges.compactMap { hr in
                guard let adjusted = adjustRange(hr.range, for: replacements) else { return nil }
                return (range: adjusted, color: hr.color)
            }
            textView.inlineCodeRanges = textView.inlineCodeRanges.compactMap { ic in
                guard let adjusted = adjustRange(ic.range, for: replacements) else { return nil }
                return (range: adjusted, bgColor: ic.bgColor)
            }
        }

        /// Adjust a single range for table replacements. Returns nil if range overlaps a table.
        /// All positions are compared in original (pre-replacement) coordinate space.
        private func adjustRange(_ range: NSRange, for replacements: [(location: Int, removed: Int)]) -> NSRange? {
            var totalDelta = 0
            let rangeStart = range.location
            let rangeEnd = range.location + range.length

            for repl in replacements {
                let replEnd = repl.location + repl.removed

                // Range overlaps the replacement — discard it
                if rangeStart < replEnd && rangeEnd > repl.location { return nil }

                // Replacement is entirely before this range — accumulate shift
                if replEnd <= rangeStart {
                    totalDelta += repl.removed - 1  // replaced N chars with 1
                }
            }

            return NSRange(location: rangeStart - totalDelta, length: range.length)
        }

        /// Adjust an array of ranges in place
        private func adjustRanges(_ ranges: inout [NSRange], for replacements: [(location: Int, removed: Int)]) {
            ranges = ranges.compactMap { adjustRange($0, for: replacements) }
        }

        /// Reconstruct full markdown source from display text + table attachments.
        /// Scans for U+FFFC (attachment char) dynamically rather than using stored positions.
        private func reconstructSourceText(from displayText: String) -> String {
            guard !tableAttachments.isEmpty else { return displayText }

            let attachmentChar = Character("\u{FFFC}")
            var result = ""
            var attachmentIndex = 0

            for ch in displayText {
                if ch == attachmentChar && attachmentIndex < tableAttachments.count {
                    // Replace attachment character with the exact original table markdown
                    result += tableAttachments[attachmentIndex].attachment.originalMarkdown
                    attachmentIndex += 1
                } else {
                    result.append(ch)
                }
            }

            return result
        }

        func textDidChange(_ notification: Notification) {
            // Handled via onTextChange callback
        }
    }
}
