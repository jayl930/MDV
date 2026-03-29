import SwiftUI

struct SettingsView: View {
    @Environment(MDVTheme.self) private var theme
    @Environment(UpdateChecker.self) private var updateChecker

    var body: some View {
        @Bindable var theme = theme

        VStack(alignment: .leading, spacing: 20) {
            // Appearance
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance")
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: $theme.appearanceMode) {
                    Text("Light").tag(AppearanceMode.light.rawValue)
                    Text("Dark").tag(AppearanceMode.dark.rawValue)
                    Text("System").tag(AppearanceMode.system.rawValue)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
            }

            // Font Size
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int(theme.fontSize))pt")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.fontSize, in: 12...24, step: 1)
                    .frame(width: 240)
            }

            // Content Width
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Content Width")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Int(theme.contentWidth))pt")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $theme.contentWidth, in: 500...1000, step: 20)
                    .frame(width: 240)
            }

            if updateChecker.isConfigured {
                Divider()

                HStack {
                    Text("Updates")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Check for Updates") {
                        updateChecker.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Spacer()

            // Version
            HStack {
                Spacer()
                Text("MDV \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 320, height: 340)
        .onChange(of: theme.appearanceMode) { theme.save() }
        .onChange(of: theme.fontSize) { theme.save() }
        .onChange(of: theme.contentWidth) { theme.save() }
    }
}
