# MDV architecture and implementation method

This architecture is grounded in the repository inspected on 2026-09-06. The module descriptions define intended ownership; the implementation record below distinguishes the changes made in this session from remaining work.

## Product contract

MDV opens ordinary Markdown files, provides one native writing and reading surface, and offers a document outline and Finder preview. The user specified lightweight, fast, easy, aesthetically pleasing, and Apple-native. Preserve SwiftUI document/window integration and AppKit text editing. Keep plain Markdown as the saved format.

## Current implementation contract: responsive and stable editing

Source: the user's renewed editing-performance and cross-section-breakage report, 2026-09-06. This section specifies this task's architecture. It is not an implementation or validation claim; the observations recorded below it will distinguish those states. The root owns this design and integration; GPT-5.6 Sol agents own production and regression code.

### Two independent responsibilities

The native edit transaction owns characters, selection, composition, undo, and canonical Markdown publication. The presentation module owns interpretation and appearance. Publishing an edit must not wait for parsing or formatting. Presentation must never write an older source snapshot back into native storage.

An edit revision describes every native character mutation, including provisional marked text. A presentation generation also changes on external replacement, style changes, cancellation, and teardown. Checking source length or token counts is insufficient: distinct texts can have identical lengths and syntax counts. A delivery and every continuation must match the current revision and generation, with no active marked text or table-cell editor that its installation would disturb.

### Semantic presentation interface

`MarkdownPresentationParser.parse(text:)` accepts an immutable String and returns Sendable Foundation value data: the source, ordered disjoint UTF-16 style runs, syntax and bullet spans, block decorations, table descriptions, and headings. Its implementation exclusively owns the swift-markdown AST traversal and source-location conversion. It does not access AppKit, the theme, the native text storage, or mutable shared parser state.

Each semantic style records the effective font role and traits, foreground role, paragraph role, link destination, and strikethrough state. Resolving overlapping AST styles happens in the parser, in the same order as authoritative rendering. This avoids moving parsing off-thread only to repeat an expensive attribute-building traversal on the input thread.

The main-thread `MarkdownPresentationPalette` resolves a semantic style to cached native attributes. The existing synchronous `InlineRenderer.render` remains an adapter for initial/exceptional rendering and Quick Look, consuming the same parser and palette. It must not become an independent Markdown implementation. A precomputed semantic result must be reusable without parsing again.

### Scheduling and installation method

1. **Native edit:** apply the UTF-16 replacement, invalidate any in-flight installation, translate unaffected display ranges and glyph masks into the new coordinates, and publish committed source. Never publish provisional composition as a completed document edit.
2. **Request:** debounce ordinary edits, holding at most one active parse and one latest pending snapshot. Replacing the pending snapshot must not enqueue another worker job. A serial worker owns computation; completion carries its immutable identity back to the main thread.
3. **Delivery:** discard stale or cancelled identities before changing any attributes, decorations, attachments, or outline entries. If composition or table editing is active, defer installation and request the current state when the edit commits. Do not spin a main-thread retry loop.
4. **Application:** map semantic runs through the current source/display projection, preserving attachment attributes. Resolve cached styles lazily and skip equal attributes. Limit work per main-loop turn by elapsed time and a finite run count, then yield. Prioritize visible runs only if doing so does not require whole-document layout. Never keep a text-storage editing transaction open across a yield.
5. **Interruption:** a new edit cancels remaining old-coordinate batches. Already installed attributes move naturally with native text storage; metadata must remain current-coordinate data. The next authoritative result covers the entire latest source, including syntax changes whose effects extend to document end.
6. **Commit:** publish authoritative masks, decorations, and headings with a defined installation point, and mark the presentation settled only after all its required attribute work completes. No presentation-only undo entries, character replacements, or document publication.

The first integrated measurement showed that merely budgeting every run still introduces excessive settlement delay. The required refinement is an installed-semantic-run cache in source coordinates. Translate its known spans through UTF-16 edits and invalidate the touched paragraph, where native paragraph-attribute propagation can occur. Compare a fresh plan against these known spans with a linear ordered traversal, regardless of run segmentation; submit only unknown or different style intervals to native storage. Style removal is a real change and must install the default style, not skip it. Theme changes, attachment reconstruction, and interrupted partial installation conservatively invalidate the cache. Reestablish it only from a fully installed authoritative plan. This optimization must not reuse old coordinates or assume equal token counts imply equal output.

Table topology changes are the exceptional projected-storage transaction: preserve identities when structure is unchanged; otherwise validate the current revision immediately before atomically rebuilding the projection and restoring source-mapped selection. Source reconstruction must remain attachment-identity-aware after coalesced edits. The existing sticky reconstruction fallback is part of the correctness contract, not disposable optimization code.

Full-load rendering and table-topology rebuilding may remain synchronous in this iteration if measured and explicitly reported. They must not silently become the ordinary typing path. An open fence can legitimately change later Markdown interpretation; “unrelated sections remain intact” means agreement with a fresh authoritative interpretation, not freezing formatting that the edited source no longer specifies.

### Verification and ownership

- **Sol semantic parser:** first capture current renderer behavior on mixed syntax fixtures, then compare the extracted parser/materializer against that baseline. Separately expose and correct Unicode range defects rather than recording broken ranges as desired behavior.
- **Sol coordinator:** implement revision scheduling, bounded installation, composition/table safeguards, and migrate existing native tests to wait for actual asynchronous settlement. Provide an injectable parsing seam so blocked/stale deliveries can be exercised deterministically through production scheduling.
- **Sol stability tests:** type and delete before and inside multiple sections; compare actual source, projected text, effective attributes, masks, decorations, and attachments against fresh authoritative output. Include emoji, combining text, multiline quotes, fences, tables, undo/redo, and edits while a parse or installation is outstanding.
- **Root:** inspect implementation ordering and Sendable isolation, build the consumed native product, rerun regressions, inspect post-edit native images at ordinary/narrow widths, and record measurements and unobserved live-host checks honestly.

