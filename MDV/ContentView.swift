//
//  ContentView.swift
//  MDV
//
//  Created by Jay Lee on 3/29/26.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: MarkdownDocument
    @State private var tocModel = ToCModel()
    @Environment(MDVTheme.self) private var theme

    var body: some View {
        HStack(spacing: 0) {
            if tocModel.isVisible {
                TableOfContentsView(tocModel: tocModel, isDark: theme.isDark)
                    .transition(.move(edge: .leading))
                Divider()
            }
            MarkdownEditorView(document: $document, tocModel: tocModel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: tocModel.isVisible)
        .overlay {
            // Pass isDark as a value so SwiftUI detects changes and calls updateNSView
            TitleBarAccessory(tocModel: tocModel, theme: theme, isDark: theme.isDark)
                .frame(width: 0, height: 0)
        }
    }
}

/// Installs a plain button into the window's title bar via NSTitlebarAccessoryViewController.
/// This avoids the default glass/bordered toolbar styling entirely.
private struct TitleBarAccessory: NSViewRepresentable {
    let tocModel: ToCModel
    let theme: MDVTheme
    let isDark: Bool  // value type to trigger updateNSView on theme change

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.tocModel = tocModel
        context.coordinator.theme = theme
        DispatchQueue.main.async {
            context.coordinator.install(from: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.tocModel = tocModel
        context.coordinator.theme = theme
        context.coordinator.updateButtonAppearance()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var tocModel: ToCModel?
        var theme: MDVTheme?
        private var button: NSButton?
        private var installed = false

        private weak var window: NSWindow?

        func install(from view: NSView) {
            guard !installed, let window = view.window else { return }
            installed = true
            self.window = window

            // Make title bar transparent so it uses the window background color
            window.titlebarAppearsTransparent = true
            window.backgroundColor = theme?.background ?? NSColor.windowBackgroundColor

            let btn = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Table of Contents")
            btn.imageScaling = .scaleProportionallyDown
            btn.imagePosition = .imageOnly
            btn.target = self
            btn.action = #selector(toggleToc)
            btn.toolTip = "Toggle Table of Contents (⌘⇧T)"

            // Set symbol configuration for small size
            if let img = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                btn.image = img.withSymbolConfiguration(config)
            }

            self.button = btn
            updateButtonAppearance()

            let accessoryVC = NSTitlebarAccessoryViewController()
            accessoryVC.view = btn
            accessoryVC.layoutAttribute = .leading
            window.addTitlebarAccessoryViewController(accessoryVC)

            // Add keyboard shortcut via menu item
            let menuItem = NSMenuItem(title: "Toggle Table of Contents", action: #selector(toggleToc), keyEquivalent: "t")
            menuItem.keyEquivalentModifierMask = [.command, .shift]
            menuItem.target = self
            if let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu {
                viewMenu.addItem(NSMenuItem.separator())
                viewMenu.addItem(menuItem)
            }
        }

        func updateButtonAppearance() {
            guard let btn = button, let theme = theme, let tocModel = tocModel else { return }
            btn.contentTintColor = tocModel.isVisible ? theme.accent : theme.secondaryText
            window?.backgroundColor = theme.background
        }

        @objc func toggleToc() {
            guard let tocModel = tocModel else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                tocModel.isVisible.toggle()
            }
            updateButtonAppearance()
        }
    }
}
