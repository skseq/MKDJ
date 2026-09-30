import AVFoundation

/// One deck's audio chain: pull source node → pre-EQ → EQ(5) → deck mixer.
/// All transport is PULL: control writes PullDeck state; a render callback pulls decoded
/// PCM from the ring. No scheduler, no ledger, no player nodes.
final class DeckEngine {

    let preEQMixer = AVAudioMixerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 5)
    let deckMixer = AVAudioMixerNode()

    let index: Int
    private let queue = DispatchQueue(label: "mkdj.deck.engine")

    private weak var hostEngine: AVAudioEngine?

    // ── File state
    private var file: AVAudioFile?
    private(set) var fileFrameCount: AVAudioFramePosition = 0
    private(set) var sampleRate: Double = 44100

    // ── Position / transport state
    private var pausedFile: AVAudioFramePosition = 0   // cue/pause anchor (cue return)
    private(set) var isPlaying = false       // written on queue only; UI reads are advisory
    private var previewing = false           // CUE is held
    /// CDJ cue→play latch — PLAY pressed while CUE is held
    /// latches playback; releasing CUE then KEEPS playing instead of
    /// returning to the cue (the standard CDJ way to start a track).
    private var cuePlayLatched = false

    // ── Rate / pitch
    private var faderRate: Double = 1.0
    private var nudgeActive = false
    private var nudgeAmount: Double = 0.04
    /// Phase trim — a small multiplicative rate offset. DORMANT since
    /// sync went tempo-only (nothing writes it but the probe); kept as a
    /// tested engine capability. Independent of the bend (nudge) and the
    /// fader; reset on disengage/load.
    private var phaseTrim: Double = 0
    private(set) var currentRate: Double = 1.0

    let pullDeck = PullDeck()
    private var pullSource: AVAudioSourceNode?
    private var throwTimer: DispatchSourceTimer?
    private var pullPollTimer: DispatchSourceTimer?

    // ── Loop
    private(set) var loopStart: AVAudioFramePosition?
    private(set) var loopEnd: AVAudioFramePosition?
    private var lastLoop: (start: AVAudioFramePosition, end: AVAudioFramePosition)?

    // ── Cue + grid
    private(set) var cueFrame: AVAudioFramePosition?
    var snapEnabled = true
    private(set) var beatFrames: Double = 0      // 0 = no grid
    private(set) var gridAnchor: AVAudioFramePosition = 0

    // Engine → UI (called on queue; observer hops to main)
    var onTransportChanged: ((Bool) -> Void)?
    var onEOF: (() -> Void)?
    /// Loop state changed (set/exit/reloop/scale) — drives the LOOP/EXIT
    /// button label without an 8 Hz poll.
    var onLoopChanged: (() -> Void)?

    // MARK: - Graph

    init(index: Int) {
        self.index = index
        configureEQ()
    }

    /// Attach + wire the deck chain into `engine` with a default format;
    /// re-wired to the file's processing format on load.
    func attach(to engine: AVAudioEngine, destination: AVAudioNode) {
        hostEngine = engine
        let src = AVAudioSourceNode { [weak self] _, _, frameCount, abl in
            guard let self else { return noErr }
            self.pullDeck.render(into: UnsafeMutableAudioBufferListPointer(abl),
                                 frames: frameCount)
            return noErr
        }
        pullSource = src
        engine.attach(src)
        engine.attach(preEQMixer)
        engine.attach(eq)
        engine.attach(deckMixer)
        reconnectChain(format: nil, destination: destination)
    }

    private func reconnectChain(format: AVAudioFormat?, destination: AVAudioNode) {
        guard let engine = hostEngine else { return }
        // disconnectNodeOutput does NOT remove taps on this
        // AVAudioEngine — installing over a live tap raises
        // "nullptr == Tap()" and the ObjC exception silently kills the
        // enclosing Swift Task. Remove the tap ourselves BEFORE the
        // disconnects so the reinstall at the tail is always on a clean bus.
        if levelTapInstalled {
            deckMixer.removeTap(onBus: 0)
            levelTapInstalled = false
        }
        if let ps = pullSource { engine.disconnectNodeOutput(ps) }
        engine.disconnectNodeOutput(preEQMixer)
        engine.disconnectNodeOutput(eq)
        engine.disconnectNodeOutput(deckMixer)
        if let ps = pullSource {
            engine.connect(ps, to: preEQMixer, format: format)
        }
        engine.connect(preEQMixer, to: eq, format: format)
        engine.connect(eq, to: deckMixer, format: format)
        engine.connect(deckMixer, to: destination, format: format)
        installLevelTap()
    }

    /// Post-fader level tap on deckMixer, held here because its
    /// lifetime IS the chain's — reinstalled at the tail of every rewire
    /// (attach + each loadFile) in the CURRENT bus format.
    private var levelTapInstalled = false
    private(set) var levelFeed: LevelFeed?

    func setLevelFeed(_ feed: LevelFeed) {
        levelFeed = feed
        if levelTapInstalled {
            deckMixer.removeTap(onBus: 0)
            levelTapInstalled = false
        }
        installLevelTap()
    }

    private func installLevelTap() {
        guard levelFeed != nil, hostEngine != nil, !levelTapInstalled else { return }
        let feed = levelFeed!
        let deckIdx = index
        var lastLog = CFAbsoluteTime(0)
        deckMixer.installTap(onBus: 0, bufferSize: 2048,
                             format: deckMixer.outputFormat(forBus: 0)) { buf, _ in
            feed.store(buffer: buf)
            // Liveness: 1 line per deck per 30 s, only while signal
            // flows — proof the meters' source is alive.
            if feed.rms > 1e-4 {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastLog > 30.0 {
                    lastLog = now
                    MKLog.engine(String(format: "level tap deck %d rms=%.4f peak=%.4f", deckIdx, feed.rms, feed.peak))
                }
            }
        }
        levelTapInstalled = true
        MKLog.engine(String(format: "level tap installed deck %d feed=%p sr=%.0f", index, unsafeBitCast(feed, to: Int.self), deckMixer.outputFormat(forBus: 0).sampleRate))
    }



    private func configureEQ() {
        Self.applyEQBandLayout(eq)
    }

    /// The deployed EQ/filter band layout — the SINGLE source of truth,
    /// consumed by both the engine and `mkdjprobe --eqdiag` (a test-side
    /// replica would drift from reality).
    /// NOTE: AVAudioUnitEQ bands ship BYPASSED by default — bands 0–2 MUST
    /// be unbypassed or their gains do nothing (the app's EQ was silent
    /// until this line existed; the filter only worked because its
    /// engagement path un-bypassed bands 3/4 explicitly).
    static func applyEQBandLayout(_ eq: AVAudioUnitEQ) {
        let b = eq.bands
        b[0].filterType = .lowShelf;      b[0].frequency = 200;  b[0].gain = 0;  b[0].bypass = false
        b[1].filterType = .parametric;    b[1].frequency = 1000; b[1].bandwidth = 1.0; b[1].gain = 0; b[1].bypass = false
        b[2].filterType = .highShelf;     b[2].frequency = 4000; b[2].gain = 0;  b[2].bypass = false
        b[3].filterType = .resonantLowPass;  b[3].frequency = 20000; b[3].bandwidth = 0.5; b[3].bypass = true
        b[4].filterType = .resonantHighPass; b[4].frequency = 20;    b[4].bandwidth = 0.5; b[4].bypass = true
    }

    // MARK: - Loading

    /// Opens the file on the caller's thread (header read, fast), then swaps
    /// deck state on the queue. Any previous track stops immediately.
    func load(url: URL) throws {
        // Exactly ONE PullDeck load per track, performed on the
        // engine queue with DeckEngine's already-open AVAudioFile handed in.
        // PullDeck's loader chain: AVAudioFile → AVAssetReader → FFmpeg.
        // Failure paths below LOG — loads used to vanish silently.
        let f = try? AVAudioFile(forReading: url)
        if f == nil, !pullDeck.ffProbe(url: url) {
            throw NSError(domain: "MKDJ", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "unreadable file"])
        }
        if f == nil {
            MKLog.app("load: AVAudioFile nil but ffProbe true — silent-skip path taken", error: true)
        }
        if let f {
            let frames = f.length
            let sr = f.processingFormat.sampleRate
            // Publish duration fields right away so UI reads after load() are fresh.
            fileFrameCount = frames
            sampleRate = sr
            // Re-wire the chain in the file's format so the player timeline counts
            // file frames (position math stays exact under any hardware rate).
            if let engine = hostEngine {
                reconnectChain(format: f.processingFormat, destination: engine.mainMixerNode)
            }
            queue.async {
                self.flushLocked(seekToPaused: false)
                self.phaseTrim = 0
                self.file = f
                self.fileFrameCount = frames
                self.sampleRate = sr
                let ok = self.pullDeck.load(url: url, preferredFile: f)
                if !ok {
                    MKLog.app("load: pullDeck.load FAILED for \(url.lastPathComponent)", error: true)
                }
                self.trackUnavailable = false
                self.readerStallSince = nil
                self.startPullPolling()
                self.pausedFile = 0
                self.cueFrame = nil
                self.previewing = false
                self.pullDeck.setLoopSuspend(false)   // preview-suspension mirror
                self.loopStart = nil
                self.loopEnd = nil
                self.lastLoop = nil
                self.faderRate = 1.0
                self.nudgeActive = false
                self.beatFrames = 0
                self.gridAnchor = 0
                self.applyTransportRateLocked()
                self.resetEQLocked()
                self.setOutputGain(1)
            }
        } else {
            // FFmpeg-only format (ogg/opus/wma/amr): PullDeck's loader is the
            // sole decoder; there is no AVAudioFile to publish from here.
            queue.async {
                self.flushLocked(seekToPaused: false)
                self.pullDeck.load(url: url, preferredFile: nil)
                self.startPullPolling()
                self.pausedFile = 0
                self.cueFrame = nil
                self.previewing = false
                self.pullDeck.setLoopSuspend(false)   // preview-suspension mirror
                self.loopStart = nil
                self.loopEnd = nil
                self.lastLoop = nil
                self.faderRate = 1.0
                self.nudgeActive = false
                self.beatFrames = 0
                self.gridAnchor = 0
                self.applyTransportRateLocked()
                self.resetEQLocked()
                self.setOutputGain(1)
            }
        }
    }

    func unload() {
        pause()   // eject stops playback first (onTransportChanged fires)
        queue.async {
            self.flushLocked(seekToPaused: false)
            self.pullDeck.unload()
            self.file = nil
            self.fileFrameCount = 0
            self.pausedFile = 0
            self.cueFrame = nil
            self.loopStart = nil
            self.loopEnd = nil
            self.lastLoop = nil
            self.beatFrames = 0
            self.gridAnchor = 0
            self.previewing = false
            self.trackUnavailable = false
            self.readerStallSince = nil
        }
    }

    // MARK: - Position


    var durationSeconds: Double { Double(fileFrameCount) / max(1, sampleRate) }

    func displayFileFrame() -> AVAudioFramePosition {
        // readFrame/displayFrame IS the rest point —
        // display/cue always read the deck's true position.
        // (This value is span-FOLDED for the eyes; persisted
        // positions use currentFileFrameLocked — the raw truth.)
        return AVAudioFramePosition(pullDeck.displayFrame)
    }

    private func currentFileFrameLocked() -> AVAudioFramePosition {
        // RAW render position — pausedFile/cue anchoring must
        // never see the display fold (a folded rest point can misplace
        // the deck by up to one loop span).
        AVAudioFramePosition(pullDeck.stateSnapshot.readFrame)
    }

    // MARK: - Transport

    func play() { queue.async { self.playLocked() } }

    private func playLocked() {
        guard file != nil, !isPlaying else { return }
        cuePlayLatched = false
            // The deck's rest point IS readFrame — PLAY resumes from
        // wherever the deck actually sits (after a paused drag, a
        // throw-to-stop, a pause). Explicit cue starts still seek (cueDown).
        if pullDeck.stateSnapshot.readFrame >= Double(fileFrameCount) {
            pullDeck.seek(toFrame: 0)   // replay from the top at EOF
        }
        pullDeck.setMomentum(1, toZero: false)
        pullDeck.setPlaying(true)
        isPlaying = true
        startPullPolling()
        let cb = onTransportChanged
        queue.async { cb?(true) }
    }

    func pause() { queue.async { self.pauseLocked() } }

    private func pauseLocked() {
        guard isPlaying else { return }
        previewing = false
        pullDeck.setLoopSuspend(false)   // preview-suspension mirror
        cuePlayLatched = false
        pausedFile = currentFileFrameLocked()
        pullDeck.setPlaying(false)
        isPlaying = false
        let cb = onTransportChanged
        queue.async { cb?(false) }
    }

    func togglePlayPause() {
        queue.async {
            // PLAY while holding CUE latches playback (CDJ combo:
            // cue-cue-cue, hold cue, press play, release cue → playing).
            // Without this the toggle saw isPlaying=true during the preview
            // and PAUSED — cue could never transition into play.
            if self.previewing {
                self.cuePlayLatched = true
                return
            }
            self.isPlaying ? self.pauseLocked() : self.playLocked()
        }
    }

    /// Seek to a file frame. Keeps playing if the deck is playing (unless
    /// `playAfter` forces otherwise); a paused seek just moves the rest point.
    func seek(toFrame target: AVAudioFramePosition, playAfter: Bool? = nil) {
        queue.async {
            guard self.file != nil else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            defer {
                // Silent in the normal path — a per-seek log line at
                // gesture rate (overview live-seek) was 60+ lines/s of file
                // I/O. Only slow dispatches are worth a trail.
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                if ms > 2.0 {
                    MKLog.engine(String(format: "seek SLOW dispatch %.1f ms (%@)",
                                          ms, self.isPlaying ? "playing" : "paused"))
                }
            }
            let f = max(0, min(target, self.fileFrameCount))
            self.pullDeck.seek(toFrame: f)
            if playAfter == true, !self.isPlaying {
                self.pullDeck.setPlaying(true)
                self.isPlaying = true
                let cb = self.onTransportChanged
                self.queue.async { cb?(true) }
            } else if playAfter == false, self.isPlaying {
                self.pullDeck.setPlaying(false)
                self.isPlaying = false
            }
            if !self.pullDeck.isScrubbing { self.pausedFile = f }
        }
    }

    func seek(toSeconds t: Double, playAfter: Bool? = nil) {
        seek(toFrame: AVAudioFramePosition(t * sampleRate), playAfter: playAfter)
    }

    /// Gesture-rate seeks — the position write goes STRAIGHT to
    /// the pull deck (its control API is any-thread, µs under the lock).
    /// The serial queue at drag rate landed seeks as stale backlog — audio
    /// chased the finger's history. Drag-END commits use the queued
    /// seek() (pausedFile bookkeeping belongs on the queue).
    func seekLive(toSeconds t: Double) {
        pullDeck.seek(toFrame: AVAudioFramePosition(t * sampleRate))
    }

