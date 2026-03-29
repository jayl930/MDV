import AppKit
import SwiftUI

enum AppearanceMode: String, CaseIterable {
    case light, dark, system
}

@Observable
final class MDVTheme {
    var appearanceMode: String
    var fontSize: Double
    var contentWidth: Double

    init() {
        self.appearanceMode = UserDefaults.standard.string(forKey: "appearance") ?? AppearanceMode.system.rawValue
        let size = UserDefaults.standard.double(forKey: "fontSize")
        self.fontSize = size > 0 ? size : 16
        let width = UserDefaults.standard.double(forKey: "contentWidth")
        self.contentWidth = width > 0 ? width : 720
    }

    func save() {
        UserDefaults.standard.set(appearanceMode, forKey: "appearance")
        UserDefaults.standard.set(fontSize, forKey: "fontSize")
        UserDefaults.standard.set(contentWidth, forKey: "contentWidth")
    }

    var isDark: Bool {
        switch AppearanceMode(rawValue: appearanceMode) ?? .system {
        case .light: return false
        case .dark: return true
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    // MARK: - Colors

    var background: NSColor {
        isDark ? NSColor(hex: 0x1E1C1A) : NSColor(hex: 0xFAFAF8)
    }

    var text: NSColor {
        isDark ? NSColor(hex: 0xE8E5DF) : NSColor(hex: 0x1A1A1A)
    }

    var headingText: NSColor {
        isDark ? NSColor(hex: 0xF4F3EE) : NSColor(hex: 0x0D0D0D)
    }

    var accent: NSColor {
        isDark ? NSColor(hex: 0xDE7356) : NSColor(hex: 0xC15F3C)
    }

    var codeBackground: NSColor {
        isDark ? NSColor(hex: 0x282523) : NSColor(hex: 0xF0EFED)
    }

    var codeText: NSColor {
        isDark ? NSColor(hex: 0xC4BFB6) : NSColor(hex: 0x3D3833)
    }

    var blockQuoteBar: NSColor {
        isDark ? NSColor(hex: 0xDE7356).withAlphaComponent(0.5) : NSColor(hex: 0xC15F3C).withAlphaComponent(0.4)
    }

    var blockQuoteBackground: NSColor {
        isDark ? NSColor(hex: 0x252220) : NSColor(hex: 0xF3F2EF)
    }

    var selection: NSColor {
        isDark ? NSColor(hex: 0xDE7356).withAlphaComponent(0.20) : NSColor(hex: 0xC15F3C).withAlphaComponent(0.15)
    }

    var cursor: NSColor { accent }

    var divider: NSColor {
        isDark ? NSColor(hex: 0x3A3632) : NSColor(hex: 0xD5D3CD)
    }

    var secondaryText: NSColor {
        isDark ? NSColor(hex: 0x9A9590) : NSColor(hex: 0x5A5550)
    }

    var tableHeaderBackground: NSColor {
        isDark ? NSColor(hex: 0x2A2725) : NSColor(hex: 0xEDECE8)
    }

    var tableBorder: NSColor {
        isDark ? NSColor(hex: 0x3A3632) : NSColor(hex: 0xD8D6D0)
    }

    // MARK: - SwiftUI Colors

    var backgroundSUI: Color { Color(nsColor: background) }
    var textSUI: Color { Color(nsColor: text) }
    var accentSUI: Color { Color(nsColor: accent) }
    var secondaryTextSUI: Color { Color(nsColor: secondaryText) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}
