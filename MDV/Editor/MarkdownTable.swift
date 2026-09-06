import Foundation

nonisolated struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case none, left, center, right }
    private struct CellLocation: Hashable { let row: Int; let column: Int }
    private struct LexicalRow: Equatable { let contentRanges: [NSRange] }
    private(set) var rows: [[String]]
    private(set) var alignments: [Alignment]
    private let originalSource: String
    private let lexicalRows: [LexicalRow]
    private var replacements: [CellLocation: String] = [:]
    private var structuralChange = false
    var columnCount: Int { max(rows.map(\.count).max() ?? 0, alignments.count) }
    var rowCount: Int { rows.count }
    var header: [String] { rows.first ?? [] }
    var body: [[String]] { Array(rows.dropFirst()) }

    init?(markdown: String) {
        let ns = markdown as NSString
        var parsedRows: [[String]] = [], lexed: [LexicalRow] = []
        var start = 0
        while start < ns.length {
            let full = ns.lineRange(for: NSRange(location: start, length: 0))
            var length = full.length
            while length > 0 && [10, 13].contains(Int(ns.character(at: full.location + length - 1))) { length -= 1 }
            let lineRange = NSRange(location: full.location, length: length)
            let line = ns.substring(with: lineRange)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                let parsed = Self.lexRow(line, baseOffset: lineRange.location)
                parsedRows.append(parsed.cells); lexed.append(LexicalRow(contentRanges: parsed.ranges))
            }
            start = NSMaxRange(full)
        }
        guard parsedRows.count >= 2, !parsedRows[0].isEmpty, parsedRows[1].count == parsedRows[0].count,
              parsedRows[1].allSatisfy(Self.isSeparator) else { return nil }
        rows = [parsedRows[0]] + Array(parsedRows.dropFirst(2))
        alignments = parsedRows[1].map(Self.alignment)
        originalSource = markdown
        lexicalRows = [lexed[0]] + Array(lexed.dropFirst(2))
    }

    mutating func setCell(row: Int, column: Int, value: String) {
        guard !value.contains("\n"), !value.contains("\r"),
              rows.indices.contains(row), rows[row].indices.contains(column),
              rows[row][column] != value else { return }
        rows[row][column] = value; replacements[CellLocation(row: row, column: column)] = value
    }
    mutating func insertRow(after row: Int) {
        guard rows.indices.contains(row) else { return }
        rows.insert(Array(repeating: "", count: columnCount), at: row + 1)
        structuralChange = true
    }

    mutating func removeRow(at row: Int) {
        guard row > 0, rows.indices.contains(row) else { return }
        rows.remove(at: row)
        structuralChange = true
    }

    mutating func moveRowUp(at row: Int) {
        guard row > 1, rows.indices.contains(row) else { return }
        rows.swapAt(row, row - 1)
        structuralChange = true
    }

    mutating func moveRowDown(at row: Int) {
        guard row > 0, rows.indices.contains(row), rows.indices.contains(row + 1) else { return }
        rows.swapAt(row, row + 1)
        structuralChange = true
    }

    mutating func insertColumn(after column: Int) {
        guard column >= 0, column < columnCount else { return }
        normalize(to: columnCount)
        for row in rows.indices {
            rows[row].insert("", at: column + 1)
        }
        alignments.insert(.none, at: column + 1)
        structuralChange = true
    }

    mutating func removeColumn(at column: Int) {
        guard columnCount > 1, column >= 0, column < columnCount else { return }
        normalize(to: columnCount)
        for row in rows.indices {
            rows[row].remove(at: column)
        }
        alignments.remove(at: column)
        structuralChange = true
    }

    func markdown() -> String {
        guard structuralChange else {
            let result = NSMutableString(string: originalSource)
            let edits = replacements.compactMap { key, value -> (NSRange, String)? in
                guard lexicalRows.indices.contains(key.row), lexicalRows[key.row].contentRanges.indices.contains(key.column) else { return nil }
                return (lexicalRows[key.row].contentRanges[key.column], Self.escape(value))
            }.sorted { $0.0.location > $1.0.location }
            for edit in edits { result.replaceCharacters(in: edit.0, with: edit.1) }
            return result as String
        }
        let count = columnCount
        let normalized = rows.map { $0 + Array(repeating: "", count: max(0, count - $0.count)) }
        let separators = (0..<count).map { column in
            Self.separator(alignments.indices.contains(column) ? alignments[column] : .none)
        }
        var lines = [Self.render(normalized[0]), Self.render(separators)]
        lines.append(contentsOf: normalized.dropFirst().map(Self.render))
        let ending = Self.lineEnding(in: originalSource)
        return lines.joined(separator: ending) + (Self.hasTrailingNewline(originalSource) ? ending : "")
    }

    static func parseRow(_ line: String) -> [String] { lexRow(line, baseOffset: 0).cells }
    private mutating func normalize(to count: Int) {
        for row in rows.indices where rows[row].count < count {
            rows[row].append(contentsOf: repeatElement("", count: count - rows[row].count))
        }
        while alignments.count < count {
            alignments.append(.none)
        }
    }
    private static func lexRow(_ line: String, baseOffset: Int) -> (cells: [String], ranges: [NSRange]) {
        let ns = line as NSString; var pipes: [Int] = []; var escaped = false
        for index in 0..<ns.length {
            let character = ns.character(at: index)
            if escaped {
                escaped = false
            } else if character == 92 {
                escaped = true
            } else if character == 124 {
                pipes.append(index)
            }
        }
        let firstNonspace = (0..<ns.length).first { !Self.isWhitespace(ns.character(at: $0)) }
        let lastNonspace = (0..<ns.length).reversed().first { !Self.isWhitespace(ns.character(at: $0)) }
        let leading = firstNonspace.map { ns.character(at: $0) == 124 } ?? false
        let trailing = lastNonspace.map { ns.character(at: $0) == 124 && pipes.contains($0) } ?? false
        var bounds = [-1] + pipes + [ns.length]
        if leading { bounds.removeFirst() }; if trailing { bounds.removeLast() }
        var cells: [String] = [], ranges: [NSRange] = []
        for i in 0..<(bounds.count - 1) {
            var s = bounds[i] + 1, e = bounds[i + 1]
            while s < e && Self.isWhitespace(ns.character(at: s)) { s += 1 }
            while e > s && Self.isWhitespace(ns.character(at: e - 1)) { e -= 1 }
            let raw = ns.substring(with: NSRange(location: s, length: e - s))
            cells.append(Self.unescape(raw))
            ranges.append(NSRange(location: baseOffset + s, length: e - s))
        }
        return (cells, ranges)
    }
    private static func isSeparator(_ value: String) -> Bool {
        let core = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return !core.isEmpty && core.allSatisfy { $0 == "-" }
    }
    private static func alignment(_ s: String) -> Alignment { if s.hasPrefix(":") && s.hasSuffix(":") { return .center }; if s.hasPrefix(":") { return .left }; if s.hasSuffix(":") { return .right }; return .none }
    private static func separator(_ a: Alignment) -> String { switch a { case .none: return "---"; case .left: return ":---"; case .center: return ":---:"; case .right: return "---:" } }
    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }

    private static func unescape(_ value: String) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count,
               characters[index + 1] == "\\" || characters[index + 1] == "|" {
                result.append(characters[index + 1])
                index += 2
            } else {
                result.append(characters[index])
                index += 1
            }
        }
        return result
    }

    private static func escape(_ value: String) -> String {
        let characters = Array(value)
        var result = ""
        var index = 0
        while index < characters.count {
            if characters[index] != "\\" {
                if characters[index] == "|" { result.append("\\") }
                result.append(characters[index])
                index += 1
                continue
            }

            let runStart = index
            while index < characters.count, characters[index] == "\\" { index += 1 }
            let slashCount = index - runStart
            if index < characters.count, characters[index] == "|" {
                result.append(String(repeating: "\\", count: slashCount * 2 + 1))
                result.append("|")
                index += 1
            } else {
                result.append(String(repeating: "\\", count: slashCount))
            }
        }
        return result
    }
    private static func render(_ cells: [String]) -> String { "| " + cells.map(escape).joined(separator: " | ") + " |" }
    private static func lineEnding(in s: String) -> String { s.contains("\r\n") ? "\r\n" : "\n" }
    private static func hasTrailingNewline(_ s: String) -> Bool { s.hasSuffix("\n") || s.hasSuffix("\r") }
}
