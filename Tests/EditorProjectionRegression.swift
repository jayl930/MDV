import AppKit

final class TableAttachment: NSTextAttachment {
    var originalMarkdown: String
    init(markdown: String) {
        originalMarkdown = markdown
        super.init(data: nil, ofType: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
struct EditorProjectionRegression {
    static func main() {
        let tableSource = NSRange(location: 5, length: 20)
        var projection = EditorProjection(sourceRanges: [tableSource])
        expect(projection.applyDisplayEdit(editedRange: NSRange(location: 2, length: 3), delta: 3), "preceding insertion")
        expect(projection.replacements[0].sourceRange.location == 8, "source table shifts after preceding edit")
        expect(projection.replacements[0].displayRange.location == 8, "display attachment shifts after preceding edit")

        let display = NSMutableAttributedString(string: "prefix \u{FFFC} suffix")
        let attachment = TableAttachment(markdown: "| A |\n| --- |\n| B |")
        display.addAttribute(.attachment, value: attachment, range: NSRange(location: 7, length: 1))
        expect(projection.source(from: display).contains(attachment.originalMarkdown), "attachment source reconstruction")

        let multi = EditorProjection(sourceRanges: [
            NSRange(location: 5, length: 10),
            NSRange(location: 20, length: 6)
        ])
        let mapped = multi.displayRange(forSource: NSRange(location: 3, length: 25))
        expect(mapped == NSRange(location: 3, length: 11), "selection maps across two tables")
        expect(mapped.flatMap(multi.sourceRange(forDisplay:)) == NSRange(location: 3, length: 25), "selection round trip")
        expect(multi.displayTextRanges(forSource: NSRange(location: 0, length: 28)) == [
            NSRange(location: 0, length: 5),
            NSRange(location: 6, length: 5),
            NSRange(location: 12, length: 2)
        ], "attribute ranges exclude attachments")

        let storage = NSTextStorage(string: "ab")
        let layout = NSLayoutManager()
        let container = NSTextContainer()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.allowsUndo = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = textView
        window.makeFirstResponder(textView)
        storage.insert(NSAttributedString(attachment: attachment), at: 1)
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: 1, length: 1))
        textView.deleteBackward(nil)
        expect(EditorProjection.identity.source(from: storage) == "ab", "native deletion removes table source")
        textView.undoManager?.undo()
        expect(EditorProjection.identity.source(from: storage) == "a" + attachment.originalMarkdown + "b", "native undo restores table source")
        print("EditorProjectionRegression: observed all assertions")
    }
}