Measure input handling, total presentation settlement, and maximum main-loop service gap separately on the same fixture. A long background parse can be acceptable while a short main-thread stall can still interrupt typing. Compare Debug with Debug and optimized with optimized; do not present minimum samples as guaranteed latency. A passing source assertion does not establish visual integrity, and a native harness screenshot does not establish installed-app interaction.

### This task's baseline observations

The root ran `bash Tests/run-editor-coordinator-regression.sh` before implementation. The existing native harness observed its source/composition/undo assertions and measured 5.2 ms insertion/publication, 4.7 ms median and 13.1 ms maximum for its ten-key Unicode burst, and 237.7 ms synchronous deferred presentation on its 147 KB repeated mixed-Markdown fixture. These measurements identify the delayed input-thread work; they do not reproduce every reported cross-section defect. The new differential regression will establish the specific stability failures separately.

The root then built the current Debug product and ran `bash Tests/run-editing-stability-regression.sh`. It failed at the deliberately targeted multiline Unicode quote assertion: the correct second marker was at UTF-16 offset 76, but hidden indices included 74, 75, and 76. In the inspected renderer, `applyBlockQuote` advanced later line locations using Swift Character counts. Emoji on an earlier line therefore shifted later hiding onto ordinary text. This is a reproduced stability defect, distinct from the measured main-thread presentation stall.

### Current implementation record

The production implementation now uses the semantic parser, a serial latest-only parsing scheduler, source/style/lifetime fences, and changed-run attribute installation. `MarkdownPresentation.swift` owns Foundation-only parsing and the linear semantic diff/cache translation. `InlineRenderer` and its cached palette adapt that result to native attributes. The old traversal is excluded from production and retained only behind the differential-test compilation flag, where it provides an independent parity reference and reproduces the original Unicode defect.

The coordinator keeps the native storage identity during ordinary edits, publishes committed source immediately, and rejects stale parsing/application work. Changed runs are applied in transactions capped at 16 runs and approximately 1 ms of loop computation, with a 1 ms scheduling gap between continuations. These are implementation limits, not a guaranteed end-to-end latency budget: TextKit's transaction completion, layout, metadata installation, and operating-system scheduling are measured separately. Source-order application is used; viewport-first ordering is not implemented.

Cached semantic spans are translated through edits, with affected paragraphs invalidated, including the following character when a deletion can join paragraphs. Interrupted partial installation, table reconstruction, and style changes clear the cache. Default-style restoration and differences in run segmentation are covered by the diff tests. Code/quote/inline-code surfaces retain provisional current-coordinate bounds during body typing; intersected syntax markers remain conservatively invalidated. Native emoji fallback is preserved independently of the code font used for adjacent ASCII.

Same-topology formatting may settle while a table cell is active because the projected attribute installer excludes attachment spans. Topology-changing results are retained for an editing-state transition, then revalidated before installation. The next-loop retry respects Tab moving immediately into another cell. This replaced a reproduced overly broad guard that dropped a valid result and left the table-edit test permanently pending. Ordinary table cell edits advance the source revision even when no outer text-storage character callback occurs.

Selection callbacks reentrant during a programmatic restyling/storage transaction are ignored until projection is complete. Table attachment insertion can trigger native selection adjustment inside `NSTextStorage.endEditing`; reading syntax ranges from that callback previously mixed partially projected coordinates. Final mapped selection and visibility are explicitly restored after attachment insertion. The regression observes that this guard is exercised by real table insertion, rather than relying only on the presence of the guard in source.

An unrelated SwiftUI refresh is not allowed to treat provisional marked text as an external replacement. Test fixture resets now use the real external-replacement transaction instead of direct coordinator/storage assignments. The native regression retains composition, undo/redo, source reconstruction after attachment deletion, active-cell identity, cancellation, and out-of-order delivery checks.

The root observed 12 fresh-render differential edit scenarios, two immediate native-typing checks on downstream attributes, and four deterministic asynchronous race scenarios. They cover paragraph joins/splits, changing/removing styles and links, Unicode/CRLF, fence changes whose interpretation extends into later headings/tables, partial application interrupted by typing, latest-only coalescing, external replacement, teardown, and composition delivery. Source, attributes, hidden/bullet indices, and decoration ranges are read back. Native snapshots show the selected edited emoji region with later quote, code, heading, and list content at 860×600 and 500×600.

The larger diagnostic uses exactly 400,000 UTF-8 bytes and no accessibility-tree traversal or repeated full-document snapshot inside its timing interval. Root-observed example after changed-run installation: 785.6 ms initial Debug render, 39.7 ms insertion/publication, 659.3 ms asynchronous settlement, one batch/one storage mutation, and 0.64 ms maximum batch. Other loaded-machine samples were substantially slower. These are session measurements, not guaranteed throughput. Initial load and exceptional table-topology rebuilding remain synchronous; ordinary typing does not use that full-render path.

The native desktop check was attempted in a separate temporary process. Full accessibility-tree inspection of the restored 400 KB window was expensive: a process sample showed most sampled main-thread work in accessibility link/attachment enumeration. That probe is not evidence of a parsing loop. The temporary instance was closed without editing its restored document; the user's original process was left running. Installed-app interaction and real Korean input-method candidate/cancellation behavior remain unverified by this task's programmatic native harnesses.

### Previous verification scope and warning follow-up

The root rebuilt the app and extension from the final transaction-guard source, then ran `bash Tests/run-regressions.sh --include-preview`. All ten harnesses reached their assertion/completion output, and the combined invocation exited 0. The combined log is `/tmp/mdv-final-regressions.log`. This establishes those exercised native interfaces, not an error-free installed application.

After that suite finished, the root independently ran `MDV_OPTIMIZED_HARNESS=1 bash Tests/run-editor-coordinator-regression.sh` against the final production sources. On the 147 KB fixture, insertion/publication took 7.0 ms; ten Unicode keystrokes had a 6.4 ms median and 7.0 ms maximum. Asynchronous presentation settled in 151.0 ms, with one changed batch, one storage mutation, and a 0.6 ms maximum batch. The maximum measured main-loop service gap was 39.3 ms, so this sample does not establish uniformly frame-budget-safe interaction. This is an optimized production-source harness linked to existing Debug package objects, not a release-app benchmark. The observed assertions and measurements are recorded in `/tmp/mdv-final-optimized-editing.log`.

