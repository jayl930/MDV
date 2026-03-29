import AppKit

struct TableOperations {

    /// Find which table the cursor is in, if any
    static func findTable(at charIndex: Int, in tables: [TableData]) -> TableData? {
        tables.first { NSLocationInRange(charIndex, $0.sourceRange) }
    }

    /// Find which row index the cursor is in (0 = header)
    static func findRowIndex(at charIndex: Int, in table: TableData) -> Int? {
        // Table context menu currently disabled for overlay-based rendering
        return nil
    }

    /// Parse a table row into cell contents (splitting by |)
    static func parseCells(from line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") && trimmed.hasSuffix("|") else {
            return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        // Remove leading/trailing pipes, split by |
        let inner = String(trimmed.dropFirst().dropLast())
        return inner.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Build a table row from cells
    static func buildRow(cells: [String], columnWidths: [Int]) -> String {
        var parts: [String] = []
        for (i, cell) in cells.enumerated() {
            let width = i < columnWidths.count ? columnWidths[i] : max(cell.count, 3)
            parts.append(" " + cell.padding(toLength: width, withPad: " ", startingAt: 0) + " ")
        }
        return "|" + parts.joined(separator: "|") + "|"
    }

    /// Build separator row
    static func buildSeparator(columnWidths: [Int]) -> String {
        let parts = columnWidths.map { String(repeating: "-", count: $0 + 2) }
        return "|" + parts.joined(separator: "|") + "|"
    }

    /// Get column widths from the table text
    static func getColumnWidths(from tableText: String) -> [Int] {
        let lines = tableText.components(separatedBy: "\n").filter { !$0.isEmpty }
        var maxWidths: [Int] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip separator rows
            if trimmed.contains("-") && trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            let cells = parseCells(from: line)
            for (i, cell) in cells.enumerated() {
                if i >= maxWidths.count {
                    maxWidths.append(cell.count)
                } else {
                    maxWidths[i] = max(maxWidths[i], cell.count)
                }
            }
        }
        return maxWidths.map { max($0, 3) }
    }

    /// Add a new row below the given row index
    static func addRowBelow(tableText: String, rowIndex: Int) -> String {
        let widths = getColumnWidths(from: tableText)
        let emptyCells = widths.map { _ in "" }
        let newRow = buildRow(cells: emptyCells, columnWidths: widths)

        var lines = tableText.components(separatedBy: "\n")
        // Map rowIndex to actual line index (skip separator)
        var dataRowCount = -1
        var insertAt = lines.count
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("-") && trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            dataRowCount += 1
            if dataRowCount == rowIndex {
                insertAt = i + 1
                // Skip separator if it's right after
                if insertAt < lines.count {
                    let next = lines[insertAt].trimmingCharacters(in: .whitespaces)
                    if next.contains("-") && next.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                        insertAt += 1
                    }
                }
                break
            }
        }
        lines.insert(newRow, at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// Delete row at given index (0 = header, which we don't allow)
    static func deleteRow(tableText: String, rowIndex: Int) -> String {
        guard rowIndex > 0 else { return tableText } // Can't delete header
        var lines = tableText.components(separatedBy: "\n")
        var dataRowCount = -1
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("-") && trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            dataRowCount += 1
            if dataRowCount == rowIndex {
                lines.remove(at: i)
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Add a column to the right
    static func addColumn(tableText: String) -> String {
        var lines = tableText.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix("|") {
                let isSeparator = trimmed.contains("-") && trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " })
                if isSeparator {
                    lines[i] = trimmed + "------|"
                } else {
                    lines[i] = trimmed + "      |"
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Delete last column
    static func deleteLastColumn(tableText: String) -> String {
        var lines = tableText.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Remove last cell: find second-to-last |
            if let lastPipe = trimmed.lastIndex(of: "|"),
               lastPipe > trimmed.startIndex {
                let beforeLast = trimmed[trimmed.startIndex..<lastPipe]
                if let secondLastPipe = beforeLast.lastIndex(of: "|") {
                    lines[i] = String(trimmed[trimmed.startIndex...secondLastPipe])
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Move row up
    static func moveRowUp(tableText: String, rowIndex: Int) -> String {
        guard rowIndex > 1 else { return tableText } // Can't move header or first data row above header
        var dataLines: [(index: Int, content: String)] = []
        let lines = tableText.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("-") && trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            dataLines.append((i, line))
        }
        guard rowIndex < dataLines.count else { return tableText }
        var result = lines
        let current = dataLines[rowIndex]
        let above = dataLines[rowIndex - 1]
        result[current.index] = above.content
        result[above.index] = current.content
        return result.joined(separator: "\n")
    }

    /// Move row down
    static func moveRowDown(tableText: String, rowIndex: Int) -> String {
        var dataLines: [(index: Int, content: String)] = []
        let lines = tableText.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.contains("-") && trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) {
                continue
            }
            dataLines.append((i, line))
        }
        guard rowIndex >= 0, rowIndex < dataLines.count - 1 else { return tableText }
        var result = lines
        let current = dataLines[rowIndex]
        let below = dataLines[rowIndex + 1]
        result[current.index] = below.content
        result[below.index] = current.content
        return result.joined(separator: "\n")
    }
}
