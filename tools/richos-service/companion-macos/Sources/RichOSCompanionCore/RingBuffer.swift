import Foundation

/// A minimal thread-safe FIFO of Float samples. The two audio callbacks (mic IOProc, system-tap
/// IOProc) are independent real-time threads; each appends its mono-downmixed frames here, and the
/// writer thread pulls frame-aligned blocks. Locking is coarse but the payloads are small (a few ms
/// of audio per callback) so contention is negligible; the real-time threads never block on I/O.
public final class RingBuffer {
    private var storage: [Float] = []
    private let lock = NSLock()
    /// Absolute epoch-ms of the most recent append — the starvation clock (§6.2).
    private(set) public var lastAppendMs: Int64 = 0

    public init() {}

    public func append(_ samples: [Float], nowMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        storage.append(contentsOf: samples)
        lastAppendMs = nowMs
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    /// Remove and return the first `n` samples (or fewer if not available).
    public func take(_ n: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let k = min(n, storage.count)
        if k == 0 { return [] }
        let out = Array(storage[0..<k])
        storage.removeFirst(k)
        return out
    }

    public func lastAppend() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return lastAppendMs
    }
}
