import Foundation

struct ToCEntry: Identifiable, Equatable {
    let id = UUID()
    let level: Int
    let title: String
    let range: NSRange

    static func == (lhs: ToCEntry, rhs: ToCEntry) -> Bool {
        lhs.level == rhs.level && lhs.title == rhs.title && lhs.range == rhs.range
    }
}
