import AppKit

/// Incrementally detects markdown patterns on affected lines after each keystroke.
/// Replaces the full-document InlineRenderer for per-edit updates.
final class IncrementalDetector {

    // MARK: - Compiled Regex Patterns

    private let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(?!\\s)(.+?)(?<!\\s)\\*\\*")
    private let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(?!\\s)(.+?)(?<!\\s)\\*(?!\\*)")
    private let strikeRegex = try! NSRegularExpression(pattern: "~~(?!\\s)(.+?)(?<!\\s)~~")
    private let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")

    // MARK: - Fence State

    /// One entry per line: true = inside a code fence
    private var fenceState: [Bool] = []
    /// Line indices that are fence delimiters (``` lines)
    private var fenceDelimiters = Set<Int>()

    // MARK: - Public API

    /// Initialize fence state from a full render's codeBlockRanges.
    /// Called once after renderMarkdown().
    func initializeFenceState(from codeBlockRanges: [NSRange], string: String) {
        let nsString = string as NSString
        let lineCount = countLines(in: nsString)
        fenceState = Array(repeating: false, count: lineCount)
        fenceDelimiters.removeAll()

        // Mark lines inside code blocks
        for codeRange in codeBlockRanges {
            let startLine = lineIndex(at: codeRange.location, in: nsString)
            let endLine = lineIndex(at: codeRange.location + max(0, codeRange.length - 1), in: nsString)
            for i in startLine...endLine where i < fenceState.count {
                fenceState[i] = true
            }
        }

        // Find fence delimiters
        var pos = 0
        var lineIdx = 0
        while pos < nsString.length {
            let lr = nsString.lineRange(for: NSRange(location: pos, length: 0))
            let text = nsString.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("```") {
                fenceDelimiters.insert(lineIdx)
            }
            pos = NSMaxRange(lr)
            if pos == lr.location { break }
            lineIdx += 1
        }
    }

    /// Main entry point. Called from textStorage(didProcessEditing) after shiftAllRanges.
    /// Detects all markdown patterns on affected lines and updates ranges + attributes.
    func detect(
        editedRange: NSRange,
        delta: Int,
        textStorage: NSTextStorage,
        string: String,
        theme: MDVTheme,
        typography: Typography,
        syntaxRanges: inout [NSRange],
        bulletRanges: inout [NSRange],
        textView: MarkdownTextView
    ) {
        let nsString = string as NSString
        guard nsString.length > 0 else { return }

        // Maintain fence state array size when lines are added/removed
        if delta != 0 {
            updateFenceStateForLineDelta(editedRange: editedRange, delta: delta, in: nsString)
        }

        // Compute affected lines (edit line + 1 above/below)
        let affectedLines = affectedLineRanges(editedRange: editedRange, in: nsString)

        // Large paste fallback
        if affectedLines.count > 50 { return }

        // Check if fence delimiters changed and rescan if so
        let fenceChanged = updateFenceState(affectedLines: affectedLines, nsString: nsString, textStorage: textStorage, theme: theme, typography: typography, textView: textView)

        if fenceChanged {
            rebuildCodeBlockRanges(nsString: nsString, theme: theme, textView: textView)
        }

        // Process each affected line
        for lineRange in affectedLines {
            let lineText = nsString.substring(with: lineRange)
            let trimmedText = lineText.replacingOccurrences(of: "\n", with: "")

            // Skip table attachment lines
            if lineText.contains("\u{FFFC}") { continue }

            let lineIdx = lineIndex(at: lineRange.location, in: nsString)
            let isInsideFence = lineIdx < fenceState.count && fenceState[lineIdx]
            let isFenceDelimiter = fenceDelimiters.contains(lineIdx)

            // Purge old ranges for this line
            purgeRangesForLine(lineRange, syntaxRanges: &syntaxRanges, bulletRanges: &bulletRanges, textView: textView)

            // Reset attributes to defaults
            if isInsideFence || isFenceDelimiter {
                textStorage.addAttributes([
                    .font: typography.code,
                    .foregroundColor: theme.codeText,
                    .paragraphStyle: typography.codeBlockParagraphStyle
                ], range: lineRange)
                continue  // Skip inline detection for code block lines
            }

            resetLineAttributes(lineRange, textStorage: textStorage, theme: theme, typography: typography)

            // Detect structural prefix (heading, blockquote, HR, list)
            let isStructural = detectStructuralPrefix(
                lineText: trimmedText, lineRange: lineRange,
                textStorage: textStorage, theme: theme, typography: typography,
                syntaxRanges: &syntaxRanges, bulletRanges: &bulletRanges, textView: textView
            )

            // Blockquote continuation: if no structural prefix was found, check if
            // this line is inside a multi-line blockquote range (from full render).
            // Continuation lines don't have ">" but are semantically part of the block.
            if !isStructural {
                let isInBlockquote = textView.blockQuoteRanges.contains {
                    NSIntersectionRange($0.characterRange, lineRange).length > 0
                }
                if isInBlockquote {
                    textStorage.addAttributes([
                        .paragraphStyle: typography.blockQuoteParagraphStyle,
                        .foregroundColor: theme.secondaryText
                    ], range: lineRange)
                }
            }

            // Detect inline patterns (bold, italic, code, strikethrough, links)
            detectInlinePatterns(
                lineText: trimmedText, lineRange: lineRange,
                textStorage: textStorage, theme: theme, typography: typography,
                syntaxRanges: &syntaxRanges, textView: textView
            )
        }
    }

