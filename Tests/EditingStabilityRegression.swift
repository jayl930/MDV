import AppKit
import SwiftUI
import QuartzCore
@testable import MDV

private final class StabilityDocumentBox {
    var value: MarkdownDocument
    init(_ text: String) { value = MarkdownDocument(text: text) }
}

private struct Harness {
    let box: StabilityDocumentBox
    let coordinator: MarkdownEditorView.Coordinator
    let textView: MarkdownTextView
    let window: NSWindow
}

private final class DelayedPresentationParser: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirst = DispatchSemaphore(value: 0)
    private var sources: [String] = []
    private var firstDidReturn = false

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sources.count
    }

    var observedSources: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sources
    }

    var didReturnFirst: Bool {
        lock.lock()
        defer { lock.unlock() }
        return firstDidReturn
    }

    func release() { releaseFirst.signal() }

    func parse(_ source: String) -> MarkdownPresentation {
        lock.lock()
        let invocation = sources.count
        sources.append(source)
        lock.unlock()

        if invocation == 0 {
            _ = releaseFirst.wait(timeout: .now() + 3)
            let parsed = MarkdownPresentationParser.parse(text: source)
            // Force multiple main-queue attribute batches. The stale job must
            // stop after an intervening source revision, even if one batch ran.
            let styleA = MarkdownPresentation.SemanticStyle()
            var styleB = MarkdownPresentation.SemanticStyle()
            styleB.bold = true
            let runs = (0..<(source as NSString).length).map {
                MarkdownPresentation.Run(
                    range: NSRange(location: $0, length: 1),
                    style: $0.isMultiple(of: 2) ? styleA : styleB
                )
            }
            lock.lock()
            firstDidReturn = true
            lock.unlock()
            return MarkdownPresentation(source: source, runs: runs, metadata: parsed.metadata)
        }
        return MarkdownPresentationParser.parse(text: source)
    }
}

private func fail(_ message: String) -> Never {
    fatalError("EditingStabilityRegression: \(message)")
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fail(message) }
}

@MainActor
private func pumpMainRunLoop(
    timeout: TimeInterval = 2,
    until condition: () -> Bool
) -> Bool {
    let deadline = CACurrentMediaTime() + timeout
    while CACurrentMediaTime() < deadline {
        if condition() { return true }
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }
    return condition()
}