The root reopened the final native editing captures: 2/2 post-edit viewports inspected at 860×600 and 500×600 points (2× pixel backing), plus the focused 720×600-point Unicode typing frame. The selected edited region, emoji, downstream quote, code body, and heading remain visible without exposed fence/language markers or an orange quote stripe. The narrow viewport continues naturally into offscreen list content; these are viewport checks, not full-document screenshots. Both regenerated Quick Look fixtures were also reopened at 860- and 500-point widths, showing the table, emoji, and final open-fence body text.

At that earlier checkpoint, the retained CRLF/emoji/quote/fence scenario still emitted AppKit's `_NSLayoutTreeLineFragmentRectForGlyphAtIndex invalid glyph index 115` diagnostic. Source and formatting assertions succeeded, so they did not detect this defect. Falsified geometry and initial-string-layout changes were removed. The reentrant table-selection guard did not eliminate the diagnostic and was not its proven fix. The explicit warning-fix follow-up below supersedes this status.

### Glyph-warning fix: observed 2026-09-06

The root reproduced the original warning again before the fix, recording `/tmp/mdv-glyph-warning-baseline.log`. A Sol worker minimized it to lengthening `EDIT` in a two-line source consisting of `EDIT` followed by inline code, with the closing backtick at EOF. The root independently observed that minimized executable emit `invalid glyph index 12`. Neither CRLF nor emoji was necessary; hidden syntax at the end of a later line exposed the ordering defect.

The debugger stopped at the actual `_NSLayoutTreeLogDebug` warning-emission path, not a coincidental call with glyph index 115. Its stack led through `NSLayoutManager` glyph invalidation to `SyntaxHider.updateVisibility`, called by `Coordinator.maintainPresentationRanges` inside `NSTextStorage.processEditing`. The editor was supplying post-edit character coordinates while TextKit was still processing the edit against its preceding layout tree.

The production fix is limited to that transaction boundary. Source, projection, glyph-mask, and decoration-range translation stay synchronous. `scheduleNativeVisibilityUpdate` coalesces the native visibility refresh onto the next main-queue turn, checks source revision and coordinator lifetime, and reads current selection/text/ranges at execution. Replacement, cancellation, and teardown cancel this work. No deferred coordinate cache, full-document layout, warning suppression, or source modification was introduced. Selection and authoritative-render visibility updates remain immediate outside the storage callback. A separate Sol reviewer inspected the ordering and cancellation contract.

The new `Tests/run-glyph-layout-warning-regression.sh` checks the minimal and CRLF/emoji/fence fixtures and fails on any `invalid glyph index` diagnostic. It also exercises rapid consecutive edits, replacement with empty source, and teardown before queued refresh. The original broad stability fixture and its source/attribute comparisons remain in place; diagnostic exploration chatter was removed.

The root rebuilt the app and extension from the final source and reran `bash Tests/run-regressions.sh --include-preview`. All 11 harnesses completed and the invocation exited 0. A fresh search of `/tmp/mdv-glyph-fix-final-regressions.log` observed zero `invalid glyph index` matches, including the original retained repro. The same run exercised source integrity, downstream styling, Unicode, composition APIs, undo, tables, asynchronous races, and preview rendering. Its 147 KB Debug sample measured 8.5 ms insertion/publication and 108.0 ms asynchronous settlement, with a 35.0 ms maximum main-loop service gap; these are observations, not a guaranteed latency bound.

The root reopened both regenerated native post-edit viewports: 2/2 verified at 860×600 and 500×600 points with 2× backing. The selected edited emoji region and downstream quote, code, and heading remained intact. The narrow frame naturally continues into offscreen list content; this does not claim full-document visual coverage.

UNVERIFIED: installed-app keyboard interaction, actual Korean IME candidate selection/cancellation, and live-window editing at the uniquely identified middle paragraph of the large fixture. Closing those pre-existing gaps requires the corresponding live host interactions. The workspace and temporary build were updated; the existing running application was not restarted or replaced.

## Earlier iteration: editing, Unicode, and block presentation

Source: the user's screenshot and typing report on 2026-09-06. The screenshot establishes exposed code fences/language and the rejected quote stripe; the reported typing slowdown and emoji breakage require a native edit reproduction. Existing workspace edits belong to the user and the concurrent optimization session. The following is the implementation contract for this correction, not a claim of completed behavior.

### Edit transaction and presentation ownership

1. AppKit commits characters in its existing text storage and preserves selection, undo, and marked text. All edit offsets and deltas are UTF-16. Do not split surrogate pairs or reconstruct glyph properties for ordinary Unicode runs.
2. The coordinator updates the canonical Markdown source immediately. Projection owns any attachment expansion. Ordinary edits should use the known edit range instead of repeatedly reconstructing unrelated attributed runs where measurement shows that cost matters.
3. Before layout observes the edited storage, syntax indices and decoration ranges must describe the new coordinates. Shift unaffected spans and discard intersected spans until parsing resolves them. A cached visibility state must never restore pre-edit indices.
4. Coalesce authoritative presentation after input pauses. Measure both the input callback and the eventual presentation: moving an expensive operation into a main-thread timer does not eliminate its typing stall. If parsing must leave the main thread, first separate an immutable semantic result from AppKit objects and validate source/style revisions before application. Do not send mutable text storage or view objects across threads.
5. Apply changed attributes without replacing ordinary text. Preserve attachment identity where structure is unchanged. Do not invalidate all glyphs or force whole-document layout for cursor movement or a small repaint.

The native edit loop identified an additional concrete rule: translate the syntax hider's cached masks into the new UTF-16 coordinates before comparing visibility. TextKit already shifts its glyph storage after an edit. Comparing old-coordinate masks with new-coordinate masks incorrectly treats later markers as changed and invalidates unrelated lines. `SyntaxHider.maintainVisibilityAfterEdit` owns this translation; the coordinator supplies the same edit range and delta used by source projection. Retain existing decorations during input instead of clearing the entire presentation between keystrokes.

