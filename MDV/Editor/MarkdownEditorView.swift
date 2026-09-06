import SwiftUI
import AppKit
import QuartzCore

/// Runs at most one immutable parse at a time and retains only the newest
/// snapshot submitted while that parse is active.
nonisolated final class LatestParseScheduler<Result: Sendable>: @unchecked Sendable {
    nonisolated struct Request: Sendable {
        let source: String
        let sourceRevision: UInt64
        let styleRevision: UInt64
        let lifetime: UInt64
    }

    typealias Parser = @Sendable (String) -> Result
    typealias Delivery = @Sendable (Request, Result) -> Void

    private let queue = DispatchQueue(label: "com.mdv.presentation-parser", qos: .userInitiated)
    private let lock = NSLock()
    private let parser: Parser
    private let delivery: Delivery
    private var active = false
    private var pending: Request?

    nonisolated init(parser: @escaping Parser, delivery: @escaping Delivery) {
        self.parser = parser
        self.delivery = delivery
    }

    nonisolated func submit(_ request: Request) {
        lock.lock()
        if active {
            pending = request
            lock.unlock()
            return
        }
        active = true
        lock.unlock()
        start(request)
    }

    nonisolated func cancelPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }

    nonisolated private func start(_ request: Request) {
        queue.async { [self] in
            let result = parser(request.source)
            delivery(request, result)

            lock.lock()
            let next = pending
            pending = nil
            if next == nil { active = false }
            lock.unlock()
            if let next { start(next) }
        }
    }
}

struct MarkdownEditorView: NSViewRepresentable {
    @Binding var document: MarkdownDocument
    var tocModel: ToCModel
    @Environment(MDVTheme.self) private var theme

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = MarkdownTextView()
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.applyTheme(theme)
        textView.font = context.coordinator.typography.body
        textView.textColor = theme.text
        textView.string = document.text

        textView.onTextChange = { [weak coordinator = context.coordinator] in
            coordinator?.handleTextChange()
        }
        textView.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.handleSelectionChange(range)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.tocModel = tocModel

        // Wire TOC scroll callback
        tocModel.scrollToRange = { [weak coordinator = context.coordinator] sourceRange in
            coordinator?.scrollToHeading(sourceRange: sourceRange)
        }

        // Set up NSTextStorageDelegate for structural change detection
        textView.textStorage?.delegate = context.coordinator

