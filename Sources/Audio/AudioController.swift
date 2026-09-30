import AVFoundation
import AppKit


/// Live output level for one deck — written from the audio
/// thread once per buffer, polled by the meter UI at its own cadence
/// (no per-buffer publishing).
final class LevelFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var _rms: Double = 0
    private var _peak: Double = 0
    private var _at: CFAbsoluteTime = 0

    var rms: Double { lock.lock(); defer { lock.unlock() }; return _rms }
    var peak: Double { lock.lock(); defer { lock.unlock() }; return _peak }
    var at: CFAbsoluteTime { lock.lock(); defer { lock.unlock() }; return _at }

    func store(rms: Double, peak: Double) {
        lock.lock()
        _rms = rms; _peak = peak; _at = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Digest one tap buffer into rms/peak. Called on the audio thread —
    /// no allocation beyond the store under lock.
    func store(buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let channels = buffer.floatChannelData else { return }
        var sumSq = 0.0
        var peak = 0.0
        for ch in 0..<Int(buffer.format.channelCount) {
            let data = channels[ch]
            for i in 0..<n {
                let v = Double(data[i])
                sumSq += v * v
                let a = abs(v)
                if a > peak { peak = a }
            }
        }
        store(rms: (sumSq / Double(n * Int(buffer.format.channelCount))).squareRoot(), peak: peak)
    }
}

/// Owns the AVAudioEngine and both decks; computes the multiplicative gain
/// stages (trim × fader × crossfade) with short ramps.
final class AudioController {

    static let shared = AudioController()

    let engine = AVAudioEngine()
    let deckA: DeckEngine
    let deckB: DeckEngine
    /// Per-deck POST-FADER level (deckMixer sits after the
    /// fader gain — the feed carries what you hear from that deck).
    let levelFeeds: [LevelFeed]

    private var deckVolume: [Double] = [0.85, 0.85]
    private var deckTrim: [Double] = [1.0, 1.0]
    private var masterVolume: Double = 1.0

    private(set) var started = false

    private init() {
        deckA = DeckEngine(index: 0)
        deckB = DeckEngine(index: 1)
        levelFeeds = [LevelFeed(), LevelFeed()]
        let main = engine.mainMixerNode
        deckA.attach(to: engine, destination: main)
        deckB.attach(to: engine, destination: main)
        main.outputVolume = Float(masterVolume)
        installLevelTaps()
        engine.prepare()
        do {
            try engine.start()
            started = true
        } catch {
            NSLog("MKDJ: AVAudioEngine failed to start: \(error)")
        }
        applyGains()
        // apply persisted engine choice (graph routing is a volume flip)
        applyPersistedOutputDevice()
        installWakeHandling()
    }

    // MARK: - Sleep/wake + engine configuration

    private var wakeTokens: [NSObjectProtocol] = []
    private var wakeWork: DispatchWorkItem?

