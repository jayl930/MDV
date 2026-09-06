import AppKit

struct TableData {
    let sourceRange: NSRange
    let numColumns: Int
    let headerCells: [String]
    let bodyRows: [[String]]
}

final class MDVTheme {
    let text = NSColor.textColor
    let codeText = NSColor.textColor
    let secondaryText = NSColor.secondaryLabelColor
    let accent = NSColor.controlAccentColor
    let codeBackground = NSColor.textBackgroundColor
    let tableHeaderBackground = NSColor.controlBackgroundColor
    let tableBorder = NSColor.separatorColor
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct TableAttachmentRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let markdown = "| Very long first column | Very long second column | Very long third column |\n| --- | --- | --- |\n| alpha alpha alpha | beta beta beta | gamma gamma gamma |"
        let data = TableData(
            sourceRange: NSRange(location: 0, length: (markdown as NSString).length),
            numColumns: 3,
            headerCells: ["Very long first column", "Very long second column", "Very long third column"],
            bodyRows: [["alpha alpha alpha", "beta beta beta", "gamma gamma gamma"]]
        )
        let attachment = TableAttachment(
            tableData: data,
            sourceRange: data.sourceRange,
            originalMarkdown: markdown,
            theme: MDVTheme(),
            typography: Typography()
        )
        guard let cell = attachment.attachmentCell as? TableAttachmentCell else { fatalError("attachment cell") }
        let container = NSTextContainer(size: NSSize(width: 220, height: 1000))
        let frame = cell.cellFrame(
            for: container,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 220, height: 1000),
            glyphPosition: .zero,
            characterIndex: 0
        )
        expect(frame.width <= 220, "attachment stays inside prose width")
        let host = NSView(frame: frame)
        cell.draw(withFrame: frame, in: host)
        guard let scroll = host.subviews.first as? NSScrollView else { fatalError("local scroll view") }
        expect(scroll.hasHorizontalScroller, "table owns a horizontal scroller")
        expect(scroll.documentView!.frame.width > scroll.contentView.bounds.width, "wide table content is horizontally scrollable")

        var editCount = 0
        attachment.embeddedView.onTableEdited = { editCount += 1 }
        attachment.embeddedView.beginEditing(row: 0, col: 0)
        let widthBeforeEdit = scroll.documentView!.frame.width
        let activeField = attachment.embeddedView.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.isEditable }
        activeField?.stringValue = String(repeating: "wider cell content ", count: 20)
        let handled = attachment.embeddedView.control(
            NSControl(),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertTab(_:))
        )
        expect(handled, "Tab navigation handled")
        expect(editCount == 1, "Tab commits exactly once")
        expect(attachment.embeddedView.isEditing, "Tab starts editing the next cell")
        let editedFrame = cell.cellFrame(
            for: container,
            proposedLineFragment: NSRect(x: 0, y: 0, width: 220, height: 1000),
            glyphPosition: .zero,
            characterIndex: 0
        )
        cell.draw(withFrame: editedFrame, in: host)
        expect(scroll.documentView!.frame.width > widthBeforeEdit, "long cell edit refreshes horizontal content width")
        attachment.detachPresentation()
        expect(scroll.superview == nil, "attachment cleanup removes local scroll view")
        print("TableAttachmentRegression: observed all assertions")
    }
}