Renderer computation must also avoid repeated whole-source bridging. Build the UTF-8/UTF-16 location index and NSString source view once per render; handlers read slices of that shared source view. Profile indexing, Markdown parsing, attribute production, and blank-line styling separately before choosing concurrency. Keep the input callback payload-free when it only signals an edit, rather than materializing a document string that its receiver ignores.

### Visual contract

- Quotes use a low-contrast neutral rounded surface, with no colored left stripe. Compute equal vertical inset around occupied line geometry; keep paragraph separation outside the surface. Wrapped and multiline quotes need the same rule. Nested surfaces must be inset if present.
- Fenced code retains exact source text for save/copy/edit. The presentation hides opening delimiters, the complete language/info string, and closing delimiters when editing the code body or another paragraph. Delimiter-line editing may reveal its source deliberately; it must not expose every fence merely because a code block is active.
- Keep code and quote drawing bounded to the dirty viewport. A block crossing the viewport edge must have a continuous surface rather than rounded seams at each dirty fragment.
- Preserve emoji fallback fonts and shaping alongside hidden ASCII syntax. A source-equality assertion alone cannot establish that emoji still renders: inspect glyphs and a native post-edit image.

### Ownership and verification method

The root owns this contract, integration, and review. GPT-5.6 Sol agents own implementation in disjoint areas: coordinator/projection and edit regressions; parser/syntax/glyph handling and syntax regressions; native text-view/theme block styling and drawing regressions. Interface changes are coordinated before editing another owner's files.

Establish a red-capable native reproduction for each symptom before selecting its fix. Exercise insertion/deletion before emoji, inside styled text and code, at the top and middle of a large mixed document, and through undo. Compare actual resulting source, selection, glyph output, and input/presentation timings. Use the screenshot's repeated paragraph/quote/code pattern as a fixture, with Unicode added to edit operations. Inspect native snapshots at ordinary and narrow widths after edits; measure quote geometry and check clipping and raw marker visibility. Existing table/source regressions protect adjacent behavior. Read back this document and standing decisions before building. Report native-host or IME checks that cannot be observed as `UNVERIFIED`.

### Correction implementation and verification boundaries

The three Sol implementation agents changed the coordinator/projection, syntax/glyph rendering, and native block drawing. Ordinary source updates now use the actual UTF-16 replacement; attachment edits retain a reconstruction fallback. The text-change callback carries no redundant document string. Unchanged authoritative attributes are retained. The unsafe manual per-UTF-16-unit fallback-font substitution was removed; native shaping handles emoji and CJK. Code-body typing selects the code font. Syntax masks are translated with edits, and hidden glyphs retain their shaped IDs. The renderer records complete fence/info spans and caches one NSString view of its source.

Quote drawing has no stripe API or draw path. One neutral rounded surface encloses each outer quote; nested quotations use indentation within it. Surface geometry ignores hidden delimiter-only lines and derives vertical padding from visible text metrics. Code and quote surfaces remain separate. Caret drawing no longer asks for the document's total glyph count.

The root observed native source, composition-commit, undo/redo, table-preservation, and Unicode-burst assertions through `Tests/EditorCoordinatorRegression.swift`. This harness wires the same text-change and selection callbacks as the app, uses actual `NSTextView.insertText`, and measures publication separately from delayed presentation. Its marked-text test invokes AppKit composition APIs directly; it does not establish the behavior of the Korean input-method candidate window or cancellation.

The native drawing harness produces 860×420 and 500×420-point block frames and a balanced-padding assertion. Root inspection found the first iteration's touching surfaces and excess code padding, and the later frames corrected those defects. These are native AppKit renders of the real renderer, not HTML mockups. Desktop automation reported `runtime_unavailable`, so installed-app interaction is not established. The temporary app build is not an installed update.

`MDV_OPTIMIZED_HARNESS=1 bash Tests/run-regressions.sh` compiles the production coordinator sources directly with optimization because an optimized Xcode app omits the Debug dylib used by the ordinary harness. Debug and optimized measurements must be reported separately. A typing burst does not establish freedom from delayed-render stalls; that phase must remain visible in the timing report.

Root-observed optimized coordinator measurements on the 147 KB repeated Markdown/Unicode fixture: insertion plus publication 4.7 ms; ten-key burst median 3.5 ms and maximum 15.0 ms; deferred presentation 211.9 ms. Source: the actual production-source harness invoked through `MDV_OPTIMIZED_HARNESS=1 bash Tests/run-regressions.sh`. The coordinator assertions completed; that suite invocation subsequently stopped at another session's newly added source-integrity harness because it expected the omitted Debug dylib. A normal Debug build is required for that harness. These measurements establish the exercised input path, not freedom from rendering stalls.

The subsequent normal Debug run of `bash Tests/run-regressions.sh` completed all seven harnesses, including the other session's attachment-deletion/insertion source-integrity check. That run measured insertion 20.4 ms, burst median 31.4 ms/maximum 191.0 ms, and delayed presentation 1,998.7 ms on the same-sized fixture. Earlier Debug measurements were lower. The variation was observed while the workspace and machine were in concurrent use; its cause was not isolated. Do not use the best optimized sample to claim consistently smooth editing. Dirty drawing in the final combined suite measured 5.384 ms on its separate 2,000-line fixture.

UNVERIFIED: large-document post-insertion viewport capture and installed-app interaction. The stress harness's initial capture attempts did not reliably show the inserted region, so those images do not establish large-document visual correctness. Source/Unicode assertions and focused native post-edit images are separate evidence. Closing the large-document visual gap requires a live window capture at a uniquely identified edited paragraph, while typing and delayed presentation are active. Korean input-method candidate selection and cancellation also require the actual input-method host.

