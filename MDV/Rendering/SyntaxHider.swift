import AppKit

@MainActor
final class SyntaxHider {
    private var previousLineRange: NSRange?
    private var previousHidden = IndexSet()
    private var previousBullets = IndexSet()
    private var previousSyntaxRanges: [NSRange] = []
    private var previousBulletRanges: [NSRange] = []

    /// Keep cached UTF-16 masks aligned with TextKit's character edit. TextKit
    /// already shifts glyph storage after the edit, so translating here avoids
    /// treating every later Markdown marker as a visibility change.
    func maintainVisibilityAfterEdit(
        editedRange: NSRange,
        changeInLength delta: Int,
        glyphManager: GlyphManager
    ) {
        let oldLength = max(0, editedRange.length - delta)
        let oldRange = NSRange(location: editedRange.location, length: oldLength)
        previousHidden = translated(previousHidden, replacing: oldRange, delta: delta)
        previousBullets = translated(previousBullets, replacing: oldRange, delta: delta)
        previousSyntaxRanges = translated(previousSyntaxRanges, replacing: oldRange, delta: delta)
        previousBulletRanges = translated(previousBulletRanges, replacing: oldRange, delta: delta)
        glyphManager.hiddenIndices = previousHidden
        glyphManager.bulletIndices = previousBullets
        previousLineRange = nil
    }

    func updateVisibility(
        layoutManager: NSLayoutManager,
        glyphManager: GlyphManager,
        string: String,
        selectedRange: NSRange,
        syntaxRanges: [NSRange],
        bulletRanges: [NSRange]
    ) {
        let fullLength = (string as NSString).length
        guard fullLength > 0 else {
            previousLineRange = nil
            previousHidden.removeAll()
            previousBullets.removeAll()
            previousSyntaxRanges.removeAll()
            previousBulletRanges.removeAll()
            glyphManager.hiddenIndices.removeAll()
            glyphManager.bulletIndices.removeAll()
            return
        }

        let cursorLineRange = lineRange(for: selectedRange, in: string)
        let rangesUnchanged = syntaxRanges == previousSyntaxRanges
            && bulletRanges == previousBulletRanges

        if rangesUnchanged, cursorLineRange == previousLineRange {
            return
        }

        let hidden = hiddenIndices(in: syntaxRanges, except: cursorLineRange, fullLength: fullLength)
        let bullets = hiddenIndices(in: bulletRanges, except: cursorLineRange, fullLength: fullLength)

        // Compute what actually changed — only invalidate those glyphs
        let hiddenDiff = hidden.symmetricDifference(previousHidden)
        let bulletDiff = bullets.symmetricDifference(previousBullets)
        let allChanged = hiddenDiff.union(bulletDiff)

        glyphManager.hiddenIndices = hidden
        glyphManager.bulletIndices = bullets
        previousHidden = hidden
        previousBullets = bullets
        previousSyntaxRanges = syntaxRanges
        previousBulletRanges = bulletRanges

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

    private func hiddenIndices(
        in ranges: [NSRange], except cursorLineRange: NSRange, fullLength: Int
    ) -> IndexSet {
        var result = IndexSet()
        for range in ranges {
            let clamped = clamp(range, to: fullLength)
            guard clamped.length > 0, !rangesOverlap(cursorLineRange, clamped) else { continue }
            result.insert(integersIn: clamped.location..<NSMaxRange(clamped))
        }
        return result
    }

    private func translated(_ ranges: [NSRange], replacing editedRange: NSRange, delta: Int) -> [NSRange] {
        ranges.compactMap { range in
            if NSMaxRange(range) <= editedRange.location { return range }
            if range.location >= NSMaxRange(editedRange) {
                return NSRange(location: max(0, range.location + delta), length: range.length)
            }
            return nil
        }
    }

    private func translated(_ indices: IndexSet, replacing editedRange: NSRange, delta: Int) -> IndexSet {
        var result = IndexSet()
        for indexRange in indices.rangeView {
            let range = NSRange(location: indexRange.lowerBound, length: indexRange.count)
            let shifted: NSRange
            if NSMaxRange(range) <= editedRange.location {
                shifted = range
            } else if range.location >= NSMaxRange(editedRange) {
                shifted = NSRange(location: max(0, range.location + delta), length: range.length)
            } else {
                continue
            }
            result.insert(integersIn: shifted.location..<NSMaxRange(shifted))
        }
        return result
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
