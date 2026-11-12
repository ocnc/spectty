import Foundation

public enum TerminalPaste {
    public static func data(for text: String, bracketed: Bool) -> Data {
        Data((bracketed ? "\u{1B}[200~" + text + "\u{1B}[201~" : text).utf8)
    }
}