The final focused 720×600-point native editing image visibly contains `Typing: typed😀` after `NSTextView.insertText`, with an intact CJK/ZWJ paragraph, a neutral quote, and a code body without fence/language text. The root reopened that image and the final 860×420/500×420 block images. The test-only capture correction was followed by another successful coordinator assertion run; its Debug timings were insertion 13.0 ms, burst median 11.7 ms/maximum 31.0 ms, and delayed presentation 522.0 ms. The large-document visual limitation above remains.

### Presentation work specified by the earlier iteration

At the end of the earlier iteration, the measured 211.9 ms presentation motivated the following proposed work. This paragraph records the earlier state; the current implementation contract and current-task observations above supersede its implementation status:

1. A serial parsing worker accepts an immutable source snapshot and source revision. Coalesce queued work to the latest snapshot; retain at most one running parse and one latest pending request. Do not queue one document parse per keystroke.
2. The worker traverses the authoritative Markdown AST and returns a semantic presentation containing UTF-16 spans, style kinds/traits, links, syntax, headings, tables, and block decorations. Use Foundation value data; do not construct or mutate views, text storage, layout managers, or theme objects on the worker.
3. The main-thread adapter resolves semantic styles through a cached style palette. Apply changed visible spans first and schedule bounded remaining application work. Source publication and native editing do not wait for presentation. Preserve the current presentation during outstanding work using the edit-coordinate translation already implemented.
4. Accept a result only if its source revision still matches. Resolve against the current style revision or discard a stale styled result. Recheck revisions between application batches. External document replacement invalidates pending jobs; view teardown drops completion callbacks. Marked text defers presentation installation until composition commits.
5. Protect this boundary with deterministic out-of-order-result tests, typing during a delayed parse, composition during delivery, fence insertion/deletion affecting the remainder of the document, attachment/source/undo preservation, and a native event-loop latency measurement while results arrive. A worker that leaves all attributed-string production on the main thread would remove only part of the measured cost.

