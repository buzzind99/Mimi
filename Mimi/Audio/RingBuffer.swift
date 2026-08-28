import Foundation

/// Single-producer / single-consumer lock-free byte ring buffer.
/// The real-time IO proc only writes (memcpy, no allocations, no locks);
/// a worker queue drains it.
final class RingBuffer {
    private let capacity: Int
    private let mask: Int
    private var storage: UnsafeMutableRawPointer
    private let head = AtomicCounter() // write index (bytes)
    private let tail = AtomicCounter() // read index (bytes)

    /// Writer-only counter of dropped bytes when the consumer falls behind.
    private(set) var droppedBytes = 0

    init(capacity: Int) {
        var cap = 1
        while cap < capacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        storage = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 64)
    }

    deinit {
        storage.deallocate()
    }

    /// Bytes currently available to read.
    var availableBytes: Int {
        head.value &- tail.value
    }

    var freeBytes: Int {
        capacity - availableBytes
    }

    /// Writes bytes; returns false if it would overflow (caller drops the block).
    func write(_ bytes: UnsafeRawPointer, count: Int) -> Bool {
        guard count <= freeBytes else {
            droppedBytes &+= count
            return false
        }
        let h = head.value & mask
        let first = min(count, capacity - h)
        storage.advanced(by: h).copyMemory(from: bytes, byteCount: first)
        if count > first {
            storage.copyMemory(from: bytes.advanced(by: first), byteCount: count - first)
        }
        head.add(count)
        return true
    }

    /// Reads up to `count` bytes into `dest` without consuming them.
    /// Returns the number of bytes peeked.
    func peek(into dest: UnsafeMutableRawPointer, count: Int) -> Int {
        let avail = min(count, availableBytes)
        guard avail > 0 else { return 0 }
        let t = tail.value & mask
        let first = min(avail, capacity - t)
        dest.copyMemory(from: storage.advanced(by: t), byteCount: first)
        if avail > first {
            dest.advanced(by: first).copyMemory(from: storage, byteCount: avail - first)
        }
        return avail
    }

    /// Consumes `count` bytes previously inspected via `peek`.
    func skip(_ count: Int) {
        tail.add(min(count, availableBytes))
    }

    /// Writer-side accounting for a block dropped before any write.
    func noteDropped(_ byteCount: Int) {
        droppedBytes &+= byteCount
    }

    /// Consumer-side recovery: discard everything currently buffered.
    func dropBuffered() {
        tail.store(head.value)
    }

    /// Reads up to `count` bytes into `dest`; returns number actually read.
    func read(into dest: UnsafeMutableRawPointer, count: Int) -> Int {
        let avail = min(count, availableBytes)
        guard avail > 0 else { return 0 }
        let t = tail.value & mask
        let first = min(avail, capacity - t)
        dest.copyMemory(from: storage.advanced(by: t), byteCount: first)
        if avail > first {
            dest.advanced(by: first).copyMemory(from: storage, byteCount: avail - first)
        }
        tail.add(avail)
        return avail
    }

    func reset() {
        tail.store(head.value)
        droppedBytes = 0
    }
}

/// Minimal 64-bit atomic counter (no allocations; safe from the IO thread).
final class AtomicCounter {
    private var storage: Int64 = 0

    var value: Int {
        Int(OSAtomicAdd64Barrier(0, &storage))
    }

    func add(_ n: Int) {
        OSAtomicAdd64Barrier(Int64(n), &storage)
    }

    func store(_ n: Int) {
        let current = value
        OSAtomicAdd64Barrier(Int64(n - current), &storage)
    }
}
