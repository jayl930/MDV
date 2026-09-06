import AppKit
import CoreText

@MainActor
final class GlyphManager: NSObject, NSLayoutManagerDelegate {
    var hiddenIndices = IndexSet()
    var bulletIndices = IndexSet()

    nonisolated func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font aFont: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        let count = glyphRange.length
        guard count > 0 else { return 0 }

        // Most generated glyph runs contain no markdown markers. Check the
        // supplied character indexes before allocating buffers or resolving
        // substitute glyphs for that overwhelmingly common path.
        let hidden = MainActor.assumeIsolated { hiddenIndices }
        let bullets = MainActor.assumeIsolated { bulletIndices }
        var containsReplacement = false
        for i in 0..<count where hidden.contains(charIndexes[i]) || bullets.contains(charIndexes[i]) {
            containsReplacement = true
            break
        }
        guard containsReplacement else { return 0 }

        var modifiedGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var modifiedProps = Array(UnsafeBufferPointer(start: props, count: count))
        var didModify = false

        // Get bullet glyph for this font
        var bulletGlyph: CGGlyph = 0
        var bulletChar: unichar = 0x2022 // •
        let hasBulletGlyph = CTFontGetGlyphsForCharacters(aFont as CTFont, &bulletChar, &bulletGlyph, 1)

        for i in 0..<count {
            let charIndex = charIndexes[i]

            if hidden.contains(charIndex) {
                // Preserve the already-shaped glyph array and its character
                // mapping. Replacing glyph IDs with ZWSP reshapes neighboring
                // emoji/fallback runs; the null property removes only this
                // existing syntax glyph from layout and display.
                modifiedProps[i].insert(.null)
                didModify = true
            } else if bullets.contains(charIndex) && hasBulletGlyph {
                modifiedGlyphs[i] = bulletGlyph
                didModify = true
            }
        }

        if didModify {
            modifiedGlyphs.withUnsafeBufferPointer { glyphBuf in
                modifiedProps.withUnsafeBufferPointer { propBuf in
                    layoutManager.setGlyphs(
                        glyphBuf.baseAddress!,
                        properties: propBuf.baseAddress!,
                        characterIndexes: charIndexes,
                        font: aFont,
                        forGlyphRange: glyphRange
                    )
                }
            }
            return count
        }

        return 0
    }
}