    /// A paused deck's reader can
    /// freeze in kernel I/O across sleep (stale descriptor on a volume
    /// that unmounted/remounted) and the deck plays silence forever with
    /// no error anywhere. Observe the lifecycle, snapshot deck health,
    /// and reopen decode handles after real wakes.
    private func installWakeHandling() {
        let ws = NSWorkspace.shared.notificationCenter
        wakeTokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification,
                                         object: nil, queue: nil) { [weak self] _ in
            MKLog.app("sleep: engine running \(self?.engine.isRunning ?? false)")
        })
        wakeTokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                         object: nil, queue: nil) { [weak self] _ in
            self?.handleWake("system wake", reopen: true)
        })
        wakeTokens.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.handleWake("engine configuration change", reopen: false)
        })
    }

    /// Log deck health; restart the engine if the system stopped it;
    /// after real wakes, reopen every loaded decode handle (debounced —
    /// wake notifications can arrive in bursts).
    private func handleWake(_ reason: String, reopen: Bool) {
        MKLog.app("wake (\(reason)): engine running \(engine.isRunning)")
        if !engine.isRunning {
            try? engine.start()
            MKLog.app("wake: engine restarted — running \(engine.isRunning)", error: !engine.isRunning)
        }
        wakeWork?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for d in self.decks { d.revalidateAfterWake(reason: reason, reopen: reopen) }
        }
        wakeWork = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    private func installLevelTaps() {
        // Tap INSTALL moved into DeckEngine.reconnectChain —
        // disconnectNodeOutput kills taps, so a tap installed here dies on
        // the first loadFile rewire. We only bind feeds now.
        deckA.setLevelFeed(levelFeeds[0])
        deckB.setLevelFeed(levelFeeds[1])
    }

    private var hotplugInstalled = false
    private func installHotplugWatcherOnce() {
        guard !hotplugInstalled else { return }
        hotplugInstalled = true
        AudioOutputDevices.installHotplugWatcher { name in
            MKLog.app("output device lost (\(name)) — falling back to system default")
            MainActor.assumeIsolated {
                AppSettings.shared.outputDeviceName = "\(name) (missing)"
            }
            self.setOutputDevice(id: 0)
        }
    }

    /// Output device at launch (0 = system default).
    private func applyPersistedOutputDevice() {
        let id = MainActor.assumeIsolated { AppSettings.shared.outputDeviceID }
        guard id != 0 else { return }
        let wasPlaying = decks.map { ($0.isPlaying, $0.displayFileFrame()) }
        let ok = AudioOutputDevices.apply(to: engine, deviceID: AudioDeviceID(id))
        MKLog.app("output device restore id \(id) — \(ok ? "ok" : "FAILED")")
        resume(decks, from: wasPlaying)
        installHotplugWatcherOnce()
    }

    /// Live output switch: engine stops/starts around the device change;
    /// playing decks resume at their audible positions.
    func setOutputDevice(id: Int) {
        // Only persist a switch that SUCCEEDED — a failed apply used
        // to become the saved launch default.
        let wasPlaying = decks.map { ($0.isPlaying, $0.displayFileFrame()) }
        let ok = AudioOutputDevices.apply(to: engine,
                                          deviceID: id == 0 ? nil : AudioDeviceID(id))
        MKLog.app("output device switch id \(id) — \(ok ? "ok" : "FAILED")", error: !ok)
        if ok {
            MainActor.assumeIsolated {
                AppSettings.shared.outputDeviceID = id
                if id != 0, let dev = AudioOutputDevices.list().first(where: { Int($0.id) == id }) {
                    AppSettings.shared.outputDeviceName = dev.name
                } else {
                    AppSettings.shared.outputDeviceName = ""
                }
            }
        }
        resume(decks, from: wasPlaying)
        installHotplugWatcherOnce()
    }

    private func resume(_ decks: [DeckEngine], from states: [(Bool, AVAudioFramePosition)]) {
        for (deck, state) in zip(decks, states) where state.0 {
            deck.seek(toFrame: state.1, playAfter: true)
        }
    }

    var decks: [DeckEngine] { [deckA, deckB] }



    // MARK: - Mixer

    func setDeckVolume(_ index: Int, _ v: Double) {
        guard decks.indices.contains(index) else { return }
        deckVolume[index] = max(0, min(1, v))
        applyGains()
    }

    func setDeckTrim(_ index: Int, _ linear: Double) {
        guard decks.indices.contains(index) else { return }
        deckTrim[index] = max(0, min(4, linear))   // ±12 dB range
        applyGains()
    }

    /// VLC-style boost — master allows up to 2.0 (200%). The
    /// deck chain already carries a 1.2 gain stage; >1.5 is tinted amber in
    /// the UI as a clipping hint for hot summed decks.
    func setMaster(_ v: Double) {
        masterVolume = max(0, min(2, v))
        engine.mainMixerNode.outputVolume = Float(masterVolume)
    }

    /// Crossfade pair for the current curve, x ∈ [0,1].
    /// The crossfader is gone; the mix stage is a fixed
    /// equal-gain center (constant-power at 0.5 = both channels full).
    private func xfadeGains() -> (a: Double, b: Double) { (1.0, 1.0) }

    private func applyGains() {
        let (xa, xb) = xfadeGains()   // fixed center (fader removed)
        let gains: [Double] = [
            deckTrim[0] * deckVolume[0] * xa * 1.2,
            deckTrim[1] * deckVolume[1] * xb * 1.2,
        ]
        deckA.setOutputGain(gains[0])
        deckB.setOutputGain(gains[1])
    }
}
