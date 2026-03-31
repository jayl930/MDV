import AppKit

struct Typography {
    let baseFontSize: CGFloat

    init(baseFontSize: CGFloat = 16) {
        self.baseFontSize = baseFontSize
    }

    // MARK: - Fonts

    var body: NSFont {
        .systemFont(ofSize: baseFontSize, weight: .regular)
    }

    var bodyBold: NSFont {
        .systemFont(ofSize: baseFontSize, weight: .bold)
    }

    var bodyItalic: NSFont {
        let descriptor = NSFont.systemFont(ofSize: baseFontSize).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseFontSize) ?? .systemFont(ofSize: baseFontSize)
    }

    var bodyBoldItalic: NSFont {
        let descriptor = NSFont.boldSystemFont(ofSize: baseFontSize).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseFontSize) ?? .boldSystemFont(ofSize: baseFontSize)
    }

    func heading(level: Int) -> NSFont {
        let size: CGFloat
        let weight: NSFont.Weight
        switch level {
        case 1: size = baseFontSize * 1.75; weight = .bold
        case 2: size = baseFontSize * 1.45; weight = .bold
        case 3: size = baseFontSize * 1.2; weight = .semibold
        case 4: size = baseFontSize * 1.05; weight = .semibold
        case 5: size = baseFontSize; weight = .semibold
        default: size = baseFontSize; weight = .medium
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    var code: NSFont {
        .monospacedSystemFont(ofSize: baseFontSize * 0.85, weight: .regular)
    }

    var codeBold: NSFont {
        .monospacedSystemFont(ofSize: baseFontSize * 0.85, weight: .bold)
    }

    // MARK: - Paragraph Styles

    var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.4
        style.paragraphSpacing = baseFontSize * 0.4
        return style
    }

    var emptyLineParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 0.9
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        return style
    }

    func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.25
        let spacing: CGFloat
        switch level {
        case 1: spacing = baseFontSize * 0.6
        case 2: spacing = baseFontSize * 0.5
        case 3: spacing = baseFontSize * 0.4
        default: spacing = baseFontSize * 0.3
        }
        style.paragraphSpacing = spacing
        style.paragraphSpacingBefore = spacing * 0.8
        return style
    }

    var blockQuoteParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.4
        style.headIndent = 16
        style.firstLineHeadIndent = 16
        style.paragraphSpacing = baseFontSize * 0.15
        return style
    }

    func listParagraphStyle(level: Int = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.4
        let indent = CGFloat(level + 1) * 20
        style.headIndent = indent
        style.firstLineHeadIndent = indent - 14
        style.paragraphSpacing = baseFontSize * 0.1
        let tab = NSTextTab(textAlignment: .left, location: indent)
        style.tabStops = [tab]
        return style
    }

    var codeParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 0
        return style
    }

    var codeBlockParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 0
        style.headIndent = 12
        style.firstLineHeadIndent = 12
        style.tailIndent = -12
        return style
    }

    var tableParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = 0
        style.headIndent = 8
        style.firstLineHeadIndent = 8
        style.lineBreakMode = .byClipping
        return style
    }
}
