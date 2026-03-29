//
//  MDVApp.swift
//  MDV
//
//  Created by Jay Lee on 3/29/26.
//

import SwiftUI

@main
struct MDVApp: App {
    @State private var theme = MDVTheme()
    @State private var updateChecker = UpdateChecker()

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document)
                .environment(theme)
                .environment(updateChecker)
                .frame(minWidth: 500, minHeight: 400)
                .onAppear {
                    applyAppearance()
                }
                .onChange(of: theme.appearanceMode) {
                    applyAppearance()
                }
        }
        .defaultSize(width: 860, height: 720)

        Settings {
            SettingsView()
                .environment(theme)
                .environment(updateChecker)
        }
    }

    private func applyAppearance() {
        switch AppearanceMode(rawValue: theme.appearanceMode) ?? .system {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}
