import AppKit

/// NSTextAttachment that embeds a TableAttachmentView inline in the text flow.
/// The layout manager handles positioning automatically.
final class TableAttachment: NSTextAttachment {
    let embeddedView: TableAttachmentView
    let sourceMarkdownRange: NSRange  // Range in the original markdown source
    var originalMarkdown: String      // The exact original table markdown text (updated on cell edit)

    init(tableData: TableData, sourceRange: NSRange, originalMarkdown: String, theme: MDVTheme, typography: Typography) {
        self.sourceMarkdownRange = sourceRange
        self.originalMarkdown = originalMarkdown
        self.embeddedView = TableAttachmentView(tableData: tableData, markdown: originalMarkdown, theme: theme, typography: typography)
        super.init(data: nil, ofType: nil)
        self.attachmentCell = TableAttachmentCell(embeddedView: embeddedView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func detachPresentation() {
        (attachmentCell as? TableAttachmentCell)?.detachPresentation()
    }
}

/// Custom cell that sizes and draws the TableAttachmentView.
final class TableAttachmentCell: NSTextAttachmentCell {
    let embeddedView: TableAttachmentView
    private let scrollView: NSScrollView
    private var lastWidth: CGFloat = 0

    init(embeddedView: TableAttachmentView) {
        self.embeddedView = embeddedView
        self.scrollView = NSScrollView()
        super.init()
        scrollView.documentView = embeddedView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override func cellSize() -> NSSize {
        MainActor.assumeIsolated {
            let availableWidth = lastWidth > 0 ? lastWidth : 600
            let contentSize = embeddedView.idealSize(for: availableWidth)
            return boundedSize(contentSize: contentSize, availableWidth: availableWidth)
        }
    }

    nonisolated override func cellBaselineOffset() -> NSPoint {
        return NSPoint(x: 0, y: 0)
    }

    nonisolated override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        MainActor.assumeIsolated {
            lastWidth = lineFrag.width
            let contentSize = embeddedView.idealSize(for: lineFrag.width)
            return NSRect(origin: .zero, size: boundedSize(contentSize: contentSize, availableWidth: lineFrag.width))
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let controlView = controlView,
              cellFrame.height > 1, cellFrame.width > 1 else { return }

        if scrollView.superview !== controlView {
            scrollView.removeFromSuperview()
            controlView.addSubview(scrollView)
        }

        if scrollView.frame != cellFrame {
            scrollView.frame = cellFrame
        }
        let contentSize = embeddedView.idealSize(for: cellFrame.width)
        let embeddedFrame = NSRect(
            origin: .zero,
            size: NSSize(width: max(cellFrame.width, contentSize.width), height: contentSize.height)
        )
        if embeddedView.frame != embeddedFrame {
            embeddedView.frame = embeddedFrame
            embeddedView.needsLayout = true
            embeddedView.needsDisplay = true
        }
    }

    func detachPresentation() {
        scrollView.removeFromSuperview()
    }

    private func boundedSize(contentSize: NSSize, availableWidth: CGFloat) -> NSSize {
        let needsHorizontalScroll = contentSize.width > availableWidth
        let scrollerHeight = needsHorizontalScroll
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: scrollView.scrollerStyle)
            : 0
        return NSSize(width: min(contentSize.width, availableWidth), height: contentSize.height + scrollerHeight)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool {
        return true
    }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        // Consume the event — TableAttachmentView handles mouse events directly as a subview
        return true
    }
}
