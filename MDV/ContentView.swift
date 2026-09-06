//
//  ContentView.swift
//  MDV
//
//  Created by Jay Lee on 3/29/26.
//

import SwiftUI

private struct TableOfContentsModelKey: FocusedValueKey {
    typealias Value = ToCModel
}

extension FocusedValues {
    var tableOfContentsModel: ToCModel? {
        get { self[TableOfContentsModelKey.self] }
        set { self[TableOfContentsModelKey.self] = newValue }
    }
}

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
        .focusedSceneValue(\.tableOfContentsModel, tocModel)
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
        let view = WindowObservingView(frame: .zero)
        context.coordinator.tocModel = tocModel
        context.coordinator.theme = theme
        view.windowDidChange = { [weak coordinator = context.coordinator] oldWindow, newWindow in
            coordinator?.move(from: oldWindow, to: newWindow)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.tocModel = tocModel
        context.coordinator.theme = theme
        context.coordinator.move(from: nil, to: nsView.window)
        context.coordinator.updateButtonAppearance()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let observingView = nsView as? WindowObservingView {
            observingView.windowDidChange = nil
        }
        coordinator.move(from: nsView.window, to: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var tocModel: ToCModel?
        var theme: MDVTheme?
        private var button: NSButton?
        private var accessoryViewController: NSTitlebarAccessoryViewController?
        private weak var window: NSWindow?

        func move(from oldWindow: NSWindow?, to newWindow: NSWindow?) {
            if let installedWindow = window, installedWindow !== newWindow {
                removeAccessory(from: installedWindow)
            } else if window == nil, let oldWindow, oldWindow !== newWindow {
                removeAccessory(from: oldWindow)
            }

            guard let window = newWindow else { return }
            guard self.window !== window || accessoryViewController == nil else { return }
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
            accessoryViewController = accessoryVC
        }

        private func removeAccessory(from window: NSWindow) {
            if let accessoryViewController,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessoryViewController }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            accessoryViewController = nil
            button = nil
            self.window = nil
        }

        func updateButtonAppearance() {
            guard let btn = button, let theme = theme, let tocModel = tocModel else { return }
            btn.contentTintColor = tocModel.isVisible ? theme.accent : theme.secondaryText
            window?.backgroundColor = theme.background
        }

        @objc func toggleToc() {
            guard let tocModel = tocModel else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                tocModel.toggleVisibility()
            }
            updateButtonAppearance()
        }
    }


    final class WindowObservingView: NSView {
        var windowDidChange: ((NSWindow?, NSWindow?) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            let oldWindow = window
            super.viewWillMove(toWindow: newWindow)
            windowDidChange?(oldWindow, newWindow)
        }
    }
}
