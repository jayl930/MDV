import AppKit

// MARK: - Horizontal Rule Attachment

final class HorizontalRuleAttachment: NSTextAttachment {
    var lineColor: NSColor = .gray

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(x: 0, y: lineFrag.height / 2, width: lineFrag.width - 48, height: 1)
    }

    override func image(
        forBounds imageBounds: NSRect,
        textContainer: NSTextContainer?,
        characterIndex charIndex: Int
    ) -> NSImage? {
        let image = NSImage(size: imageBounds.size)
        image.lockFocus()
        lineColor.setFill()
        NSRect(x: 0, y: 0, width: imageBounds.width, height: 1).fill()
        image.unlockFocus()
        return image
    }
}
