import Foundation
import SwiftData

/// Terminal profile configuration (font, colors, behavior).
@Model
final class TerminalProfile {
    var id: UUID
    var name: String

    /// Font name.
    var fontName: String
    /// Font size in points.
    var fontSize: Double

    /// Color scheme name.
    var colorSchemeName: String

    /// Cursor style: "block", "underline", "bar".
    var cursorStyle: String

    /// Scrollback buffer size.
    var scrollbackLines: Int

    /// Terminal type reported to the server.
    var termType: String

    /// Whether to send bell notifications.
    var bellEnabled: Bool

    init(
        name: String = "Default",
        fontName: String = "Menlo",
        fontSize: Double = 14,
        colorSchemeName: String = "Default",
        cursorStyle: String = "block",
        scrollbackLines: Int = 10_000,
        termType: String = "xterm-256color",
        bellEnabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorSchemeName = colorSchemeName
        self.cursorStyle = cursorStyle
        self.scrollbackLines = scrollbackLines
        self.termType = termType
        self.bellEnabled = bellEnabled
    }
}