    /// Returns the structural type for a line (used by updateTypingAttributes)
    func structuralType(for lineText: String) -> StructuralLineType {
        let stripped = lineText.trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("#") {
            var level = 0
            for ch in stripped { if ch == "#" { level += 1 } else { break } }
            if level <= 6 && (stripped.count == level || stripped.dropFirst(level).first == " ") {
                return .heading(level)
            }
        }
        if stripped.hasPrefix(">") { return .blockQuote }
        return .body
    }

    enum StructuralLineType: Equatable {
        case heading(Int)
        case blockQuote
        case body
    }

    // MARK: - Affected Lines

    private func affectedLineRanges(editedRange: NSRange, in nsString: NSString) -> [NSRange] {
        let editLine = nsString.lineRange(for: NSRange(location: min(editedRange.location, max(0, nsString.length - 1)), length: 0))

        var start = editLine.location
        if start > 0 {
            start = nsString.lineRange(for: NSRange(location: start - 1, length: 0)).location
        }

        var end = NSMaxRange(editLine)
        if end < nsString.length {
            end = NSMaxRange(nsString.lineRange(for: NSRange(location: end, length: 0)))
        }

        var lines: [NSRange] = []
        var pos = start
        while pos < end {
            let lr = nsString.lineRange(for: NSRange(location: pos, length: 0))
            lines.append(lr)
            let nextPos = NSMaxRange(lr)
            if nextPos == pos { break }
            pos = nextPos
        }
        return lines
    }

    // MARK: - Fence State Management

    private func updateFenceStateForLineDelta(editedRange: NSRange, delta: Int, in nsString: NSString) {
        // Count newlines in the delta to determine lines added/removed
        guard delta != 0 else { return }
        let editLineIdx = lineIndex(at: min(editedRange.location, max(0, nsString.length - 1)), in: nsString)

        let newLineCount = countLines(in: nsString)
        let oldLineCount = fenceState.count

        if newLineCount > oldLineCount {
            let added = newLineCount - oldLineCount
            let insertAt = min(editLineIdx + 1, fenceState.count)
            let inheritState = editLineIdx < fenceState.count ? fenceState[editLineIdx] : false
            fenceState.insert(contentsOf: Array(repeating: inheritState, count: added), at: insertAt)
            // Shift fence delimiters
            let shifted = fenceDelimiters.filter { $0 >= insertAt }.map { $0 + added }
            fenceDelimiters.subtract(fenceDelimiters.filter { $0 >= insertAt })
            fenceDelimiters.formUnion(shifted)
        } else if newLineCount < oldLineCount {
            let removed = oldLineCount - newLineCount
            let removeAt = min(editLineIdx, fenceState.count - removed)
            if removeAt >= 0 && removeAt + removed <= fenceState.count {
                fenceState.removeSubrange(removeAt..<(removeAt + removed))
                // Shift fence delimiters
                let inRange = fenceDelimiters.filter { $0 >= removeAt && $0 < removeAt + removed }
                fenceDelimiters.subtract(inRange)
                let shifted = fenceDelimiters.filter { $0 >= removeAt + removed }.map { $0 - removed }
                fenceDelimiters.subtract(fenceDelimiters.filter { $0 >= removeAt + removed })
                fenceDelimiters.formUnion(shifted)
            }
        }
    }