[Typora](https://typora.io/) is a reference for continuous reading/editing and its outline; [MarkText](https://github.com/marktext/marktext) is a reference for live Markdown editing. Their other features are context, not a feature backlog. This change does not introduce folder management, cloud storage, plugins, or a browser editor.

## What the existing code makes difficult

These are source findings, not claims that every user-reported symptom has been reproduced.

| Area | Inspected evidence | Consequence for the design |
| --- | --- | --- |
| Document publication | `MarkdownEditorView.Coordinator.handleTextChange` originally deferred document binding updates by one second and skipped sync during table editing. | Saved source must be updated independently of expensive rendering. A presentation timer must never be a persistence prerequisite. |
| Source/display conversion | The coordinator originally reconstructed tables by the ordinal occurrence of U+FFFC and separately adjusted selection, drawing, and TOC ranges. | One projection module must own UTF-16 coordinate conversion and attachment identity. Deleting one table must never substitute another table's source. |
| Styling | `InlineRenderer` uses swift-markdown; `IncrementalDetector` implements regex/line parsing. Original reconciliation compared only four array counts; detection returned early for more than 50 affected lines. | One authoritative interpretation must determine final formatting. Equal token counts are not semantic equality. Large edits need an explicit render path. |
| Tables | `TableOperations`, `InlineRenderer.applyTable`, and `TableAttachmentView.markdownString` independently split or serialize pipes. | One table module must preserve source spelling, escaped pipes, and alignment, and own structural operations. |
| Structural table edits | The original coordinator scheduled a render after 0.05 seconds but source publication after one second. Rendering also required source and display lengths to match. | Commit and presentation replacement must be one ordered transaction, without a timing dependency. |
| Window navigation | `TitleBarAccessory` originally appended to the global View menu for each window and attempted installation in one asynchronous callback. | The focused scene owns command routing. Accessory installation and removal follow actual window attachment. |
| Quick Look | `PreviewViewController` originally made syntax transparent, did not lay out tables, and had separate decoration handling. | A read-only presentation should consume the same parsed result and remove editing syntax from layout. |
| Unicode | Original link-label offsets, blockquote offsets, and several selections used `String.count` with `NSRange`. | All AppKit/source ranges are UTF-16. Character counts are only appropriate for user-facing quantities. |
| Theme and geometry | `Theme`, `Typography`, table layout, and TOC each contain appearance knowledge; content width is applied by the text view's resize path. | Style values and geometry invalidation need explicit ownership. A settings change must not require resizing the window. |
| Verification | The original Xcode project contains app and extension targets but no test target or regression suite. | Add repeatable checks at the interfaces that protect source integrity and rendering. Retain native runtime checks for focus, IME, undo, and layout. |

The main problem is dispersed knowledge, not file length. Renaming the coordinator or splitting it into forwarding classes would leave callers with the same ordering and coordinate obligations.

## Deep modules and their interfaces

### Document editing

Intended interface: load a source revision, apply an edit, obtain the current source/selection, and request its presentation. The implementation owns edit ordering, pending presentation work, and the relation between document source and native editing state. SwiftUI is an adapter for file persistence; NSTextView is an adapter for native typing, selection, clipboard, accessibility, and undo.

Invariants:

- Canonical source is Markdown, never attachment placeholders.
- Every committed edit publishes source before returning to the document lifecycle. Rendering may be deferred; publication may not.
- Native marked text must remain under the input method's control. Do not rebuild storage while composition is active.
- User edits participate in undo. Formatting-only updates do not create undo entries or mark the document edited.
- External document replacement invalidates queued presentation work and refreshes the binding used by callbacks.
- A table cell commit and a table structure change each form one logical edit, with source and layout updated in that order.

Do not introduce a persistence protocol merely to wrap `FileDocument`; there is no second persistence adapter required by this task. The deepening opportunity is edit ownership.

### Source/display projection

Intended interface: construct a projection from attributed display storage, recover source, and map source/display ranges. The implementation enumerates actual table attachment identities, reads each attachment's current Markdown, and accumulates UTF-16 offsets.

Collapsed tables are atomic display spans. A selection inside one maps to a documented table endpoint or whole-table range, depending on the operation. Arbitrary source text containing a literal U+FFFC is not a table. Reordering/deleting attachments must follow storage identity rather than the previous render's array order.

Tests use the same mapping/reconstruction interface as navigation and publication. They cover empty text, multiple tables, a removed first table, preceding edits, emoji/CJK, and selection endpoints. This module earns depth because source recovery, selection, navigation, and rendering otherwise repeat its rules.

### Markdown presentation

Intended interface: `present(source, style)` returns attributed source plus source-coordinate headings, syntax, tables, and decorations. Keep swift-markdown traversal, source-location conversion, and supported-syntax decisions within the implementation. The existing `InlineRenderer` is the starting seam; a name change alone is unnecessary.

The editor adapter projects tables and hides syntax around the active selection. The read-only adapter materializes text without editing markers and lays out native tables. Both consume the same parsed interpretation. Keep their distinct selection/layout policies explicit; Finder does not need an editable text view or editor timers.

Correctness comes before incremental optimization. The first step is authoritative reconciliation that covers changed locations and styling, including large pastes. The intended end state removes the independent regex interpretation. If measurements show that full parsing is too expensive, cache block presentations by revision and invalidate the enclosing semantic block; do not maintain another Markdown grammar. Fence edits can affect the rest of the document and cannot be limited to adjacent lines.

### Table editing

Intended interface: parse Markdown, read cells/alignment, replace a cell or apply a structural operation, and retrieve Markdown. A Foundation-only model owns separator recognition, escaped delimiters, row shape, and serialization. The AppKit grid is an adapter for native cell focus, keyboard navigation, and contextual commands.

Preservation rules:

- An untouched table round-trips byte-for-byte.
- A cell edit preserves unrelated cells and separator alignment; normalization must not silently truncate content.
- Invalid operations leave source unchanged. Header deletion and deletion of the final column are guarded.
- Add/delete column acts at the contextual cell, not always at the end.
- Return, Tab, Shift-Tab, and focus changes commit an editor once. Escape cancels only the active uncommitted edit.
- Layout reports its actual dimensions. When columns cannot fit readably, horizontal scrolling is preferable to drawing outside a falsely narrow frame.

The model is in-process computation. No mock transport or dependency-injection framework is needed.

### Window navigation

Interface: the scene exposes its outline model; one command toggles that focused model; selecting an entry requests navigation through the projection. Entries update from document content regardless of sidebar visibility.

The title-bar adapter observes actual window movement, installs once per attached window, and removes exactly the accessory it installed. No per-window mutation of global menus. Close/reopen and two-window focus are required runtime checks.

### Appearance and layout

`MDVTheme` owns semantic colors and user settings; `Typography` owns text metrics. Drawing adapters read these values. Content width changes invalidate text-container insets and table layout immediately. A theme change preserves source, selection, and active edits. Quick Look resolves appearance from its own host and does not assume it shares the editor's process or preferences domain.

## Implementation sequence and ownership

This sequence is the method for the requested editor improvement, not a separate product roadmap.

1. **Root:** inspect the source and references, define the interfaces/invariants above, build the original app, and integrate work. Record verification limits explicitly.
2. **Sol — window/preview:** replace global menu mutation with focused-scene routing and lifecycle-based accessory installation. Then deepen the read-only renderer and verify native attributed output.
3. **Sol — tables:** consolidate table parsing/editing/serialization, contextual operations, edit lifecycle, and narrow layout. Provide deterministic source-preservation regressions.
4. **Sol — editor:** consolidate source/display projection and source publication; replace stale-source structural rendering and fix UTF-16 selection/range handling. Add regressions through the actual projection and editor interfaces.
5. **Root integration:** inspect every changed interface, build app and extension, run the regressions, read emitted source, and exercise native workflows. Return remaining architecture gaps as gaps, not implemented features.

Shared-file coordination: the table agent owns `InlineRenderer.applyTable`; the editor agent owns the rest of that renderer. The preview agent owns target membership updates. Changes to the coordinator are owned by the editor agent. Integration failures return to the responsible Sol agent.

## Acceptance checks

| Interface or user workflow | Required observation |
| --- | --- |
| Source integrity | Compare reconstructed/saved Markdown after typing, deleting the first of two tables, editing around tables, and table operations. No placeholder leakage or unrelated source changes. |
| Unicode editing | Read selection and link ranges after emoji, combining characters, and CJK; run bold/italic/link commands and verify selected content. |
| Styling convergence | Change one syntax form to another with the same token count, paste more than 50 lines, edit fence delimiters, and compare final attributed output with a fresh render. |
| Table round-trip | Escaped pipes, optional outer pipes, alignment, empty cells, CRLF, and long cells survive the relevant operations. |
| Native table interaction | Edit then Tab/Shift-Tab/Return/Escape, resize, add/delete at selected column, undo, and read source back. |
| TOC lifecycle | Toggle after close/reopen; open two documents and confirm shortcut acts on the focused window; navigate below multiple tables after preceding edits. |
| Finder preview | Host a Markdown fixture through the extension; inspect headings, links, lists, code, tables, and Unicode at narrow and ordinary preview widths, light and dark. |
| Presentation quality | Capture the actual native view and inspect clipping, spacing, borders, text legibility, and scroll reachability. Native app verification uses its window/extension host; an HTTP page is not a substitute for AppKit behavior. |
| Latency | Measure parse/presentation separately from input handling on recorded fixture sizes and hardware. No speed claim without timings; no arbitrary product budget represented as user-approved. |

Build success establishes compilation only. A Foundation harness establishes its exercised interface only. Neither establishes Finder hosting, native focus, visual quality, or a finished WYSIWYG experience.

## Implementation record

The first refactor retains SwiftUI, AppKit, TextKit 1, swift-markdown, FileDocument, and the existing theme. It adds no runtime package dependency.

- `EditorProjection` now owns UTF-16 source/display mapping, attachment-aware source reconstruction, ordinary edit shifts, and splitting styling ranges around attachments. Source recovery reads attachment attributes rather than the ordinal occurrence of placeholder characters.
- `MarkdownEditorView.Coordinator` publishes committed source synchronously and coalesces ordinary-edit presentation after a 120 ms typing pause. Structural table operations present immediately. Authoritative AST formatting updates ordinary display text without replacing its characters; cell-length changes retain table views, and table source changes register undo/redo. The separate `IncrementalDetector` was removed. The coordinator remains substantial: deeper extraction of presentation installation and edit transactions is still warranted, provided native editing behavior is protected by the interface tests.
- `MarkdownTable` centralizes lexical table parsing, targeted cell replacement, alignment, and structural operations. Untouched source and unrelated cell spelling are preserved for cell edits. Structural operations intentionally serialize a normalized table while preserving line-ending style and alignment; byte-identical structural edits are not claimed.
- `TableAttachmentCell` owns a local horizontal scroll view. `TableAttachmentView` commits by editor identity and applies commands at the contextual column. The obsolete, unreachable text-view table menu was removed.
- `InlineRenderer` now uses UTF-16 link label ranges, distinguishes ATX and setext heading markers, and visits inline children inside headings. The latter was the cause of literal emphasis markers inside heading previews.
- `ContentView` exposes a focused outline model; `MDVApp` installs one scene-routed outline command. The title-bar adapter follows actual window movement and removes the exact accessory it owns.
- `MarkdownPreviewRenderer` consumes `InlineRenderer` output, removes syntax from layout, materializes native `NSTextTable` cells and a drawn horizontal-rule attachment, and handles fenced-code delimiters. `PreviewViewController` observes host appearance and adjusts insets with available width.
- `Tests/run-regressions.sh` provides one entry point for the source/projection/table/coordinator harnesses. `--include-preview` adds native preview assertions and snapshots. These are standalone macOS harnesses, not an Xcode test target.

## Observed visual checks and limits

The root inspected the temporary build's native editor at 860×720 points with a Markdown fixture containing Unicode links, a table, headings, lists, a quote, and code. The complete label “한글 😀 link” was visible after the range fix. For the outline lifecycle check, the temporary process had no windows after closing; reopening created a different window, and its title-bar button displayed the three expected headings. These observations cover the title-bar button flow, not the keyboard/focus matrix.

The root also opened and inspected the native preview renderer's two light-appearance snapshots at 500- and 860-point widths. The corrected snapshots show nested heading formatting, a solid horizontal rule, aligned table cells, and emoji without the earlier marker or rule defects. These are AppKit renderer snapshots, not a claim that Finder loaded the newly built extension.

The actual-coordinator harness imports the built MDV module and uses its real text view, attachments, document binding, and undo manager. It observed immediate source publication before presentation flushing, updated attributes after a same-length link edit, a longer cell commit followed by Tab with the same attachment/window retained, a real structural command, exact pre-edit source after undo, exact changed source after redo, and deletion of the first of two tables while preserving the second. The table and projection harnesses additionally cover lexical preservation, short valid GFM alignment separators from the dependency's test fixtures, UTF-16 edits, local scrolling, and attachment cleanup. Source integrity assertions compare actual returned/bound Markdown; they do not infer correctness from the code that assigned it.

UNVERIFIED: Finder Space-bar hosting of the built extension; close/reopen keyboard shortcuts across two focused documents; Korean IME composition and candidate selection; the full light/dark/width interaction matrix; autosave/close during an active cell edit; accessibility and clipboard behavior for collapsed tables. Closing these gaps requires the corresponding acceptance workflows above in the app and Finder host. The unsigned temporary build does not establish distribution signing or installed extension registration.

Performance is an open architecture constraint. The initial unoptimized preview harness measured medians of 280.9 ms for 10,050 bytes and 1,511.4 ms for 100,050 bytes. A three-run 1 MB attempt exceeded 90 seconds and was stopped; no 1 MB timing is claimed. The subsequent `swiftc -O` harness isolated the shared renderer from preview materialization:

| Repeated Markdown fixture, UTF-8 bytes | InlineRenderer median | Full preview median |
| --- | --- | --- |
| 10,050 | 21.7 ms | 22.9 ms |
| 100,050 | 277.9 ms | 299.4 ms |

Source: `Tests/QuickLookPreviewHarness.swift`, three runs per renderer/input, on this session's macOS machine. These are computation measurements, not editor input latency. The shared parse/styling implementation dominates this fixture's cost. Ordinary typing therefore needs immediate source publication with coalesced presentation work; per-keystroke full rendering is unsuitable. The preview stress case is opt-in.

The root's final rerun while other validation work was active measured 44.4/42.3 ms (inline/preview) at 10,050 bytes and 401.3/564.3 ms at 100,050 bytes. This variation reinforces that these are session measurements, not guaranteed budgets. The optimization target remains the same.

The next performance work should stay inside the presentation module: profile source-location conversion and attributed-string mutation independently, pre-index UTF-8-to-UTF-16 line offsets, cache unchanged semantic blocks, and move parsing off the input thread using immutable revision-tagged results. Apply a result only if its source revision and style revision still match. A fence edit invalidates dependent blocks through the matching close or document end. Measure the same fixtures before and after each optimization, and retain differential comparison against a fresh full parse. Do not reintroduce an independent regex grammar to obtain a faster but inconsistent result.

## Final reproducible validation

The root reran the following on the final source and read the outputs:

```sh
xcodebuild -scheme MDV -configuration Debug \
  -derivedDataPath /tmp/mdv-build -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO build
bash Tests/run-regressions.sh
bash Tests/run_quicklook_preview_harness.sh /tmp/mdv-preview-final
```

The build completed successfully for the app and extension. The projection, table model, native table attachment, and actual coordinator harnesses each reported their observed assertions; the preview harness completed its rendering assertions and generated two snapshots. The final editor screenshot was inspected at 860×720 points. 2/2 native preview frames were visually inspected at 500- and 860-point widths. These results are limited to the fixtures and workflows described above; the UNVERIFIED items remain open.

First-time builds need to resolve the project's existing Swift packages. The coordinator harness imports the Debug build at `MDV_DERIVED_DATA` (default `/tmp/mdv-build`), so rebuild before running it after changing application source. The standalone scripts require macOS and Xcode; Swift Observation macro execution and AppKit hosting may need execution outside a restrictive sandbox.

## Large-document optimization method (2026-09-06)

The follow-up request is to remove pauses while large documents render and reveal more content. This change targets the existing native editor; it does not introduce a document-size cutoff or drop Markdown features.

Ownership and interfaces:

- `InlineRenderer` continues to own Markdown interpretation and source-coordinate presentation. Build position indexes once per source snapshot; converting parser locations must not rescan the preceding document. Retain UTF-8 parser columns and UTF-16 AppKit ranges, including emoji and CRLF coverage.
- `MarkdownTextView` owns viewport drawing. Determine the dirty viewport's character/glyph range once, then intersect decorations before asking TextKit for their geometry. A drawing callback must not lay out all later code blocks or quotations just to paint the current screen. Long blocks crossing the viewport need continuous backgrounds without false rounded ends at clipping boundaries.
- `Coordinator` owns publication and presentation application. Preserve immediate canonical-source publication and attachment identity. Reuse an already computed render result when a structural change requires rebuilding the projection. Compare authoritative attributes against existing attributes and apply only differences where practical, so unchanged paragraphs retain layout.
- `GlyphManager` owns glyph substitutions. Avoid allocation and font lookup for runs containing no hidden syntax or bullets, and avoid repeatedly bridging the whole source within a glyph loop.

Method: measure parser computation separately from actual native drawing; reproduce with repeated headings, links, Unicode, quotations and fenced code; compare the same fixture before and after. Add assertions at the actual drawing/coordinator seams, preserve existing source/undo/table regressions, and inspect native snapshots at the top, middle and end of a large document. No background AppKit work or second Markdown grammar is authorized by this design. Asynchronous parsing would require an immutable semantic result and source/style revision validation; it is unnecessary to introduce that concurrency before removing measured excess work.

Baseline observations this turn: the existing optimized preview harness measured InlineRenderer medians of 11.4 ms for 10,050 bytes and 112.2 ms for 100,050 bytes, and full preview medians of 11.9 ms and 127.1 ms. A generated 400,346-byte document was opened in the temporary Debug app. A two-second process sample contained substantial main-thread background drawing through every code block and quotation. The window inspection also induced expensive accessibility link enumeration and ultimately lost its runtime connection, so its elapsed time is not a valid document-loading benchmark. These observations motivate separate computation and viewport measurements rather than treating automation delay as application latency.

### Observed performance slice and integration boundary

The delegated performance implementation now filters decoration geometry by the dirty viewport, avoids unnecessary glyph-substitution work and table subview invalidation, reuses an existing render result for structural table rebuilding, and indexes parser positions with sparse Unicode corrections. Blank-line code-block membership uses a sorted forward scan. Attribute-difference application and asynchronous parsing were not implemented by this performance slice.

The layout agent's original 2,000-inline-span draw reproduction took 593.131 ms and failed its 100 ms guard. The root reran the expanded native drawing harness with quotations, rules, and a long code block: 5.460 ms, then 2.596 ms. These are single dirty-viewport drawing measurements, not whole-document loading or typing latency. The root reopened the regenerated top/middle/tail PNGs: line 0000 had top inset, the middle retained a continuous code-block surface, and line 1999 plus `END OF DOCUMENT` remained visible with bottom inset. All three captures use a 720×400-point frame.

The parser's root rerun completed Unicode LF/CRLF/CR range assertions and produced native preview frames at 500/860-point widths, both reopened and visually inspected. Timings under active machine load were 57.4/398.6 ms for 10,050/100,050-byte inline rendering and 42.6/528.4 ms for full preview. They do not establish a reliable parser speedup against the earlier, less-loaded baseline. No final 1 MB speedup is claimed.

Additional edits arrived concurrently outside the two performance agents' ownership, including incremental source synchronization, quotation presentation, emoji handling, unchanged-attribute comparisons, and expanded tests. They were preserved and integrated. The performance agents additionally reproduced a source-integrity bug against the actual compiled coordinator: deleting a table and inserting text before one synchronization restored the deleted table in canonical Markdown. The implemented fallback requirement now remains set through subsequent callbacks until reconstruction; table callbacks explicitly require reconstruction too. The new `CoordinatorSourceIntegrityRegression` observed the corrected result after rebuilding.

The final isolated app/extension build in `/tmp/mdv-performance-build` succeeded. The root reran `MDV_DERIVED_DATA=/tmp/mdv-performance-build MDV_GLYPH_SNAPSHOT=/tmp/mdv-glyph-final.png bash Tests/run-regressions.sh` and observed completion of all seven harnesses: projection, table model, table attachment, editor coordinator, batched source integrity, layout, and syntax/glyph shaping. Product source fingerprints remained unchanged through this verification. The previously failing emoji assertion was corrected to compare actual emoji glyph identities/properties to the native baseline; the root inspected the regenerated composed-emoji frame at 420×100 points.

Final measured values on this machine: viewport draw 5.863 ms with 2,000 decorations; 147 KB mixed-Markdown insertion/publication 17.1 ms; a ten-key Unicode burst 15.1 ms median and 47.7 ms maximum. Deferred presentation still took 1,081.5 ms on this run. These are Debug integration measurements under variable machine load, not guaranteed latency budgets. The root inspected the actual coordinator's 720×600-point output, the three 720×400-point top/middle/tail frames, and quotation/code frames at 500×420 and 860×420 points. Native screenshots are test observations; they do not prove every interactive workflow.

Remaining performance limitation: a full authoritative formatting pass still runs after typing pauses and can block the main thread. The viewport optimization removes repeated offscreen layout work, but does not establish uniformly smooth editing during that deferred pass. The follow-up architecture is immutable source/style snapshots, background semantic computation with revision checks, and applying only changed block presentation on the main thread; preserve one Markdown interpretation and avoid accessing live AppKit views or mutable theme state from workers.

UNVERIFIED: interactive Korean IME behavior, the user's original document, and the historical null-glyph line-fragment edge cases. Close these with native composition and typing/scrolling observations on the representative document plus targeted line-start glyph regressions. The earlier Finder-host and distribution limits still apply.
