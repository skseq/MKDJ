import AppKit
import ObjectiveC

/// Permanent alert-sound suppression: a performance app has no
/// legitimate use for the system beep. `NSSound.beep` becomes a logged no-op
/// for THIS process only — every other app is untouched. Suppressed beeps
/// are counted and logged with an abbreviated caller, so if anything still
/// tries to beep we see exactly who.
enum BeepGuard {

    /// Counted by the dyld interposition of NSBeep() in stretch_shim.cpp —
    /// the one choke point every alert sound in the process funnels through.
    static var suppressedCount: Int { Int(mk_beep_suppressed_count()) }

    private static var lastSeen = 0

    static func install() {
        let ok = mk_beep_rebind_install() == 0
        MKLog.app("BeepGuard: NSBeep() rebound via fishhook (counted, not played) — \(ok ? "ok" : "FAILED")",
                   error: !ok)
        // Log increments at a gentle cadence; the Diagnostics window reads
        // the live counter directly.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 2.0)
        timer.setEventHandler {
            let n = suppressedCount
            if n != lastSeen {
                lastSeen = n
                MKLog.beep("suppressed — count now \(n)")
            }
        }
        timer.resume()
    }
}
