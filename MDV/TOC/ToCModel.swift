import Foundation

@Observable
final class ToCModel {
    var entries: [ToCEntry] = []
    var isVisible: Bool = false
    var scrollToRange: ((NSRange) -> Void)?

    func toggleVisibility() {
        isVisible.toggle()
    }
}
