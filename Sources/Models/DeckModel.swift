import Foundation
import Combine
import AVFoundation
import AppKit

enum AnalysisState: Equatable {
    case idle
    case running
    case ready
    case failed(String)
}

/// UI-facing state for one deck. Owns nothing audio-heavy; commands flow
/// DeckModel → DeckEngine, positions flow back by polling the engine.
@MainActor
final class DeckModel: ObservableObject {

    let index: Int
    let engine: DeckEngine

    // File
    @Published var fileURL: URL?
    @Published var title: String = ""
    /// The title is the bare filename (no metadata title in the file) —
    /// the UI renders it in the italic "no metadata" voice.
    @Published var titleIsFilename = false
    /// Tag artist; stays blank when the file carries no metadata.
    @Published var artist: String = ""
    @Published var duration: Double = 0
    @Published var rejectionNotice: String?

    // Transport echo (engine → UI)
    @Published var isPlaying = false

    // Tempo / pitch
    @Published var tempoRate: Double = 1.0
    @Published var pitchSemitones: Double = 0
    @Published var keylock = false
    @Published var snapEnabled = false

    // Grid / analysis
    @Published var analysisState: AnalysisState = .idle
    @Published var baseBPM: Double?
    @Published var gridAnchorSeconds: Double = 0
    @Published var gridConfidence: Double = 0
    @Published var noBeatFound = false
    @Published var multiTempo = false
    @Published var peaks: PeakPyramid?
    @Published var analyzedSeconds: Double = 0
    var analysisTask: Task<Void, Never>?
    /// Beat times (source seconds) from the last analysis — for tap-anchor
    /// snapping ("on the kicks").
    var analyzedBeatTimes: [Double] = []

    var hasGrid: Bool { baseBPM != nil }

    // Loop
    @Published var loopBeats: Int = 4

    // Mixer (committed values; live drags publish through `atoms` only)
    @Published var trimDb: Double = 0
    @Published var eqLowDb: Double = 0
    @Published var eqMidDb: Double = 0
    @Published var eqHighDb: Double = 0
    @Published var filterKnob: Double = 0
    @Published var volume: Double = 1.0   // default 100%

    /// Event-rate mirrors for control drags: mid-drag UI reads
    /// these atoms; the committed fields above are written on release.
    let atoms: (trim: ControlAtom, eqLow: ControlAtom, eqMid: ControlAtom,
                eqHigh: ControlAtom, filter: ControlAtom, volume: ControlAtom,
                tempo: ControlAtom, pitch: ControlAtom)

    /// Seek plumbing: invalidation tick. (There is no ghost-target field —
    /// overview drags seek live, so nothing is ever "pending".)
    @Published private(set) var positionTick = 0

    /// Analysis v2 provenance + sections + live in-stream estimate.
    @Published var sections: [GridEstimator.Section] = []
    @Published var analyzer: String = "v1"
    let liveDetector = LiveBeatDetector()
    /// Converging in-stream BPM (nil until enough beats have played).

    /// Display position. PULL mode polls the engine's render
    /// truth on every read (Mixxx VisualPlayPosition pattern) — the old
    /// extrapolation cache advanced at the legacy transport rate (it knows
    /// nothing of the pull chase/momentum) and snapped to truth every
    /// 200 ms, the "steppy" scratch display. Paused decks always polled
    /// truth directly, which is why paused felt flawless and playing never
    /// did. The cache remains for the legacy push path.
    var positionSeconds: Double {
        Double(engine.displayFileFrame()) / engine.sampleRate
    }

    /// All UI seeks funnel here: engine command + invalidation
    /// tick so paused lanes redraw at event rate instead of the 2 Hz idle.
    func seek(to seconds: Double) {
        engine.seek(toSeconds: seconds)
        positionTick &+= 1
    }

    private var lastLiveSeekTick: CFAbsoluteTime = 0

    /// Gesture-rate seek — direct pull-deck write (no queue
    /// backlog) + THROTTLED invalidation. The old path published the full
    /// model at up to 100 Hz mid-drag, which starved key dispatch.
    func seekLive(to seconds: Double) {
        guard hasTrack else { return }
        engine.seekLive(toSeconds: seconds)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastLiveSeekTick > 1.0 / 30.0 {
            lastLiveSeekTick = now
            positionTick &+= 1
        }
    }

    var hasTrack: Bool { fileURL != nil }

