import Foundation

/// Concurrency utilities (IINA-patterned): one Ticket type for
/// cancel-lapsed-work checks and one lock discipline helper, so the epoch
/// counters hand-rolled in five places stop being per-file conventions.


/// Scoped lock acquisition — makes critical sections visible and unbalanced
/// unlocks impossible.


/// Rolling frame-time stats: the lane Canvas draw times feed
/// this on the render thread; p50/p95/max are published periodically so
/// remaining drag lag can be attributed with NUMBERS (scheduling vs draw
/// cost) instead of by feel.
final class FrameStats: ObservableObject {
    static let shared = FrameStats()

    @Published private(set) var p50ms: Double = 0
    @Published private(set) var p95ms: Double = 0
    @Published private(set) var maxMs: Double = 0
    @Published private(set) var frames: Int = 0

    private var samples = [Double]()
    private let lock = NSLock()
    private var lastPublish = Date.distantPast

    func record(_ ms: Double) {
        lock.lock()
        samples.append(ms)
        if samples.count > 600 { samples.removeFirst(samples.count - 600) }
        let now = Date()
        let shouldPublish = now.timeIntervalSince(lastPublish) >= 2.0
        lock.unlock()
        if shouldPublish { publish() }
    }

    private func publish() {
        lock.lock()
        lastPublish = Date()
        let s = samples.sorted()
        let count = s.count
        let vals = count > 0
            ? (p50: s[count / 2], p95: s[Int(Double(count - 1) * 0.95)], max: s[count - 1], n: count)
            : (p50: 0, p95: 0, max: 0, n: 0)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.p50ms = vals.p50
            self?.p95ms = vals.p95
            self?.maxMs = vals.max
            self?.frames = vals.n
        }
        MKLog.engine(String(format: "lane draw p50 %.2f ms · p95 %.2f ms · max %.2f ms (n=%d)",
                             vals.p50, vals.p95, vals.max, vals.n))
    }
}
