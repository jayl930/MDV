import AppKit

/// Maps canonical markdown source coordinates to the text presented by the editor.
///
/// AppKit character ranges are UTF-16 ranges. Each replacement collapses a source
/// range (currently a markdown table) to one attachment character in the display.
struct EditorProjection {
    struct Replacement {
        let sourceRange: NSRange
        let displayRange: NSRange
    }

    static let identity = EditorProjection(replacements: [])

    private(set) var replacements: [Replacement]

    init(sourceRanges: [NSRange]) {
        var removedLength = 0
        replacements = sourceRanges.sorted { $0.location < $1.location }.map { sourceRange in
            let displayRange = NSRange(
                location: sourceRange.location - removedLength,
                length: 1
            )
            removedLength += max(0, sourceRange.length - 1)
            return Replacement(sourceRange: sourceRange, displayRange: displayRange)
        }
    }

    private init(replacements: [Replacement]) {
        self.replacements = replacements
    }

    func displayRange(forSource sourceRange: NSRange) -> NSRange? {
        map(sourceRange, from: \Replacement.sourceRange, to: \Replacement.displayRange)
    }

    func sourceRange(forDisplay displayRange: NSRange) -> NSRange? {
        map(displayRange, from: \Replacement.displayRange, to: \Replacement.sourceRange)
    }

    /// Splits a source range around replacements and maps only ordinary text.
    /// This lets callers restyle displayed text without clearing attachment attrs.
    func displayTextRanges(forSource sourceRange: NSRange) -> [NSRange] {
        var ranges: [NSRange] = []
        var cursor = sourceRange.location
        let end = NSMaxRange(sourceRange)

        for replacement in replacements {
            let replaced = replacement.sourceRange
            guard replaced.location < end, NSMaxRange(replaced) > cursor else { continue }
            if cursor < replaced.location,
               let mapped = displayRange(forSource: NSRange(location: cursor, length: replaced.location - cursor)) {
                ranges.append(mapped)
            }
            cursor = max(cursor, NSMaxRange(replaced))
        }
        if cursor < end,
           let mapped = displayRange(forSource: NSRange(location: cursor, length: end - cursor)) {
            ranges.append(mapped)
        }
        return ranges
    }

    /// Reconstructs markdown from the attributed display. Reading attachment
    /// attributes makes deletion and reordering deterministic; no positional list
    /// of attachment characters is consulted.
    func source(from display: NSAttributedString) -> String {
        guard display.length > 0 else { return "" }

        let result = NSMutableString()
        let fullRange = NSRange(location: 0, length: display.length)
        var location = 0
        while location < fullRange.length {
            var effectiveRange = NSRange()
            let value = display.attribute(.attachment, at: location, effectiveRange: &effectiveRange)
            if let table = value as? TableAttachment {
                for _ in 0..<effectiveRange.length { result.append(table.originalMarkdown) }
            } else {
                result.append((display.string as NSString).substring(with: effectiveRange))
            }
            location = NSMaxRange(effectiveRange)
        }
        return result as String
    }

    /// Converts one post-edit NSTextStorage character edit into its canonical
    /// source replacement. The edited range and delta use TextKit's UTF-16
    /// coordinates. Attachment edits deliberately return nil so callers can
    /// fall back to identity-aware reconstruction.
    func sourceEdit(
        afterDisplayEdit editedRange: NSRange,
        delta: Int,
        replacement: String,
        displayLength: Int
    ) -> (range: NSRange, replacement: String)? {
        guard editedRange.location >= 0,
              editedRange.length >= 0,
              NSMaxRange(editedRange) <= displayLength,
              (replacement as NSString).length == editedRange.length else { return nil }

        let oldLength = editedRange.length - delta
        guard oldLength >= 0 else { return nil }
        let oldDisplayRange = NSRange(location: editedRange.location, length: oldLength)

        for replacement in replacements {
            let attachmentRange = replacement.displayRange
            if oldLength == 0 {
                if editedRange.location > attachmentRange.location,
                   editedRange.location < NSMaxRange(attachmentRange) { return nil }
            } else if NSIntersectionRange(oldDisplayRange, attachmentRange).length > 0 {
                return nil
            }
        }

        guard let sourceRange = sourceRange(forDisplay: oldDisplayRange) else { return nil }
        return (
            sourceRange,
            replacement
        )
    }

    /// Keeps the projection current for a normal text edit. Returns false when
    /// the edit consumes an attachment; callers should rebuild from source then.
    mutating func applyDisplayEdit(editedRange: NSRange, delta: Int) -> Bool {
        let oldLength = max(0, editedRange.length - delta)
        let oldRange = NSRange(location: editedRange.location, length: oldLength)

        if replacements.contains(where: { replacement in
            if oldLength == 0 { return editedRange.location > replacement.displayRange.location && editedRange.location < NSMaxRange(replacement.displayRange) }
            return NSIntersectionRange(oldRange, replacement.displayRange).length > 0
        }) {
            return false
        }

        replacements = replacements.map { replacement in
            guard replacement.displayRange.location >= NSMaxRange(oldRange) else { return replacement }
            return Replacement(
                sourceRange: NSRange(location: replacement.sourceRange.location + delta, length: replacement.sourceRange.length),
                displayRange: NSRange(location: replacement.displayRange.location + delta, length: replacement.displayRange.length)
            )
        }
        return true
    }

    mutating func updateReplacement(at index: Int, sourceLength: Int) {
        guard replacements.indices.contains(index) else { return }
        let old = replacements[index]
        let delta = sourceLength - old.sourceRange.length
        replacements[index] = Replacement(
            sourceRange: NSRange(location: old.sourceRange.location, length: sourceLength),
            displayRange: old.displayRange
        )
        guard delta != 0, index + 1 < replacements.count else { return }
        for following in (index + 1)..<replacements.count {
            let item = replacements[following]
            replacements[following] = Replacement(
                sourceRange: NSRange(location: item.sourceRange.location + delta, length: item.sourceRange.length),
                displayRange: item.displayRange
            )
        }
    }

    private func map(
        _ range: NSRange,
        from sourceKeyPath: KeyPath<Replacement, NSRange>,
        to targetKeyPath: KeyPath<Replacement, NSRange>
    ) -> NSRange? {
        if range.length == 0 {
            guard let location = mapPosition(
                range.location, affinity: .leading,
                from: sourceKeyPath, to: targetKeyPath
            ) else { return nil }
            return NSRange(location: location, length: 0)
        }

        guard let start = mapPosition(
            range.location, affinity: .leading,
            from: sourceKeyPath, to: targetKeyPath
        ), let end = mapPosition(
            NSMaxRange(range), affinity: .trailing,
            from: sourceKeyPath, to: targetKeyPath
        ) else { return nil }
        return NSRange(location: start, length: max(0, end - start))
    }

    private enum Affinity { case leading, trailing }

    private func mapPosition(
        _ position: Int,
        affinity: Affinity,
        from sourceKeyPath: KeyPath<Replacement, NSRange>,
        to targetKeyPath: KeyPath<Replacement, NSRange>
    ) -> Int? {
        var delta = 0
        for replacement in replacements {
            let source = replacement[keyPath: sourceKeyPath]
            let target = replacement[keyPath: targetKeyPath]
            let sourceEnd = NSMaxRange(source)

            if position == source.location { return target.location }
            if position == sourceEnd { return NSMaxRange(target) }
            if position > source.location && position < sourceEnd {
                return affinity == .leading ? target.location : NSMaxRange(target)
            }
            if sourceEnd < position {
                delta += target.length - source.length
            }
        }
        return position + delta
    }
}