    /// Vinyl pitch factor — the engine's unlocked render multiplies rate
    /// by 2^(st/12) (keylock off); keylock on = pure transposition.
    var vinylPitchFactor: Double {
        keylock ? 1.0 : pow(2.0, pitchSemitones / 12.0)
    }

    /// True audible BPM: pitch drags move this number live on
    /// the vinyl path; keylock keeps it independent of pitch.
    var liveBPM: Double? {
        guard let b = baseBPM else { return nil }
        return b * tempoRate * vinylPitchFactor
    }

    /// BPM the ears hear: engine transport (fader × bend × sync phase
    /// trim) × vinyl pitch. The readout shows THIS — a sync trim or a
    /// held bend must never make the number disagree with the audio.
    var audibleBPM: Double? {
        guard let b = baseBPM else { return nil }
        return b * audibleRateNow
    }

    /// Live rate including bend/momentum (engine truth) × vinyl pitch —
    /// what the big readout shows while a tempo bend is held.
    var audibleRateNow: Double {
        engine.currentRate * vinylPitchFactor
    }

    /// Normalized EQ knob value (−1…+1) → dB. A feel curve, not
    /// a math curve — audible within the first 20% of travel both ways,
    /// Symmetric ±12 dB ceiling — quadratic cut (gentle near center,
    /// −12 dB at full throw), slightly fast boost (+12 dB at +1).
    nonisolated static func eqKnobToDb(_ v: Double) -> Double {
        v < 0 ? -12.0 * pow(-v, 2)
              : 12.0 * pow(v, 1.2)
    }

    init(index: Int) {
        self.index = index
        self.engine = AudioController.shared.decks[index]
        self.atoms = (trim: ControlAtom(0), eqLow: ControlAtom(0), eqMid: ControlAtom(0),
                      eqHigh: ControlAtom(0), filter: ControlAtom(0), volume: ControlAtom(1.0),
                      tempo: ControlAtom(1.0), pitch: ControlAtom(0))
        engine.snapEnabled = AppSettings.shared.snapEnabled
        engine.onTransportChanged = { [weak self] playing in
            DispatchQueue.main.async {
                self?.isPlaying = playing
                LaneClock.shared.syncNow()   // sync cadence now — no first-play stall
            }
        }
        engine.onLoopChanged = { [weak self] in
            DispatchQueue.main.async {
                self?.loopActive = (self?.engine.loopStart != nil)
            }
        }
        engine.onNotice = { [weak self] message in
            DispatchQueue.main.async {
                self?.showNotice(message)
            }
        }
        applyMixer()
    }

    // MARK: - Loading

    static let acceptedExtensions: Set<String> = ["mp3", "flac", "wav", "aiff", "aif", "m4a",
                                                  // FFmpeg-decoded
                                                  "ogg", "opus", "oga", "wma", "amr", "mkv"]

    /// EJECT unloads ONLY (no dialog — re-issue intent
    /// explicitly); LOAD (empty deck) opens the picker. `pickFile` stays
    /// injectable so probe gates drive it without a UI.
    var pickFile: () -> URL? = { AppFilePanel.pickTrack() }

    func ejectOrLoad() {
        if hasTrack {
            unloadTrack()
        } else if let url = pickFile() {
            loadFile(url)
        }
    }

    func unloadTrack() {
        analysisTask?.cancel()
        analysisTask = nil
        engine.pullDeck.chunkObserver = nil
        engine.unload()
        fileURL = nil
        title = ""
        titleIsFilename = true
        artist = ""
        liveDetector.reset()
        sections = []
        duration = 0
        isPlaying = false
        tempoRate = 1.0
        pitchSemitones = 0
        keylock = false
        loopBeats = 4
        manualLoopActive = false
        manualIn = 0
        manualOut = 0
        // analysis verdicts are track state — gone with the track.
        // Desk state (EQ/gain/filter/volume/tempo atoms) is RETAINED:
        // they're the desk, not the media.
        baseBPM = nil
        gridConfidence = 0
        noBeatFound = false
        multiTempo = false
        peaks = nil
        analyzedSeconds = 0
        analyzedBeatTimes = []
        analysisState = .idle
        MKLog.app("deck \(index + 1): eject")
    }

    /// The load picker shares the drop target's accepted extensions.
    enum AppFilePanel {
        static func pickTrack() -> URL? {
            let p = NSOpenPanel()
            p.canChooseFiles = true
            p.canChooseDirectories = false
            p.allowsMultipleSelection = false
            p.message = "Choose an audio file (mp3, flac, wav, aiff, m4a, ogg, opus…)"
            let ok = p.runModal() == .OK
            return ok ? p.url : nil
        }
    }

