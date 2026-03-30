import AppKit

final class SyntaxHider {
    private var previousLineRange: NSRange?
    private var previousHidden = IndexSet()
    private var previousBullets = IndexSet()

    func updateVisibility(
        layoutManager: NSLayoutManager,
        glyphManager: GlyphManager,
        string: String,
        selectedRange: NSRange,
        syntaxRanges: [NSRange],
        bulletRanges: [NSRange]
    ) {
        let fullLength = (string as NSString).length
        guard fullLength > 0 else { return }

        let cursorLineRange = lineRange(for: selectedRange, in: string)

        var hidden = IndexSet()
        var bullets = IndexSet()

        for syntaxRange in syntaxRanges {
            let clamped = clamp(syntaxRange, to: fullLength)
            guard clamped.length > 0 else { continue }

            if !rangesOverlap(cursorLineRange, clamped) {
                hidden.insert(integersIn: clamped.location..<(clamped.location + clamped.length))
            }
        }

        for bulletRange in bulletRanges {
            let clamped = clamp(bulletRange, to: fullLength)
            guard clamped.length > 0 else { continue }

            if !rangesOverlap(cursorLineRange, clamped) {
                bullets.insert(integersIn: clamped.location..<(clamped.location + clamped.length))
            }
        }

        // Compute what actually changed — only invalidate those glyphs
        let hiddenDiff = hidden.symmetricDifference(previousHidden)
        let bulletDiff = bullets.symmetricDifference(previousBullets)
        let allChanged = hiddenDiff.union(bulletDiff)

        glyphManager.hiddenIndices = hidden
        glyphManager.bulletIndices = bullets
        previousHidden = hidden
        previousBullets = bullets

        // Only invalidate glyph ranges that actually changed visibility
        let nsString = string as NSString
        for range in allChanged.rangeView {
            let nsRange = clamp(NSRange(location: range.lowerBound, length: range.count), to: fullLength)
            if nsRange.length > 0 {
                layoutManager.invalidateGlyphs(forCharacterRange: nsRange, changeInLength: 0, actualCharacterRange: nil)
                // Invalidate layout for the entire line — glyph width changes
                // (ZWSP ↔ visible) shift all subsequent characters on the line
                let lineRange = nsString.lineRange(for: nsRange)
                layoutManager.invalidateLayout(forCharacterRange: lineRange, actualCharacterRange: nil)
            }
        }

        previousLineRange = cursorLineRange
    }

    func invalidateAll(layoutManager: NSLayoutManager, length: Int) {
        guard length > 0 else { return }
        let fullRange = NSRange(location: 0, length: length)
        layoutManager.invalidateGlyphs(forCharacterRange: fullRange, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
    }

    private func lineRange(for range: NSRange, in string: String) -> NSRange {
        guard !string.isEmpty else { return NSRange(location: 0, length: 0) }
        let nsString = string as NSString
        let clampedLocation = min(range.location, max(0, nsString.length - 1))
        let lineStart = nsString.lineRange(for: NSRange(location: clampedLocation, length: 0))

        if range.length == 0 {
            return lineStart
        }

        let endLocation = min(range.location + range.length, nsString.length)
        let endLineRange = nsString.lineRange(for: NSRange(location: max(0, endLocation - 1), length: 0))
        return NSUnionRange(lineStart, endLineRange)
    }

    private func rangesOverlap(_ r1: NSRange, _ r2: NSRange) -> Bool {
        let start = max(r1.location, r2.location)
        let end = min(r1.location + r1.length, r2.location + r2.length)
        return start < end
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let start = max(0, min(range.location, length))
        let end = max(start, min(range.location + range.length, length))
        return NSRange(location: start, length: end - start)
    }
}