        DispatchQueue.main.async {
            context.coordinator.renderMarkdown()
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        let themeChanged = coordinator.lastThemeIsDark != theme.isDark ||
            coordinator.lastFontSize != theme.fontSize ||
            coordinator.lastContentWidth != theme.contentWidth
        coordinator.theme = theme
        coordinator.typography = Typography(baseFontSize: theme.fontSize)
        textView.applyTheme(theme)
        textView.updateTextContainerInset(for: scrollView.contentSize.width)

        if !coordinator.isUpdating {
            // During composition sourceText deliberately contains provisional
            // native text while the document binding still contains the last
            // committed source. That mismatch is not an external replacement.
            guard !textView.hasMarkedText() else { return }
            let textChanged = coordinator.sourceText != document.text
            if textChanged {
                coordinator.replaceSourceFromParent(document.text)
            } else if themeChanged {
                coordinator.cancelPendingPresentation()
                coordinator.noteStyleChanged()
                coordinator.isUpdating = true
                coordinator.renderMarkdown()
                coordinator.isUpdating = false
            }
        }

        // Inset is now updated synchronously via MarkdownTextView.setFrameSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingPresentation()
        coordinator.textView?.onTextChange = nil
        coordinator.textView?.onSelectionChange = nil
        coordinator.tocModel.scrollToRange = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditorView
        var textView: MarkdownTextView?
        var scrollView: NSScrollView?
        var isUpdating = false
        var theme: MDVTheme
        var typography: Typography
        var tocModel: ToCModel
        private let presentationParser: @Sendable (String) -> MarkdownPresentation
        private var parseScheduler: LatestParseScheduler<MarkdownPresentation>!
        private let syntaxHider = SyntaxHider()
        private var lastSyntaxRanges: [NSRange] = []
        private var lastBulletRanges: [NSRange] = []
        var lastThemeIsDark: Bool?
        var lastFontSize: Double?
        var lastContentWidth: Double?

        /// The canonical markdown source text (always pure markdown)
        var sourceText: String

        /// Mapping from attachment positions in display text to source ranges
        private var tableAttachments: [(displayLocation: Int, attachment: TableAttachment)] = []

        /// Owns all canonical-source ↔ editor-display coordinate conversion.
        fileprivate var projection = EditorProjection.identity

        /// Flag to prevent re-rendering during structural re-style
        private var isRestyling = false
        private var pendingPresentation: DispatchWorkItem?
        private var pendingApplication: DispatchWorkItem?
        private var pendingNativeVisibilityUpdate: DispatchWorkItem?
        private var deferredTablePresentation: (
            LatestParseScheduler<MarkdownPresentation>.Request,
            MarkdownPresentation
        )?
        private var sourceRevision: UInt64 = 0
        private var styleRevision: UInt64 = 0
        private var lifetime: UInt64 = 0
        private(set) var latestRequestedPresentationRevision: UInt64?
        private(set) var settledPresentationRevision: UInt64?
        private var installedSemanticRuns: [MarkdownPresentation.Run]?
        private(set) var lastPresentationStorageMutationCount = 0
        private(set) var lastPresentationBatchCount = 0
        private(set) var lastPresentationMaximumBatchMilliseconds = 0.0
        private(set) var lastInputSourceSyncMilliseconds = 0.0
        private(set) var lastInputCacheMaintenanceMilliseconds = 0.0
        private(set) var lastInputGlyphMaintenanceMilliseconds = 0.0
        private(set) var lastInputRangeMaintenanceMilliseconds = 0.0
        private(set) var suppressedRestylingSelectionChangeCount = 0
        var isPresentationPending: Bool {
            pendingPresentation != nil || pendingApplication != nil ||
                (latestRequestedPresentationRevision.map { $0 != settledPresentationRevision } ?? false)
        }
        var presentationDebugState: String {
            "sourceRevision=\(sourceRevision) styleRevision=\(styleRevision) lifetime=\(lifetime) " +
                "requested=\(String(describing: latestRequestedPresentationRevision)) " +
                "settled=\(String(describing: settledPresentationRevision)) " +
                "debounce=\(pendingPresentation != nil) application=\(application != nil) " +
                "applicationWork=\(pendingApplication != nil) marked=\(textView?.hasMarkedText() == true)"
        }
        /// Set by NSTextStorageDelegate when sourceText already incorporates
        /// the current native character edit, avoiding a full display scan in
        /// didChangeText. Attachment-only operations leave this false.
        private var hasIncrementalSourceUpdate = false
        /// Sticky until the next source sync. Once any edit cannot be mapped
        /// incrementally, later callbacks must not apply to stale sourceText.
        private var requiresFullSourceReconstruction = false

        init(_ parent: MarkdownEditorView) {
            self.parent = parent
            self.theme = parent.theme
            self.typography = Typography(baseFontSize: parent.theme.fontSize)
            self.sourceText = parent.document.text
            self.tocModel = parent.tocModel
            self.presentationParser = { @Sendable text in
                MarkdownPresentationParser.parse(text: text)
            }
            super.init()
            configureParseScheduler()
        }

        init(_ parent: MarkdownEditorView, theme: MDVTheme) {
            self.parent = parent
            self.theme = theme
            self.typography = Typography(baseFontSize: theme.fontSize)
            self.sourceText = parent.document.text
            self.tocModel = parent.tocModel
            self.presentationParser = { @Sendable text in
                MarkdownPresentationParser.parse(text: text)
            }
            super.init()
            configureParseScheduler()
        }

        init(
            _ parent: MarkdownEditorView,
            theme: MDVTheme,
            presentationParser: @escaping @Sendable (String) -> MarkdownPresentation
        ) {
            self.parent = parent
            self.theme = theme
            self.typography = Typography(baseFontSize: theme.fontSize)
            self.sourceText = parent.document.text
            self.tocModel = parent.tocModel
            self.presentationParser = presentationParser
            super.init()
            configureParseScheduler()
        }

        private func configureParseScheduler() {
            parseScheduler = LatestParseScheduler(parser: presentationParser) { [weak self] request, result in
                DispatchQueue.main.async { [weak self] in
                    self?.receivePresentation(request, result)
                }
            }
        }

        fileprivate func noteStyleChanged() {
            styleRevision &+= 1
            installedSemanticRuns = nil
        }

        func replaceSourceFromParent(_ source: String) {
            guard let textView else { return }
            cancelPendingPresentation()
            sourceRevision &+= 1
            isUpdating = true
            let selectedSourceRange = projection.sourceRange(forDisplay: textView.selectedRange())
                ?? NSRange(location: 0, length: 0)
            sourceText = source
            textView.string = source
            projection = .identity
            let sourceLength = (source as NSString).length
            let safeLocation = min(selectedSourceRange.location, sourceLength)
            textView.setSelectedRange(NSRange(
                location: safeLocation,
                length: min(selectedSourceRange.length, sourceLength - safeLocation)
            ))
            renderMarkdown()
            isUpdating = false
        }


        // MARK: - Text Change Handling

        func handleTextChange() {
            guard !isUpdating, !isRestyling else { return }
            guard textView?.hasMarkedText() != true else { return }
            syncSourceText(presentImmediately: false)
        }

        /// Publishes canonical markdown immediately. Presentation is either
        /// immediate for structural operations or coalesced for ordinary typing.
        private func syncSourceText(presentImmediately: Bool) {
            guard let textView = textView else { return }

            // Don't sync while a table cell is being edited
            for (_, attachment) in tableAttachments {
                if attachment.embeddedView.isEditing { return }
            }

            isUpdating = true
            guard let textStorage = textView.textStorage else {
                isUpdating = false
                return
            }
            if requiresFullSourceReconstruction {
                sourceText = projection.source(from: textStorage)
                requiresFullSourceReconstruction = false
                hasIncrementalSourceUpdate = false
            } else if hasIncrementalSourceUpdate {
                hasIncrementalSourceUpdate = false
            } else {
                sourceText = projection.source(from: textStorage)
            }
            parent.document.text = sourceText

            if presentImmediately {
                requestPresentationNow()
            } else {
                schedulePresentation()
            }
            isUpdating = false
        }

        private func schedulePresentation() {
            pendingPresentation?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.requestPresentationNow()
            }
            pendingPresentation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func flushPendingPresentation() {
            pendingPresentation?.cancel()
            pendingPresentation = nil
            guard !isRestyling, textView?.hasMarkedText() != true else { return }
            requestPresentationNow()
        }

        func cancelPendingPresentation() {
            pendingNativeVisibilityUpdate?.cancel()
            pendingNativeVisibilityUpdate = nil
            pendingPresentation?.cancel()
            pendingPresentation = nil
            pendingApplication?.cancel()
            pendingApplication = nil
            if application != nil { installedSemanticRuns = nil }
            application = nil
            lifetime &+= 1
            parseScheduler?.cancelPending()
            deferredTablePresentation = nil
            latestRequestedPresentationRevision = nil
        }

        private func requestPresentationNow() {
            pendingPresentation?.cancel()
            pendingPresentation = nil
            guard !isRestyling, textView?.hasMarkedText() != true else { return }
            let request = LatestParseScheduler<MarkdownPresentation>.Request(
                source: sourceText,
                sourceRevision: sourceRevision,
                styleRevision: styleRevision,
                lifetime: lifetime
            )
            latestRequestedPresentationRevision = sourceRevision
            parseScheduler.submit(request)
        }

        private func advanceSourceRevisionOutsideTextStorage() {
            sourceRevision &+= 1
            pendingApplication?.cancel()
            pendingApplication = nil
            application = nil
            installedSemanticRuns = nil
        }

        private func receivePresentation(
            _ request: LatestParseScheduler<MarkdownPresentation>.Request,
            _ presentation: MarkdownPresentation
        ) {
            guard request.sourceRevision == sourceRevision,
                  request.styleRevision == styleRevision,
                  request.lifetime == lifetime,
                  presentation.source == sourceText,
                  textView?.hasMarkedText() != true else { return }

            let palette = MarkdownPresentationPalette(theme: theme, typography: typography)
            let tableRanges = presentation.metadata.tables.map(\.sourceRange)
            if tableRanges != projection.replacements.map(\.sourceRange) {
                guard tableAttachments.allSatisfy({ !$0.attachment.embeddedView.isEditing }) else {
                    deferredTablePresentation = (request, presentation)
                    return
                }
                let result = palette.materialize(presentation: presentation)
                guard request.sourceRevision == sourceRevision,
                      request.styleRevision == styleRevision,
                      request.lifetime == lifetime else { return }
                renderMarkdown(result: result, presentation: presentation)
                settledPresentationRevision = request.sourceRevision
                return
            }
            beginBatchedApplication(presentation, request: request, palette: palette)
        }

        private func retryDeferredTablePresentation() {
            guard tableAttachments.allSatisfy({ !$0.attachment.embeddedView.isEditing }),
                  let deferred = deferredTablePresentation else { return }
            deferredTablePresentation = nil
            receivePresentation(deferred.0, deferred.1)
        }

        private final class Application {
            let presentation: MarkdownPresentation
            let changedRuns: [MarkdownPresentation.Run]
            let request: LatestParseScheduler<MarkdownPresentation>.Request
            let palette: MarkdownPresentationPalette
            var nextRun = 0

            init(
                presentation: MarkdownPresentation,
                changedRuns: [MarkdownPresentation.Run],
                request: LatestParseScheduler<MarkdownPresentation>.Request,
                palette: MarkdownPresentationPalette
            ) {
                self.presentation = presentation
                self.changedRuns = changedRuns
                self.request = request
                self.palette = palette
            }
        }

        private var application: Application?

        private func beginBatchedApplication(
            _ presentation: MarkdownPresentation,
            request: LatestParseScheduler<MarkdownPresentation>.Request,
            palette: MarkdownPresentationPalette
        ) {
            pendingApplication?.cancel()
            let cached = installedSemanticRuns.map {
                MarkdownPresentation(source: presentation.source, runs: $0, metadata: .init())
            }
            let changedRuns = presentation.changedRuns(comparedTo: cached)
            lastPresentationStorageMutationCount = 0
            lastPresentationBatchCount = 0
            lastPresentationMaximumBatchMilliseconds = 0
            application = Application(
                presentation: presentation,
                changedRuns: changedRuns,
                request: request,
                palette: palette
            )
            applyNextPresentationBatch()
        }

        /// Applies only attributes, in bounded transactions. Character storage,
        /// selection, undo and attachment identity remain under AppKit's control.
        private func applyNextPresentationBatch() {
            pendingApplication = nil
            guard let application, let textView, let storage = textView.textStorage,
                  isCurrent(application.request), textView.hasMarkedText() != true else {
                self.application = nil
                return
            }

            let start = CACurrentMediaTime()
            var applied = 0
            isRestyling = true
            storage.beginEditing()
            while application.nextRun < application.changedRuns.count,
                  applied < 16, CACurrentMediaTime() - start < 0.001 {
                let run = application.changedRuns[application.nextRun]
                application.nextRun += 1
                applied += 1
                let attributes = application.palette.attributes(for: run.style)
                for displayRange in projection.displayTextRanges(forSource: run.range)
                where displayRange.length > 0 && NSMaxRange(displayRange) <= storage.length {
                    var effectiveRange = NSRange()
                    let current = storage.attributes(at: displayRange.location, effectiveRange: &effectiveRange)
                    if NSLocationInRange(displayRange.location, effectiveRange),
                       NSMaxRange(effectiveRange) >= NSMaxRange(displayRange),
                       NSDictionary(dictionary: current).isEqual(to: attributes) { continue }
                    storage.setAttributes(attributes, range: displayRange)
                    lastPresentationStorageMutationCount += 1
                }
            }
            storage.endEditing()
            isRestyling = false
            lastPresentationBatchCount += 1
            lastPresentationMaximumBatchMilliseconds = max(
                lastPresentationMaximumBatchMilliseconds,
                (CACurrentMediaTime() - start) * 1_000
            )

            guard isCurrent(application.request) else {
                self.application = nil
                return
            }
            if application.nextRun < application.changedRuns.count {
                let work = DispatchWorkItem { [weak self] in self?.applyNextPresentationBatch() }
                pendingApplication = work
                // Leave a small scheduling gap so AppKit input/timer sources can
                // run between chunks instead of recursively filling main dispatch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.001, execute: work)
                return
            }
            commitPresentationMetadata(application.presentation, request: application.request, to: textView)
            installedSemanticRuns = application.presentation.runs
            self.application = nil
        }

        private func isCurrent(_ request: LatestParseScheduler<MarkdownPresentation>.Request) -> Bool {
            request.sourceRevision == sourceRevision && request.styleRevision == styleRevision &&
                request.lifetime == lifetime && request.source == sourceText
        }

        private func commitPresentationMetadata(
            _ presentation: MarkdownPresentation,
            request: LatestParseScheduler<MarkdownPresentation>.Request,
            to textView: MarkdownTextView
        ) {
            guard isCurrent(request), let layoutManager = textView.layoutManager else { return }
            let metadata = presentation.metadata
            let syntaxRanges = metadata.syntaxRanges.compactMap(projection.displayRange(forSource:))
            let bulletRanges = metadata.bulletRanges.compactMap(projection.displayRange(forSource:))
            let masksChanged = syntaxRanges != lastSyntaxRanges || bulletRanges != lastBulletRanges
            lastSyntaxRanges = syntaxRanges
            lastBulletRanges = bulletRanges
            tocModel.entries = metadata.headings.map { ToCEntry(level: $0.level, title: $0.title, range: $0.range) }
            textView.blockQuoteRanges = metadata.blockQuoteRanges.compactMap {
                projection.displayRange(forSource: $0).map {
                    MarkdownTextView.BlockQuoteRange(
                        characterRange: $0,
                        backgroundColor: theme.blockQuoteBackground
                    )
                }
            }
            textView.codeBlockRanges = metadata.codeBlockRanges.compactMap {
                projection.displayRange(forSource: $0).map { (range: $0, bgColor: theme.codeBackground) }
            }
            textView.horizontalRuleRanges = metadata.horizontalRuleRanges.compactMap {
                projection.displayRange(forSource: $0).map { (range: $0, color: theme.divider) }
            }
            textView.inlineCodeRanges = metadata.inlineCodeRanges.compactMap {
                projection.displayRange(forSource: $0).map { (range: $0, bgColor: theme.codeBackground) }
            }
            if masksChanged {
                syntaxHider.updateVisibility(
                    layoutManager: layoutManager,
                    glyphManager: textView.glyphManager,
                    string: textView.string,
                    selectedRange: textView.selectedRange(),
                    syntaxRanges: lastSyntaxRanges,
                    bulletRanges: lastBulletRanges
                )
            }
            settledPresentationRevision = request.sourceRevision
            textView.needsDisplay = true
        }

        func handleSelectionChange(_ range: NSRange) {
            // NSTextStorage may synchronously move selection while a table's
            // source range is being replaced by its attachment. Projection and
            // glyph masks are intentionally incomplete until that transaction
            // finishes; renderMarkdown performs the authoritative update after
            // inserting all attachments and restoring the mapped selection.
            guard !isRestyling else {
                suppressedRestylingSelectionChangeCount += 1
                return
            }
            guard let textView = textView, let layoutManager = textView.layoutManager else { return }

            syntaxHider.updateVisibility(
                layoutManager: layoutManager,
                glyphManager: textView.glyphManager,
                string: textView.string,
                selectedRange: range,
                syntaxRanges: lastSyntaxRanges,
                bulletRanges: lastBulletRanges
            )

            updateTypingAttributes(at: range)
            textView.needsDisplay = true
        }

        // MARK: - TOC Scroll

        /// Scrolls to a heading given its source-text range, mapping through table attachments.
        func scrollToHeading(sourceRange: NSRange) {
            guard let textView = textView else { return }

            // Map source range to display range by accounting for table attachments
            let displayLocation = projection.displayRange(forSource: sourceRange)?.location ?? sourceRange.location

            let nsString = textView.string as NSString
            let clampedLocation = min(displayLocation, max(0, nsString.length - 1))
            let lineRange = nsString.lineRange(for: NSRange(location: clampedLocation, length: 0))

            // Scroll to the heading line
            textView.scrollRangeToVisible(lineRange)

            // Brief themed highlight instead of yellow showFindIndicator
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x = 0
            rect.size.width = textView.bounds.width
            let origin = textView.textContainerOrigin
            rect.origin.x += origin.x
            rect.origin.y += origin.y

            let highlight = NSView(frame: rect)
            highlight.wantsLayer = true
            highlight.layer?.backgroundColor = theme.accent.withAlphaComponent(0.15).cgColor
            highlight.layer?.cornerRadius = 3
            textView.addSubview(highlight)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.8
                highlight.animator().alphaValue = 0
            } completionHandler: {
                highlight.removeFromSuperview()
            }
        }