    func handleDroppedURL(_ url: URL?) {
        guard let url else { return }
        let ext = url.pathExtension.lowercased()
        guard Self.acceptedExtensions.contains(ext) else {
            showNotice("Rejected “\(url.lastPathComponent)” — unsupported format (want mp3, flac, wav, aiff or m4a)")
            return
        }
        loadFile(url)
    }

    func loadFile(_ url: URL) {
        do {
            try engine.load(url: url)
        } catch {
            MKLog.app("load failed for \(url.lastPathComponent) — \(error.localizedDescription)", error: true)
            showNotice("Couldn't open “\(url.lastPathComponent)” — \(error.localizedDescription)")
            return
        }
        // Full deck state reset on every load
        analysisTask?.cancel()
        analysisTask = nil
        fileURL = url
        title = url.deletingPathExtension().lastPathComponent
        titleIsFilename = true
        artist = ""
        // Tags first, filename only as the fallback: refine the display
        // from the container's common metadata (ID3 TIT2/TPE1, Vorbis
        // TITLE/ARTIST, MP4 ©nam/©art) once it lands. An untagged file
        // keeps the filename as title and shows no artist. The fileURL
        // guard rejects a refine that outlives a newer load/eject.
        Task { [weak self] in
            let (metaTitle, metaArtist) = await Self.readDisplayMetadata(url)
            guard let self, self.fileURL == url else { return }
            if let metaTitle {
                self.title = metaTitle
                self.titleIsFilename = false
            }
            self.artist = metaArtist ?? ""
        }
        // in-stream beat tap — fresh per track
        liveDetector.reset()
        sections = []
        engine.pullDeck.chunkObserver = { [weak liveDetector] ptr, count, sr in
            liveDetector?.feed(samples: ptr, count: count, sampleRate: sr)
        }
        duration = engine.durationSeconds
        isPlaying = false
        tempoRate = 1.0
        pitchSemitones = 0
        keylock = false                      // default off
        snapEnabled = AppSettings.shared.snapEnabled
        engine.snapEnabled = snapEnabled
        loopBeats = 4
        manualLoopActive = false       // manual span is session-only
        manualIn = 0
        manualOut = 0
        trimDb = 0
        eqLowDb = 0
        eqMidDb = 0
        eqHighDb = 0
        filterKnob = 0
        volume = 1.0
        atoms.trim.v = 0; atoms.eqLow.v = 0; atoms.eqMid.v = 0
        atoms.eqHigh.v = 0; atoms.filter.v = 0; atoms.volume.v = 1.0   // 100%, matching `volume`
        atoms.tempo.v = 1.0; atoms.pitch.v = 0
        applyMixer()
        baseBPM = nil
        gridConfidence = 0
        noBeatFound = false
        multiTempo = false
        peaks = nil
        analyzedSeconds = 0
        analyzedBeatTimes = []
        analysisState = .idle
        AnalysisService.shared.analyze(deck: self, url: url)
    }

