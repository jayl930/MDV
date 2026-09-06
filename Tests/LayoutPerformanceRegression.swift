import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct LayoutPerformanceRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let view = MarkdownTextView()
        view.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        view.textContainerInset = NSSize(width: 32, height: 16)
        guard let storage = view.textStorage, let layout = view.layoutManager,
              let container = view.textContainer else { fatalError("text system") }
        let line = "0000 `inline` and ordinary text that fills one line\n"
        let lineLength = (line as NSString).length
        let lineCount = 2_000
        let lines = (0..<lineCount).map { index in
            let suffix = index == lineCount - 1 ? " END OF DOCUMENT" : ""
            return String(format: "%04d `inline` and ordinary text that fills one line%@\n", index, suffix)
        }
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: lines.joined())
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: storage.length))
        view.inlineCodeRanges = (0..<lineCount).map {
            (range: NSRange(location: $0 * lineLength + 5, length: 8), bgColor: NSColor.controlBackgroundColor)
        }
        view.blockQuoteRanges = stride(from: 2, to: lineCount, by: 40).map {
            MarkdownTextView.BlockQuoteRange(
                characterRange: NSRange(location: $0 * lineLength, length: lineLength),
                backgroundColor: NSColor.systemBlue.withAlphaComponent(0.08)
            )
        }
        view.horizontalRuleRanges = stride(from: 20, to: lineCount, by: 100).map {
            (range: NSRange(location: $0 * lineLength, length: lineLength), color: NSColor.separatorColor)
        }
        view.codeBlockRanges = [(
            range: NSRange(location: 200 * lineLength, length: 1_200 * lineLength),
            bgColor: NSColor.systemGray.withAlphaComponent(0.12)
        )]

        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: 720, height: 500), in: container)
        let image = NSImage(size: NSSize(width: 720, height: 400))
        image.lockFocus()
        let start = CFAbsoluteTimeGetCurrent()
        view.drawBackground(in: NSRect(x: 0, y: 0, width: 720, height: 400))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        image.unlockFocus()

        print(String(format: "LayoutPerformanceRegression: dirty-draw %.3f ms, decorations=%d", elapsed * 1_000, lineCount))
        expect(elapsed < 0.100, "small dirty draw must stay bounded as document decorations grow")

        layout.ensureLayout(for: container)
        let documentHeight = ceil(layout.usedRect(for: container).height + view.textContainerInset.height * 2)
        view.frame.size.height = documentHeight
        snapshot(view: view, y: 0, name: "top")
        snapshot(view: view, y: max(0, documentHeight / 2 - 200), name: "middle")
        snapshot(view: view, y: max(0, documentHeight - 400), name: "tail")
        print("LayoutPerformanceRegression: wrote top/middle/tail snapshots at 720x400")
        visualFixture(width: 860, name: "ordinary")
        visualFixture(width: 500, name: "narrow")
        print("LayoutPerformanceRegression: wrote quote/code fixtures at 860x420 and 500x420")
    }

    @MainActor private static func visualFixture(width: CGFloat, name: String) {
        let view = MarkdownTextView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 420)
        view.textContainerInset = NSSize(width: 32, height: 18)
        guard let storage = view.textStorage, let layout = view.layoutManager,
              let container = view.textContainer else { fatalError("text system") }
        let source = """
        Quiet surfaces, readable structure

        > A quotation should feel set apart without shouting.
        > 한글과 emoji 😀 stay comfortably inside the same calm surface.
        > > A nested thought is quietly inset.

        ```swift
        let greeting = "안녕하세요, MDV 😀"
        print(greeting)
        ```

        Ordinary prose resumes without a decorative aftertaste.
        """
        let theme = MDVTheme()
        theme.appearanceMode = AppearanceMode.light.rawValue
        theme.fontSize = 16
        let result = InlineRenderer().render(text: source, theme: theme, typography: Typography(baseFontSize: 16))
        storage.setAttributedString(result.attributedString)
        view.blockQuoteRanges = result.blockQuoteRanges.map {
            MarkdownTextView.BlockQuoteRange(characterRange: $0, backgroundColor: theme.blockQuoteBackground)
        }
        view.codeBlockRanges = result.codeBlockRanges.map { ($0, theme.codeBackground) }
        view.glyphManager.hiddenIndices = IndexSet(result.syntaxRanges.flatMap { Array($0.location..<NSMaxRange($0)) })
        guard let quoteRange = result.blockQuoteRanges.first else { fatalError("rendered quote range") }
        layout.ensureLayout(for: container)

        guard let surface = view.blockSurfaceRect(for: quoteRange, layoutManager: layout, horizontalPadding: 0)
        else { fatalError("quote surface") }
        let glyphRange = layout.glyphRange(forCharacterRange: quoteRange, actualCharacterRange: nil)
        var textTop = CGFloat.greatestFiniteMagnitude
        var textBottom = -CGFloat.greatestFiniteMagnitude
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { lineRect, _, _, lineGlyphRange, _ in
            let overlap = NSIntersectionRange(lineGlyphRange, glyphRange)
            guard overlap.length > 0 else { return }
            let characters = NSIntersectionRange(
                layout.characterRange(forGlyphRange: overlap, actualGlyphRange: nil), quoteRange
            )
            guard let index = (characters.location..<NSMaxRange(characters)).first(where: {
                !view.glyphManager.hiddenIndices.contains($0)
                    && (storage.string as NSString).character(at: $0) != 0x0A
                    && (storage.string as NSString).character(at: $0) != 0x0D
            }) else { return }
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as! NSFont
            let baseline = lineRect.minY + layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: index)).y
            textTop = min(textTop, baseline - font.ascender + view.textContainerInset.height)
            textBottom = max(textBottom, baseline - font.descender + view.textContainerInset.height)
        }
        expect(abs((textTop - surface.minY) - (surface.maxY - textBottom)) < 0.25,
               "quote surface must have equal top and bottom padding")
        snapshot(view: view, y: 0, width: width, height: 420, name: "blocks-\(name)")
    }

    @MainActor private static func snapshot(view: MarkdownTextView, y: CGFloat, name: String) {
        snapshot(view: view, y: y, width: 720, height: 400, name: name)
    }

    @MainActor private static func snapshot(
        view: MarkdownTextView, y: CGFloat, width: CGFloat, height: CGFloat, name: String
    ) {
        let captureRect = NSRect(x: 0, y: y, width: width, height: height)
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: captureRect) else {
            fatalError("snapshot bitmap")
        }
        view.cacheDisplay(in: captureRect, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("snapshot encoding")
        }
        try! png.write(to: URL(fileURLWithPath: "/tmp/mdv-layout-\(name).png"))
    }
}