        // MARK: - Typing Attributes

        /// Sets typingAttributes based on the current line's markdown structure.
        /// Determines style from the line prefix, not from existing text storage attributes.
        private func updateTypingAttributes(at range: NSRange) {
            guard let textView = textView else { return }
            let nsString = textView.string as NSString
            guard nsString.length > 0 else {
                textView.typingAttributes = [
                    .font: typography.body,
                    .foregroundColor: theme.text,
                    .paragraphStyle: typography.bodyParagraphStyle
                ]
                return
            }

            if textView.codeBlockRanges.contains(where: {
                range.location >= $0.range.location && range.location <= NSMaxRange($0.range)
            }) {
                textView.typingAttributes = [
                    .font: typography.code,
                    .foregroundColor: theme.codeText,
                    .paragraphStyle: typography.codeBlockParagraphStyle
                ]
                return
            }

            let clampedLoc = min(range.location, max(0, nsString.length - 1))
            let lineRange = nsString.lineRange(for: NSRange(location: clampedLoc, length: 0))
            let lineText = nsString.substring(with: lineRange).trimmingCharacters(in: .newlines)

            // After pressing Enter, check if we're on a NEW empty line
            if range.location > 0 {
                let prevChar = nsString.character(at: range.location - 1)
                if prevChar == 0x0A && lineText.isEmpty {
                    textView.typingAttributes = [
                        .font: typography.body,
                        .foregroundColor: theme.text,
                        .paragraphStyle: typography.emptyLineParagraphStyle
                    ]
                    return
                }
            }

            // Determine style from line prefix
            let stripped = lineText.trimmingCharacters(in: .whitespaces)
            let font: NSFont
            let color: NSColor
            let paraStyle: NSParagraphStyle
            if stripped.hasPrefix("#") {
                let level = min(6, stripped.prefix(while: { $0 == "#" }).count)
                font = typography.heading(level: level)
                color = theme.headingText
                paraStyle = typography.headingParagraphStyle(level: level)
            } else if stripped.hasPrefix(">") {
                font = typography.body
                color = theme.secondaryText
                paraStyle = typography.blockQuoteParagraphStyle
            } else {
                font = typography.body
                color = theme.text
                paraStyle = typography.bodyParagraphStyle
            }
            textView.typingAttributes = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paraStyle
            ]
        }

        // MARK: - NSTextStorageDelegate (structural change detection)

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }

            MainActor.assumeIsolated {
                guard !isUpdating, !isRestyling else { return }
                let sourceStart = CACurrentMediaTime()
                sourceRevision &+= 1
                pendingApplication?.cancel()
                pendingApplication = nil
                if application != nil { installedSemanticRuns = nil }
                application = nil
                let oldSource = sourceText as NSString
                let replacement = textStorage.attributedSubstring(from: editedRange).string
                var mappedSourceEdit: NSRange?
                if !requiresFullSourceReconstruction,
                   let edit = projection.sourceEdit(
                    afterDisplayEdit: editedRange,
                    delta: delta,
                    replacement: replacement,
                    displayLength: textStorage.length
                ), NSMaxRange(edit.range) <= oldSource.length {
                    let updated = oldSource.mutableCopy() as! NSMutableString
                    updated.replaceCharacters(in: edit.range, with: edit.replacement)
                    sourceText = updated as String
                    hasIncrementalSourceUpdate = true
                    mappedSourceEdit = edit.range
                } else {
                    hasIncrementalSourceUpdate = false
                    requiresFullSourceReconstruction = true
                }
                lastInputSourceSyncMilliseconds = (CACurrentMediaTime() - sourceStart) * 1_000
                let cacheStart = CACurrentMediaTime()
                if let mappedSourceEdit, installedSemanticRuns != nil {
                    var paragraphProbe = mappedSourceEdit
                    let editEnd = NSMaxRange(mappedSourceEdit)
                    if editEnd < oldSource.length {
                        paragraphProbe = NSUnionRange(
                            paragraphProbe,
                            NSRange(location: editEnd, length: 1)
                        )
                    }
                    let invalidatedParagraph = oldSource.paragraphRange(for: paragraphProbe)
                    installedSemanticRuns = MarkdownPresentationDiff.translateCachedRuns(
                        installedSemanticRuns!,
                        through: .init(
                            range: mappedSourceEdit,
                            replacementLength: (replacement as NSString).length
                        ),
                        invalidatedOldRanges: [invalidatedParagraph]
                    )
                } else {
                    installedSemanticRuns = nil
                }
                lastInputCacheMaintenanceMilliseconds = (CACurrentMediaTime() - cacheStart) * 1_000
                let glyphStart = CACurrentMediaTime()
                if let glyphManager = textView?.glyphManager {
                    syntaxHider.maintainVisibilityAfterEdit(
                        editedRange: editedRange,
                        changeInLength: delta,
                        glyphManager: glyphManager
                    )
                }
                lastInputGlyphMaintenanceMilliseconds = (CACurrentMediaTime() - glyphStart) * 1_000
                let rangeStart = CACurrentMediaTime()
                if delta != 0 {
                    let projectionStayedValid = projection.applyDisplayEdit(editedRange: editedRange, delta: delta)
                    if !projectionStayedValid { projection = .identity }
                }
                maintainPresentationRanges(
                    editedRange: editedRange,
                    delta: delta,
                    displayLength: textStorage.length
                )
                lastInputRangeMaintenanceMilliseconds = (CACurrentMediaTime() - rangeStart) * 1_000
            }
        }

        /// Keeps unaffected presentation ranges stable while an authoritative
        /// presentation is pending. Ranges touched by the edit are discarded.
        private func maintainPresentationRanges(editedRange: NSRange, delta: Int, displayLength: Int) {
            guard let textView else { return }
            lastSyntaxRanges = maintained(lastSyntaxRanges, editedRange: editedRange, delta: delta, limit: displayLength)
            lastBulletRanges = maintained(lastBulletRanges, editedRange: editedRange, delta: delta, limit: displayLength)
            textView.blockQuoteRanges = textView.blockQuoteRanges.compactMap { item in
                maintainedDecoration(item.characterRange, editedRange: editedRange, delta: delta, limit: displayLength).map {
                    MarkdownTextView.BlockQuoteRange(characterRange: $0, backgroundColor: item.backgroundColor)
                }
            }
            textView.codeBlockRanges = textView.codeBlockRanges.compactMap { item in
                maintainedDecoration(item.range, editedRange: editedRange, delta: delta, limit: displayLength).map { (range: $0, bgColor: item.bgColor) }
            }
            textView.horizontalRuleRanges = textView.horizontalRuleRanges.compactMap { item in
                maintained(item.range, editedRange: editedRange, delta: delta, limit: displayLength).map { (range: $0, color: item.color) }
            }
            textView.inlineCodeRanges = textView.inlineCodeRanges.compactMap { item in
                maintainedDecoration(item.range, editedRange: editedRange, delta: delta, limit: displayLength).map { (range: $0, bgColor: item.bgColor) }
            }
            scheduleNativeVisibilityUpdate()
            textView.needsDisplay = true
        }

        /// NSTextStorage invokes its delegate from inside `processEditing`.
        /// Defer NSLayoutManager invalidation until TextKit has consumed the
        /// character edit; masks and presentation ranges remain synchronous.
        private func scheduleNativeVisibilityUpdate() {
            pendingNativeVisibilityUpdate?.cancel()
            let expectedRevision = sourceRevision
            let expectedLifetime = lifetime
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingNativeVisibilityUpdate = nil
                guard self.sourceRevision == expectedRevision,
                      self.lifetime == expectedLifetime,
                      !self.isUpdating,
                      !self.isRestyling,
                      let textView = self.textView,
                      let layoutManager = textView.layoutManager else { return }
                self.syntaxHider.updateVisibility(
                    layoutManager: layoutManager,
                    glyphManager: textView.glyphManager,
                    string: textView.string,
                    selectedRange: textView.selectedRange(),
                    syntaxRanges: self.lastSyntaxRanges,
                    bulletRanges: self.lastBulletRanges
                )
                textView.needsDisplay = true
            }
            pendingNativeVisibilityUpdate = work
            DispatchQueue.main.async(execute: work)
        }

        private func maintained(
            _ ranges: [NSRange], editedRange: NSRange, delta: Int, limit: Int
        ) -> [NSRange] {
            ranges.compactMap { maintained($0, editedRange: editedRange, delta: delta, limit: limit) }
        }

        private func maintained(
            _ range: NSRange, editedRange: NSRange, delta: Int, limit: Int
        ) -> NSRange? {
            let oldLength = max(0, editedRange.length - delta)
            let oldEnd = editedRange.location + oldLength
            let rangeEnd = NSMaxRange(range)
            let overlaps: Bool
            if oldLength == 0 {
                overlaps = range.location < editedRange.location && rangeEnd > editedRange.location
            } else {
                overlaps = range.location < oldEnd && rangeEnd > editedRange.location
            }
            if overlaps { return nil }

            let shifted: NSRange
            if range.location >= oldEnd {
                shifted = NSRange(location: range.location + delta, length: range.length)
            } else {
                shifted = range
            }
            guard shifted.location >= 0, NSMaxRange(shifted) <= limit else { return nil }
            return shifted
        }

        /// Native typing inside an already-presented quote/code surface keeps
        /// that surface in current coordinates until authoritative parsing lands.
        /// Marker masks remain conservative and use `maintained` above.
        private func maintainedDecoration(
            _ range: NSRange, editedRange: NSRange, delta: Int, limit: Int
        ) -> NSRange? {
            let oldLength = max(0, editedRange.length - delta)
            let oldEnd = editedRange.location + oldLength
            let rangeEnd = NSMaxRange(range)
            let editIsInside: Bool
            if oldLength == 0 {
                editIsInside = editedRange.location > range.location && editedRange.location < rangeEnd
            } else {
                editIsInside = editedRange.location >= range.location && oldEnd <= rangeEnd
            }
            if editIsInside {
                let adjusted = NSRange(location: range.location, length: range.length + delta)
                guard adjusted.length > 0, NSMaxRange(adjusted) <= limit else { return nil }
                return adjusted
            }
            return maintained(range, editedRange: editedRange, delta: delta, limit: limit)
        }

        // MARK: - One-Time Full Render (on load and theme change only)

        func renderMarkdown(
            result precomputedResult: RenderResult? = nil,
            presentation precomputedPresentation: MarkdownPresentation? = nil
        ) {
            guard let textView = textView, let layoutManager = textView.layoutManager,
                  let textStorage = textView.textStorage else { return }

            if precomputedResult == nil {
                cancelPendingPresentation()
                sourceRevision &+= 1
            }

            let semanticPresentation = precomputedPresentation ?? (precomputedResult == nil
                ? MarkdownPresentationParser.parse(text: sourceText) : nil)
            let result = precomputedResult ?? MarkdownPresentationPalette(theme: theme, typography: typography)
                .materialize(presentation: semanticPresentation!)
            hasIncrementalSourceUpdate = false
            let selectedSourceRange = projection.sourceRange(forDisplay: textView.selectedRange())
                ?? NSRange(location: 0, length: 0)

            // A previous presentation may contain table attachments. Always put
            // canonical source back before applying source-coordinate attributes.
            if textStorage.string != sourceText {
                isRestyling = true
                textStorage.setAttributedString(NSAttributedString(string: sourceText))
                isRestyling = false
            }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            guard fullRange.length == result.attributedString.length else { return }

            // Apply all attributes at once
            isRestyling = true
            textStorage.beginEditing()
            result.attributedString.enumerateAttributes(in: fullRange) { attrs, range, _ in
                textStorage.setAttributes(attrs, range: range)
            }
            textStorage.endEditing()
            isRestyling = false

            lastSyntaxRanges = result.syntaxRanges
            lastBulletRanges = result.bulletRanges
            tocModel.entries = result.headings

            // Update custom drawing ranges
            textView.blockQuoteRanges = result.blockQuoteRanges.map { range in
                MarkdownTextView.BlockQuoteRange(
                    characterRange: range,
                    backgroundColor: theme.blockQuoteBackground
                )
            }
            textView.codeBlockRanges = result.codeBlockRanges.map { (range: $0, bgColor: theme.codeBackground) }
            textView.horizontalRuleRanges = result.horizontalRuleRanges.map { (range: $0, color: theme.divider) }
            textView.inlineCodeRanges = result.inlineCodeRanges.map { (range: $0, bgColor: theme.codeBackground) }

            lastThemeIsDark = theme.isDark
            lastFontSize = theme.fontSize
            lastContentWidth = theme.contentWidth

            // Create table attachments and adjust all stored ranges
            // Must happen BEFORE fence state init so fenceState matches the display string
            insertTableAttachments(tables: result.tables, textView: textView)

            // Restore cursor (after table insertion may have changed text length)
            let projectedSelection = projection.displayRange(forSource: selectedSourceRange) ?? NSRange(location: 0, length: 0)
            let displayLength = (textView.string as NSString).length
            let safeLocation = min(projectedSelection.location, displayLength)
            let safeRange = NSRange(
                location: safeLocation,
                length: min(projectedSelection.length, displayLength - safeLocation)
            )
            textView.setSelectedRange(safeRange)

            // Apply glyph hiding (after range adjustment)
            syntaxHider.updateVisibility(
                layoutManager: layoutManager,
                glyphManager: textView.glyphManager,
                string: textView.string,
                selectedRange: safeRange,
                syntaxRanges: lastSyntaxRanges,
                bulletRanges: lastBulletRanges
            )

            // The display and canonical source are synchronized after a full
            // render, including external programmatic replacements.
            hasIncrementalSourceUpdate = false
            requiresFullSourceReconstruction = false
            installedSemanticRuns = semanticPresentation?.runs
            settledPresentationRevision = sourceRevision
            textView.needsDisplay = true
        }

        // MARK: - Table Attachments

        private func insertTableAttachments(tables: [TableData], textView: MarkdownTextView) {
            guard let textStorage = textView.textStorage else { return }

            // Remove old table attachment views
            for (_, attachment) in tableAttachments {
                attachment.detachPresentation()
            }
            tableAttachments.removeAll()
            projection = EditorProjection(sourceRanges: tables.map(\.sourceRange))

            guard !tables.isEmpty else { return }

            // Insert attachments from end to start (so earlier ranges aren't shifted)
            // Track the cumulative offset changes for adjusting stored ranges
            isRestyling = true

            // Sort tables by location descending for safe replacement
            let sortedTables = tables.sorted { $0.sourceRange.location > $1.sourceRange.location }

            // Collect (location, lengthRemoved) pairs for range adjustment
            var replacements: [(location: Int, removed: Int)] = []  // ascending order

            let nsSource = sourceText as NSString
            for tableData in sortedTables {
                let originalMD = nsSource.substring(with: tableData.sourceRange)
                let attachment = TableAttachment(
                    tableData: tableData,
                    sourceRange: tableData.sourceRange,
                    originalMarkdown: originalMD,
                    theme: theme,
                    typography: typography
                )

                // Wire editing callbacks
                attachment.embeddedView.onTableEdited = { [weak self, weak attachment] in
                    guard let self = self, let attachment = attachment else { return }
                    let previousMarkdown = attachment.originalMarkdown
                    let newMarkdown = attachment.embeddedView.markdownString()
                    guard newMarkdown != previousMarkdown else { return }
                    if let index = self.tableAttachments.firstIndex(where: { $0.attachment === attachment }),
                       self.projection.replacements.indices.contains(index) {
                        let sourceRange = self.projection.replacements[index].sourceRange
                        self.registerTableUndo(
                            sourceRange: NSRange(location: sourceRange.location, length: (newMarkdown as NSString).length),
                            replacement: previousMarkdown
                        )
                        self.projection.updateReplacement(
                            at: index,
                            sourceLength: (newMarkdown as NSString).length
                        )
                    }
                    attachment.originalMarkdown = newMarkdown
                    self.advanceSourceRevisionOutsideTextStorage()
                    self.hasIncrementalSourceUpdate = false
                    self.requiresFullSourceReconstruction = true
                    self.syncSourceText(presentImmediately: false)
                }
                attachment.embeddedView.onStructuralChange = { [weak self, weak attachment] newMarkdown in
                    guard let self = self, let attachment = attachment else { return }
                    let previousMarkdown = attachment.originalMarkdown
                    if let sourceRange = self.sourceRange(for: attachment) {
                        self.registerTableUndo(
                            sourceRange: NSRange(location: sourceRange.location, length: (newMarkdown as NSString).length),
                            replacement: previousMarkdown
                        )
                    }
                    attachment.originalMarkdown = newMarkdown
                    self.advanceSourceRevisionOutsideTextStorage()
                    self.hasIncrementalSourceUpdate = false
                    self.requiresFullSourceReconstruction = true
                    self.syncSourceText(presentImmediately: true)
                }
                attachment.embeddedView.onEditingStateChanged = { [weak self] isEditing in
                    guard !isEditing else { return }
                    DispatchQueue.main.async { [weak self] in
                        self?.retryDeferredTablePresentation()
                    }
                }

                let attachmentString = NSAttributedString(attachment: attachment)
                textStorage.replaceCharacters(in: tableData.sourceRange, with: attachmentString)

                replacements.append((
                    location: tableData.sourceRange.location,
                    removed: tableData.sourceRange.length
                ))

                tableAttachments.append((
                    displayLocation: tableData.sourceRange.location,
                    attachment: attachment
                ))
            }
            isRestyling = false

            // Sort ascending for range adjustment
            replacements.sort { $0.location < $1.location }
            tableAttachments.sort { $0.displayLocation < $1.displayLocation }

            // Adjust all stored ranges to account for table text → single char replacements
            adjustRanges(&lastSyntaxRanges, for: replacements)
            adjustRanges(&lastBulletRanges, for: replacements)

            // Adjust drawing ranges
            textView.blockQuoteRanges = textView.blockQuoteRanges.compactMap { bq in
                guard let adjusted = adjustRange(bq.characterRange, for: replacements) else { return nil }
                return MarkdownTextView.BlockQuoteRange(
                    characterRange: adjusted,
                    backgroundColor: bq.backgroundColor
                )
            }
            textView.codeBlockRanges = textView.codeBlockRanges.compactMap { cb in
                guard let adjusted = adjustRange(cb.range, for: replacements) else { return nil }
                return (range: adjusted, bgColor: cb.bgColor)
            }
            textView.horizontalRuleRanges = textView.horizontalRuleRanges.compactMap { hr in
                guard let adjusted = adjustRange(hr.range, for: replacements) else { return nil }
                return (range: adjusted, color: hr.color)
            }
            textView.inlineCodeRanges = textView.inlineCodeRanges.compactMap { ic in
                guard let adjusted = adjustRange(ic.range, for: replacements) else { return nil }
                return (range: adjusted, bgColor: ic.bgColor)
            }
        }

        private func sourceRange(for attachment: TableAttachment) -> NSRange? {
            guard let index = tableAttachments.firstIndex(where: { $0.attachment === attachment }),
                  projection.replacements.indices.contains(index) else { return nil }
            return projection.replacements[index].sourceRange
        }

        private func registerTableUndo(sourceRange: NSRange, replacement: String) {
            textView?.undoManager?.registerUndo(withTarget: self) { target in
                target.replaceTableSource(in: sourceRange, with: replacement)
            }
        }

        private func replaceTableSource(in sourceRange: NSRange, with replacement: String) {
            let current = sourceText as NSString
            guard NSMaxRange(sourceRange) <= current.length else { return }
            let inverse = current.substring(with: sourceRange)
            let replacementLength = (replacement as NSString).length

            textView?.undoManager?.registerUndo(withTarget: self) { target in
                target.replaceTableSource(
                    in: NSRange(location: sourceRange.location, length: replacementLength),
                    with: inverse
                )
            }

            let updated = current.mutableCopy() as! NSMutableString
            updated.replaceCharacters(in: sourceRange, with: replacement)
            isUpdating = true
            cancelPendingPresentation()
            sourceText = updated as String
            parent.document.text = sourceText
            renderMarkdown()
            isUpdating = false
        }

        /// Adjust a single range for table replacements. Returns nil if range overlaps a table.
        /// All positions are compared in original (pre-replacement) coordinate space.
        private func adjustRange(_ range: NSRange, for replacements: [(location: Int, removed: Int)]) -> NSRange? {
            var totalDelta = 0
            let rangeStart = range.location
            let rangeEnd = range.location + range.length

            for repl in replacements {
                let replEnd = repl.location + repl.removed

                // Range overlaps the replacement — discard it
                if rangeStart < replEnd && rangeEnd > repl.location { return nil }

                // Replacement is entirely before this range — accumulate shift
                if replEnd <= rangeStart {
                    totalDelta += repl.removed - 1  // replaced N chars with 1
                }
            }

            return NSRange(location: rangeStart - totalDelta, length: range.length)
        }

        /// Adjust an array of ranges in place
        private func adjustRanges(_ ranges: inout [NSRange], for replacements: [(location: Int, removed: Int)]) {
            ranges = ranges.compactMap { adjustRange($0, for: replacements) }
        }

        func textDidChange(_ notification: Notification) {
            // Handled via onTextChange callback
        }
    }
}
