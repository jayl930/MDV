import AppKit
import SwiftUI
import QuartzCore
#if !MDV_STANDALONE
@testable import MDV
#endif

final class DocumentBox {
    var value: MarkdownDocument
    init(_ text: String) { value = MarkdownDocument(text: text) }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@MainActor
private func settlePresentation(
    _ coordinator: MarkdownEditorView.Coordinator,
    label: String = "unspecified",
    timeout: TimeInterval = 20
) {
    coordinator.flushPendingPresentation()
    let deadline = Date().addingTimeInterval(timeout)
    while coordinator.isPresentationPending && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    if coordinator.isPresentationPending {
        let diagnostic = "EditorCoordinatorRegression timeout [\(label)]: \(coordinator.presentationDebugState)\n"
        FileHandle.standardError.write(Data(diagnostic.utf8))
    }
    expect(!coordinator.isPresentationPending, "asynchronous presentation settles before timeout [\(label)]")
    expect(
        coordinator.latestRequestedPresentationRevision == coordinator.settledPresentationRevision,
        "settled presentation revision matches latest requested revision"
    )
}

@MainActor
private func measuredSettlement(
    _ coordinator: MarkdownEditorView.Coordinator,
    label: String,
    timeout: TimeInterval = 20
) -> (elapsedMilliseconds: Double, maximumServiceGapMilliseconds: Double) {
    var lastService = CACurrentMediaTime()
    var maximumGap = 0.0
    let timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { _ in
        let now = CACurrentMediaTime()
        maximumGap = max(maximumGap, (now - lastService) * 1_000)
        lastService = now
    }
    let start = CACurrentMediaTime()
    settlePresentation(coordinator, label: label, timeout: timeout)
    let finished = CACurrentMediaTime()
    maximumGap = max(maximumGap, (finished - lastService) * 1_000)
    let elapsed = (finished - start) * 1_000
    timer.invalidate()
    return (elapsed, maximumGap)
}

@main
struct EditorCoordinatorRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let firstTable = "| A | B |\n| --- | --- |\n| one | two |"
        let secondTable = "| C |\n| --- |\n| three |"
        let initial = "lead\n\n[one](https://a)\n\n\(firstTable)\n\nmiddle\n\n\(secondTable)\n"
        let box = DocumentBox(initial)
        let binding = Binding<MarkdownDocument>(get: { box.value }, set: { box.value = $0 })
        let parent = MarkdownEditorView(document: binding, tocModel: ToCModel())
        let coordinator = MarkdownEditorView.Coordinator(parent, theme: MDVTheme())
        let textView = MarkdownTextView()
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = initial
        textView.delegate = coordinator
        textView.textStorage?.delegate = coordinator
        coordinator.textView = textView
        textView.onTextChange = { [weak coordinator] in coordinator?.handleTextChange() }
        textView.onSelectionChange = { [weak coordinator] range in coordinator?.handleSelectionChange(range) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: window.contentView!.bounds)
        textView.frame = scrollView.contentView.bounds
        scrollView.documentView = textView
        window.contentView = scrollView
        window.makeKeyAndOrderFront(nil)
        textView.undoManager?.groupsByEvent = false
        coordinator.renderMarkdown()
        expect(
            coordinator.suppressedRestylingSelectionChangeCount > 0,
            "table attachment insertion suppresses reentrant selection presentation"
        )
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.displayIfNeeded()

        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.beginUndoGrouping()
        textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        expect(box.value.text == initial, "provisional marked text is not published")
        let marked = textView.markedRange()
        textView.setMarkedText("한😀", selectedRange: NSRange(location: 3, length: 0), replacementRange: marked)
        expect(box.value.text == initial, "replacement marked text remains unpublished")
        textView.insertText("한😀", replacementRange: textView.markedRange())
        textView.undoManager?.endUndoGrouping()
        let committedIMEText = box.value.text
        expect(committedIMEText.hasPrefix("한😀lead"), "committed composition publishes exact emoji source")
        textView.undoManager?.undo()
        expect(box.value.text == initial, "undo restores source before composed input")
        textView.undoManager?.redo()
        expect(box.value.text == committedIMEText, "redo restores composed input source")

        box.value.text = initial
        coordinator.replaceSourceFromParent(initial)