    func showNotice(_ text: String) {
        rejectionNotice = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.rejectionNotice == text { self?.rejectionNotice = nil }
        }
    }

    // MARK: - Display metadata

    /// Common-metadata title/artist for the deck header. Whitespace-only
    /// values count as absent, so a stripped tag falls back cleanly.
    static func readDisplayMetadata(_ url: URL) async -> (title: String?, artist: String?) {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.metadata)) ?? []
        func value(_ id: AVMetadataIdentifier) async -> String? {
            guard let s = try? await AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id)
                .first?.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !s.isEmpty else { return nil }
            return s
        }
        return (await value(.commonIdentifierTitle), await value(.commonIdentifierArtist))
    }

    // MARK: - Transport

    func togglePlayPause() { engine.togglePlayPause() }

    /// Sync is TEMPO-ONLY by design: play and cue entries stay exact —
    /// no phase nudges anywhere.
    func cueDown() { engine.cueDown() }
    func cueUp() { engine.cueUp() }
    func setCue() { engine.setCueAtCurrent() }

    /// Snap is a global setting: the toggle flips it for both
    /// decks; this deck's mirror updates for display.

    /// Live-BPM display drives off this while a bend is held.
    @Published private(set) var nudgeActiveUI = false

    /// Signed bend — hold arrows and keyboard hold-keys both land
    /// here (sign −1/0/+1; 0 on release so the last release clears cleanly).
    func nudge(active: Bool, sign: Int = 1) {
        let fraction = AppSettings.shared.nudgePercent / 100.0
        engine.setNudgeAmount(active ? Double(sign) * fraction : 0)
        engine.setNudge(active: active)
        nudgeActiveUI = active
    }

    func beatJump(_ beats: Int) { engine.beatJump(beats) }

    // MARK: - Loops

    @Published private(set) var loopActive: Bool = false

    // Manual loop mode — M button + draggable IN/OUT points.
    // Points are TIME-domain model state: zoom changes the mapping,
    // never the values (zooming can't lose a point). Session-only,
    // cleared on load like cues.
    @Published var manualLoopActive = false
    @Published var manualIn: Double = 0
    @Published var manualOut: Double = 0

    private var minLoopSeconds: Double { Double(DeckEngine.minLoopFrames) / max(engine.sampleRate, 1) }

    /// M button: engage the manual loop at the current position (IN here,
    /// OUT one armed window ahead), or exit M mode when already on.
    func toggleManualLoop() {
        if manualLoopActive {
            engine.exitLoop()
            manualLoopActive = false
            return
        }
        if loopActive { engine.exitLoop() }
        let sr = engine.sampleRate
        let pos = Double(engine.displayFileFrame()) / sr
        let len = engine.beatFrames > 0 ? Double(loopBeats) * engine.beatFrames / sr : 2.0
        manualIn = max(0, min(pos, duration))
        manualOut = min(duration, manualIn + max(len, minLoopSeconds))
        engine.setLoopSpan(start: AVAudioFramePosition(manualIn * sr),
                           end: AVAudioFramePosition(manualOut * sr))
        manualLoopActive = true
    }

    /// Handle drags — absolute time in, clamped against the other point
    /// and the track; optional grid snap (global setting, default off).
    func dragManualIn(_ t: Double) {
        guard manualLoopActive else { return }
        let c = AppSettings.shared.snapEnabled ? engine.snappedGridTime(t) : t
        manualIn = max(0, min(c, manualOut - minLoopSeconds))
        applyManualSpan()
    }

    func dragManualOut(_ t: Double) {
        guard manualLoopActive else { return }
        let c = AppSettings.shared.snapEnabled ? engine.snappedGridTime(t) : t
        manualOut = min(duration, max(c, manualIn + minLoopSeconds))
        applyManualSpan()
    }

    /// Translate the whole window — span preserved exactly,
    /// clamped to [0, duration] (the handles' world). Snap follows the same
    /// global rule as the handles (applied to the incoming IN).
    func dragManualSpan(_ newIn: Double) {
        guard manualLoopActive else { return }
        let span = manualOut - manualIn
        let c = AppSettings.shared.snapEnabled ? engine.snappedGridTime(newIn) : newIn
        manualIn = max(0, min(c, max(0, duration - span)))
        manualOut = manualIn + span
        applyManualSpan()
    }

    private func applyManualSpan() {
        let sr = engine.sampleRate
        engine.setLoopSpanLive(start: AVAudioFramePosition(manualIn * sr),
                               end: AVAudioFramePosition(manualOut * sr))
    }

    /// Gesture-end commit — the queued path owns lastLoop,
    /// logs, and the jump-in rule.
    func commitManualSpan() {
        let sr = engine.sampleRate
        engine.setLoopSpan(start: AVAudioFramePosition(manualIn * sr),
                           end: AVAudioFramePosition(manualOut * sr))
    }

    func loopSetExit() { engine.setLoop(beats: loopBeats) }
    func reloop() { engine.reloop() }

    /// Beats-button path — live-resizes the ACTIVE loop (anchor
    /// kept); when no loop is active it just arms the length. A
    /// number press hands a manual loop back to the grid (anchored at its
    /// IN) and leaves M mode.
    func selectLoopBeats(_ b: Int) {
        manualLoopActive = false
        loopBeats = max(1, min(32, b))
        if loopActive { engine.setLoopLength(beats: loopBeats) }
    }

    /// ×2/÷2 resize the engine loop AND the selection.
    /// In manual mode the model stays the span's source of truth.
    func loopScale(_ factor: Double) {
        if manualLoopActive {
            manualOut = min(duration, max(manualIn + minLoopSeconds, manualIn + (manualOut - manualIn) * factor))
            applyManualSpan()
            return
        }
        engine.scaleLoop(factor)
        let scaled = Double(loopBeats) * factor
        loopBeats = max(1, min(32, Int(scaled.rounded())))
    }

    // MARK: - Tempo / pitch

    /// All tempo changes converge here (fader, scroll, entry, nudge, match BPM).
    func setTempoRate(_ r: Double) {
        tempoRate = max(1.0 / 32.0, min(2.0, r))
        atoms.tempo.v = tempoRate
        engine.setFaderRate(tempoRate)
        applyPitch()
        // A user's own tempo commit takes over from continuous sync
        // (the sync's own writes are flagged and don't disengage it).
        MainActor.assumeIsolated { AppModelHolder.shared?.userTouchedTempo(index) }
    }

    /// Recompute with MKDJ's OWN analyzer, bypassing the cache —
    /// the displayed number is always visibly MKDJ-computed, never
    /// inherited from file metadata (which MKDJ never reads anyway).
    func reanalyzeBPM() {
        guard let url = fileURL else { return }
        AnalysisService.shared.analyze(deck: self, url: url, force: true)
    }

    func setPitch(_ semitones: Double) {
        pitchSemitones = max(-24, min(24, semitones))
        atoms.pitch.v = pitchSemitones
        applyPitch()
    }

    func toggleKeylock() {
        keylock.toggle()
        applyPitch()
    }

    /// Keylock on: rate → tempo only. Keylock off (Join, vinyl): rate also
    /// transposes by the musical amount.
    func applyPitch() {
        engine.setPitch(semitones: pitchSemitones, keylock: keylock)
    }

    // MARK: - Live appliers (single data path: model + atom + engine move
    // together — a drag updates the thumb, the readout, and the audio in
    // the same step; engine-only writes snap thumbs home and freeze
    // readouts).

    func tempoLive(_ rate: Double) {
        tempoRate = max(1.0 / 32.0, min(2.0, rate))
        atoms.tempo.v = tempoRate
        engine.setFaderRate(tempoRate)
        applyPitch()   // vinyl join follows the live rate inside PullDeck
        // A user drag is a user tempo action: takes over from continuous
        // sync (the sync's own writes go through setTempoRate under the
        // syncWritingTempo flag and never land here).
        MainActor.assumeIsolated { AppModelHolder.shared?.userTouchedTempo(index) }
    }

    func pitchLive(_ semitones: Double) {
        pitchSemitones = max(-24, min(24, semitones))
        atoms.pitch.v = pitchSemitones
        applyPitch()
    }

    /// The trim slider is a KNOB (−1…+1), not dB — feeding it
    /// straight into pow(10, db/20) was ±1 dB at the extremes (inaudible).
    /// The model/atom keep the knob; the engine gets the same feel curve
    /// the readout shows (±12 dB at the extremes).
    func trimLive(_ knob: Double) {
        trimDb = knob
        atoms.trim.v = knob
        AudioController.shared.setDeckTrim(index, pow(10, Self.eqKnobToDb(knob) / 20))
    }

    /// Deck volume — the mix control. ONE path: model, atom, and engine
    /// move together, so the fader, the readout, and the audio can never
    /// disagree (engine-only writes made the fader snap back while the
    /// readout showed a stale model value).
    func volumeLive(_ v: Double) {
        let v = max(0, min(1, v))
        volume = v
        atoms.volume.v = v
        AudioController.shared.setDeckVolume(index, v)
    }
    func eqLowLive(_ v: Double) { eqLowDb = v; atoms.eqLow.v = v; applyEQ(low: v, mid: eqMidDb, high: eqHighDb) }
    func eqMidLive(_ v: Double) { eqMidDb = v; atoms.eqMid.v = v; applyEQ(low: eqLowDb, mid: v, high: eqHighDb) }
    func eqHighLive(_ v: Double) { eqHighDb = v; atoms.eqHigh.v = v; applyEQ(low: eqLowDb, mid: eqMidDb, high: v) }

    /// One path for all three EQ live drags (was three copies).
    private func applyEQ(low: Double, mid: Double, high: Double) {
        engine.setEQ(lowDb: Self.eqKnobToDb(low),
                     midDb: Self.eqKnobToDb(mid),
                     highDb: Self.eqKnobToDb(high))
    }
    func filterLive(_ v: Double) {
        filterKnob = v
        atoms.filter.v = v
        engine.setFilterKnob(v)
    }

    // MARK: - BPM / grid

    func applyGrid(bpm: Double, anchorSeconds: Double) {
        baseBPM = bpm
        gridAnchorSeconds = anchorSeconds
        engine.setGrid(bpm: bpm, anchorFrame: AVAudioFramePosition(anchorSeconds * engine.sampleRate))
    }

    func bpmMultiply(_ factor: Double) {
        guard let b = baseBPM else { return }
        let new = b * factor
        guard new >= 30, new <= 300 else { return }
        baseBPM = new
        engine.setGrid(bpm: new, anchorFrame: AVAudioFramePosition(gridAnchorSeconds * engine.sampleRate))
    }

    func setBaseBPM(_ bpm: Double) {
        guard bpm >= 30, bpm <= 300 else { return }
        baseBPM = bpm
        engine.setGrid(bpm: bpm, anchorFrame: AVAudioFramePosition(gridAnchorSeconds * engine.sampleRate))
    }

    // Tap tempo: taps carry BOTH tempo and phase — a
    // least-squares fit over (beat index, source position) gives the period
    // AND the anchor. Tapping the kick defines beat 1; the
    // grid renders 4-beat downbeats from it.

    private struct TapPoint {
        let t: CFTimeInterval      // wall time (3 s reset window)
        let position: Double       // SOURCE seconds at tap time
    }
    @Published private(set) var tapCount = 0
    private var taps: [TapPoint] = []

    func tapBPM() {
        tapBPM(now: CACurrentMediaTime(), position: positionSeconds)
    }

    /// Injectable core (the gate feeds synthetic taps at known
    /// wall-times and source positions — the wall clock can't be faked).
    func tapBPM(now: Double, position: Double) {
        if let last = taps.last, now - last.t > 3.0 { taps.removeAll() }
        taps.append(TapPoint(t: now, position: position))
        taps = Array(taps.suffix(9))
        tapCount = taps.count
        guard taps.count >= 2 else { return }

        // initial period: median wall interval
        let intervals = zip(taps, taps.dropFirst()).map { $1.t - $0.t }
        let sortedI = intervals.sorted()
        var period = sortedI[sortedI.count / 2]
        guard period > 0.15, period < 3.0 else { return }

        // iterate: assign beat indices by rounding, least-squares refit of
        // position(k) = anchor + periodSrc·k over SOURCE positions (slope in
        // source-seconds per beat — tempo-rate adjusted by construction).
        var anchor = taps[0].position
        for _ in 0..<4 {
            let ks: [Double] = taps.map { (($0.position - anchor) / period).rounded() }
            guard ks.count >= 2 else { break }
            let n = Double(ks.count)
            let sk = ks.reduce(0, +)
            let sp = taps.map(\.position).reduce(0, +)
            let skp = zip(ks, taps).reduce(0.0) { $0 + $1.0 * $1.1.position }
            let skk = ks.reduce(0.0) { $0 + $1 * $1 }
            let den = n * skk - sk * sk
            guard abs(den) > 1e-9 else { break }
            let slope = (n * skp - sk * sp) / den
            let intercept = (sp - slope * sk) / n
            guard slope > 0.15, slope < 3.0 else { break }
            period = slope
            anchor = intercept
        }

        // A user-authored grid stands on its own — the old ±100 ms
        // snap toward analyzed beats dragged a correct tap fit back toward
        // the (possibly wrong) analysis phase, which is usually WHY the
        // user is tapping. The fit's phase is the tapped truth.
        let anchorSeconds = anchor

        let base = 60.0 / period       // slope is source-seconds per beat
        guard base >= 30, base <= 300 else { return }
        baseBPM = base
        gridAnchorSeconds = anchorSeconds
        gridConfidence = 1.0   // user-authored grid
        engine.setGrid(bpm: base, anchorFrame: AVAudioFramePosition(anchorSeconds * engine.sampleRate))
    }

    // MARK: - Mixer

    func applyMixer() {
        AudioController.shared.setDeckTrim(index, pow(10, trimDb / 20))
        AudioController.shared.setDeckVolume(index, volume)
        engine.setEQ(lowDb: Self.eqKnobToDb(eqLowDb),
                     midDb: Self.eqKnobToDb(eqMidDb),
                     highDb: Self.eqKnobToDb(eqHighDb))
        engine.setFilterKnob(filterKnob)
    }
}
