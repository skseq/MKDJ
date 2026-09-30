import Foundation

/// Eased snapback-to-default: four curves
/// (easing.dev vocabulary), one shared main-thread tween driver, and a
/// Settings pair (curve + 0…0.5 s duration; 0 s = the instant jump).
enum SnapEase: String, CaseIterable, Identifiable {
    case linear
    case inOutCubic
    case outExpo
    case inOutExpo

    var id: String { rawValue }

    var name: String {
        switch self {
        case .linear: return "Linear"
        case .inOutCubic: return "Smooth in-out"
        case .outExpo: return "Snappy out"
        case .inOutExpo: return "In-out expo"
        }
    }

    /// Normalized time t ∈ [0,1] → progress p ∈ [0,1]. Endpoints exact.
    func p(_ t: Double) -> Double {
        let c = min(1, max(0, t))
        if c <= 0 { return 0 }
        if c >= 1 { return 1 }
        switch self {
        case .linear: return c
        case .inOutCubic: return c < 0.5 ? 4 * c * c * c : 1 - pow(-2 * c + 2, 3) / 2
        case .outExpo: return 1 - pow(2, -10 * c)
        case .inOutExpo:
            return c < 0.5 ? pow(2, 20 * c - 10) / 2 : (2 - pow(2, -20 * c + 10)) / 2
        }
    }
}

/// One tween driver for every control (no per-control timers). Resets pass
/// the SAME live setter the instant path used (the single-data-path
/// law) plus a `read` of the control's current value: a tween whose value
/// was written by anyone else (a grab, sync, another reset) cancels itself
/// on its next tick — no id bookkeeping, the freshest writer always wins.
/// Ticks run newest-tween-first so a same-control re-reset orphans the OLD
/// tween, not the new one. Any grab additionally calls `cancelAll()`
/// (explicit, immediate — a tween must never fight a tracking loop).
///
/// `advance(now:)` is the entire tick logic; the 60 Hz timer only calls it
/// (probe gates drive it with synthetic timestamps — deterministic).
enum Snapback {

    private static var tweens: [Tween] = []
    private static var timer: Timer?

    private final class Tween {
        let origin: Double
        let target: Double
        let start: Date
        let duration: Double
        let curve: SnapEase
        let apply: (Double) -> Void
        let read: () -> Double
        var lastWritten: Double
        init(origin: Double, target: Double, start: Date, duration: Double,
             curve: SnapEase, apply: @escaping (Double) -> Void,
             read: @escaping () -> Double) {
            self.origin = origin
            self.target = target
            self.start = start
            self.duration = duration
            self.curve = curve
            self.apply = apply
            self.read = read
            self.lastWritten = origin
        }
    }

    static var activeCount: Int { tweens.count }

    /// Reset entry point (MainActor — reads AppSettings). Duration ≤ 0 =
    /// one synchronous write, byte-for-byte today's behavior.
    @MainActor
    static func reset(current: Double, to target: Double,
                      apply: @escaping (Double) -> Void,
                      read: @escaping () -> Double) {
        let s = AppSettings.shared
        run(current: current, to: target, curve: s.snapEase,
            duration: s.snapSeconds, apply: apply, read: read)
    }

    /// Tween engine (main thread; settings were captured by the caller).
    /// `startTimer: false` = deterministic mode for probe gates, which then
    /// drive `advance(now:)` with synthetic timestamps.
    static func run(current: Double, to target: Double, curve: SnapEase,
                    duration: Double, apply: @escaping (Double) -> Void,
                    read: @escaping () -> Double, startTimer: Bool = true) {
        assert(Thread.isMainThread)
        guard duration > 0, current != target else {
            apply(target)
            return
        }
        tweens.append(Tween(origin: current, target: target, start: Date(),
                            duration: duration, curve: curve,
                            apply: apply, read: read))
        if startTimer { ensureTimer() }
    }

    static func cancelAll() {
        assert(Thread.isMainThread)
        tweens.removeAll()
        timer?.invalidate()
        timer = nil
    }

    static func advance(now: Date) {
        assert(Thread.isMainThread)
        var alive: [Tween] = []
        // newest first — in a same-control collision the OLD tween sees the
        // new tween's write and orphans itself
        for tw in tweens.reversed() {
            if abs(tw.read() - tw.lastWritten) > 1e-9 { continue }   // foreign writer
            let t = now.timeIntervalSince(tw.start) / tw.duration
            if t >= 1 {
                tw.apply(tw.target)
                continue
            }
            let v = tw.origin + (tw.target - tw.origin) * tw.curve.p(t)
            tw.apply(v)
            tw.lastWritten = v
            alive.append(tw)
        }
        tweens = alive.reversed()
        if tweens.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func ensureTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            advance(now: Date())
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
}
