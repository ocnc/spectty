import Foundation

/// Ring buffer for terminal scrollback history.
public struct TerminalBuffer: Sendable {
    private var storage: [TerminalLine]
    private var head: Int = 0
    private var _count: Int = 0
    public let capacity: Int

    public var count: Int { _count }

    public init(capacity: Int = 10_000) {
        self.capacity = capacity
        self.storage = []
        self.storage.reserveCapacity(min(capacity, 1024))
    }

    /// Push a line into the scrollback buffer.
    public mutating func push(_ line: TerminalLine) {
        if storage.count < capacity {
            storage.append(line)
            _count = storage.count
        } else {
            storage[head] = line
            head = (head + 1) % capacity
            _count = capacity
        }
    }

    /// Access a line by index (0 = oldest visible, count-1 = most recent).
    public func line(at index: Int) -> TerminalLine? {
        guard index >= 0, index < _count else { return nil }
        let storageIndex: Int
        if storage.count < capacity {
            storageIndex = index
        } else {
            storageIndex = (head + index) % capacity
        }
        return storage[storageIndex]
    }

    /// Clear the scrollback buffer.
    public mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        _count = 0
    }
}
