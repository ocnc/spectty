import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultFontName") private var fontName = "Menlo"
    @AppStorage("defaultFontSize") private var fontSize = 14.0
    @AppStorage("defaultColorScheme") private var colorScheme = "Default"
    @AppStorage("scrollbackLines") private var scrollbackLines = 10_000
    @AppStorage("cursorStyle") private var cursorStyle = "block"

    var body: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Font")
                    Spacer()
                    Text(fontName)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Size")
                    Spacer()
                    Stepper("\(Int(fontSize))pt", value: $fontSize, in: 8...32, step: 1)
                }
            }

            Section("Terminal") {
                Picker("Cursor Style", selection: $cursorStyle) {
                    Text("Block").tag("block")
                    Text("Underline").tag("underline")
                    Text("Bar").tag("bar")
                }

                HStack {
                    Text("Scrollback Lines")
                    Spacer()
                    TextField("10000", value: $scrollbackLines, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
            }

            Section("Theme") {
                Picker("Color Scheme", selection: $colorScheme) {
                    Text("Default").tag("Default")
                    Text("Solarized Dark").tag("Solarized Dark")
                    Text("Solarized Light").tag("Solarized Light")
                    Text("Dracula").tag("Dracula")
                    Text("Nord").tag("Nord")
                    Text("Monokai").tag("Monokai")
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
    }
}
