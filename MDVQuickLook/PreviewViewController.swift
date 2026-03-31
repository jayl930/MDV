import Cocoa
import Quartz

class PreviewViewController: NSViewController, QLPreviewingController {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let contentSize = scrollView.contentSize
        textView.frame = NSRect(origin: .zero, size: contentSize)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 40, height: 24)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true

        scrollView.documentView = textView
        self.view = scrollView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)

            let theme = MDVTheme()
            let typography = Typography(baseFontSize: theme.fontSize)
            let renderer = InlineRenderer()
            let result = renderer.render(text: text, theme: theme, typography: typography)

            let styledText = NSMutableAttributedString(attributedString: result.attributedString)

            // Apply background colors for code blocks
            for range in result.codeBlockRanges {
                guard range.location + range.length <= styledText.length else { continue }
                styledText.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
            }

            // Apply background colors for inline code
            for range in result.inlineCodeRanges {
                guard range.location + range.length <= styledText.length else { continue }
                styledText.addAttribute(.backgroundColor, value: theme.codeBackground, range: range)
            }

            // Apply background colors for blockquotes
            for range in result.blockQuoteRanges {
                guard range.location + range.length <= styledText.length else { continue }
                styledText.addAttribute(.backgroundColor, value: theme.blockQuoteBackground, range: range)
            }

            // Hide syntax markers (# for headings, ** for bold, etc.)
            for range in result.syntaxRanges {
                guard range.location + range.length <= styledText.length else { continue }
                styledText.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
            }

            // Replace bullet markers with bullet character
            for range in result.bulletRanges {
                guard range.location + range.length <= styledText.length else { continue }
                styledText.replaceCharacters(in: range, with: "\u{2022}")
            }

            textView.backgroundColor = theme.background
            textView.textStorage?.setAttributedString(styledText)

            handler(nil)
        } catch {
            handler(error)
        }
    }
}
