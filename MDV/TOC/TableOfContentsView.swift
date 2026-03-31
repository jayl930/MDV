import SwiftUI

struct TableOfContentsView: View {
    let tocModel: ToCModel
    let isDark: Bool
    @Environment(MDVTheme.self) private var theme

    private var bgColor: Color {
        isDark ? Color(red: 0x1E/255, green: 0x1C/255, blue: 0x1A/255)
               : Color(red: 0xFA/255, green: 0xFA/255, blue: 0xF8/255)
    }

    private var textColor: Color {
        isDark ? Color(red: 0xE8/255, green: 0xE5/255, blue: 0xDF/255)
               : Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255)
    }

    private var accentColor: Color {
        isDark ? Color(red: 0xDE/255, green: 0x73/255, blue: 0x56/255)
               : Color(red: 0xC1/255, green: 0x5F/255, blue: 0x3C/255)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(tocModel.entries) { entry in
                        ToCEntryRow(
                            entry: entry,
                            textColor: textColor,
                            accentColor: accentColor
                        ) {
                            tocModel.scrollToRange?(entry.range)
                        }
                    }
                }
                .padding(.top, geo.safeAreaInsets.top + 8)
                .padding(.bottom, 8)
                .padding(.horizontal, 4)
            }
            .ignoresSafeArea()
            .background(bgColor.ignoresSafeArea())
        }
        .frame(width: 220)
    }
}

private struct ToCEntryRow: View {
    let entry: ToCEntry
    let textColor: Color
    let accentColor: Color
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Text(entry.title)
                .font(.system(size: fontSize, weight: fontWeight))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, indentation)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? accentColor.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var fontSize: CGFloat {
        switch entry.level {
        case 1: return 14
        case 2: return 13
        case 3: return 12.5
        default: return 12
        }
    }

    private var fontWeight: Font.Weight {
        entry.level <= 2 ? .semibold : .regular
    }

    private var indentation: CGFloat {
        12 + CGFloat(entry.level - 1) * 14
    }
}
