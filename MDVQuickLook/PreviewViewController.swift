import Cocoa
import Quartz

class PreviewViewController: NSViewController, QLPreviewingController {

    private let scrollView = AppearanceObservingScrollView()
    private let textView = NSTextView()
    private var markdown = ""

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
        scrollView.appearanceDidChange = { [weak self] in self?.renderPreview() }
        self.view = scrollView
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            markdown = try String(contentsOf: url, encoding: .utf8)
            renderPreview()
            handler(nil)
        } catch {
            handler(error)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let horizontalInset = min(48, max(20, view.bounds.width * 0.06))
        textView.textContainerInset = NSSize(width: horizontalInset, height: 24)
    }

    private func renderPreview() {
        let theme = MDVTheme()
        if theme.appearanceMode == AppearanceMode.system.rawValue {
            let match = scrollView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            theme.appearanceMode = match == .darkAqua ? AppearanceMode.dark.rawValue : AppearanceMode.light.rawValue
        }
        let typography = Typography(baseFontSize: theme.fontSize)
        let styledText = MarkdownPreviewRenderer().render(text: markdown, theme: theme, typography: typography)
        textView.backgroundColor = theme.background
        textView.textStorage?.setAttributedString(styledText)
    }
}

private final class AppearanceObservingScrollView: NSScrollView {
    var appearanceDidChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceDidChange?()
    }
}
