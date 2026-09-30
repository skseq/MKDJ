import Foundation
import AppKit

/// Adaptive display clock for the wave lanes (IINA-patterned):
/// ONE main-runloop Timer in `.common` mode — it keeps firing during
/// native slider tracking and gesture tracking, which implicit SwiftUI
/// animation schedules don't guarantee — stepping at the rate the app
/// actually needs: 0 Hz idle (a 5 Hz watchdog watches for state changes),
/// 30 Hz playing, 120 Hz scrubbing/throw. Views redraw on `tick`.
final class LaneClock: ObservableObject {

    static let shared = LaneClock()

    @Published private(set) var tick: UInt64 = 0

    private var displayTimer: Timer?
    private var watchdog: Timer?
    private var rate: Double = 0

    /// What cadence does the app need right now? Reads both decks' live
    /// transport state (cheap, lock-guarded).
    private var rateProvider: () -> Double = {
        let decks = AudioController.shared.decks
        var active = false
        var manipulating = false
        for d in decks {
            let s = d.pullDeckStateForClock
            if s.playing { active = true }
            if s.scrubbing || abs(s.momentum - 1.0) > 0.01 { manipulating = true }
        }
        // 120 Hz while manipulating — macOS gesture events arrive
        // at up to ~120 Hz; the pinned-cursor view should redraw at the
        // same cadence so the display tracks the hand 1:1.
        if manipulating { return 120 }
        // 60 Hz while playing (was 30 — half the display rate
        // read as skip/stepping). Affordable: a lane frame is
        // ~1 ms; both decks at 60 Hz ≈ 12% of one core, total.
        if active { return 60 }
        return 0
    }

    private init() {
        let w = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.syncRate()
        }
        RunLoop.main.add(w, forMode: .common)
        watchdog = w
        syncRate()
    }

    /// Transport changes sync the cadence IMMEDIATELY — the
    /// 0.2 s watchdog meant PLAY left the lane ticking at the idle rate for
    /// up to 200 ms (the first-play stall).
    func syncNow() { syncRate() }

    private func syncRate() {
        let target = rateProvider()
        if target == rate { return }
        rate = target
        displayTimer?.invalidate()
        displayTimer = nil
        guard target > 0 else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / target, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick &+= 1
            self.syncRate()   // cadence follows state within one frame
        }
        RunLoop.main.add(t, forMode: .common)
        displayTimer = t
    }
}
