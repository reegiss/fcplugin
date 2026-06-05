import Metal

final class MetalDeviceCache {

    static let shared = MetalDeviceCache()

    private struct CacheEntry {
        let device: MTLDevice
        var queues: [(queue: MTLCommandQueue, inUse: Bool)]
    }

    private var cache: [UInt64: CacheEntry] = [:]
    private let lock = NSLock()

    private init() {
        for device in MTLCopyAllDevices() {
            var queues: [(queue: MTLCommandQueue, inUse: Bool)] = []
            for _ in 0..<4 {
                if let q = device.makeCommandQueue() { queues.append((q, false)) }
            }
            cache[device.registryID] = CacheEntry(device: device, queues: queues)
        }
    }

    func device(forRegistryID id: UInt64) -> MTLDevice? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]?.device
    }

    func commandQueue(forRegistryID id: UInt64) -> MTLCommandQueue? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = cache[id] else { return nil }
        for i in entry.queues.indices where !entry.queues[i].inUse {
            entry.queues[i].inUse = true
            cache[id] = entry
            return entry.queues[i].queue
        }
        return nil
    }

    func returnCommandQueue(_ queue: MTLCommandQueue, forRegistryID id: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard var entry = cache[id] else { return }
        for i in entry.queues.indices where entry.queues[i].queue === queue {
            entry.queues[i].inUse = false
        }
        cache[id] = entry
    }
}