@MainActor
private func makeHarness(
    _ source: String,
    presentationParser: (@Sendable (String) -> MarkdownPresentation)? = nil
) -> Harness {
    let box = StabilityDocumentBox(source)
    let binding = Binding<MarkdownDocument>(get: { box.value }, set: { box.value = $0 })
    let parent = MarkdownEditorView(document: binding, tocModel: ToCModel())
    let coordinator: MarkdownEditorView.Coordinator
    if let presentationParser {
        coordinator = MarkdownEditorView.Coordinator(
            parent, theme: MDVTheme(), presentationParser: presentationParser
        )
    } else {
        coordinator = MarkdownEditorView.Coordinator(parent, theme: MDVTheme())
    }
    let textView = MarkdownTextView()
    textView.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
    textView.isVerticallyResizable = true
    textView.textContainer?.widthTracksTextView = true
    textView.string = source
    textView.delegate = coordinator
    textView.textStorage?.delegate = coordinator
    coordinator.textView = textView
    textView.onTextChange = { [weak coordinator] in coordinator?.handleTextChange() }
    textView.onSelectionChange = { [weak coordinator] range in coordinator?.handleSelectionChange(range) }
    let window = NSWindow(
        contentRect: textView.frame, styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = textView
    window.makeFirstResponder(textView)
    textView.undoManager?.groupsByEvent = false
    coordinator.renderMarkdown()
    return Harness(box: box, coordinator: coordinator, textView: textView, window: window)
}

private func colorSignature(_ color: NSColor?) -> String {
    guard let color = color?.usingColorSpace(.deviceRGB) else { return "nil" }
    return String(format: "%.4f/%.4f/%.4f/%.4f", color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
}

private func attributeSignature(_ attributes: [NSAttributedString.Key: Any]) -> String {
    let font = attributes[.font] as? NSFont
    let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
    let attachment = attributes[.attachment] as? TableAttachment
    let link = attributes[.link].map { String(describing: $0) } ?? "nil"
    return [
        "font=\(font?.fontName ?? "nil")@\(font.map { String(format: "%.2f", $0.pointSize) } ?? "nil")",
        "fg=\(colorSignature(attributes[.foregroundColor] as? NSColor))",
        "bg=\(colorSignature(attributes[.backgroundColor] as? NSColor))",
        "para=\(paragraph.map { "\($0.alignment.rawValue)/\($0.headIndent)/\($0.firstLineHeadIndent)/\($0.paragraphSpacingBefore)/\($0.paragraphSpacing)" } ?? "nil")",
        "link=\(link)",
        "underline=\(attributes[.underlineStyle].map(String.init(describing:)) ?? "nil")",
        "underlineColor=\(colorSignature(attributes[.underlineColor] as? NSColor))",
        "strike=\(attributes[.strikethroughStyle].map(String.init(describing:)) ?? "nil")",
        "strikeColor=\(colorSignature(attributes[.strikethroughColor] as? NSColor))",
        "syntax=\(attributes[.syntaxToken] != nil)",
        "bullet=\(attributes[.bulletMarker] != nil)",
        "table=\(attachment?.originalMarkdown ?? "nil")"
    ].joined(separator: "|")
}

@MainActor
private func snapshot(_ textView: MarkdownTextView) -> String {
    guard let storage = textView.textStorage else { fail("missing text storage") }
    var canonicalRuns: [(range: NSRange, signature: String)] = []
    for location in 0..<storage.length {
        let signature = attributeSignature(storage.attributes(at: location, effectiveRange: nil))
        if let previous = canonicalRuns.last,
           previous.signature == signature,
           NSMaxRange(previous.range) == location {
            canonicalRuns[canonicalRuns.count - 1].range.length += 1
        } else {
            canonicalRuns.append((NSRange(location: location, length: 1), signature))
        }
    }
    let runs = canonicalRuns.map { "\($0.range.location):\($0.range.length):\($0.signature)" }
    func ranges(_ values: [NSRange]) -> String {
        values.map { "\($0.location):\($0.length)" }.joined(separator: ",")
    }
    return [
        "display=\(storage.string)",
        "attrs=\(runs.joined(separator: "\n"))",
        "hidden=\(textView.glyphManager.hiddenIndices.sorted())",
        "bullets=\(textView.glyphManager.bulletIndices.sorted())",
        "quotes=\(ranges(textView.blockQuoteRanges.map(\.characterRange)))",
        "code=\(ranges(textView.codeBlockRanges.map(\.range)))",
        "rules=\(ranges(textView.horizontalRuleRanges.map(\.range)))",
        "inline=\(ranges(textView.inlineCodeRanges.map(\.range)))"
    ].joined(separator: "\n")
}

@MainActor
private func freshSnapshot(_ source: String, selectedRange: NSRange) -> String {
    let fresh = makeHarness(source)
    let safeLocation = min(selectedRange.location, fresh.textView.textStorage?.length ?? 0)
    fresh.textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
    fresh.coordinator.handleSelectionChange(fresh.textView.selectedRange())
    return snapshot(fresh.textView)
}

@MainActor
private func writeNativeSnapshot(
    _ harness: Harness,
    width: CGFloat,
    height: CGFloat,
    path: String
) {
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let scrollView = NSScrollView(frame: frame)
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = true
    harness.textView.frame = scrollView.contentView.bounds
    harness.textView.minSize = NSSize(width: 0, height: height)
    harness.textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    harness.textView.isVerticallyResizable = true
    harness.textView.isHorizontallyResizable = false
    harness.textView.autoresizingMask = [.width]
    harness.textView.textContainer?.widthTracksTextView = true
    scrollView.documentView = harness.textView
    harness.window.setContentSize(frame.size)
    harness.window.contentView = scrollView
    harness.textView.layoutManager?.ensureLayout(for: harness.textView.textContainer!)
    harness.textView.scrollRangeToVisible(harness.textView.selectedRange())
    scrollView.layoutSubtreeIfNeeded()
    scrollView.displayIfNeeded()
    guard let bitmap = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else {
        fail("could not allocate native snapshot at \(Int(width))x\(Int(height))")
    }
    scrollView.cacheDisplay(in: scrollView.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [.compressionFactor: 0.9]) else {
        fail("could not encode native snapshot at \(Int(width))x\(Int(height))")
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("could not write native snapshot \(path): \(error)")
    }
    print("EditingStabilityRegression: observed and wrote native post-edit snapshot \(path) at \(Int(width))x\(Int(height))")
}

/// Drains only normal AppKit/main-queue work. This deliberately does not call
/// Coordinator.flushPendingPresentation(), so it remains valid for a future
/// asynchronous/background parsing pipeline.
@MainActor
private func waitForAuthoritativePresentation(
    _ harness: Harness,
    expectedSource: String,
    timeout: TimeInterval = 2.0
) -> Double {
    let expected = freshSnapshot(expectedSource, selectedRange: harness.textView.selectedRange())
    let start = CACurrentMediaTime()
    expect(pumpMainRunLoop(timeout: timeout) { !harness.coordinator.isPresentationPending },
           "authoritative presentation did not report settlement for source=\(expectedSource.debugDescription)")
    let actual = snapshot(harness.textView)
    guard actual == expected else {
        let prefix = actual.commonPrefix(with: expected).count
        fail("settled presentation differs from fresh render at snapshot UTF-16-ish offset \(prefix); source=\(harness.box.value.text.debugDescription)")
    }
    return (CACurrentMediaTime() - start) * 1_000
}

private extension String {
    func commonPrefix(with other: String) -> String {
        String(zip(self, other).prefix(while: ==).map(\.0))
    }
}

@MainActor
private func replace(
    _ harness: Harness,
    range: NSRange,
    with replacement: String,
    expected: String,
    label: String
) -> (Double, Double) {
    let quoteBefore = harness.textView.blockQuoteRanges.map(\.characterRange)
    let codeBefore = harness.textView.codeBlockRanges.map(\.range)
    let delta = (replacement as NSString).length - range.length
    let started = CACurrentMediaTime()
    harness.textView.textStorage!.replaceCharacters(in: range, with: replacement)
    harness.coordinator.handleTextChange()
    let editMilliseconds = (CACurrentMediaTime() - started) * 1_000
    expect(harness.box.value.text == expected, "\(label): bound source was not exact immediately; actual=\(harness.box.value.text.debugDescription)")
    if NSMaxRange(range) <= quoteBefore.first?.location ?? -1 {
        expect(harness.textView.blockQuoteRanges.first?.characterRange.location == quoteBefore[0].location + delta,
               "\(label): downstream quote range was damaged before authoritative settle")
    }
    if NSMaxRange(range) <= codeBefore.first?.location ?? -1 {
        expect(harness.textView.codeBlockRanges.first?.range.location == codeBefore[0].location + delta,
               "\(label): downstream code range was damaged before authoritative settle")
    }
    let settled = waitForAuthoritativePresentation(harness, expectedSource: expected)
    return (editMilliseconds, settled)
}

@MainActor
private func nativeInsertWithImmediateDownstreamAttributeCheck(
    source: String,
    insertionLocation: Int,
    insertion: String,
    downstreamAnchors: [String],
    label: String
) {
    let h = makeHarness(source)
    guard let storage = h.textView.textStorage else { fail("\(label): missing storage") }
    let nsSource = source as NSString
    let before = downstreamAnchors.map { anchor -> (String, Int, String) in
        let location = nsSource.range(of: anchor).location
        expect(location != NSNotFound && location > insertionLocation, "\(label): invalid downstream anchor \(anchor)")
        return (anchor, location, attributeSignature(storage.attributes(at: location, effectiveRange: nil)))
    }
    h.textView.setSelectedRange(NSRange(location: insertionLocation, length: 0))
    h.textView.undoManager?.beginUndoGrouping()
    h.textView.insertText(insertion, replacementRange: h.textView.selectedRange())
    h.textView.undoManager?.endUndoGrouping()
    let delta = (insertion as NSString).length
    let expected = NSMutableString(string: source)
    expected.insert(insertion, at: insertionLocation)
    expect(h.box.value.text == expected as String, "\(label): native insertText source was not exact immediately")
    for (anchor, oldLocation, oldSignature) in before {
        let actual = attributeSignature(storage.attributes(at: oldLocation + delta, effectiveRange: nil))
        expect(actual == oldSignature,
               "\(label): downstream \(anchor) attributes changed before parser settlement; before=\(oldSignature), after=\(actual)")
    }
    _ = waitForAuthoritativePresentation(h, expectedSource: expected as String)
}

@main
struct EditingStabilityRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let tableOne = "| A | B |\n| --- | --- |\n| one | two |"
        let tableTwo = "| C |\n| --- |\n| three |"
        let fixture = """
        lead paragraph

        ## Styled heading 😀

        > quoted 😀 **section** with `inline`
        > second quoted line

        ```swift
        let greeting = "안녕 🌍"
        ```

        \(tableOne)

        middle paragraph

        \(tableTwo)

        tail
        """
        let largeUnit = """
        ## Performance section

        한글 👨🏽‍💻 paragraph with **bold**, [link](https://example.com), and `inline code`.

        > Quoted Unicode section 😀
        > Downstream quote line remains stable.

        ```swift
        let value = "large fixture 🌍"
        ```

        \(tableOne)

        """
        let largeFixture = String(repeating: largeUnit, count: 90)
            + "\n## EDIT HERE — UNIQUE MIDDLE MARKER\n\n⟦EDIT HERE 😀⟧ replace only this text.\n\n"
            + String(repeating: largeUnit, count: 90)
            + "\n## END — UNIQUE FINAL MARKER\n"
        let largeFixturePath = "/tmp/mdv-editing-stability-live.md"
        do {
            try largeFixture.write(toFile: largeFixturePath, atomically: true, encoding: .utf8)
            let observed = try String(contentsOfFile: largeFixturePath, encoding: .utf8)
            expect(observed == largeFixture, "large native fixture read-back differs from emitted source")
            expect(observed.contains("⟦EDIT HERE 😀⟧") && observed.hasSuffix("## END — UNIQUE FINAL MARKER\n"),
                   "large native fixture is missing its middle or final observation marker")
            print("EditingStabilityRegression: observed emitted large native fixture \(largeFixturePath), \(observed.utf8.count) bytes")
        } catch {
            fail("could not emit/read large native fixture: \(error)")
        }
        var metrics: [(String, Double, Double)] = []

        do {
            let h = makeHarness(fixture)
            let secondMarker = (h.textView.string as NSString).range(of: "> second quoted line").location
            expect(h.textView.glyphManager.hiddenIndices.contains(secondMarker),
                   "Unicode quote mask: second marker at UTF-16 index \(secondMarker) is visible; hidden indices nearby=\(h.textView.glyphManager.hiddenIndices.filter { abs($0 - secondMarker) <= 3 }.sorted())")
            expect(!h.textView.glyphManager.hiddenIndices.contains(secondMarker - 1),
                   "Unicode quote mask: character before second marker was hidden; marker=\(secondMarker), hidden indices nearby=\(h.textView.glyphManager.hiddenIndices.filter { abs($0 - secondMarker) <= 3 }.sorted())")
        }

        do {
            let h = makeHarness(fixture)
            let expected = "BEGIN 😀\n" + fixture
            let m = replace(h, range: NSRange(location: 0, length: 0), with: "BEGIN 😀\n", expected: expected, label: "beginning insertion")
            metrics.append(("beginning insertion", m.0, m.1))
        }

        do {
            let h = makeHarness(fixture)
            let ns = fixture as NSString
            let target = ns.range(of: "paragraph")
            let expected = ns.replacingCharacters(in: target, with: "")
            let m = replace(h, range: target, with: "", expected: expected, label: "middle deletion")
            metrics.append(("middle deletion", m.0, m.1))
        }

        do {
            let h = makeHarness(fixture)
            let ns = fixture as NSString
            let fenceLanguage = ns.range(of: "swift")
            let expected = ns.replacingCharacters(in: fenceLanguage, with: "")
            let m = replace(h, range: fenceLanguage, with: "", expected: expected, label: "fence language deletion")
            metrics.append(("fence language deletion", m.0, m.1))
        }

        let dirtyParagraphCases: [(label: String, source: String, target: String, replacement: String)] = [
            (
                "join paragraphs by deleting newline",
                "First paragraph.\nSecond paragraph with **bold**.\n\n> downstream quote\n",
                "\n", ""
            ),
            (
                "split paragraph by inserting newline",
                "One paragraph with a split marker and [link](https://example.com).\n\n```swift\nlet x = 1\n```\n",
                " split", "\n split"
            ),
            (
                "remove bold syntax length-changing",
                "Before **bold value** after.\n\n> downstream\n",
                "**bold value**", "bold value"
            ),
            (
                "change link destination same-length",
                "A [linked label](https://example.com) before `inline`.\n\n## Downstream\n",
                "https://example.com", "https://example.net"
            ),
            (
                "remove inline-code syntax same-length",
                "Before `inline` after with **bold**.\n\n> downstream\n",
                "`inline`", " inline "
            ),
            (
                "remove link syntax length-changing",
                "Before [label](https://example.com) after.\n\n```text\ndownstream\n```\n",
                "[label](https://example.com)", "label"
            ),
            (
                "remove structural opening fence before downstream table",
                "Before.\n\n```swift\nlet value = 1\n```\n\n## Downstream heading\n\n| A |\n| --- |\n| cell |\n",
                "```swift\n", ""
            ),
            (
                "remove structural closing fence before downstream table",
                "Before.\n\n```swift\nlet value = 1\n```\n\n## Downstream heading\n\n| A |\n| --- |\n| cell |\n",
                "\n```\n\n## Downstream heading", "\n\n## Downstream heading"
            )
        ]
        for item in dirtyParagraphCases {
            let h = makeHarness(item.source)
            let range = (item.source as NSString).range(of: item.target)
            expect(range.location != NSNotFound, "\(item.label): target missing from fixture")
            let expected = (item.source as NSString).replacingCharacters(in: range, with: item.replacement)
            let m = replace(h, range: range, with: item.replacement, expected: expected, label: item.label)
            metrics.append((item.label, m.0, m.1))
        }

        do {
            // Keep the quote + fenced block at EOF: this exact CRLF/Unicode
            // combination previously provoked AppKit's invalid-glyph-index
            // diagnostic despite source and attribute convergence.
            let source = "Emoji prefix 👨🏽‍💻 before CRLF\r\n\r\n## Styled heading 😀\r\n\r\n> quoted `inline`\r\n\r\n```swift\r\nlet value = 1\r\n```"
            let h = makeHarness(source)
            let target = (source as NSString).range(of: "before CRLF")
            let expected = (source as NSString).replacingCharacters(in: target, with: "before edited CRLF")
            let m = replace(
                h, range: target, with: "before edited CRLF", expected: expected,
                label: "CRLF edit after complex emoji before styled sections"
            )
            let displayLength = h.textView.textStorage?.length ?? 0
            expect(h.textView.glyphManager.hiddenIndices.allSatisfy { $0 >= 0 && $0 < displayLength },
                   "CRLF+emoji: hidden marker index escaped displayed UTF-16 bounds")
            if let layout = h.textView.layoutManager, let container = h.textView.textContainer {
                layout.ensureLayout(for: container)
                expect(layout.numberOfGlyphs <= displayLength,
                       "CRLF+emoji: layout generated more glyphs than displayed UTF-16 units")
            }
            metrics.append(("CRLF+emoji preceding edit", m.0, m.1))
        }

        do {
            let source = "Body edit point.\n\n## Downstream heading\n\nA **bold target** and [link target](https://example.com).\n"
            let insertionLocation = (source as NSString).range(of: "edit point").location + 4
            nativeInsertWithImmediateDownstreamAttributeCheck(
                source: source, insertionLocation: insertionLocation,
                insertion: "⟦TYPED😀⟧",
                downstreamAnchors: ["Downstream heading", "bold target", "link target"],
                label: "native body insert immediate downstream attributes"
            )
        }

        do {
            let source = "```swift\nlet value = 1\n```\n\n## Downstream heading\n\nA **bold target** and [link target](https://example.com).\n"
            let insertionLocation = (source as NSString).range(of: "value").location + 3
            nativeInsertWithImmediateDownstreamAttributeCheck(
                source: source, insertionLocation: insertionLocation,
                insertion: "TYPED😀",
                downstreamAnchors: ["Downstream heading", "bold target", "link target"],
                label: "native code insert immediate downstream attributes"
            )
        }

        do {
            let h = makeHarness(fixture)
            h.textView.undoManager?.removeAllActions()
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            h.textView.undoManager?.beginUndoGrouping()
            h.textView.insertText("undo😀 ", replacementRange: h.textView.selectedRange())
            h.textView.undoManager?.endUndoGrouping()
            let inserted = "undo😀 " + fixture
            expect(h.box.value.text == inserted, "undo/redo: insertion source mismatch")
            _ = waitForAuthoritativePresentation(h, expectedSource: inserted)
            h.textView.undoManager?.undo()
            expect(h.box.value.text == fixture, "undo/redo: undo did not restore bound source")
            _ = waitForAuthoritativePresentation(h, expectedSource: fixture)
            h.textView.undoManager?.redo()
            expect(h.box.value.text == inserted, "undo/redo: redo did not restore bound source")
            _ = waitForAuthoritativePresentation(h, expectedSource: inserted)
        }

        do {
            let h = makeHarness(fixture)
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            h.textView.undoManager?.beginUndoGrouping()
            h.textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            expect(h.box.value.text == fixture, "marked text: provisional composition escaped to binding")
            h.textView.setMarkedText("한👨🏽‍💻", selectedRange: NSRange(location: 9, length: 0), replacementRange: h.textView.markedRange())
            expect(h.box.value.text == fixture, "marked text: replacement composition escaped to binding")
            h.textView.insertText("한👨🏽‍💻", replacementRange: h.textView.markedRange())
            h.textView.undoManager?.endUndoGrouping()
            let committed = "한👨🏽‍💻" + fixture
            expect(h.box.value.text == committed, "marked text: committed Unicode source mismatch")
            _ = waitForAuthoritativePresentation(h, expectedSource: committed)
        }

        do {
            let source = String(repeating: "plain text line for batched stale application\n", count: 80)
            let parser = DelayedPresentationParser()
            let h = makeHarness(source, presentationParser: { source in parser.parse(source) })
            h.textView.textStorage!.insert(NSAttributedString(string: "FIRST "), at: 0)
            h.coordinator.handleTextChange()
            let firstSource = "FIRST " + source
            expect(h.box.value.text == firstSource, "stale batch: first source was not immediately published")
            expect(pumpMainRunLoop { parser.invocationCount == 1 }, "stale batch: delayed parser did not start")
            parser.release()
            expect(pumpMainRunLoop { parser.didReturnFirst }, "stale batch: delayed parser did not return")
            let boldApplied = pumpMainRunLoop { () -> Bool in
                guard let font = h.textView.textStorage?.attribute(.font, at: 1, effectiveRange: nil) as? NSFont else { return false }
                return NSFontManager.shared.traits(of: font).contains(.boldFontMask)
            }
            expect(boldApplied && h.coordinator.isPresentationPending,
                   "stale batch: could not observe a partial first-revision application")

            h.textView.textStorage!.insert(NSAttributedString(string: "SECOND "), at: 0)
            h.coordinator.handleTextChange()
            let finalSource = "SECOND " + firstSource
            expect(h.box.value.text == finalSource, "stale batch: rapid edit source was not exact")
            expect(pumpMainRunLoop { parser.invocationCount >= 2 }, "stale batch: newest parse was not submitted")
            expect(pumpMainRunLoop { !h.coordinator.isPresentationPending }, "stale batch: newest presentation did not settle")
            _ = waitForAuthoritativePresentation(h, expectedSource: finalSource)
            expect(parser.observedSources == [firstSource, finalSource],
                   "stale batch: parser did not coalesce to first/latest sources: \(parser.observedSources)")
        }

        do {
            let source = "# Original\n\nbody\n"
            let parser = DelayedPresentationParser()
            let h = makeHarness(source, presentationParser: { source in parser.parse(source) })
            h.textView.textStorage!.insert(NSAttributedString(string: "typed "), at: (source as NSString).length)
            h.coordinator.handleTextChange()
            expect(pumpMainRunLoop { parser.invocationCount == 1 }, "external replacement: parser did not start")
            let external = "# External replacement 😀\n\n> authoritative\n"
            h.box.value.text = external
            h.coordinator.replaceSourceFromParent(external)
            expect(h.box.value.text == external && h.textView.string == external,
                   "external replacement: exact external source was not installed")
            parser.release()
            expect(pumpMainRunLoop { parser.didReturnFirst }, "external replacement: stale parser did not return")
            _ = pumpMainRunLoop(timeout: 0.15) { false }
            expect(!h.coordinator.isPresentationPending, "external replacement: cancelled job remained pending")
            expect(snapshot(h.textView) == freshSnapshot(external, selectedRange: h.textView.selectedRange()),
                   "external replacement: stale delivery changed authoritative presentation")
        }

        do {
            let source = "# Teardown\n\nbody\n"
            let parser = DelayedPresentationParser()
            let h = makeHarness(source, presentationParser: { source in parser.parse(source) })
            h.textView.textStorage!.insert(NSAttributedString(string: "X"), at: 0)
            h.coordinator.handleTextChange()
            expect(pumpMainRunLoop { parser.invocationCount == 1 }, "teardown: parser did not start")
            let before = snapshot(h.textView)
            MarkdownEditorView.dismantleNSView(NSScrollView(), coordinator: h.coordinator)
            parser.release()
            expect(pumpMainRunLoop { parser.didReturnFirst }, "teardown: stale parser did not return")
            _ = pumpMainRunLoop(timeout: 0.15) { false }
            expect(!h.coordinator.isPresentationPending, "teardown: cancelled coordinator remained pending")
            expect(snapshot(h.textView) == before, "teardown: late parser delivery mutated detached text storage")
        }

        do {
            let source = "# Composition race\n\n> downstream 😀\n"
            let parser = DelayedPresentationParser()
            let h = makeHarness(source, presentationParser: { source in parser.parse(source) })
            h.textView.textStorage!.insert(NSAttributedString(string: "A"), at: 0)
            h.coordinator.handleTextChange()
            let committedBeforeComposition = "A" + source
            expect(pumpMainRunLoop { parser.invocationCount == 1 }, "composition race: parser did not start")
            h.textView.setSelectedRange(NSRange(location: 0, length: 0))
            h.textView.undoManager?.beginUndoGrouping()
            h.textView.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
            expect(h.box.value.text == committedBeforeComposition,
                   "composition race: provisional marked text escaped to binding")
            parser.release()
            expect(pumpMainRunLoop { parser.didReturnFirst }, "composition race: invalidated parser did not return")
            _ = pumpMainRunLoop(timeout: 0.05) { false }
            expect(h.coordinator.settledPresentationRevision != h.coordinator.latestRequestedPresentationRevision,
                   "composition race: stale presentation settled during active composition")
            h.textView.insertText("한😀", replacementRange: h.textView.markedRange())
            h.textView.undoManager?.endUndoGrouping()
            let committed = "한😀" + committedBeforeComposition
            expect(h.box.value.text == committed, "composition race: committed source was not exact")
            expect(pumpMainRunLoop { parser.invocationCount >= 2 }, "composition race: committed parse was not submitted")
            expect(pumpMainRunLoop { !h.coordinator.isPresentationPending }, "composition race: committed presentation did not settle")
            _ = waitForAuthoritativePresentation(h, expectedSource: committed)
        }

        do {
            let captureSource = """
            # Native editing stability capture

            Intro before the edited region.

            ## Edited region

            Replace this marker while downstream styling remains intact.

            > Downstream quote 😀
            > Its second line must retain the correct mask and surface.

            ```swift
            let downstream = "code remains styled 🌍"
            ```

            ## Further downstream

            The second section must remain intact after the edit above.

            - First downstream list item
            - Second downstream list item 😀

            ---

            Final downstream paragraph.
            """
            let marker = "Replace this marker"
            for width in [CGFloat(860), CGFloat(500)] {
                let h = makeHarness(captureSource)
                let range = (captureSource as NSString).range(of: marker)
                let replacement = "⟦EDITED 😀 REGION⟧"
                let expected = (captureSource as NSString).replacingCharacters(in: range, with: replacement)
                h.textView.setSelectedRange(NSRange(location: range.location, length: 0))
                _ = replace(h, range: range, with: replacement, expected: expected, label: "\(Int(width))px native capture edit")
                let editedDisplayRange = (h.textView.string as NSString).range(of: replacement)
                expect(editedDisplayRange.location != NSNotFound, "\(Int(width))px capture: edited region not displayed")
                h.textView.setSelectedRange(editedDisplayRange)
                let path = "/tmp/mdv-editing-stability-\(Int(width))x600.png"
                writeNativeSnapshot(h, width: width, height: 600, path: path)
            }
        }

        for item in metrics {
            print(String(format: "EditingStabilityRegression: %@ synchronous edit/publication %.2f ms; correctness-harness convergence %.2f ms", item.0, item.1, item.2))
        }
        if ProcessInfo.processInfo.environment["MDV_LARGE_STABILITY"] == "1" {
            let unit = "## Section 😀\n\nA **styled** paragraph with [link](https://example.com) and `code`.\n\n> quote line\n\n"
            let repetitions = max(1, 400_000 / unit.utf8.count)
            let source = String(repeating: unit, count: repetitions)
            let loadStart = CACurrentMediaTime()
            let h = makeHarness(source)
            let loadMilliseconds = (CACurrentMediaTime() - loadStart) * 1_000
            expect(!h.coordinator.isPresentationPending,
                   "400KB diagnostic: initial render incorrectly reports pending; requested=\(String(describing: h.coordinator.latestRequestedPresentationRevision)), settled=\(String(describing: h.coordinator.settledPresentationRevision))")
            let middle = (source as NSString).length / 2
            h.textView.setSelectedRange(NSRange(location: middle, length: 0))
            let editStart = CACurrentMediaTime()
            h.textView.undoManager?.beginUndoGrouping()
            h.textView.insertText("⟦400KB EDIT 😀⟧", replacementRange: h.textView.selectedRange())
            h.textView.undoManager?.endUndoGrouping()
            let editMilliseconds = (CACurrentMediaTime() - editStart) * 1_000
            let expected = NSMutableString(string: source)
            expected.insert("⟦400KB EDIT 😀⟧", at: middle)
            expect(h.box.value.text == expected as String, "400KB diagnostic: middle insertion source mismatch")
            expect(!h.textView.hasMarkedText(), "400KB diagnostic: ordinary insertText unexpectedly remained marked")
            expect(h.coordinator.isPresentationPending,
                   "400KB diagnostic: exact edit published but no presentation work is pending; requested=\(String(describing: h.coordinator.latestRequestedPresentationRevision)), settled=\(String(describing: h.coordinator.settledPresentationRevision))")
            let settleStart = CACurrentMediaTime()
            expect(pumpMainRunLoop(timeout: 8) { !h.coordinator.isPresentationPending },
                   "400KB diagnostic: background presentation did not settle in 8s; requested=\(String(describing: h.coordinator.latestRequestedPresentationRevision)), settled=\(String(describing: h.coordinator.settledPresentationRevision)), batches=\(h.coordinator.lastPresentationBatchCount), mutations=\(h.coordinator.lastPresentationStorageMutationCount), maxBatchMs=\(h.coordinator.lastPresentationMaximumBatchMilliseconds), initialRenderMs=\(loadMilliseconds), editMs=\(editMilliseconds)")
            let settleMilliseconds = (CACurrentMediaTime() - settleStart) * 1_000
            expect(h.textView.string == expected as String, "400KB diagnostic: displayed source mismatch after settle")
            print(String(format: "EditingStabilityRegression: optional %d-byte native diagnostic initial render %.1f ms, middle edit/publication %.1f ms, settle %.1f ms, batches %d, storage mutations %d, max batch %.2f ms (no full snapshot or accessibility traversal)", source.utf8.count, loadMilliseconds, editMilliseconds, settleMilliseconds, h.coordinator.lastPresentationBatchCount, h.coordinator.lastPresentationStorageMutationCount, h.coordinator.lastPresentationMaximumBatchMilliseconds))
        }
        print("EditingStabilityRegression: observed \(metrics.count) differential edits, 2 native insertText immediate-downstream-attribute scenarios, 4 deterministic async races (partial-stale/latest-only, external replacement, teardown, active composition), exact bound source, masks, decorations, undo/redo, and two tables")
    }
}
