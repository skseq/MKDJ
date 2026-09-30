import Foundation
import Combine
import AppKit

@MainActor
final class AppModel: ObservableObject {

    let deckA: DeckModel
    let deckB: DeckModel
    var decks: [DeckModel] { [deckA, deckB] }

    // NOT @Published — no view reads these (the atoms own the
    // display); every write used to invalidate the whole tree for nothing.
    private(set) var masterVolume: Double = 1.0
    @Published var focusedDeck: Int = 0
    /// Focus badges mean "the ACTIVE app's focused deck" — they
    /// dim while MKDJ is backgrounded instead of glowing at the desktop.
    @Published var appActive = true
    let masterAtom = ControlAtom(1.0)

    let settings = AppSettings.shared
    private var activeObservers: [NSObjectProtocol] = []

    init() {
        deckA = DeckModel(index: 0)
        deckB = DeckModel(index: 1)
        applyMixer()
        let nc = NotificationCenter.default
        activeObservers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.appActive = true
        })
        activeObservers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.appActive = false
        })
    }

    func deck(_ i: Int) -> DeckModel { i == 0 ? deckA : deckB }



    func masterLive(_ v: Double) {
        AudioController.shared.setMaster(max(0, min(2, v)))
    }


    func setMasterVolume(_ v: Double) {
        masterVolume = max(0, min(2, v))
        masterAtom.v = masterVolume
        AudioController.shared.setMaster(masterVolume)
    }

    func applyMixer() {
        // The crossfader is gone — A/B volume faders are the mix
        // control; the engine's crossfade stage sits at dead center.
        AudioController.shared.setMaster(masterVolume)
        for d in decks { d.applyMixer() }
    }

    // MARK: - Continuous sync. Master-clock pattern (one
    // coordinator owns the tempo source; cf. Mixxx's sync-leader
    // architecture), mapped to two decks: the unsynced deck is the leader.

    /// The deck that FOLLOWS the other (its SYNC button is lit). At most
    /// one; engaging one releases the other — no cycles possible.
    @Published var syncedDeck: Int?
    private var syncTimer: Timer?
    /// The sync's own tempo writes must not disengage it.
    private var syncWritingTempo = false

    func toggleSync(_ deckIndex: Int) {
        // Belt-and-braces: the engine's trim capability is dormant (sync
        // is tempo-only), but any disengagement still zeroes it.
        if let old = syncedDeck {
            deck(old).engine.setPhaseTrim(0)
        }
        syncedDeck = (syncedDeck == deckIndex) ? nil : deckIndex
        syncTimer?.invalidate()
        syncTimer = nil
        guard syncedDeck != nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.syncTick()
        }
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
        syncTick()
    }

    /// Pure sync math (probe-gated): the slave rate that puts the slave's
    /// live BPM on the master's. Master tempo domain = transport rate
    /// (fader × nudge × jog) × throw momentum — NOT the scrub chase (sync
    /// follows tempo, not scratches). Octave-folded into [0.5, 2.0].
    nonisolated static func syncRate(masterBase: Double, masterTransport: Double,
                                     masterMomentum: Double, slaveBase: Double) -> Double? {
        guard masterBase > 0, slaveBase > 0 else { return nil }
        var rate = masterBase * masterTransport * masterMomentum / slaveBase
        while rate > 2.0 { rate /= 2 }
        while rate < 0.5 { rate *= 2 }
        return rate
    }

    func syncTick() {
        guard let slaveIdx = syncedDeck else { return }
        let slave = deck(slaveIdx), master = deck(1 - slaveIdx)
        let ms = master.engine.pullDeck.stateSnapshot
        // masterTransport is the FADER-only rate — a held tempo
        // bend (arrows/keys) is the deck's independent fine-tuning and must
        // not drag the synced deck with it. Throws (momentum) still follow.
        guard let rate = Self.syncRate(masterBase: master.baseBPM ?? 0,
                                       masterTransport: master.engine.faderOnlyRate,
                                       masterMomentum: ms.momentum,
                                       slaveBase: slave.baseBPM ?? 0) else { return }
        // Steady state publishes nothing — a 30 Hz write of an
        // unchanged rate cascaded @Published invalidations for nothing.
        // (The PHASE block below still runs every tick — returning here
        // used to freeze a stale trim once the tempo settled.)
        if abs(rate - slave.tempoRate) > 0.0005 {
            syncWritingTempo = true
            slave.setTempoRate(rate)
            syncWritingTempo = false
        }

    }

    /// A user's own tempo commit takes over: disengage that deck's sync.
    func userTouchedTempo(_ deckIndex: Int) {
        if syncedDeck == deckIndex, !syncWritingTempo {
            toggleSync(deckIndex)
        }
    }

    // MARK: - Focus + wave windows

    /// Wave zoom per deck, owned here so keyboard zoom can reach the
    /// FOCUSED deck (views bind into the array).
    @Published var waveWindows: [Double] = [15, 15]

    func zoomFocusedDeck(_ factor: Double) {
        let i = focusedDeck
        waveWindows[i] = min(180, max(3, waveWindows[i] * factor))
    }

    /// Single dispatch point for shortcut actions (mouse paths call the deck
    /// methods directly; this mirrors them for keyboard).
    func perform(deck i: Int, action: DeckAction, down: Bool) {
        let d = deck(i)
        switch action {
        case .playPause: if down { d.togglePlayPause() }
        case .cueHold: down ? d.cueDown() : d.cueUp()
        case .setCue: if down { d.setCue() }
        case .keylockToggle: if down { d.toggleKeylock() }
        case .nudgeMinus: d.nudge(active: down, sign: -1)
        case .nudgePlus: d.nudge(active: down, sign: 1)
        case .bpmDouble: if down { d.bpmMultiply(2) }
        case .bpmHalve: if down { d.bpmMultiply(0.5) }
        case .loopRestart: if down { d.reloop() }
        case .volumeUp: if down { d.volumeLive(d.volume + 0.05) }
        case .volumeDown: if down { d.volumeLive(d.volume - 0.05) }
        }
    }

}

/// Shared AppModel handle (DeckModel.setTempoRate needs this for the sync
/// take-over hook; it lives outside MKApp.swift, which the probe target
/// excludes).
@MainActor
enum AppModelHolder {
    static var shared: AppModel?
}
