import AppKit
import SwiftUI
@testable import MDV

private final class GlyphWarningDocumentBox {
    var value: MarkdownDocument
    init(_ text: String) { value = MarkdownDocument(text: text) }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("GlyphLayoutWarningRegression: \(message)") }
}

private struct GlyphWarningHarness {
    let box: GlyphWarningDocumentBox
    let coordinator: MarkdownEditorView.Coordinator
    let textView: MarkdownTextView
    let window: NSWindow
}

@MainActor
private func makeGlyphWarningHarness(_ source: String) -> GlyphWarningHarness {
    let box = GlyphWarningDocumentBox(source)
    let binding = Binding<MarkdownDocument>(get: { box.value }, set: { box.value = $0 })
    let parent = MarkdownEditorView(document: binding, tocModel: ToCModel())
    let coordinator = MarkdownEditorView.Coordinator(parent, theme: MDVTheme())
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true
    textView.string = source
    textView.delegate = coordinator
    textView.textStorage?.delegate = coordinator
    coordinator.textView = textView
    textView.onTextChange = { [weak coordinator] in coordinator?.handleTextChange() }
    let window = NSWindow(contentRect: textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = textView
    window.makeFirstResponder(textView)
    coordinator.renderMarkdown()
    return GlyphWarningHarness(box: box, coordinator: coordinator, textView: textView, window: window)
}

@main
struct GlyphLayoutWarningRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let variant = ProcessInfo.processInfo.environment["MDV_GLYPH_VARIANT"] ?? "minimal"
        let original = variant == "original"
            ? "EDIT 👨🏽‍💻 before CRLF\r\n\r\n## Styled heading 😀\r\n\r\n> quoted `inline`\r\n\r\n```swift\r\nlet value = 1\r\n```"
            : "EDIT\n`x`"
        let edited = (original as NSString).replacingCharacters(
            in: (original as NSString).range(of: "EDIT"), with: "EDIT-LONG"
        )
        let active = makeGlyphWarningHarness(original)
        let editRange = (active.textView.string as NSString).range(of: "EDIT")
        FileHandle.standardError.write(Data("GlyphLayoutWarningRegression: begin length-changing edit\n".utf8))
        active.textView.textStorage!.replaceCharacters(in: editRange, with: "EDIT-LONG")
        active.coordinator.handleTextChange()
        FileHandle.standardError.write(Data("GlyphLayoutWarningRegression: end length-changing edit\n".utf8))
        expect(active.box.value.text == edited, "active editor did not publish exact edited source")
        let length = active.textView.textStorage?.length ?? 0
        expect(active.textView.glyphManager.hiddenIndices.allSatisfy { $0 >= 0 && $0 < length },
               "hidden marker index escaped UTF-16 storage bounds")
        if let layout = active.textView.layoutManager, let container = active.textView.textContainer {
            layout.ensureLayout(for: container)
            expect(layout.numberOfGlyphs <= length, "layout generated more glyphs than UTF-16 units")
        }
        active.textView.displayIfNeeded()
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        print("GlyphLayoutWarningRegression: observed \(variant) exact source and bounded masks")
        withExtendedLifetime(active) {}

        do {
            let rapid = makeGlyphWarningHarness("EDIT\n`x`")
            rapid.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 4), with: "LONG")
            rapid.coordinator.handleTextChange()
            rapid.textView.textStorage!.insert(NSAttributedString(string: "Z"), at: 0)
            rapid.coordinator.handleTextChange()
            expect(rapid.box.value.text == "ZLONG\n`x`", "rapid edits did not publish exact final source")
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }

        do {
            let replaced = makeGlyphWarningHarness("EDIT\n`x`")
            replaced.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 4), with: "LONG")
            replaced.coordinator.handleTextChange()
            replaced.box.value.text = ""
            replaced.coordinator.replaceSourceFromParent("")
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            expect(replaced.textView.string.isEmpty && replaced.box.value.text.isEmpty,
                   "external empty replacement was changed by queued invalidation")
        }

        do {
            let detached = makeGlyphWarningHarness("EDIT\n`x`")
            detached.textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 4), with: "LONG")
            detached.coordinator.handleTextChange()
            let beforeDetach = detached.textView.string
            MarkdownEditorView.dismantleNSView(NSScrollView(), coordinator: detached.coordinator)
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            expect(detached.textView.string == beforeDetach, "queued invalidation mutated detached editor")
        }
        print("GlyphLayoutWarningRegression: observed rapid-edit, external-empty, and teardown invalidation lifetimes")
    }
}