private func startLocked(at frame: AVAudioFramePosition) {
        // Pull start: seek + roll (used by cue preview — an explicit start
        // position, unlike playLocked which resumes from the rest point).
        stopThrowTimerLocked()
        pullDeck.scrubCancel()
        pullDeck.seek(toFrame: frame)
        pullDeck.setMomentum(1, toZero: false)
        pullDeck.setPlaying(true)
        isPlaying = true
        previewing = false
        pullDeck.setLoopSuspend(false)   // preview-suspension mirror (redundant safety)
        startPullPolling()
        let cb = onTransportChanged
        queue.async { cb?(true) }
    }

    /// Stop transport and (pull mode) drop the deck to `pausedFile`.
    /// The pull branch SEEKS to the paused/cue point — the
    /// old flow paused in place, so CUE-while-playing never returned to the
    /// cue. `seekToPaused: false` is for load/unload, where pausedFile
    /// belongs to a track that's being replaced.
    private func flushLocked(seekToPaused: Bool = true) {
        /// Stop transport and drop the deck to `pausedFile`. The
        /// seek is what makes CUE-while-playing RETURN to the cue.
        /// `seekToPaused: false` is for load/unload, where pausedFile
        /// belongs to a track being replaced.
        let wasPlaying = isPlaying
        stopThrowTimerLocked()
        pullDeck.scrubCancel()
        pullDeck.setPlaying(false)
        cuePlayLatched = false
        if seekToPaused {
            pullDeck.seek(toFrame: pausedFile)
        }
        isPlaying = false
        previewing = false
        pullDeck.setLoopSuspend(false)   // preview over = loop armed
        if wasPlaying {
            let cb = onTransportChanged
            queue.async { cb?(false) }
        }
    }

    func setFaderRate(_ r: Double) {
        queue.async {
            self.faderRate = max(1.0 / 32.0, min(8.0, r))
            self.applyTransportRateLocked()
        }
    }

    func setNudgeAmount(_ fraction: Double) {
        queue.async {
            self.nudgeAmount = max(-0.5, min(0.5, fraction))
            if self.nudgeActive { self.applyTransportRateLocked() }
        }
    }

    func setNudge(active: Bool) {
        queue.async {
            guard self.nudgeActive != active else { return }
            self.nudgeActive = active
            self.applyTransportRateLocked()
        }
    }

    /// Fader-only transport (NO bend) — sync follows tempo, not the bend
    /// (by design: pitch bending stays independent of sync).
    var faderOnlyRate: Double {
        queue.sync { faderRate }
    }

    /// The transport rate the deck should run at right now (fader × nudge ×
    /// jog). Rate is a live parameter — position math never re-anchors.
    private func applyTransportRateLocked() {
        // Transport rate = fader × bend × sync-phase-trim. Scrub/throw
        // momentum is owned by PullDeck; pitch/vinyl-join likewise.
        let transport = faderRate
            * (nudgeActive ? (1.0 + nudgeAmount) : 1.0)
            * (1.0 + phaseTrim)
        currentRate = transport
        pullDeck.setBaseRate(transport)
    }

    /// Sync's bar-phase trim (fraction, clamped ±12%); 0 = none.
    func setPhaseTrim(_ fraction: Double) {
        queue.async {
            let f = max(-0.12, min(0.12, fraction))
            guard abs(f - self.phaseTrim) > 1e-6 else { return }
            self.phaseTrim = f
            self.applyTransportRateLocked()
        }
    }

    /// Current sync trim (queue-safe readback; gates + diagnostics).
    var syncTrimFraction: Double {
        queue.sync { phaseTrim }
    }

    // MARK: - Pitch (key)

    func setPitch(semitones: Double, keylock: Bool) {
        queue.async {
            self.pullDeck.setPitch(semitones: semitones, keylock: keylock)
        }
    }


    // MARK: - Cue (CDJ spec)

    /// CUE pressed (mouse or key down).
    func cueDown() {
        queue.async {
            guard self.file != nil else { return }
            // PRESS mode — hit = jump to the cue and PLAY
            // continuously; repeated hits retrigger. No hold, no snapback,
            // no preview suspension. (cueUp's `previewing` guard makes it
            // a no-op here.) Defaults read directly — AppSettings is
            // @MainActor and the queue is not.
            let mode = UserDefaults.standard.string(forKey: "cueMode") ?? "hold"
            if mode == "press" {
                self.previewing = false
                self.pullDeck.setLoopSuspend(false)
                if self.cueFrame == nil {
                    self.cueFrame = self.snapLocked(self.currentFileFrameLocked())
                }
                self.startLocked(at: self.cueFrame!)
                return
            }
            if self.isPlaying {
                // tap while playing (or previewing): return to cue and pause
                self.pausedFile = self.cueFrame ?? 0
                self.flushLocked()
            } else {
                if self.cueFrame == nil {
                    // Anchor the first cue where the deck
                    // actually sits (post-drag readFrame), not the stale
                    // push-era pausedFile — that snapped the cue (and the
                    // preview) back to 0:00 after any paused drag.
                    self.cueFrame = self.snapLocked(self.currentFileFrameLocked())
                }
                self.startLocked(at: self.cueFrame!)
                self.previewing = true   // startLocked clears it; restore after
                self.pullDeck.setLoopSuspend(true)   // preview suspends the wrap
                self.previewStartHost = CFAbsoluteTimeGetCurrent()
            }
        }
    }

    /// CUE released. With the cue→play latch armed (PLAY was
    /// pressed while CUE was held), release KEEPS the deck playing from the
    /// preview position — the CDJ "exit cue into play".
    func cueUp() {
        queue.async {
            guard self.previewing else { return }
            self.previewing = false
            self.pullDeck.setLoopSuspend(false)   // loop re-arms
            if self.cuePlayLatched {
                self.cuePlayLatched = false
                return
            }
            self.pausedFile = self.cueFrame ?? 0
            self.flushLocked()
        }
    }

    /// SET CUE: place/move the single cue at the current position (snapped).
    func setCueAtCurrent() {
        queue.async {
            guard self.file != nil else { return }
            self.cueFrame = self.snapLocked(self.currentFileFrameLocked())
        }
    }

    func clearCue() {
        queue.async { self.cueFrame = nil }
    }

    // MARK: - Grid

    func setGrid(bpm: Double, anchorFrame: AVAudioFramePosition) {
        queue.async {
            guard bpm > 20, bpm < 400 else { return }
            self.gridAnchor = anchorFrame
            self.beatFrames = 60.0 / bpm * self.sampleRate
        }
    }

    func clearGrid() {
        queue.async {
            self.beatFrames = 0
            self.gridAnchor = 0
        }
    }

    var hasGrid: Bool { beatFrames > 0 }

    /// Nearest grid beat to `frame` (raw when no grid or snap off).
    private func snapLocked(_ frame: AVAudioFramePosition) -> AVAudioFramePosition {
        guard snapEnabled, beatFrames > 0 else { return max(0, frame) }
        let n = (Double(frame) - Double(gridAnchor)) / beatFrames
        let snapped = Double(gridAnchor) + n.rounded() * beatFrames
        return max(0, AVAudioFramePosition(snapped))
    }

    // MARK: - Beat jump

    func beatJump(_ beats: Int) {
        queue.async {
            guard self.beatFrames > 0, self.file != nil else { return }
            let f = self.currentFileFrameLocked()
            let n = ((Double(f) - Double(self.gridAnchor)) / self.beatFrames).rounded()
            let target = AVAudioFramePosition(Double(self.gridAnchor) + (n + Double(beats)) * self.beatFrames)
            let clamped = max(0, min(target, self.fileFrameCount))
            // jumping out of an active loop exits it (last loop kept for re-loop)
            if let ls = self.loopStart, let le = self.loopEnd,
               clamped < ls || clamped >= le {
                self.lastLoop = (ls, le)
                self.loopStart = nil
                self.loopEnd = nil
            }
            if self.isPlaying {
                self.startLocked(at: clamped)
            } else {
                // Move the DECK — readFrame is the rest point.
                self.pullDeck.seek(toFrame: clamped)
                self.pausedFile = clamped
            }
        }
    }

    // MARK: - Loops

    /// SET: loop of `beats` starting at the current position snapped to the
    /// grid. Pressing while a loop is active exits it. The wrap applies
    /// in-render; by design: engaging while playing jumps to the loop start
    /// (no play-to-end-first).
    func setLoop(beats: Int) {
        queue.async {
            guard self.file != nil else { return }
            if self.loopStart != nil {
                self.exitLoopLocked()
                return
            }
            guard self.beatFrames > 0, beats > 0 else { return }
            let start = self.snapLocked(self.currentFileFrameLocked())
            let length = AVAudioFramePosition(Double(beats) * self.beatFrames)
            self.loopStart = start
            self.loopEnd = min(start + length, self.fileFrameCount)
            self.lastLoop = (start, self.loopEnd!)
            self.logLoop("engage beats", start, self.loopEnd!)
            self.pullDeck.setLoop(start: start, end: self.loopEnd!)
            let lcb = self.onLoopChanged
            self.queue.async { lcb?() }
            if self.isPlaying {
                // wrap applies in-render; jump into the loop region
                let cur = AVAudioFramePosition(self.pullDeck.stateSnapshot.readFrame)   // true position — displayFrame is span-folded
                if cur < start || cur >= self.loopEnd! {
                    self.pullDeck.seek(toFrame: start)
                }
            }
        }
    }

    /// Engage a loop at EXPLICIT frame positions (manual mode —
    /// the M button's arbitrary in/out). Same contract as setLoop(beats:):
    /// jump into the region if playing outside it; lastLoop updated so ↺
    /// reloops the manual span.
    static let minLoopFrames: AVAudioFramePosition = 1024

    /// Gesture-rate span moves — bounds write straight to the
    /// pull deck (any-thread, lock-guarded); the queued setLoopSpan on
    /// release commits the engine-side bookkeeping (lastLoop, logs, the
    /// jump-in rule). Span-drags never MOVE the playhead by design, so
    /// the live write only re-bounds the wrap.
    func setLoopSpanLive(start: AVAudioFramePosition, end: AVAudioFramePosition) {
        guard fileFrameCount > 0 else { return }
        let s = max(0, min(start, fileFrameCount))
        let e = min(max(s + Self.minLoopFrames, end), fileFrameCount)
        guard e > s else { return }
        pullDeck.setLoop(start: s, end: e)
    }

    func setLoopSpan(start: AVAudioFramePosition, end: AVAudioFramePosition) {
        queue.async {
            guard self.file != nil else { return }
            let maxFrame = self.fileFrameCount
            let s = max(0, min(start, maxFrame))
            // enforce a floor so the wrap can't thrash inside one render
            // quantum; refuse only when the track tail leaves no room
            let e = min(max(s + Self.minLoopFrames, end), maxFrame)
            guard e > s else { return }
            let resizing = self.loopStart != nil
            self.loopStart = s
            self.loopEnd = e
            self.lastLoop = (s, e)
            self.logLoop(resizing ? "resize manual" : "engage manual", s, e, throttle: resizing)
            self.pullDeck.setLoop(start: s, end: e)
            let lcb = self.onLoopChanged
            self.queue.async { lcb?() }
            if self.isPlaying {
                let cur = AVAudioFramePosition(self.pullDeck.stateSnapshot.readFrame)   // true position — displayFrame is span-folded
                if cur < s || cur >= e {
                    self.pullDeck.seek(toFrame: s)
                }
            }
        }
    }

    /// Nearest-grid-beat time for manual handle snapping. Gridless
    /// decks return the input unchanged. Pure math — safe from any thread.
    func snappedGridTime(_ seconds: Double) -> Double {
        guard beatFrames > 0, sampleRate > 0 else { return seconds }
        let beat = beatFrames / sampleRate
        let anchor = Double(gridAnchor) / sampleRate
        return anchor + ((seconds - anchor) / beat).rounded() * beat
    }

    private func exitLoopLocked() {
        if let ls = loopStart, let le = loopEnd {
            lastLoop = (ls, le)
            logLoop("exit", ls, le)
        }
        loopStart = nil
        loopEnd = nil
        // wrap lives in the render read; clearing it releases instantly
        pullDeck.clearLoop()
        let lcb = onLoopChanged
        queue.async { lcb?() }
    }

    func exitLoop() { queue.async { self.exitLoopLocked() } }

    func reloop() {
        queue.async {
            guard let ll = self.lastLoop else { return }
            self.loopStart = ll.start
            self.loopEnd = ll.end
            self.logLoop("reloop", ll.start, ll.end)
            self.pullDeck.setLoop(start: ll.start, end: ll.end)
            let lcb = self.onLoopChanged
            self.queue.async { lcb?() }
            if self.isPlaying {
                self.pullDeck.seek(toFrame: ll.start)
            } else {
                self.pausedFile = ll.start
                self.pullDeck.seek(toFrame: ll.start)
            }
        }
    }

    func scaleLoop(_ factor: Double) {
        queue.async {
            guard let ls = self.loopStart, let le = self.loopEnd else { return }
            let newEnd = ls + AVAudioFramePosition(Double(le - ls) * factor)
            self.loopEnd = max(ls + 1, min(newEnd, self.fileFrameCount))
            self.logLoop("scale ×\(factor)", ls, self.loopEnd!)
            self.pullDeck.setLoop(start: ls, end: self.loopEnd!)
            let lcb = self.onLoopChanged
            self.queue.async { lcb?() }
        }
    }

    /// Resize the ACTIVE loop in place — anchor stays at its
    /// loopStart, length becomes `beats` on the current grid. The beats
    /// buttons call this live (the old path required exit → re-enter).
    func setLoopLength(beats: Int) {
        queue.async {
            guard self.loopStart != nil, self.beatFrames > 0, beats > 0 else { return }
            let ls = self.loopStart!
            let newEnd = min(ls + AVAudioFramePosition(Double(beats) * self.beatFrames),
                             self.fileFrameCount)
            guard newEnd > ls else { return }
            self.loopEnd = newEnd
            self.lastLoop = (ls, newEnd)
            self.logLoop("resize beats \(beats)", ls, newEnd)
            self.pullDeck.setLoop(start: ls, end: newEnd)
            let lcb = self.onLoopChanged
            self.queue.async { lcb?() }
            if self.isPlaying {
                // wrap applies in-render; jump inside if the playhead fell
                // outside the shortened loop
                let cur = AVAudioFramePosition(self.pullDeck.stateSnapshot.readFrame)   // true position — displayFrame is span-folded
                if cur < ls || cur >= newEnd {
                    self.pullDeck.seek(toFrame: ls)
                }
            }
        }
    }

    // MARK: - Scrub interaction

    /// All three gesture entry points call PullDeck DIRECTLY
    /// (from the UI thread) instead of hopping the engine queue — PullDeck
    /// is internally synchronized (atomics for the move-rate hot path, a
    /// sub-µs lock for begin/end), and same-thread calls preserve
    /// begin→set→end ordering by construction. The queue hop was the last
    /// piece of avoidable latency between the gesture and the render block.

    /// Grab (press): cursor owns position; audio chases to a stop.
    func scrubBegin() {
        pullDeck.scrubBegin()
    }

    /// Cursor target in absolute file frames (wait-free; 60–120 Hz).
    func scrubSet(targetFrame: AVAudioFramePosition) {
        pullDeck.scrubSet(targetFrame: targetFrame)
    }

    /// Release with velocity in file-frames/s. Playing: strong throw that
    /// settles to base rate over ~0.8 s (a 0.16 s decay
    /// was imperceptible). Paused: decays to a stop.
    func scrubEnd(velocityFramesPerSec v: Double) {
        pullDeck.scrubEnd(velocityFramesPerSec: v)
        queue.async { self.startThrowDecayLocked() }
    }

    /// Escape hatch: clears a grab without a throw — used when a
    /// lane disappears mid-gesture; scrubEnd is otherwise reachable only
    /// from the gesture's onEnded. DIRECT like begin/set: a queued
    /// cancel landed after the recovery path's fresh begin and killed it.
    func scrubCancel() {
        pullDeck.scrubCancel()
    }

    private func startThrowDecayLocked() {
        stopThrowTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let m = self.pullDeck.momentumSnapshot
            // Through a settle the grab is still "live" — skip the
            // tick (don't stop the timer) so the captured throw decays the
            // moment the chase arrives.
            if self.pullDeck.isScrubbing { return }
            // Decay toward the TRANSPORT rate (playing: 1×,
            // passing through 0 for backward throws — the motor pulls the
            // platter back) or toward a STOP (paused — spin down; the old
            // code decayed everything toward 1× and dropped momentumToZero
            // on the first tick, so paused throws stopped instantly).
            let tau = 0.8
            let dt = 1.0 / 60.0
            let playing = self.isPlaying
            let newM = playing ? 1.0 + (m - 1.0) * exp(-dt / tau)
                               : m * exp(-dt / tau)
            let settled = playing ? abs(newM - 1.0) < 0.01 : abs(newM) < 0.02
            if settled {
                self.pullDeck.setMomentum(playing ? 1 : 0, toZero: !playing)
                self.stopThrowTimerLocked()
            } else {
                self.pullDeck.setMomentum(newM, toZero: !playing)
            }
        }
        timer.resume()
        throwTimer = timer
    }

    private func stopThrowTimerLocked() {
        throwTimer?.cancel()
        throwTimer = nil
    }

    /// Grab-state for views (advisory UI read, same contract as isPlaying).
    var isScrubbing: Bool { pullDeck.isScrubbing }

    /// LaneClock cadence input: live transport state (any thread, cheap).
    var pullDeckStateForClock: (playing: Bool, scrubbing: Bool, momentum: Double) {
        let s = pullDeck.stateSnapshot
        return (s.playing, s.scrubbing, s.momentum)
    }

    /// Polls render-side EOF (set inside the pull render) and fires onEOF.
    /// Also carries the leaked-grab detector — a live gesture
    /// writes scrubSet at event rate, so stillness this long is either a
    /// deliberate hold or a gesture that died without scrubEnd (log-only;
    /// auto-canceling would kill legitimate hand-on-record holds).
    private var scrubIdleLogged = false

    // Reader-stall watchdog state + counters (engine queue).
    private var readerStallSince: CFAbsoluteTime?
    private(set) var stallDetections = 0
    private(set) var readerRecoveries = 0
    /// Set when a recovery couldn't reopen the track (disk gone) — the
    /// transport stopped and the user was notified. Cleared on next load.
    private(set) var trackUnavailable = false
    /// Surfaces user-visible deck failures to the UI (e.g. the track's
    /// disk vanished across sleep). Called on the engine queue.
    var onNotice: ((String) -> Void)?

    /// One line per loop lifecycle event — diagnosing a desync needs
    /// loop state visible in the log. Resizes
    /// throttle to 2 Hz (M-handle drags write at gesture rate;
    /// per-event file I/O would flood the log).
    private var loopLogAt: CFAbsoluteTime = 0
    private func logLoop(_ event: String, _ a: AVAudioFramePosition, _ b: AVAudioFramePosition,
                         throttle: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if throttle, now - loopLogAt < 0.5 { return }
        loopLogAt = now
        MKLog.engine(String(format: "loop: deck %d %@ [%.3f, %.3f)s",
                             index, event, Double(a) / sampleRate, Double(b) / sampleRate))
    }
    private var previewStartHost: CFAbsoluteTime = 0
    private var previewHeldLogged: CFAbsoluteTime = 0

    private func startPullPolling() {
        stopPullPolling()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.pullDeck.stateSnapshot.eof && self.isPlaying {
                // Fire the transport callback too — without it the
                // PLAY button stayed lit at track end until the next click
                self.isPlaying = false
                self.pausedFile = self.fileFrameCount
                let eof = self.onEOF
                let cb = self.onTransportChanged
                self.queue.async {
                    eof?()
                    cb?(false)
                }
            }
            if self.pullDeck.consumeSettleStarved {
                MKLog.engine("settle starved: lag forced at release")
            }
            if self.pullDeck.isScrubbing {
                let idle = self.pullDeck.scrubIdleSeconds
                if idle > 10, !self.scrubIdleLogged {
                    self.scrubIdleLogged = true
                    MKLog.engine(String(format: "scrub idle %.1fs — held still or leaked gesture", idle))
                }
            } else {
                self.scrubIdleLogged = false
            }
            // Reader-stall watchdog. A playing deck whose ring
            // stays empty for >2s means the reader thread stopped producing
            // (known form: blocked in kernel I/O on a descriptor whose
            // volume went away across sleep — no return, no error). Recover
            // by reopening the handle in place; if nothing reopens, stop the
            // transport and say so instead of a ghost play.
            let h = self.pullDeck.ringHealth()
            let starved = h.playing && h.hasHandle && !h.scrubbing && !h.settling && !h.eof
                && abs(h.momentum - 1) < 0.02
                && h.ringEnd <= Int64(h.readFrame) + 8192
            if starved {
                if self.readerStallSince == nil {
                    self.readerStallSince = CFAbsoluteTimeGetCurrent()
                } else if CFAbsoluteTimeGetCurrent() - self.readerStallSince! > 2.0 {
                    self.readerStallSince = nil
                    self.stallDetections += 1
                    MKLog.engine(String(format: "reader stalled: deck %d readFrame %.0f ring [%lld..%lld] readerIters %d underruns %d — recovering",
                                         self.index, h.readFrame, h.ringStart, h.ringEnd,
                                         h.readerIters, h.underruns))
                    if self.pullDeck.recoverReader(reason: "watchdog") {
                        self.readerRecoveries += 1
                    } else {
                        self.trackUnavailable = true
                        MKLog.app("deck \(self.index + 1): track's disk unavailable — stopping", error: true)
                        self.isPlaying = false
                        self.pausedFile = Int64(max(0, h.readFrame))
                        let cb = self.onTransportChanged
                        let notice = self.onNotice
                        self.queue.async {
                            cb?(false)
                            notice?("Track's disk unavailable — deck stopped")
                        }
                    }
                }
            } else {
                self.readerStallSince = nil
            }
            KeepAwake.shared.setDeckPlaying(self.index, self.isPlaying)
            // Long-held cue previews surface at 10 s cadence
            if self.previewing {
                let now = CFAbsoluteTimeGetCurrent()
                if now - self.previewHeldLogged > 10.0 {
                    self.previewHeldLogged = now
                    MKLog.app(String(format: "cue preview: deck %d held %.1fs",
                                      self.index + 1, now - self.previewStartHost))
                }
            }
        }
        timer.resume()
        pullPollTimer = timer
    }

    private func stopPullPolling() {
        pullPollTimer?.cancel()
        pullPollTimer = nil
        KeepAwake.shared.setDeckPlaying(index, false)
    }

    /// Wake-time deck health check. Logs a snapshot always;
    /// on system wake (not plain engine config changes — those don't
    /// touch file descriptors) the decode handle is reopened proactively:
    /// sleep can leave the descriptor stale before anything visibly fails.
    func revalidateAfterWake(reason: String, reopen: Bool) {
        let h = pullDeck.ringHealth()
        guard h.hasHandle || pullDeck.loadedURL != nil else { return }
        MKLog.app(String(format: "wake: deck %d playing %d readFrame %.0f ring [%lld..%lld] eof %d eafErr %d — %@",
                          index, h.playing ? 1 : 0, h.readFrame, h.ringStart, h.ringEnd,
                          h.eof ? 1 : 0, h.eafErrored ? 1 : 0, reason))
        guard reopen, let url = pullDeck.loadedURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            trackUnavailable = true
            MKLog.app("wake: deck \(index + 1) file missing — \(url.path)", error: true)
            if h.playing {
                isPlaying = false
                pausedFile = Int64(max(0, h.readFrame))
                let cb = onTransportChanged
                let notice = onNotice
                queue.async {
                    cb?(false)
                    notice?("Track's disk unavailable — deck stopped")
                }
            }
            return
        }
        if pullDeck.recoverReader(reason: reason) {
            readerRecoveries += 1
        }
    }

    // MARK: - EQ / filter / gain

    func setEQ(lowDb: Double, midDb: Double, highDb: Double) {
        queue.async {
            self.eq.bands[0].gain = Float(max(-12, min(12, lowDb)))
            self.eq.bands[1].gain = Float(max(-12, min(12, midDb)))
            self.eq.bands[2].gain = Float(max(-12, min(12, highDb)))
        }
    }

    private func resetEQLocked() {
        for i in 0...2 { eq.bands[i].gain = 0 }
        setFilterKnobLocked(0)
    }

    /// −1 = LP full left … 0 = hard bypass … +1 = HP full right.
    func setFilterKnob(_ x: Double) {
        queue.async { self.setFilterKnobLocked(x) }
    }

    /// Gate readback — both filter bands bypassed (knob at off).
    var filterBypassed: Bool {
        queue.sync { eq.bands[3].bypass && eq.bands[4].bypass }
    }

    private func setFilterKnobLocked(_ xIn: Double) {
        let x = max(-1, min(1, xIn))
        if abs(x) < 0.02 {
            eq.bands[3].bypass = true
            eq.bands[4].bypass = true
            return
        }
        if x < 0 {
            // resonant LP sweeping 20 kHz → 30 Hz
            let t = -x
            let freq = exp(log(20000) + t * (log(30) - log(20000)))
            eq.bands[4].bypass = true
            eq.bands[3].frequency = Float(freq)
            eq.bands[3].bypass = false
        } else {
            // resonant HP sweeping 20 Hz → 10 kHz
            let freq = exp(log(20) + x * (log(10000) - log(20)))
            eq.bands[3].bypass = true
            eq.bands[4].frequency = Float(freq)
            eq.bands[4].bypass = false
        }
    }

    /// Combined deck output gain (trim × fader × crossfade, computed upstream).
    /// Nodes have no ramped-volume API (that's AVAudioPlayer only); callers
    /// update at UI rate with small deltas, which keeps steps inaudible.
    func setOutputGain(_ gain: Double) {
        let g = Float(max(0, min(1.5, gain)))
        if deckMixer.outputVolume != g {
            deckMixer.outputVolume = g
        }
    }
}
