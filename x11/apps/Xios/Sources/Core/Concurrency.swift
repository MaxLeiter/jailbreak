import Foundation

/// A generation counter readable from any thread. Work that leaves the main
/// thread captures the value it started under and abandons itself (or has its
/// result dropped on the way back) when the counter has moved: a stale result can
/// never touch a newer connection.
final class Epoch {
    private let lock = NSLock()
    private var current = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    @discardableResult
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return current
    }
}

/// A value shared with a worker queue.
final class Locked<T> {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
