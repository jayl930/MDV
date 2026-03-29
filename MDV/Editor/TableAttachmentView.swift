import AppKit

/// A self-contained table view with inline-styled cells and overlay editing.
/// Double-click a cell to edit. Edits update the source markdown via callbacks.
final class TableAttachmentView: NSView, NSTextFieldDelegate {

    override var isFlipped: Bool { true }

    private var cells: [[NSTextField]] = []  // [row][col]
    private var rawTexts: [[String]] = []   // original markdown text per cell
    private let tableData: TableData
    private var theme: MDVTheme
    private let typography: Typography
    let numColumns: Int
    let numRows: Int

    private let cellPaddingH: CGFloat = 10
    private let cellPaddingV: CGFloat = 6
    private let borderWidth: CGFloat = 0.5

    // Editing state
    private var activeEditor: NSTextField?
    private var editingRow: Int = -1
    private var editingCol: Int = -1
    private var contextRow: Int = 0
    private var contextCol: Int = 0

    // Callbacks to coordinator
    var onTableEdited: (() -> Void)?
    var onStructuralChange: ((String) -> Void)?

    var isEditing: Bool { activeEditor != nil }

    // Compiled regex patterns for inline markdown
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*(?!\\s)(.+?)(?<!\\s)\\*\\*")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*(?!\\*)(?!\\s)(.+?)(?<!\\s)\\*(?!\\*)")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~(?!\\s)(.+?)(?<!\\s)~~")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)")

    init(tableData: TableData, theme: MDVTheme, typography: Typography) {
        self.tableData = tableData
        self.theme = theme
        self.typography = typography
        self.numColumns = tableData.numColumns
        self.numRows = 1 + tableData.bodyRows.count
        super.init(frame: .zero)

        buildCells()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Build Cells

    private func buildCells() {
        // First row (from header cells)
        var firstRow: [NSTextField] = []
        var firstRowTexts: [String] = []
        for (col, text) in tableData.headerCells.enumerated() {
            let field = makeField(text: text, row: 0, col: col)
            firstRow.append(field)
            firstRowTexts.append(text)
            addSubview(field)
        }
        while firstRow.count < numColumns {
            let field = makeField(text: "", row: 0, col: firstRow.count)
            firstRow.append(field)
            firstRowTexts.append("")
            addSubview(field)
        }
        cells.append(firstRow)
        rawTexts.append(firstRowTexts)

        // Remaining rows
        for (rowIdx, row) in tableData.bodyRows.enumerated() {
            var bodyRow: [NSTextField] = []
            var bodyRowTexts: [String] = []
            for col in 0..<numColumns {
                let text = col < row.count ? row[col] : ""
                let field = makeField(text: text, row: rowIdx + 1, col: col)
                bodyRow.append(field)
                bodyRowTexts.append(text)
                addSubview(field)
            }
            cells.append(bodyRow)
            rawTexts.append(bodyRowTexts)
        }
    }

    private func makeField(text: String, row: Int, col: Int) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = typography.body
        field.allowsEditingTextAttributes = true
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = 0
        field.cell?.wraps = true
        field.tag = row * 1000 + col
        field.attributedStringValue = styledAttributedString(for: text)
        return field
    }

    // MARK: - Inline Markdown Styling

    private func styledAttributedString(for text: String) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: typography.body,
            .foregroundColor: theme.text
        ]

        guard !text.isEmpty else {
            return NSAttributedString(string: "", attributes: baseAttrs)
        }

        // Work on the original text to find match ranges, then build output with syntax removed
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var claimed = IndexSet()

        // Collect replacements: (range in original, replacement string, attributes)
        struct Replacement {
            let range: NSRange          // range in original text
            let displayText: String     // text to show (syntax stripped)
            let attributes: [NSAttributedString.Key: Any]
        }
        var replacements: [Replacement] = []

        // 1. Inline code
        for match in Self.inlineCodeRegex.matches(in: text, range: fullRange) {
            let r = match.range
            guard r.length >= 2 else { continue }
            let content = nsText.substring(with: NSRange(location: r.location + 1, length: r.length - 2))
            replacements.append(Replacement(range: r, displayText: content, attributes: [
                .font: typography.code,
                .foregroundColor: theme.codeText
            ]))
            claimed.insert(integersIn: r.location..<(r.location + r.length))
        }

        // 2. Bold
        for match in Self.boldRegex.matches(in: text, range: fullRange) {
            let r = match.range
            if !claimed.intersection(IndexSet(integersIn: r.location..<(r.location + r.length))).isEmpty { continue }
            guard r.length >= 4 else { continue }
            let content = nsText.substring(with: NSRange(location: r.location + 2, length: r.length - 4))
            let boldFont = NSFontManager.shared.convert(typography.body, toHaveTrait: .boldFontMask)
            replacements.append(Replacement(range: r, displayText: content, attributes: [
                .font: boldFont,
                .foregroundColor: theme.text
            ]))
            claimed.insert(integersIn: r.location..<(r.location + r.length))
        }

        // 3. Italic
        for match in Self.italicRegex.matches(in: text, range: fullRange) {
            let r = match.range
            if !claimed.intersection(IndexSet(integersIn: r.location..<(r.location + r.length))).isEmpty { continue }
            guard r.length >= 2 else { continue }
            let content = nsText.substring(with: NSRange(location: r.location + 1, length: r.length - 2))
            let italicFont = NSFontManager.shared.convert(typography.body, toHaveTrait: .italicFontMask)
            replacements.append(Replacement(range: r, displayText: content, attributes: [
                .font: italicFont,
                .foregroundColor: theme.text
            ]))
            claimed.insert(integersIn: r.location..<(r.location + r.length))
        }

        // 4. Strikethrough
        for match in Self.strikeRegex.matches(in: text, range: fullRange) {
            let r = match.range
            if !claimed.intersection(IndexSet(integersIn: r.location..<(r.location + r.length))).isEmpty { continue }
            guard r.length >= 4 else { continue }
            let content = nsText.substring(with: NSRange(location: r.location + 2, length: r.length - 4))
            replacements.append(Replacement(range: r, displayText: content, attributes: [
                .font: typography.body,
                .foregroundColor: theme.secondaryText,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: theme.secondaryText
            ]))
            claimed.insert(integersIn: r.location..<(r.location + r.length))
        }

        // 5. Links
        for match in Self.linkRegex.matches(in: text, range: fullRange) {
            let r = match.range
            if !claimed.intersection(IndexSet(integersIn: r.location..<(r.location + r.length))).isEmpty { continue }
            let matchText = nsText.substring(with: r)
            guard let closeBracket = matchText.firstIndex(of: "]") else { continue }
            let textLen = matchText.distance(from: matchText.startIndex, to: closeBracket)
            let linkText = (matchText as NSString).substring(with: NSRange(location: 1, length: max(0, textLen - 1)))
            replacements.append(Replacement(range: r, displayText: linkText, attributes: [
                .font: typography.body,
                .foregroundColor: theme.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.accent.withAlphaComponent(0.4)
            ]))
            claimed.insert(integersIn: r.location..<(r.location + r.length))
        }

        // If no replacements, return plain styled text
        if replacements.isEmpty {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }

        // Build attributed string: process replacements from end to start
        replacements.sort { $0.range.location > $1.range.location }

        let result = NSMutableAttributedString(string: text, attributes: baseAttrs)
        for rep in replacements {
            let styled = NSAttributedString(string: rep.displayText, attributes: baseAttrs.merging(rep.attributes) { _, new in new })
            result.replaceCharacters(in: rep.range, with: styled)
        }

        return result
    }

    // MARK: - Cell Hit Testing

    private func cellAt(point: NSPoint) -> (row: Int, col: Int)? {
        let colWidths = columnWidths(for: bounds.width)
        var y: CGFloat = borderWidth
        for rowIdx in 0..<numRows {
            let rh = rowHeight(for: rowIdx, columnWidths: colWidths)
            var x: CGFloat = borderWidth
            for colIdx in 0..<numColumns {
                let cw = colIdx < colWidths.count ? colWidths[colIdx] : 60
                let cellRect = NSRect(x: x, y: y, width: cw, height: rh)
                if cellRect.contains(point) {
                    return (rowIdx, colIdx)
                }
                x += cw + borderWidth
            }
            y += rh + borderWidth
        }
        return nil
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if event.clickCount >= 2 {
            if let (row, col) = cellAt(point: point) {
                beginEditing(row: row, col: col)
                return
            }
        }

        // Single click: commit any active edit
        if activeEditor != nil {
            commitEditing()
        }
        // Do NOT call super — it would route back through NSTextAttachmentCell causing recursion
    }

    // MARK: - Overlay Editing

    func beginEditing(row: Int, col: Int) {
        // Commit any existing edit first
        if activeEditor != nil {
            commitEditing()
        }

        guard row >= 0, row < cells.count, col >= 0, col < cells[row].count else { return }

        editingRow = row
        editingCol = col

        let displayCell = cells[row][col]
        let rawText = rawTexts[row][col]

        // Create overlay editor at the display cell's frame
        let editor = NSTextField()
        editor.isEditable = true
        editor.isSelectable = true
        editor.isBordered = false
        editor.focusRingType = .none
        editor.font = typography.body
        editor.textColor = theme.text
        editor.backgroundColor = theme.codeBackground
        editor.drawsBackground = true
        editor.lineBreakMode = .byWordWrapping
        editor.cell?.wraps = true
        editor.stringValue = rawText
        editor.delegate = self
        editor.frame = displayCell.frame

        addSubview(editor)
        activeEditor = editor
        displayCell.isHidden = true

        // Make editor first responder
        window?.makeFirstResponder(editor)
    }

    func commitEditing() {
        guard let editor = activeEditor,
              editingRow >= 0, editingRow < rawTexts.count,
              editingCol >= 0, editingCol < rawTexts[editingRow].count else {
            cleanupEditor()
            return
        }

        let newText = editor.stringValue
        rawTexts[editingRow][editingCol] = newText

        // Re-style the display cell
        let displayCell = cells[editingRow][editingCol]
        displayCell.attributedStringValue = styledAttributedString(for: newText)
        displayCell.isHidden = false

        cleanupEditor()

        // Notify coordinator
        onTableEdited?()

        // Trigger re-layout in case cell size changed
        needsLayout = true
        needsDisplay = true
    }

    func cancelEditing() {
        guard editingRow >= 0, editingRow < cells.count,
              editingCol >= 0, editingCol < cells[editingRow].count else {
            cleanupEditor()
            return
        }
        cells[editingRow][editingCol].isHidden = false
        cleanupEditor()
    }

    private func cleanupEditor() {
        activeEditor?.removeFromSuperview()
        activeEditor = nil
        editingRow = -1
        editingCol = -1
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ notification: Notification) {
        commitEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            let row = editingRow
            let col = editingCol
            commitEditing()
            if row + 1 < numRows {
                beginEditing(row: row + 1, col: col)
            }
            return true
        }
        if commandSelector == #selector(insertTab(_:)) {
            let row = editingRow
            let col = editingCol
            commitEditing()
            if col + 1 < numColumns {
                beginEditing(row: row, col: col + 1)
            } else if row + 1 < numRows {
                beginEditing(row: row + 1, col: 0)
            }
            return true
        }
        if commandSelector == #selector(insertBacktab(_:)) {
            let row = editingRow
            let col = editingCol
            commitEditing()
            if col - 1 >= 0 {
                beginEditing(row: row, col: col - 1)
            } else if row - 1 >= 0 {
                beginEditing(row: row - 1, col: numColumns - 1)
            }
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }

    // MARK: - Context Menu (Structural Operations)

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (row, col) = cellAt(point: point) else { return nil }

        contextRow = row
        contextCol = col

        let menu = NSMenu()
        menu.addItem(withTitle: "Add Row Below", action: #selector(addRowBelow(_:)), keyEquivalent: "")
        if row > 0 {
            menu.addItem(withTitle: "Delete Row", action: #selector(deleteRow(_:)), keyEquivalent: "")
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Add Column", action: #selector(addColumnRight(_:)), keyEquivalent: "")
        if numColumns > 1 {
            menu.addItem(withTitle: "Delete Last Column", action: #selector(deleteLastColumn(_:)), keyEquivalent: "")
        }

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    @objc private func addRowBelow(_ sender: Any) {
        let md = markdownString()
        let newMD = TableOperations.addRowBelow(tableText: md, rowIndex: contextRow)
        onStructuralChange?(newMD)
    }

    @objc private func deleteRow(_ sender: Any) {
        let md = markdownString()
        let newMD = TableOperations.deleteRow(tableText: md, rowIndex: contextRow)
        onStructuralChange?(newMD)
    }

    @objc private func addColumnRight(_ sender: Any) {
        let md = markdownString()
        let newMD = TableOperations.addColumn(tableText: md)
        onStructuralChange?(newMD)
    }

    @objc private func deleteLastColumn(_ sender: Any) {
        let md = markdownString()
        let newMD = TableOperations.deleteLastColumn(tableText: md)
        onStructuralChange?(newMD)
    }

    // MARK: - Layout

    private func columnWidths(for totalWidth: CGFloat) -> [CGFloat] {
        guard numColumns > 0 else { return [] }

        let minColWidth: CGFloat = 60
        let totalBorders = CGFloat(numColumns + 1) * borderWidth
        let availableWidth = totalWidth - totalBorders

        var naturalWidths = [CGFloat](repeating: minColWidth, count: numColumns)
        for row in cells {
            for (col, field) in row.enumerated() where col < numColumns {
                let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10000, height: 100)) ?? .zero
                naturalWidths[col] = max(naturalWidths[col], size.width + cellPaddingH * 2)
            }
        }

        let totalNatural = naturalWidths.reduce(0, +)
        if totalNatural <= availableWidth {
            let extra = availableWidth - totalNatural
            return naturalWidths.map { $0 + extra * ($0 / totalNatural) }
        } else {
            let scale = availableWidth / totalNatural
            return naturalWidths.map { max(minColWidth, $0 * scale) }
        }
    }

    private func rowHeight(for rowIndex: Int, columnWidths: [CGFloat]? = nil) -> CGFloat {
        guard rowIndex < cells.count else { return 30 }
        var maxHeight: CGFloat = 20
        for (col, field) in cells[rowIndex].enumerated() where col < numColumns {
            let colW: CGFloat
            if let cws = columnWidths, col < cws.count {
                colW = cws[col] - cellPaddingH * 2
            } else {
                colW = 10000
            }
            let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(colW, 30), height: 10000)) ?? .zero
            maxHeight = max(maxHeight, size.height)
        }
        return maxHeight + cellPaddingV * 2
    }

    func idealSize(for width: CGFloat) -> NSSize {
        let colWidths = columnWidths(for: width)
        let totalWidth = colWidths.reduce(0, +) + CGFloat(numColumns + 1) * borderWidth
        var totalHeight: CGFloat = 0
        for row in 0..<numRows {
            totalHeight += rowHeight(for: row, columnWidths: colWidths)
        }
        totalHeight += CGFloat(numRows + 1) * borderWidth
        return NSSize(width: min(totalWidth, width), height: totalHeight)
    }

    override func layout() {
        super.layout()
        let colWidths = columnWidths(for: bounds.width)

        var y: CGFloat = borderWidth
        for rowIndex in 0..<numRows {
            let rh = rowHeight(for: rowIndex, columnWidths: colWidths)
            var x: CGFloat = borderWidth
            guard rowIndex < cells.count else { continue }
            for (col, field) in cells[rowIndex].enumerated() where col < numColumns {
                let cw = col < colWidths.count ? colWidths[col] : 60
                field.frame = NSRect(
                    x: x + cellPaddingH,
                    y: y + cellPaddingV,
                    width: cw - cellPaddingH * 2,
                    height: rh - cellPaddingV * 2
                )
                x += cw + borderWidth
            }
            y += rh + borderWidth
        }
    }

    // MARK: - Drawing (borders)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let colWidths = columnWidths(for: bounds.width)
        theme.tableBorder.setStroke()

        // Horizontal lines
        var y: CGFloat = 0
        for rowIndex in 0...numRows {
            let path = NSBezierPath()
            path.lineWidth = borderWidth
            let lineY = y + borderWidth / 2
            path.move(to: NSPoint(x: 0, y: lineY))
            path.line(to: NSPoint(x: bounds.width, y: lineY))
            path.stroke()

            if rowIndex < numRows {
                y += rowHeight(for: rowIndex, columnWidths: colWidths) + borderWidth
            }
        }

        // Vertical lines
        var x: CGFloat = 0
        for col in 0...numColumns {
            let path = NSBezierPath()
            path.lineWidth = borderWidth
            let lineX = x + borderWidth / 2
            path.move(to: NSPoint(x: lineX, y: 0))
            path.line(to: NSPoint(x: lineX, y: bounds.height))
            path.stroke()

            if col < numColumns && col < colWidths.count {
                x += colWidths[col] + borderWidth
            }
        }
    }

    // MARK: - Theme Update

    func updateTheme(_ newTheme: MDVTheme) {
        // Cancel any active edit before theme change
        if isEditing { cancelEditing() }

        self.theme = newTheme
        for (rowIdx, row) in cells.enumerated() {
            for (colIdx, field) in row.enumerated() {
                let rawText = rowIdx < rawTexts.count && colIdx < rawTexts[rowIdx].count ? rawTexts[rowIdx][colIdx] : ""
                field.attributedStringValue = styledAttributedString(for: rawText)
            }
        }
        needsDisplay = true
    }

    // MARK: - Cell Content

    func markdownString() -> String {
        var lines: [String] = []

        let headerCells = rawTexts.first ?? []
        lines.append("| " + headerCells.joined(separator: " | ") + " |")

        let separators = headerCells.map { _ in "---" }
        lines.append("| " + separators.joined(separator: " | ") + " |")

        for rowIndex in 1..<rawTexts.count {
            lines.append("| " + rawTexts[rowIndex].joined(separator: " | ") + " |")
        }

        return lines.joined(separator: "\n")
    }
}
