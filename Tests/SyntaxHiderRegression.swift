import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct SyntaxHiderRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let string = "**one**\n**two**\n**three**\n"
        let ranges = [
            NSRange(location: 0, length: 2), NSRange(location: 5, length: 2),
            NSRange(location: 8, length: 2), NSRange(location: 13, length: 2),
            NSRange(location: 16, length: 2), NSRange(location: 23, length: 2)
        ]
        let hider = SyntaxHider()
        let glyphManager = GlyphManager()
        let layout = NSLayoutManager()
        let storage = NSTextStorage(string: string)
        let container = NSTextContainer(size: NSSize(width: 500, height: 500))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        hider.updateVisibility(
            layoutManager: layout,
            glyphManager: glyphManager,
            string: string,
            selectedRange: NSRange(location: 3, length: 0),
            syntaxRanges: ranges,
            bulletRanges: []
        )
        expect(!glyphManager.hiddenIndices.contains(0), "syntax on cursor line stays visible")
        expect(glyphManager.hiddenIndices.contains(8), "syntax outside cursor line is hidden")

        hider.updateVisibility(
            layoutManager: layout,
            glyphManager: glyphManager,
            string: string,
            selectedRange: NSRange(location: 11, length: 0),
            syntaxRanges: ranges,
            bulletRanges: []
        )
        expect(glyphManager.hiddenIndices.contains(0), "old cursor line becomes hidden")
        expect(!glyphManager.hiddenIndices.contains(8), "new cursor line becomes visible")
        expect(glyphManager.hiddenIndices.contains(16), "unaffected line remains hidden")

        hider.maintainVisibilityAfterEdit(
            editedRange: NSRange(location: 8, length: 1),
            changeInLength: 1,
            glyphManager: glyphManager
        )
        expect(glyphManager.hiddenIndices.contains(17), "cached UTF-16 masks shift after insertion")
        expect(!glyphManager.hiddenIndices.contains(16), "old mask coordinate is not retained after insertion")

        // A hidden ASCII marker run adjacent to a multi-scalar emoji must not
        // replace or split any glyph belonging to the emoji's UTF-16 range.
        let emojiString = "**👩🏽‍💻**"
        let baselineStorage = NSTextStorage(string: emojiString)
        let baselineLayout = NSLayoutManager()
        baselineLayout.addTextContainer(NSTextContainer(size: NSSize(width: 500, height: 100)))
        baselineStorage.addLayoutManager(baselineLayout)
        _ = baselineLayout.glyphRange(for: baselineLayout.textContainers[0])
        let emojiStorage = NSTextStorage(string: emojiString)
        let emojiLayout = NSLayoutManager()
        emojiLayout.delegate = glyphManager
        emojiLayout.addTextContainer(NSTextContainer(size: NSSize(width: 500, height: 100)))
        emojiStorage.addLayoutManager(emojiLayout)
        glyphManager.hiddenIndices = IndexSet(integersIn: 0..<2)
            .union(IndexSet(integersIn: 9..<11))
        _ = emojiLayout.glyphRange(for: emojiLayout.textContainers[0])
        let emojiUTF16Range = NSRange(location: 2, length: 7)
        let emojiGlyphRange = emojiLayout.glyphRange(forCharacterRange: emojiUTF16Range, actualCharacterRange: nil)
        let baselineGlyphRange = baselineLayout.glyphRange(forCharacterRange: emojiUTF16Range, actualCharacterRange: nil)
        expect(emojiGlyphRange.length > 0, "emoji grapheme still generates glyphs beside hidden syntax")
        let emojiGlyphs = (emojiGlyphRange.location..<NSMaxRange(emojiGlyphRange)).compactMap { index in
            emojiUTF16Range.contains(emojiLayout.characterIndexForGlyph(at: index))
                ? (emojiLayout.glyph(at: index), emojiLayout.propertyForGlyph(at: index)) : nil
        }
        let baselineGlyphs = (baselineGlyphRange.location..<NSMaxRange(baselineGlyphRange)).compactMap { index in
            emojiUTF16Range.contains(baselineLayout.characterIndexForGlyph(at: index))
                ? (baselineLayout.glyph(at: index), baselineLayout.propertyForGlyph(at: index)) : nil
        }
        expect(emojiGlyphs.elementsEqual(baselineGlyphs, by: { $0.0 == $1.0 && $0.1 == $1.1 }),
               "emoji glyph identities and properties match native shaping baseline")

        // Exercise EOF-hidden glyph invalidation with CRLF and a complex emoji.
        // AppKit must never be asked for a line fragment at numberOfGlyphs.
        let crlfSource = "Emoji prefix 👨🏽‍💻 before CRLF\r\n\r\n## Styled heading 😀\r\n\r\n> quoted `inline`\r\n\r\n```swift\r\nlet value = 1\r\n```"
        let crlfStorage = NSTextStorage(string: crlfSource)
        let crlfLayout = NSLayoutManager()
        let crlfContainer = NSTextContainer(size: NSSize(width: 500, height: 1_000))
        let crlfGlyphManager = GlyphManager()
        let crlfHider = SyntaxHider()
        crlfLayout.delegate = crlfGlyphManager
        crlfLayout.addTextContainer(crlfContainer)
        crlfStorage.addLayoutManager(crlfLayout)
        let initialRanges = syntaxRanges(in: crlfSource)
        crlfHider.updateVisibility(
            layoutManager: crlfLayout, glyphManager: crlfGlyphManager,
            string: crlfSource, selectedRange: NSRange(location: 0, length: 0),
            syntaxRanges: initialRanges, bulletRanges: []
        )
        crlfLayout.ensureLayout(for: crlfContainer)
        let target = (crlfSource as NSString).range(of: "before CRLF")
        let replacement = "before edited CRLF"
        let delta = (replacement as NSString).length - target.length
        crlfStorage.replaceCharacters(in: target, with: replacement)
        let editedRange = NSRange(location: target.location, length: (replacement as NSString).length)
        crlfHider.maintainVisibilityAfterEdit(
            editedRange: editedRange, changeInLength: delta, glyphManager: crlfGlyphManager
        )
        let editedSource = crlfStorage.string
        crlfHider.updateVisibility(
            layoutManager: crlfLayout, glyphManager: crlfGlyphManager,
            string: editedSource, selectedRange: NSRange(location: 0, length: 0),
            syntaxRanges: syntaxRanges(in: editedSource), bulletRanges: []
        )
        crlfLayout.ensureLayout(for: crlfContainer)
        expect(crlfGlyphManager.hiddenIndices.allSatisfy { $0 < crlfStorage.length },
               "CRLF EOF hidden indices stay inside UTF-16 storage")
        expect(crlfLayout.numberOfGlyphs <= crlfStorage.length,
               "CRLF EOF layout glyph count stays inside UTF-16 storage")
        if let snapshotPath = ProcessInfo.processInfo.environment["MDV_GLYPH_SNAPSHOT"] {
            writeSnapshot(to: snapshotPath, glyphManager: glyphManager)
        }
        print("SyntaxHiderRegression: observed incremental old/new line visibility")
    }

    private static func syntaxRanges(in source: String) -> [NSRange] {
        let ns = source as NSString
        var result: [NSRange] = []
        for token in ["## ", "> ", "```swift"] {
            let range = ns.range(of: token)
            if range.location != NSNotFound { result.append(range) }
        }
        let inline = ns.range(of: "`inline`")
        if inline.location != NSNotFound {
            result.append(NSRange(location: inline.location, length: 1))
            result.append(NSRange(location: NSMaxRange(inline) - 1, length: 1))
        }
        let closing = ns.range(of: "```", options: .backwards)
        if closing.location != NSNotFound { result.append(closing) }
        return result
    }

    @MainActor private static func writeSnapshot(to path: String, glyphManager: GlyphManager) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        view.backgroundColor = .white
        view.textColor = .black
        view.font = .systemFont(ofSize: 28)
        view.textContainerInset = NSSize(width: 20, height: 20)
        view.string = "**👩🏽‍💻** native shaping"
        glyphManager.hiddenIndices = IndexSet(integersIn: 0..<2)
            .union(IndexSet(integersIn: 9..<11))
        view.layoutManager?.delegate = glyphManager
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fputs("FAIL: could not create glyph snapshot bitmap\n", stderr)
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fputs("FAIL: could not encode glyph snapshot\n", stderr)
            exit(1)
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fputs("FAIL: could not write glyph snapshot: \(error)\n", stderr)
            exit(1)
        }
    }
}
