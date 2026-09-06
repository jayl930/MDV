import AppKit
import Foundation

@main
enum QuickLookPreviewHarness {
    static let fixture = """
    # Emoji 👩🏽‍💻 **nested _formatting_**

    - Actual list item

        indented code with ``` inside

    ````swift
    let marker = "```"
    ````

    ---

    | Left | Center | Right |
    | :--- | :----: | ----: |
    | **bold** | `code` | 👋🏽 |

    ```
    open fence must keep its final body line
    """

    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let theme = MDVTheme()
        theme.appearanceMode = AppearanceMode.light.rawValue
        let renderer = MarkdownPreviewRenderer()
        let typography = Typography(baseFontSize: 16)

        let rendered = renderer.render(
            text: fixture,
            theme: theme,
            typography: typography
        )
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/mdv-preview-snapshots")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writeSnapshots(value: rendered, theme: theme, to: output)

        if !rendered.string.contains("Emoji 👩🏽‍💻 nested formatting") {
            let raw = InlineRenderer().render(text: fixture, theme: theme, typography: typography)
            let source = fixture as NSString
            let tokens = raw.syntaxRanges.compactMap { range in
                NSMaxRange(range) <= source.length ? "\(range):\(source.substring(with: range))" : nil
            }
            fputs("Syntax ranges: \(tokens.joined(separator: ", "))\n", stderr)
        }
        require(rendered.string.contains("Emoji 👩🏽‍💻 nested formatting"), "nested syntax after emoji changed")
        require(!rendered.string.contains("# Emoji"), "heading marker survived")
        require(!rendered.string.contains("**nested"), "strong marker survived")
        require(rendered.string.contains("•"), "unordered-list bullet was not presented")
        require(rendered.string.contains("open fence must keep its final body line"), "open-fence body was dropped")

        let rawFence = InlineRenderer().render(
            text: "```swift 한글\nlet emoji = \"👩🏽‍💻\"\n```\n",
            theme: theme,
            typography: typography
        )
        let rawFenceSource = rawFence.attributedString.string as NSString
        let hiddenFenceText = rawFence.syntaxRanges.map { rawFenceSource.substring(with: $0) }
        let emojiLocation = rawFenceSource.range(of: "👩🏽‍💻").location
        require(hiddenFenceText.contains("```swift 한글"), "opening fence and complete language info are not one hidden syntax span")
        require(hiddenFenceText.contains("```"), "closing fence is not hidden syntax")
        require(!rawFence.syntaxRanges.contains(where: { $0.location <= emojiLocation && NSMaxRange($0) > emojiLocation }),
                "emoji code body was included in a hidden syntax span")

        let fenceCases = """
            indented code with ``` inside

        ````swift
        let marker = "```"
        ````

        ```
        mixed closer stays
        ~~~
        """
        let fences = renderer.render(text: fenceCases, theme: theme, typography: typography).string
        require(fences.contains("indented code with ``` inside"), "indented-code content changed")
        require(fences.contains("let marker = \"```\""), "body fence fragment changed")
        require(fences.contains("mixed closer stays\n~~~"), "mismatched closing fence was deleted")

        let fullRange = NSRange(location: 0, length: rendered.length)
        var tableBlocks = 0
        var horizontalRules = 0
        rendered.enumerateAttributes(in: fullRange) { attributes, _, _ in
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle,
               style.textBlocks.contains(where: { $0 is NSTextTableBlock }) {
                tableBlocks += 1
            }
            if attributes[.previewHorizontalRule] as? Bool == true { horizontalRules += 1 }
        }
        require(tableBlocks >= 9, "native table cells were not produced")
        require(horizontalRules > 0, "native horizontal rule was not produced")

        verifySourceRanges(theme: theme, typography: typography)

        measureRenderer(renderer, theme: theme, typography: typography)
        print("Quick Look preview harness wrote 2 snapshots to \(output.path)")
    }

    private static func verifySourceRanges(theme: MDVTheme, typography: Typography) {
        for newline in ["\n", "\r\n", "\r"] {
            let source = "# 👩🏽‍💻 title\(newline)\(newline)Paragraph [한글](https://example.com) and **bold**."
            let rendered = InlineRenderer().render(text: source, theme: theme, typography: typography)
            let nsSource = source as NSString
            let syntax = rendered.syntaxRanges.map { nsSource.substring(with: $0) }
            require(syntax.contains("# "), "heading marker range changed for newline \(newline.debugDescription)")
            require(syntax.contains("["), "link prefix range changed for newline \(newline.debugDescription)")
            require(syntax.contains("](https://example.com)"), "link suffix range changed for newline \(newline.debugDescription)")
            require(syntax.filter { $0 == "**" }.count == 2, "strong ranges changed for newline \(newline.debugDescription)")
        }
    }

    private static func writeSnapshots(value: NSAttributedString, theme: MDVTheme, to directory: URL) throws {
        for width: CGFloat in [500, 860] {
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.textContainerInset = NSSize(width: min(48, max(20, width * 0.06)), height: 24)
            textView.textContainer?.lineFragmentPadding = 0
            textView.textContainer?.widthTracksTextView = true
            textView.backgroundColor = theme.background
            textView.textStorage?.setAttributedString(value)
            guard let container = textView.textContainer, let layoutManager = textView.layoutManager else {
                throw HarnessError.missingTextSystem
            }
            layoutManager.ensureLayout(for: container)
            textView.frame.size.height = ceil(layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2)
            guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
                throw HarnessError.bitmapCreation
            }
            textView.cacheDisplay(in: textView.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw HarnessError.pngEncoding
            }
            try png.write(to: directory.appendingPathComponent("quick-look-\(Int(width)).png"))
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func measureRenderer(
        _ renderer: MarkdownPreviewRenderer,
        theme: MDVTheme,
        typography: Typography
    ) {
        let inlineRenderer = InlineRenderer()
        let sample = "## Heading\n\nParagraph with **bold**, _emphasis_, and `code`.\n\n- list item\n\n"
        var sizes = [10_000, 100_000]
        if ProcessInfo.processInfo.environment["MDV_PREVIEW_STRESS_1MB"] == "1" {
            sizes.append(1_000_000)
        }
        for byteCount in sizes {
            let repetitions = byteCount / sample.utf8.count + 1
            let markdown = String(repeating: sample, count: repetitions)
            var inlineElapsed: [Double] = []
            var previewElapsed: [Double] = []
            for _ in 0..<3 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = inlineRenderer.render(text: markdown, theme: theme, typography: typography)
                inlineElapsed.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)

                let previewStart = CFAbsoluteTimeGetCurrent()
                _ = renderer.render(text: markdown, theme: theme, typography: typography)
                previewElapsed.append((CFAbsoluteTimeGetCurrent() - previewStart) * 1_000)
            }
            inlineElapsed.sort()
            previewElapsed.sort()
            print("inline \(markdown.utf8.count) bytes median \(String(format: "%.1f", inlineElapsed[1])) ms")
            print("preview \(markdown.utf8.count) bytes median \(String(format: "%.1f", previewElapsed[1])) ms")
        }

    }

    private enum HarnessError: Error { case missingTextSystem, bitmapCreation, pngEncoding }
}
