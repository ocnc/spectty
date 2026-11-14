import Foundation

/// A read-only view of native scrollback; lines are decoded only when requested.
public struct TerminalBuffer: Sendable {
    public let count: Int
    public let capacity: Int
    private let readLine: (@Sendable (Int) -> TerminalLine?)?

    public init(capacity: Int = 10_000) {
        count = 0
        self.capacity = capacity
        readLine = nil
    }

    init(count: Int, capacity: Int, line: @escaping @Sendable (Int) -> TerminalLine?) {
        self.count = count
        self.capacity = capacity
        readLine = line
    }

    /// Index zero is the oldest retained line.
    public func line(at index: Int) -> TerminalLine? {
        guard index >= 0, index < count else { return nil }
        return readLine?(index)
    }
}
