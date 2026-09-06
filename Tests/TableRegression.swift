import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct TableRegression {
static func main() {
let source = "| Name | Formula | Note |\n| :--- | ---: | :---: |\n| alpha | a\\|b | keep |"
guard var table = MarkdownTable(markdown: source) else { fatalError("parse") }

expect(table.markdown() == source, "untouched source must be byte-identical")
expect(table.alignments == [.left, .right, .center], "alignment parsing")
expect(table.rows[1][1] == "a|b", "escaped pipe is one cell")

let dependencyFixture = "a | b | c | d | e\n:-- | --- | :-: | --- | --:\n1 | 2 | 3 | 4 | 5"
expect(MarkdownTable(markdown: dependencyFixture) != nil, "accepts swift-cmark delimiter fixture variants")

let optionalPipes = "Left | Right\n:--- | ---:\nplain | escaped\\|pipe"
guard let optional = MarkdownTable(markdown: optionalPipes) else { fatalError("optional pipes parse") }
expect(optional.markdown() == optionalPipes, "optional outer pipes round-trip untouched")
expect(optional.rows[1] == ["plain", "escaped|pipe"], "optional pipes preserve escaped separator")

let lexical = " H1  |  H2 \r\n :--- | ---: \r\n C:\\tmp\\file  | literal \\*star\\* and end\\| \r\n"
guard var preserved = MarkdownTable(markdown: lexical) else { fatalError("lexical parse") }
expect(preserved.markdown() == lexical, "CRLF, trailing newline, whitespace, and backslashes round-trip")
let beforeColumns = preserved.columnCount
preserved.setCell(row: 99, column: 99, value: "invalid")
expect(preserved.columnCount == beforeColumns && preserved.markdown() == lexical, "invalid cell edit is a no-op")
preserved.setCell(row: 1, column: 0, value: "new")
let targeted = preserved.markdown()
expect(targeted.contains(" H1  |  H2 \r\n :--- | ---: \r\n new  | literal \\*star\\* and end\\| \r\n"), "targeted edit preserves unrelated lexical source")

let emojiSource = "| 😀 | path |\n| --- | --- |\n| 🧪 | C:\\tmp |"
guard var emoji = MarkdownTable(markdown: emojiSource) else { fatalError("emoji parse") }
expect(emoji.markdown() == emojiSource, "emoji survives lexical scan")
emoji.setCell(row: 1, column: 1, value: "slash\\|pipe")
let slashPipe = emoji.markdown()
guard let reparsedSlashPipe = MarkdownTable(markdown: slashPipe) else { fatalError("slash-pipe reparse") }
expect(reparsedSlashPipe.rows[1][1] == "slash\\|pipe", "backslash adjacent to pipe round-trips semantically")

let raggedSource = "| A | B |\n| --- | --- |\n| one | two | three |"
guard var ragged = MarkdownTable(markdown: raggedSource) else { fatalError("ragged parse") }
ragged.insertRow(after: 1)
expect(ragged.markdown().contains("| --- | --- | --- |"), "ragged structural serialization fills missing alignment")

let escapedMarkdown = "| A | B |\n| --- | --- |\n| \\*literal\\* | C:\\tmp\\file |"
guard var escapedStructural = MarkdownTable(markdown: escapedMarkdown) else { fatalError("escaped structural parse") }
escapedStructural.insertRow(after: 1)
let escapedStructuralOutput = escapedStructural.markdown()
expect(escapedStructuralOutput.contains("| \\*literal\\* | C:\\tmp\\file |"), "structural edit preserves non-table Markdown escapes and paths")

guard var newlineRejected = MarkdownTable(markdown: source) else { fatalError("newline validation parse") }
newlineRejected.setCell(row: 1, column: 0, value: "row\ninjection")
expect(newlineRejected.markdown() == source, "cell values reject row-injecting newlines")

guard var invalidStructural = MarkdownTable(markdown: source) else { fatalError("invalid structural parse") }
invalidStructural.insertRow(after: -99)
invalidStructural.insertColumn(after: 999)
expect(invalidStructural.markdown() == source, "invalid structural indices are no-ops")

table.setCell(row: 1, column: 2, value: "changed | value")
let edited = table.markdown()
expect(edited.contains("| :--- | ---: | :---: |"), "cell edit preserves alignments")
expect(edited.contains("changed \\| value"), "cell edit escapes literal pipe")
let once = edited
table.setCell(row: 1, column: 2, value: "changed | value")
expect(table.markdown() == once, "repeated identical edit is idempotent")

table.insertColumn(after: 0)
expect(table.columnCount == 4, "contextual column insertion")
table.removeColumn(at: 1)
expect(table.columnCount == 3, "contextual column removal")
table.insertRow(after: 1)
expect(table.rowCount == 3, "row insertion")
table.removeRow(at: 2)
expect(table.rowCount == 2, "row removal")

print("TableRegression: observed all assertions")
}
}