    private func updateFenceState(
        affectedLines: [NSRange], nsString: NSString,
        textStorage: NSTextStorage, theme: MDVTheme, typography: Typography,
        textView: MarkdownTextView
    ) -> Bool {
        var fenceChanged = false

        for lineRange in affectedLines {
            let lineIdx = lineIndex(at: lineRange.location, in: nsString)
            let lineText = nsString.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let isFence = lineText.hasPrefix("```")
            let wasFence = fenceDelimiters.contains(lineIdx)
            if isFence != wasFence {
                fenceChanged = true
                break
            }
        }

        guard fenceChanged else { return false }

        // Re-scan from the earliest affected line
        let scanStart = lineIndex(at: affectedLines.first!.location, in: nsString)
        var insideFence = false
        if scanStart > 0 {
            // Walk backward to find the inherited state
            insideFence = scanStart - 1 < fenceState.count ? fenceState[scanStart - 1] : false
            if fenceDelimiters.contains(scanStart - 1) {
                insideFence = true
            }
        }

        let totalLines = fenceState.count
        let affectedEndLine = lineIndex(at: NSMaxRange(affectedLines.last!), in: nsString)
        var stateConverged = false

        for lineIdx in scanStart..<totalLines {
            let lr = lineRangeForIndex(lineIdx, in: nsString)
            guard lr.length > 0 || lr.location < nsString.length else { break }
            let lt = nsString.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines)
            let isFenceDelimiter = lt.hasPrefix("```")

            if isFenceDelimiter {
                insideFence.toggle()
                fenceDelimiters.insert(lineIdx)
            } else {
                fenceDelimiters.remove(lineIdx)
            }

            let newState = insideFence || isFenceDelimiter
            let oldState = lineIdx < fenceState.count ? fenceState[lineIdx] : false

            if lineIdx < fenceState.count {
                fenceState[lineIdx] = newState
            }

            // Early termination past affected area
            if lineIdx > affectedEndLine && newState == oldState {
                stateConverged = true
                break
            }
        }

