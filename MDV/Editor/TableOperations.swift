import AppKit

struct TableOperations {
    static func findTable(at charIndex: Int, in tables: [TableData]) -> TableData? {
        tables.first { NSLocationInRange(charIndex, $0.sourceRange) }
    }

    static func findRowIndex(at charIndex: Int, in table: TableData) -> Int? {
        nil
    }

    static func parseCells(from line: String) -> [String] {
        MarkdownTable.parseRow(line)
    }

    static func addRowBelow(tableText: String, rowIndex: Int) -> String {
        mutate(tableText) { $0.insertRow(after: rowIndex) }
    }

    static func deleteRow(tableText: String, rowIndex: Int) -> String {
        mutate(tableText) { $0.removeRow(at: rowIndex) }
    }

    static func addColumn(tableText: String) -> String {
        mutate(tableText) { table in
            table.insertColumn(after: table.columnCount - 1)
        }
    }

    static func addColumn(tableText: String, after columnIndex: Int) -> String {
        mutate(tableText) { $0.insertColumn(after: columnIndex) }
    }

    static func deleteLastColumn(tableText: String) -> String {
        mutate(tableText) { table in
            table.removeColumn(at: table.columnCount - 1)
        }
    }

    static func deleteColumn(tableText: String, at columnIndex: Int) -> String {
        mutate(tableText) { $0.removeColumn(at: columnIndex) }
    }

    static func moveRowUp(tableText: String, rowIndex: Int) -> String {
        mutate(tableText) { $0.moveRowUp(at: rowIndex) }
    }

    static func moveRowDown(tableText: String, rowIndex: Int) -> String {
        mutate(tableText) { $0.moveRowDown(at: rowIndex) }
    }

    private static func mutate(
        _ markdown: String,
        operation: (inout MarkdownTable) -> Void
    ) -> String {
        guard var table = MarkdownTable(markdown: markdown) else { return markdown }
        operation(&table)
        return table.markdown()
    }
}
