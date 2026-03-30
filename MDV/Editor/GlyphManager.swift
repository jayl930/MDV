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

        var modifiedGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: count))
        var modifiedProps = Array(UnsafeBufferPointer(start: props, count: count))
        var didModify = false

        // Get bullet glyph for this font
        var bulletGlyph: CGGlyph = 0
        var bulletChar: unichar = 0x2022 // •
        let hasBulletGlyph = CTFontGetGlyphsForCharacters(aFont as CTFont, &bulletChar, &bulletGlyph, 1)

        // Get zero-width space glyph for hiding syntax characters.
        // Using ZWSP glyph substitution instead of .null property because .null
        // is meant for line break glyphs and causes NSLayoutManager to create
        // phantom empty line fragments when used at the start of a line.
        var zwsGlyph: CGGlyph = 0
        var zwsChar: unichar = 0x200B // ZERO WIDTH SPACE
        let hasZWSGlyph = CTFontGetGlyphsForCharacters(aFont as CTFont, &zwsChar, &zwsGlyph, 1)

        // Access indices directly (safe since layout happens on main thread)
        let hidden = MainActor.assumeIsolated { hiddenIndices }
        let bullets = MainActor.assumeIsolated { bulletIndices }

        for i in 0..<count {
            let charIndex = charIndexes[i]

            if hidden.contains(charIndex) {
                // Only hide ASCII characters — all markdown syntax is ASCII.
                // Prevents CJK characters from being hidden if ranges drift.
                if let storage = layoutManager.textStorage, charIndex < storage.length {
                    let ch = (storage.string as NSString).character(at: charIndex)
                    if ch >= 0x80 { continue }
                }
                if hasZWSGlyph {
                    modifiedGlyphs[i] = zwsGlyph
                } else {
                    modifiedProps[i] = .null
                }
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