        return true
    }

    private func rebuildCodeBlockRanges(nsString: NSString, theme: MDVTheme, textView: MarkdownTextView) {
        var ranges: [(range: NSRange, bgColor: NSColor)] = []
        var blockStart: Int? = nil

        for lineIdx in 0..<fenceState.count {
            if fenceState[lineIdx] {
                if blockStart == nil {
                    let lr = lineRangeForIndex(lineIdx, in: nsString)
                    blockStart = lr.location
                }
            } else {
                if let start = blockStart {
                    let prevLr = lineRangeForIndex(lineIdx - 1, in: nsString)
                    let end = NSMaxRange(prevLr)
                    let blockRange = NSRange(location: start, length: end - start)
                    // Trim trailing newline
                    var trimmedEnd = blockRange.location + blockRange.length
                    while trimmedEnd > blockRange.location && nsString.character(at: trimmedEnd - 1) == 0x0A {
                        trimmedEnd -= 1
                    }
                    ranges.append((range: NSRange(location: blockRange.location, length: trimmedEnd - blockRange.location), bgColor: theme.codeBackground))
                    blockStart = nil
                }
            }
        }
        // Handle unclosed fence
        if let start = blockStart {
            let end = nsString.length
            ranges.append((range: NSRange(location: start, length: end - start), bgColor: theme.codeBackground))
        }

        textView.codeBlockRanges = ranges
    }

    // MARK: - Purge & Reset

    private func purgeRangesForLine(
        _ lineRange: NSRange,
        syntaxRanges: inout [NSRange],
        bulletRanges: inout [NSRange],
        textView: MarkdownTextView
    ) {
        syntaxRanges.removeAll { NSIntersectionRange($0, lineRange).length > 0 }
        bulletRanges.removeAll { NSIntersectionRange($0, lineRange).length > 0 }
        textView.inlineCodeRanges.removeAll { NSIntersectionRange($0.range, lineRange).length > 0 }
        // blockQuoteRanges: only purge ranges entirely within this line.
        // Multi-line ranges (from full render) are preserved so continuation lines
        // keep their blockquote styling. Drift reconciliation corrects any staleness.
        textView.blockQuoteRanges.removeAll {
            $0.characterRange.location >= lineRange.location &&
            NSMaxRange($0.characterRange) <= NSMaxRange(lineRange)
        }
        textView.horizontalRuleRanges.removeAll { NSIntersectionRange($0.range, lineRange).length > 0 }
        // codeBlockRanges NOT purged here — rebuilt in fence state pass
    }

    private func resetLineAttributes(_ lineRange: NSRange, textStorage: NSTextStorage, theme: MDVTheme, typography: Typography) {
        textStorage.addAttributes([
            .font: typography.body,
            .foregroundColor: theme.text,
            .paragraphStyle: typography.bodyParagraphStyle
        ], range: lineRange)
        textStorage.removeAttribute(.strikethroughStyle, range: lineRange)
        textStorage.removeAttribute(.strikethroughColor, range: lineRange)
        textStorage.removeAttribute(.underlineStyle, range: lineRange)
        textStorage.removeAttribute(.underlineColor, range: lineRange)
        textStorage.removeAttribute(.link, range: lineRange)
    }

    // MARK: - Structural Prefix Detection

    /// Returns `true` if a structural prefix was detected (heading, blockquote, HR, list).
    @discardableResult
    private func detectStructuralPrefix(
        lineText: String, lineRange: NSRange,
        textStorage: NSTextStorage, theme: MDVTheme, typography: Typography,
        syntaxRanges: inout [NSRange], bulletRanges: inout [NSRange],
        textView: MarkdownTextView
    ) -> Bool {
        let stripped = lineText.trimmingCharacters(in: .whitespaces)
        let indent = lineText.count - lineText.drop(while: { $0 == " " }).count

        // Heading
        if stripped.hasPrefix("#") {
            var level = 0
            for ch in stripped { if ch == "#" { level += 1 } else { break } }
            if level <= 6 && (stripped.count == level || stripped.dropFirst(level).first == " ") {
                textStorage.addAttributes([
                    .font: typography.heading(level: level),
                    .foregroundColor: theme.headingText,
                    .paragraphStyle: typography.headingParagraphStyle(level: level)
                ], range: lineRange)
                let syntaxLen = min(level + 1, lineRange.length)
                syntaxRanges.append(NSRange(location: lineRange.location + indent, length: syntaxLen))
                return true
            }
        }

        // Horizontal rule
        let hrChars: [Character] = ["-", "*", "_"]
        for hrChar in hrChars {
            if stripped.count >= 3 && stripped.allSatisfy({ $0 == hrChar || $0 == " " }) && stripped.filter({ $0 == hrChar }).count >= 3 {
                textStorage.addAttribute(.foregroundColor, value: NSColor.clear, range: lineRange)
                textView.horizontalRuleRanges.append((range: lineRange, color: theme.divider))
                return true
            }
        }

        // Blockquote
        if stripped.hasPrefix(">") {
            textStorage.addAttributes([
                .paragraphStyle: typography.blockQuoteParagraphStyle,
                .foregroundColor: theme.secondaryText
            ], range: lineRange)
            textView.blockQuoteRanges.append(MarkdownTextView.BlockQuoteRange(
                characterRange: lineRange,
                barColor: theme.blockQuoteBar,
                backgroundColor: theme.blockQuoteBackground
            ))
            let syntaxLen = stripped.count > 1 && stripped.dropFirst().first == " " ? 2 : 1
            syntaxRanges.append(NSRange(location: lineRange.location + indent, length: syntaxLen))
            return true
        }

        // Bullet list
        let bulletPrefixes = ["- ", "* ", "+ "]
        for prefix in bulletPrefixes {
            if stripped.hasPrefix(prefix) {
                let bulletLoc = lineRange.location + indent
                textStorage.addAttribute(.paragraphStyle, value: typography.listParagraphStyle(level: 0), range: lineRange)
                bulletRanges.append(NSRange(location: bulletLoc, length: 1))
                // Space after bullet stays visible for proper spacing
                return true
            }
        }

        // Ordered list
        if let dotIdx = stripped.firstIndex(of: ".") {
            let numPart = stripped[stripped.startIndex..<dotIdx]
            if !numPart.isEmpty && numPart.allSatisfy(\.isNumber) {
                let afterDot = stripped.index(after: dotIdx)
                if afterDot < stripped.endIndex && stripped[afterDot] == " " {
                    let numLen = numPart.count
                    textStorage.addAttribute(.paragraphStyle, value: typography.listParagraphStyle(level: 0), range: lineRange)
                    // Keep "1. " fully visible (number, dot, and space)
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Inline Pattern Detection

    private func detectInlinePatterns(
        lineText: String, lineRange: NSRange,
        textStorage: NSTextStorage, theme: MDVTheme, typography: Typography,
        syntaxRanges: inout [NSRange], textView: MarkdownTextView
    ) {
        let nsLine = lineText as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        var claimed = IndexSet()

        // 1. Inline code (highest priority — suppresses other patterns)
        for match in inlineCodeRegex.matches(in: lineText, range: fullRange) {
            let absRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            guard absRange.location + absRange.length <= textStorage.length else { continue }
            textStorage.addAttributes([.font: typography.code, .foregroundColor: theme.codeText], range: absRange)
            textView.inlineCodeRanges.append((range: absRange, bgColor: theme.codeBackground))
            if match.range.length >= 2 {
                syntaxRanges.append(NSRange(location: absRange.location, length: 1))
                syntaxRanges.append(NSRange(location: absRange.location + absRange.length - 1, length: 1))
            }
            claimed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }

        // 2. Bold
        for match in boldRegex.matches(in: lineText, range: fullRange) {
            if !claimed.intersection(IndexSet(integersIn: match.range.location..<(match.range.location + match.range.length))).isEmpty { continue }
            let absRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            guard absRange.location + absRange.length <= textStorage.length else { continue }
            textStorage.enumerateAttribute(.font, in: absRange) { value, subRange, _ in
                if let font = value as? NSFont {
                    textStorage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: subRange)
                }
            }
            syntaxRanges.append(NSRange(location: absRange.location, length: 2))
            syntaxRanges.append(NSRange(location: absRange.location + absRange.length - 2, length: 2))
            claimed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }

        // 3. Italic
        for match in italicRegex.matches(in: lineText, range: fullRange) {
            if !claimed.intersection(IndexSet(integersIn: match.range.location..<(match.range.location + match.range.length))).isEmpty { continue }
            let absRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            guard absRange.location + absRange.length <= textStorage.length else { continue }
            textStorage.enumerateAttribute(.font, in: absRange) { value, subRange, _ in
                if let font = value as? NSFont {
                    textStorage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask), range: subRange)
                }
            }
            syntaxRanges.append(NSRange(location: absRange.location, length: 1))
            syntaxRanges.append(NSRange(location: absRange.location + absRange.length - 1, length: 1))
            claimed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }

        // 4. Strikethrough
        for match in strikeRegex.matches(in: lineText, range: fullRange) {
            if !claimed.intersection(IndexSet(integersIn: match.range.location..<(match.range.location + match.range.length))).isEmpty { continue }
            let absRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            guard absRange.location + absRange.length <= textStorage.length else { continue }
            textStorage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.secondaryText,
                .foregroundColor: theme.secondaryText
            ], range: absRange)
            syntaxRanges.append(NSRange(location: absRange.location, length: 2))
            syntaxRanges.append(NSRange(location: absRange.location + absRange.length - 2, length: 2))
            claimed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }

        // 5. Links
        for match in linkRegex.matches(in: lineText, range: fullRange) {
            if !claimed.intersection(IndexSet(integersIn: match.range.location..<(match.range.location + match.range.length))).isEmpty { continue }
            let absRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            guard absRange.location + absRange.length <= textStorage.length else { continue }
            let matchText = nsLine.substring(with: match.range)
            if let closeBracket = matchText.firstIndex(of: "]") {
                let textLen = matchText.distance(from: matchText.startIndex, to: closeBracket)
                syntaxRanges.append(NSRange(location: absRange.location, length: 1))
                let urlStart = absRange.location + textLen
                let urlLen = absRange.length - textLen
                if urlLen > 0 { syntaxRanges.append(NSRange(location: urlStart, length: urlLen)) }
                let textRange = NSRange(location: absRange.location + 1, length: max(0, textLen - 1))
                if textRange.length > 0 {
                    textStorage.addAttributes([
                        .foregroundColor: theme.accent,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .underlineColor: theme.accent.withAlphaComponent(0.4)
                    ], range: textRange)
                }
            }
            claimed.insert(integersIn: match.range.location..<(match.range.location + match.range.length))
        }
    }

    // MARK: - Helpers

    private func countLines(in nsString: NSString) -> Int {
        var count = 0
        var pos = 0
        while pos <= nsString.length {
            if pos == nsString.length { count += 1; break }
            let lr = nsString.lineRange(for: NSRange(location: pos, length: 0))
            count += 1
            let next = NSMaxRange(lr)
            if next == pos { break }
            pos = next
        }
        return max(count, 1)
    }

    private func lineIndex(at charPos: Int, in nsString: NSString) -> Int {
        let clamped = max(0, min(charPos, nsString.length - 1))
        var idx = 0
        var pos = 0
        while pos < nsString.length {
            let lr = nsString.lineRange(for: NSRange(location: pos, length: 0))
            if clamped >= lr.location && clamped < NSMaxRange(lr) {
                return idx
            }
            let next = NSMaxRange(lr)
            if next == pos { break }
            pos = next
            idx += 1
        }
        return idx
    }

    private func lineRangeForIndex(_ lineIdx: Int, in nsString: NSString) -> NSRange {
        var idx = 0
        var pos = 0
        while pos < nsString.length {
            let lr = nsString.lineRange(for: NSRange(location: pos, length: 0))
            if idx == lineIdx { return lr }
            let next = NSMaxRange(lr)
            if next == pos { break }
            pos = next
            idx += 1
        }
        return NSRange(location: max(0, nsString.length - 1), length: 0)
    }
}
