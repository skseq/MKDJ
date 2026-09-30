import Foundation

/// Hold the system awake while audio is flowing (any deck
/// playing or REC armed). Sleep mid-playback is the one state the pull
/// transport can't ride out intact — decode descriptors go stale across
/// unmount/remount; the watchdog heals it after the fact, but preventing
/// the sleep is cheaper than the surgery. Paused-idle sessions still
/// sleep normally (covered by the wake-time reopen).
final class KeepAwake {
    static let shared = KeepAwake()
    private let lock = NSLock()
    private var activity: NSObjectProtocol?
    private var playingMask = 0
    private var recording = false

    private init() {}

    /// Idempotent — called at 10 Hz from each deck's poll timer.
    func setDeckPlaying(_ index: Int, _ playing: Bool) {
        lock.lock()
        if playing { playingMask |= (1 << index) } else { playingMask &= ~(1 << index) }
        let mask = playingMask, rec = recording
        lock.unlock()
        evaluate(active: mask != 0 || rec)
    }

    func setRecording(_ on: Bool) {
        lock.lock()
        recording = on
        let mask = playingMask
        lock.unlock()
        evaluate(active: mask != 0 || on)
    }

    private func evaluate(active: Bool) {
        lock.lock(); defer { lock.unlock() }
        if active && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "MKDJ audio playing or recording")
            MKLog.app("keep-awake: ON")
        } else if !active && activity != nil {
            if let a = activity { ProcessInfo.processInfo.endActivity(a) }
            activity = nil
            MKLog.app("keep-awake: OFF")
        }
    }
}
