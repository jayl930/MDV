import Foundation

@Observable
final class ToCModel {
    var entries: [ToCEntry] = []
    var isVisible: Bool {
        didSet { UserDefaults.standard.set(isVisible, forKey: "isToCVisible") }
    }
    var scrollToRange: ((NSRange) -> Void)?

    init() {
        self.isVisible = UserDefaults.standard.bool(forKey: "isToCVisible")
    }
}
