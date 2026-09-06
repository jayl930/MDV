import AppKit
import SwiftUI
@testable import MDV

final class SourceIntegrityDocumentBox {
    var value: MarkdownDocument
    init(_ text: String) { value = MarkdownDocument(text: text) }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@main
struct CoordinatorSourceIntegrityRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let table = "| A |\n| --- |\n| cell |"
        let initial = "lead\n\n\(table)\n\ntail"
        let box = SourceIntegrityDocumentBox(initial)
        let binding = Binding<MarkdownDocument>(get: { box.value }, set: { box.value = $0 })
        let parent = MarkdownEditorView(document: binding, tocModel: ToCModel())
        let coordinator = MarkdownEditorView.Coordinator(parent, theme: MDVTheme())
        let textView = MarkdownTextView()
        textView.string = initial
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        coordinator.renderMarkdown()

        guard let storage = textView.textStorage else { fatalError("text storage") }
        let attachmentRange = (storage.string as NSString).range(of: "\u{FFFC}")
        expect(attachmentRange.location != NSNotFound, "fixture renders table attachment")

        // Simulate coalesced native edits: both storage callbacks arrive before
        // the text view publishes one didChangeText notification.
        storage.deleteCharacters(in: attachmentRange)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        let expected = storage.string
        coordinator.handleTextChange()

        expect(box.value.text == expected, "fallback remains sticky through later incremental edit")
        expect(!box.value.text.contains(table), "deleted attachment source is not resurrected")
        print("CoordinatorSourceIntegrityRegression: observed batched attachment deletion and insertion")
    }
}