        let unicodeUnit = """
        ## 한글 👨🏽‍💻 e\u{301} heading

        A **bold** paragraph with [링크 😀](https://example.com).

        > 인용문 with emoji 🧑🏾‍🚀

        ```swift
        let greeting = "안녕 🌍"
        ```

        """
        let largeText = String(repeating: unicodeUnit, count: 800)
        box.value.text = largeText
        coordinator.replaceSourceFromParent(largeText)
        let insertion = "typed😀 "
        let insertionLocation = (String(repeating: unicodeUnit, count: 400) as NSString).length
        textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
        let typingStart = CACurrentMediaTime()
        textView.undoManager?.beginUndoGrouping()
        textView.insertText(insertion, replacementRange: textView.selectedRange())
        textView.undoManager?.endUndoGrouping()
        let typingMilliseconds = (CACurrentMediaTime() - typingStart) * 1_000
        let expectedLargeSource = NSMutableString(string: largeText)
        expectedLargeSource.insert(insertion, at: insertionLocation)
        let expectedSource = expectedLargeSource as String
        expect(
            box.value.text == expectedSource,
            "large mixed-Unicode insertion preserves exact UTF-16 source (expected \((expectedSource as NSString).length), got \((box.value.text as NSString).length))"
        )
        let presentationStart = CACurrentMediaTime()
        let settlement = measuredSettlement(coordinator, label: "large insertion")
        let presentationMilliseconds = max(
            settlement.elapsedMilliseconds,
            (CACurrentMediaTime() - presentationStart) * 1_000
        )
        let visibleLayoutStart = CACurrentMediaTime()
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(forBoundingRect: textView.visibleRect, in: textContainer)
        }
        let visibleLayoutMilliseconds = (CACurrentMediaTime() - visibleLayoutStart) * 1_000
        expect(textView.string == expectedSource, "deferred presentation preserves mixed-Unicode display")
        print(String(format: "EditorCoordinatorRegression: %d KB mixed-Markdown insert+publication %.1f ms (source %.1f, cache %.1f, glyph %.1f, ranges %.1f); async presentation settlement %.1f ms; max main-loop service gap %.1f ms; visible layout %.1f ms; changed batches %d; storage mutations %d; max batch %.1f ms", largeText.utf8.count / 1_000, typingMilliseconds, coordinator.lastInputSourceSyncMilliseconds, coordinator.lastInputCacheMaintenanceMilliseconds, coordinator.lastInputGlyphMaintenanceMilliseconds, coordinator.lastInputRangeMaintenanceMilliseconds, presentationMilliseconds, settlement.maximumServiceGapMilliseconds, visibleLayoutMilliseconds, coordinator.lastPresentationBatchCount, coordinator.lastPresentationStorageMutationCount, coordinator.lastPresentationMaximumBatchMilliseconds))

        var burstMilliseconds: [Double] = []
        for token in ["한", "😀", "e\u{301}", "글", "🧑🏾‍🚀", "a", "b", "c", "🌍", "끝"] {
            let start = CACurrentMediaTime()
            textView.undoManager?.beginUndoGrouping()
            textView.insertText(token, replacementRange: textView.selectedRange())
            textView.undoManager?.endUndoGrouping()
            burstMilliseconds.append((CACurrentMediaTime() - start) * 1_000)
        }
        let sortedBurst = burstMilliseconds.sorted()
        expect(box.value.text == textView.string, "native Unicode burst publishes exact source")
        print(String(format: "EditorCoordinatorRegression: 10-key mixed-Unicode burst p50 %.1f ms; max %.1f ms", sortedBurst[sortedBurst.count / 2], sortedBurst.last!))

        let codeBodyFixture = "before\n\n```swift\nlet value = 42\n```\n\nafter\n"
        box.value.text = codeBodyFixture
        coordinator.replaceSourceFromParent(codeBodyFixture)
        let codeInsertionLocation = NSMaxRange((textView.string as NSString).range(of: "let"))
        textView.setSelectedRange(NSRange(location: codeInsertionLocation, length: 0))
        textView.undoManager?.beginUndoGrouping()
        textView.insertText("x😀", replacementRange: textView.selectedRange())
        textView.undoManager?.endUndoGrouping()
        expect(
            textView.codeBlockRanges.contains { NSLocationInRange(codeInsertionLocation, $0.range) },
            "code-body insertion retains its provisional code decoration before parsing settles"
        )
        let insertedFont = textView.textStorage?.attribute(
            .font, at: codeInsertionLocation, effectiveRange: nil
        ) as? NSFont
        expect(
            insertedFont?.fontName == coordinator.typography.code.fontName,
            "code-body insertion immediately uses the code font"
        )
        settlePresentation(coordinator, label: "code body insertion")

        let visualFixture = "# Editing check\n\n한글 👩🏽‍💻 remains intact.\n\n> Balanced quote\n\n```swift\nlet value = 42\n```\n\nTyping: "
        box.value.text = visualFixture
        coordinator.replaceSourceFromParent(visualFixture)
        textView.setSelectedRange(NSRange(location: (visualFixture as NSString).length, length: 0))
        textView.undoManager?.beginUndoGrouping()
        textView.insertText("typed😀", replacementRange: textView.selectedRange())
        textView.undoManager?.endUndoGrouping()
        settlePresentation(coordinator, label: "visual fixture insertion")
        expect(box.value.text.hasSuffix("Typing: typed😀"), "visual fixture publishes inserted emoji")
        expect(textView.string.hasSuffix("Typing: typed😀"), "visual fixture displays inserted emoji")
        textView.scrollRangeToVisible(NSRange(location: 0, length: 1))
        textView.layoutSubtreeIfNeeded()
        let snapshotView = scrollView.contentView
        if let bitmap = snapshotView.bitmapImageRepForCachingDisplay(in: snapshotView.bounds) {
            snapshotView.cacheDisplay(in: snapshotView.bounds, to: bitmap)
            let properties: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.9]
            if let png = bitmap.representation(using: .png, properties: properties) {
                let snapshotURL = URL(fileURLWithPath: "/tmp/mdv-editor-mixed-unicode.png")
                try! png.write(to: snapshotURL)
                print("EditorCoordinatorRegression: wrote \(snapshotURL.path)")
            }
        }

        box.value.text = initial
        coordinator.replaceSourceFromParent(initial)

        textView.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        coordinator.handleTextChange()
        expect(box.value.text.hasPrefix("Xlead"), "ordinary typing publishes canonical source")

        let displayed = textView.string as NSString
        let aRange = displayed.range(of: "https://a")
        textView.textStorage!.replaceCharacters(in: NSRange(location: NSMaxRange(aRange) - 1, length: 1), with: "b")
        coordinator.handleTextChange()
        settlePresentation(coordinator, label: "same-length link edit")
        let labelRange = (textView.string as NSString).range(of: "one")
        expect(textView.textStorage!.attribute(.link, at: labelRange.location, effectiveRange: nil) as? String == "https://b", "same-length link edit refreshes link attribute")

        let attachmentRange = (textView.string as NSString).range(of: "\u{FFFC}")
        guard let attachment = textView.textStorage!.attribute(.attachment, at: attachmentRange.location, effectiveRange: nil) as? TableAttachment else { fatalError("first attachment") }
        guard let attachmentCell = attachment.attachmentCell as? TableAttachmentCell else { fatalError("first attachment cell") }
        let attachmentFrame = NSRect(x: 0, y: 100, width: 500, height: attachmentCell.cellSize().height)
        attachmentCell.draw(withFrame: attachmentFrame, in: textView)
        attachment.embeddedView.beginEditing(row: 1, col: 0)
        guard let editor = attachment.embeddedView.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }) else { fatalError("cell editor") }
        editor.stringValue = "a much longer edited value"
        textView.undoManager?.beginUndoGrouping()
        _ = attachment.embeddedView.control(editor, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:)))
        textView.undoManager?.endUndoGrouping()
        settlePresentation(coordinator, label: "table cell edit")
        expect(box.value.text.contains("a much longer edited value"), "cell Tab publishes longer source")
        let currentAttachmentRange = (textView.string as NSString).range(of: "\u{FFFC}")
        let currentAttachment = textView.textStorage!.attribute(.attachment, at: currentAttachmentRange.location, effectiveRange: nil) as? TableAttachment
        expect(currentAttachment === attachment, "cell length change keeps the same attachment in storage")
        expect(attachment.embeddedView.window === window, "cell length change keeps table view in its window")

        let beforeStructuralSource = box.value.text
        let rowsBefore = MarkdownTable(markdown: attachment.originalMarkdown)!.rowCount
        textView.undoManager?.removeAllActions()
        textView.undoManager?.beginUndoGrouping()
        attachment.embeddedView.perform(Selector(("addRowBelow:")), with: nil)
        textView.undoManager?.endUndoGrouping()
        expect(MarkdownTable(markdown: box.value.text.components(separatedBy: "\n\n").first(where: { $0.contains("| A |") })!)!.rowCount == rowsBefore + 1, "real structural action publishes source")
        let structuralSource = box.value.text
        textView.undoManager?.undo()
        expect(box.value.text == beforeStructuralSource, "table structural undo restores exact prior source")
        textView.undoManager?.redo()
        expect(box.value.text == structuralSource, "table structural redo restores source")

        let attachmentLocations = (0..<textView.textStorage!.length).filter {
            textView.textStorage!.attribute(.attachment, at: $0, effectiveRange: nil) is TableAttachment
        }
        expect(attachmentLocations.count == 2, "two table attachments rendered")
        textView.textStorage!.deleteCharacters(in: NSRange(location: attachmentLocations[0], length: 1))
        coordinator.handleTextChange()
        settlePresentation(coordinator, label: "table attachment deletion")
        expect(!box.value.text.contains("a much longer edited value"), "deleting first attachment deletes its source")
        expect(box.value.text.contains(secondTable), "deleting first table preserves exact second source")
        print("EditorCoordinatorRegression: observed all assertions")
    }
}
