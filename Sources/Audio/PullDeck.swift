import AVFoundation
import AudioToolbox

/// Pull-model transport core: control writes a small state
/// struct; the audio render path reads it every callback and pulls decoded
/// PCM from a ring the reader thread keeps filled. Seeks/scrubs/jogs take
/// effect at the next render block — no flushing, no rescheduling, no ledger.
///
/// Threading: ONE NSLock guards {transport + ring indices + memcpys}; every
/// section is sub-microsecond. The lock is never held across file I/O; DSP
/// (SoundTouch) runs under the lock only for short put/receive calls — its
/// own shim lock (mk_dsp_lock.h) covers cross-instance safety.
///
/// Render paths:
/// • VINYL — linear resample at rate × 2^(pitch/12): pitch follows speed.
///   Instant; used for scrub, throw, keylock-off. The pitch knob is audible
///   in every state.
/// • KEYLOCK — steady playback with keylock on: SoundTouch in-render with
///   INDEPENDENT tempo/pitch (the classic DJ decoupling; ~92 ms latency,
///   bypassed during manipulation for grab responsiveness).
final class PullDeck {

    // MARK: - Shared state (under `lock`)

    struct State {
        var readFrame: Double = 0         // absolute file frame (fractional)
        var playing = false
        var scrubbing = false
        /// Release with chase-lag — the chase finishes the trip to
        /// the frozen cursor before the release completes (no hard seek).
        var settling = false
        var settleStartHost: Double = 0
        var baseRate: Double = 1.0
        var momentum: Double = 1.0        // throw multiplier
        var momentumToZero = false        // paused-release throw decays to stop
        var loopStart: Int64 = -1
        var loopEnd: Int64 = -1
        var eof = false
        var epoch: Int = 0
        var underrunsPub: Int = 0
        /// Render-side chase rate (slewed) — only the render thread writes.
        var chaseRate: Double = 0
        /// User key shift (semitones) + keylock decoupling.
        var userPitchSemitones: Double = 0
        var keylock = false
    }

    private var st = State()
    private let lock = NSLock()

    /// Single-writer atomics (cf. Mixxx's lock-free control
    /// exchange): the hottest UI→render path —
    /// scrub-target writes at gesture rate (60–120 Hz) vs render reads at
    /// ~86 Hz — runs through C11 atomics instead of the NSLock, so a drag
    /// never waits on ring bookkeeping and the render never waits on the
    /// drag. The locked State stays authoritative for everything else;
    /// these mirrors are written on BOTH paths (cheap) and read lock-free.
    private var scrubTargetAt = mk_atomic_i64_t()
    private var scrubbingAt = mk_atomic_i8_t()
    /// A live (gesture-rate) seek is in flight — the display
    /// pins to its target until the render anchor catches up.
    private var seekLiveAt = mk_atomic_i8_t()
    /// Display anchor published by the render callback —
    /// (display frame, host µs, effective-rate bits). The display side
    /// time-interpolates between callbacks (the Mixxx VisualPlayPosition
    /// pattern): the ring's read position only advances in 512-frame render
    /// quanta, so a raw read gives the playhead a visible ~12 ms stair-step.
    private var dispAnchorFrameAt = mk_atomic_i64_t()
    private var dispAnchorHostAt = mk_atomic_i64_t()
    private var dispAnchorRateAt = mk_atomic_i64_t()
    /// Pre-callback display frame, captured under the render lock and
    /// published atomically at callback end.
    private var anchorPreFrame: Int64 = 0
    /// Play-start probe state (guarded by the render lock).
    private var playStartHostUs: Int64 = 0
    private var firstFrameLogged = true
    /// Lock-free companions for the hot path — track length for
    /// wait-free clamping, and the last gesture write (µs) for liveness.
    private var fileFramesAt = mk_atomic_i64_t()
    private var scrubMoveHostAt = mk_atomic_i64_t()

    /// Planar ring: channel c, frame i → ring[c * ringFrames + i].
    private var ring: UnsafeMutablePointer<Float>
    private let ringFrames: Int
    private var ringStart: Int64 = 0     // absolute frame of ring index 0
    private var ringFilled = 0
    private(set) var channels: Int = 2
    private(set) var sampleRate: Double = 44100

    /// The decode handle is the ExtAudioFile C API — status-
    /// returning, never throws. AVAudioFile's ObjC exceptions (uncatchable
    /// in Swift) aborted the process on codec/seek errors; that entire
    /// crash class is now impossible. Client format is always float32
    /// non-interleaved stereo — ExtAudioFile converts from the file's
    /// native layout, so the read buffers below are fixed-size.
    ///
    /// ARC lifetime for the raw handles: disposing them under
    /// the lock while a superseded reader was still mid-read on a captured
    /// raw pointer was a use-after-free — AVAudioFile only ever survived
    /// this pattern because it was itself a refcounted object. The boxes
    /// restore that guarantee: dispose happens when the LAST holder (a
    /// finishing reader) lets go.
    private final class EAFHandle {
        let ref: ExtAudioFileRef
        init(_ r: ExtAudioFileRef) { ref = r }
        deinit { ExtAudioFileDispose(ref) }
    }
    private final class FFHandle {
        let ref: OpaquePointer
        init(_ r: OpaquePointer) { ref = r }
        deinit { mk_ff_close(ref) }
    }
    private var eaf: EAFHandle?
    private var ff: FFHandle?
    private var eafErrored = false        // log-once throttle for read/seek errors
    private static let chunkFrames = 16384
    private var readScratch = [Float](repeating: 0, count: 16384 * 2)
    /// Two-buffer AudioBufferList (heap: the Swift import only models the
    /// single-buffer tail), reused by every read.
    private var readListPtr: UnsafeMutablePointer<AudioBufferList>
    private var fileFrames: Int64 = 0

    /// FFmpeg decode fallback for formats CoreAudio can't read
    /// (ogg/opus/wma/amr); nil when the ExtAudioFile path opened the file.
    private var ffScratch = [Float](repeating: 0, count: 16384 * 2)

    // Keylock stretcher (per-deck SoundTouch; created at load)
    private var stouch: OpaquePointer?
    private var stLatencyFrames: Int64 = 0
    private var stEngaged = false        // stretcher primed for steady output
    private var outputThroughStretcher = false

    // Reader thread
    // The old `cancelled` BOOL handshake resurrected stopped
    // readers — startReader flipped it back to false microseconds after
    // stopReader set it true, so a reader mid-decode (MP3 reads take
    // milliseconds) sailed past the flag. A monotonic generation replaces
    // it: each thread captures its generation and only the newest survives;
    // dead generations can never match again.
    private var readerThread: Thread?
    private var readerSem = DispatchSemaphore(value: 0)
    private var readerGeneration = 0
    /// Outer-loop iterations of the live reader — the watchdog's
    /// heartbeat (a frozen thread stops advancing this).
    private var readerIters = 0
    /// URL of the loaded track — the recovery path's reopen
    /// source (descriptors gone stale across sleep are reopened from it).
    private(set) var loadedURL: URL?
    /// Set by the render when a settle starves out; the deck's poll timer
    /// logs it (render thread must not format strings or touch the log).
    private var settleStarvedFlag = false

    /// Epoch carry across `State()` resets: `st.epoch` used to
    /// restart at 0 on every load, which is exactly why a zombie reader's
    /// stale capture kept passing the ring-invalidation guard.
    private var epochCarry = 0
    /// Live reader threads (probe gate: must always be 0 or 1 per deck).
    private static var liveReaderCount = 0
    private static let readerCountLock = NSLock()
    static var liveReaders: Int {
        readerCountLock.lock(); defer { readerCountLock.unlock() }
        return liveReaderCount
    }

    // Render-thread private
    private var fadeEnv: Float = 1
    private var fadeRamp: Float = 0
    private var lastRate: Double = 1
    /// 2^(pitch/12), cached (previously recomputed every block)
    private var pitchFactor: Double = 1
    private static let fadeFrames: Float = 220   // ~5 ms click guard
    private var scratchIn = [Float]()
    private var scratchOut = [Float]()
    /// Preallocated stretcher I/O plumbing — per-block
    /// `.map` arrays (and the EOF tail) would be heap allocations on the
    /// render thread. Fixed capacity: 2ch, SoundTouch-planar layout.
    private var stInBuf: [UnsafePointer<Float>?] = [nil, nil]
    private var stOutBuf: [UnsafeMutablePointer<Float>?] = [nil, nil]
    private var stTail = [Float](repeating: 0, count: 1024 * 2)

    // MARK: - Snapshots (any thread)

    var stateSnapshot: State {
        lock.lock(); defer { lock.unlock() }
        return st
    }

    /// Decoded frames available ahead of the read position (harness gate).
    var decodedAhead: Int64 {
        lock.lock(); defer { lock.unlock() }
        return ringEndFrame - Int64(st.readFrame)
    }

    /// Display position: scrubbing pins to the cursor
    /// target; keylock steady output lags the read point by the stretcher
    /// latency; otherwise it's the audio's actual position.
    /// While playing at a settled rate, the position is
    /// TIME-INTERPOLATED from the render callback's anchor — the raw read
    /// position advances in 512-frame render quanta and gave the playhead
    /// a visible ~12 ms stair-step (the Mixxx VisualPlayPosition pattern).
    var displayFrame: Int64 {
        // Fast path: during a grab the display polls at 60 Hz —
        // serve it entirely from the atomics, no lock.
        if mk_at_load_i8(&scrubbingAt) != 0 || mk_at_load_i8(&seekLiveAt) != 0 {
            return mk_at_load_i64(&scrubTargetAt)
        }
        lock.lock(); defer { lock.unlock() }
        let base = outputThroughStretcher ? max(0, Int64(st.readFrame) - stLatencyFrames)
                                          : Int64(st.readFrame)
        guard st.playing, abs(st.momentum - 1.0) < 0.01, !st.settling else { return base }
        let anchorF = mk_at_load_i64(&dispAnchorFrameAt)
        let anchorT = mk_at_load_i64(&dispAnchorHostAt)
        let rateBits = UInt64(bitPattern: mk_at_load_i64(&dispAnchorRateAt))
        let rate = Double(bitPattern: rateBits)
        guard rate > 1e-4, anchorF >= 0 else { return base }
        let elapsedUs = Int64(CFAbsoluteTimeGetCurrent() * 1e6) - anchorT
        // anchors older than ~1.5 callbacks fall back to the raw read
        // (offline harness pacing, engine stalls)
        guard elapsedUs >= 0, elapsedUs < 17_000 else { return base }
        var p = anchorF + Int64(Double(elapsedUs) * 1e-6 * rate * sampleRate)
        // The extrapolation must respect an armed loop — the
        // true position wraps at loopEnd, so running linearly past it
        // overshot the playhead at every wrap (sawtooth; aliasing thrash
        // for sub-window loops). Suspended (cue preview) = genuinely no
        // wrap this instant.
        if !loopSuspended, st.loopStart >= 0, st.loopEnd > st.loopStart {
            if p >= st.loopEnd {
                p = st.loopStart + (p - st.loopStart) % (st.loopEnd - st.loopStart)
            }
        }
        return max(0, p)
    }

    /// Publish the display anchor at the end of every render callback (audio
    /// thread, wait-free). The anchor frame is the PRE-callback read
    /// position — the content that corresponds to "now" (the audio the
    /// callback is about to render is heard one callback-duration later;
    /// anchoring at the post-advance frame ran the display a quantum ahead
    /// — the selftest audible-position gates caught it at +23 ms).
    private func publishDisplayAnchor(rate: Double) {
        // Once the render anchor is within ~50 ms of the live
        // seek target, the pin releases (paused decks never render — the
        // pin correctly holds until playback resumes).
        if mk_at_load_i8(&seekLiveAt) != 0,
           abs(anchorPreFrame - mk_at_load_i64(&scrubTargetAt)) < Int64(sampleRate / 20) {
            mk_at_store_i8(&seekLiveAt, 0)
        }
        mk_at_store_i64(&dispAnchorFrameAt, anchorPreFrame)
        mk_at_store_i64(&dispAnchorHostAt, Int64(CFAbsoluteTimeGetCurrent() * 1e6))
        mk_at_store_i64(&dispAnchorRateAt, Int64(bitPattern: rate.bitPattern))
    }

    var isScrubbing: Bool {
        lock.lock(); defer { lock.unlock() }
        return st.scrubbing
    }

    var momentumSnapshot: Double {
        lock.lock(); defer { lock.unlock() }
        return st.momentum
    }

    private func effectiveRateLocked() -> Double {
        // Gate on the SAME atomic the gesture hot path writes —
        // the locked mirror is begin/end/diagnostic state only. A path that
        // ever reached scrubSet without a completed scrubBegin must not
        // leave the display pinned while the audio ignores the drag.
        if mk_at_load_i8(&scrubbingAt) != 0 { return st.chaseRate }
        if !st.playing { return st.momentumToZero ? st.momentum : 0 }
        return st.baseRate * st.momentum
    }

    /// Render-only: slewed chase toward the cursor. Ceiling ±32,
    /// damped corrections (τ ≈ 23 ms), easing to 0 at the target.
    /// Reads the ATOMIC mirrors — this runs every callback and
    /// must not contend with gesture-rate lock holders.
    private func updateChaseLocked() {
        let scrubbing = mk_at_load_i8(&scrubbingAt) != 0
        guard scrubbing else { st.chaseRate = 0; return }
        let target = mk_at_load_i64(&scrubTargetAt)
        let blockFrames = 512.0
        let ideal = (Double(target) - st.readFrame) / blockFrames
        // Ring-aware ceiling. A fixed ±32 lets a hard drag outrun
        // the refill into park-silence — drag feedback you can't HEAR reads
        // as "weak, not fighting the track". Clamp the chase to what the
        // ring can sustain (drain ≤ ¼ of the runway per block, ≥2× so a
        // grab always overpowers playback); silence gaps are gone and the
        // release catch-up covers the residual cursor lag.
        let pos = Int64(st.readFrame)
        let runway = ideal >= 0 ? ringEndFrame - pos : pos - ringStart
        let sustainable = Double(max(0, runway)) / (blockFrames * 4.0)
        let cap = max(2.0, min(32.0, sustainable))
        let clamped = max(-cap, min(cap, ideal))
        st.chaseRate += (clamped - st.chaseRate) * 0.5
        if abs(st.chaseRate) < 1e-4, abs(ideal) < 1e-4 { st.chaseRate = 0 }

        // Settle completion: the chase arrived (or starved out after
        // 1.5 s — the only place a hard seek remains, logged).
        if st.settling {
            let arrived = abs(Double(target) - st.readFrame) < blockFrames
            let starved = CFAbsoluteTimeGetCurrent() - st.settleStartHost > 1.5
            if arrived || starved {
                if starved && !arrived {
                    settleStarvedFlag = true   // logged by the poll timer:
                                              // no string formatting on the render thread
                    let clampedT = max(0, min(target, fileFrames))
                    st.readFrame = Double(clampedT)
                    st.eof = false
                    if clampedT < ringStart || clampedT >= ringEndFrame {
                        resetRingLocked(clampedT)
                        kickReader()
                    }
                }
                st.settling = false
                st.scrubbing = false
                st.chaseRate = 0
                mk_at_store_i8(&scrubbingAt, 0)
            }
        }
    }

    // MARK: - Lifecycle (engine queue)

    init() {
        ringFrames = 1 << 20              // ~23.8 s @ 44.1k
        ring = .allocate(capacity: ringFrames * 2)
        // The Swift import of AudioBufferList models only ONE trailing
        // buffer — a two-buffer list needs raw bytes for both (allocating
        // `capacity: 1` of the imported type and writing the second buffer
        // is a heap overrun).
        let ablBytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        readListPtr = UnsafeMutableRawPointer.allocate(byteCount: ablBytes,
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
            .assumingMemoryBound(to: AudioBufferList.self)
        let list = UnsafeMutableAudioBufferListPointer(readListPtr)
        list.count = 2
        for i in 0..<2 {
            list[i].mNumberChannels = 1   // one channel per buffer (non-interleaved)
            list[i].mDataByteSize = 0
            list[i].mData = nil
        }
    }

    deinit {
        stopReader()
        if let s = stouch { mk_stouch_destroy(s) }
        readListPtr.deallocate()
        ring.deallocate()
    }

    /// The ONE load entry (called once per track, on
    /// the engine queue, with DeckEngine's already-open AVAudioFile when
    /// there is one). Chain: preferred AVAudioFile → own AVAudioFile →
    /// AVAssetReader mono fallback → FFmpeg shim. Returns false when the
    /// file is unreadable by anything.
    @discardableResult
    func load(url: URL, preferredFile: AVAudioFile? = nil) -> Bool {
        // Remember the source + log the full path/volume — a stall
        // diagnosis must be able to tell which disk a dead
        // deck's track lived on.
        loadedURL = url
        let vol = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "?"
        MKLog.engine("load: \(url.path) [volume \(vol)]")
        if let f = preferredFile ?? (try? AVAudioFile(forReading: url)) {
            // EAF adoption is PROVEN by a probe read — an
            // openable-but-undecodable file (e.g. some Vorbis/FLAC-in-ogg)
            // falls through to the decode chain instead of reading zeros.
            if loadWithExtAudio(file: f) { return true }
        }
        // AVAssetReader middle fallback — some files the file API
        // rejects decode fine through the asset path.
        if let (samples, sr) = try? BPMEngine.readMonoViaAssetReaderPublic(url: url) {
            MKLog.engine("load: AVAssetReader fallback (\(samples.count) frames) for \(url.lastPathComponent)")
            loadPCM(samples: samples, sampleRate: sr)
            return true
        }
        var sr: Double = 0
        var frames: Int64 = 0
        guard let h = url.path.cString(using: .utf8).map({ mk_ff_open($0, &sr, &frames) }),
              let handle = h, handle != OpaquePointer(bitPattern: 0) else {
            MKLog.engine("load: FAILED — no decoder for \(url.lastPathComponent)")
            return false
        }
        ff = FFHandle(handle)
        MKLog.engine("load: FFmpeg (len \(frames)) for \(url.lastPathComponent)")
        loadFF(sampleRate: sr, frames: frames)
        return true
    }

    /// Quick readability probe for files AVAudioFile rejects:
    /// can the FFmpeg shim open it? (Open+close only — the real handle is
    /// opened at load time.)
    func ffProbe(url: URL) -> Bool {
        var sr: Double = 0
        var frames: Int64 = 0
        guard let c = url.path.cString(using: .utf8),
              let h = mk_ff_open(c, &sr, &frames),
              h != OpaquePointer(bitPattern: 0) else { return false }
        mk_ff_close(h)
        return true
    }

    /// Fresh transport state that can never collide with a prior load's
    /// ring-invalidation epoch and never leaks gesture atomics
    /// into the next track.
    private func freshStateLocked() {
        epochCarry &+= 1
        var s = State()
        s.epoch = epochCarry
        st = s
        resetScrubAtomicsLocked()
    }

    /// Raw-PCM load: convert the mono/decoded samples into the planar ring
    /// directly (used by the AVAssetReader fallback).
    private func loadPCM(samples: [Float], sampleRate sr: Double) {
        lock.lock()
        closeDecodeHandlesLocked()
        fileFrames = Int64(samples.count)
        channels = 2
        sampleRate = sr > 0 ? sr : 44100
        freshStateLocked()
        ringStart = 0
        ringFilled = 0
        // pre-fill the ring from the decoded block (duplicate mono to both channels)
        let fill = min(ringFrames, samples.count)
        for i in 0..<fill {
            ring[i] = samples[i]
            ring[ringFrames + i] = samples[i]
        }
        ringFilled = fill
        if let s = mk_stouch_create(Int32(channels), Int32(sampleRate)) {
            stouch = s
            stLatencyFrames = Int64(mk_stouch_latency(s))
        }
        lock.unlock()
        startReader()
        kickReader()
    }

    private func loadFF(sampleRate sr: Double, frames: Int64) {
        lock.lock()
        closeDecodeHandlesLocked(keepFF: true)   // ff was just opened by load(url:)
        // Containers without duration metadata report frames=0 — a
        // literal zero fences every read off. Use a sentinel: reads proceed
        // until decode EOF, which sets st.eof (see the reader's exhaustion
        // path) so the transport stops cleanly instead of playing silence.
        fileFrames = frames > 0 ? frames : (Int64.max / 4)
        channels = 2
        sampleRate = sr > 0 ? sr : 44100
        freshStateLocked()
        ringStart = 0
        ringFilled = 0
        if let s = mk_stouch_create(Int32(channels), Int32(sampleRate)) {
            stouch = s
            stLatencyFrames = Int64(mk_stouch_latency(s))
        }
        lock.unlock()
        startReader()
        kickReader()
    }

    /// Primary load. The AVAudioFile is consulted ONLY for url,
    /// length and format — the decode handle is ExtAudioFile (C API,
    /// status-returning). Client format is forced to float32 non-interleaved
    /// stereo so the read path is layout-independent. Returns false (and
    /// cleans up) when the file opens but cannot actually decode — the
    /// caller then falls through to the AVAssetReader/FFmpeg chain.
    private func loadWithExtAudio(file: AVAudioFile) -> Bool {
        guard let opened = Self.openProvenEAF(url: file.url,
                                              fileSR: file.processingFormat.sampleRate,
                                              fallbackLen: Int64(file.length)) else {
            return false
        }
        lock.lock()
        closeDecodeHandlesLocked()
        eaf = opened.handle
        eafErrored = false
        fileFrames = opened.frames
        channels = 2
        sampleRate = opened.sampleRate
        freshStateLocked()
        ringStart = 0
        ringFilled = 0
        if let s = mk_stouch_create(Int32(channels), Int32(sampleRate)) {
            stouch = s
            stLatencyFrames = Int64(mk_stouch_latency(s))
        }
        lock.unlock()
        MKLog.engine("load: EAF adopted (len \(opened.frames), sr \(sampleRate)) for \(file.url.lastPathComponent)")
        startReader()
        kickReader()
        return true
    }

    /// The open-prove-size sequence for an ExtAudioFile handle,
    /// shared by load and reader recovery. File I/O — never under `lock`.
    /// `fallbackLen` (the opener's AVAudioFile.length) is consulted only
    /// when the EAF itself can't size the file.
    private static func openProvenEAF(url: URL, fileSR: Double,
                                      fallbackLen: Int64) -> (handle: EAFHandle, frames: Int64, sampleRate: Double)? {
        var ref: ExtAudioFileRef?
        guard ExtAudioFileOpenURL(url as CFURL, &ref) == noErr, let opened = ref else {
            return nil
        }
        let client = AVAudioFormat(standardFormatWithSampleRate: fileSR, channels: 2)!
        var asbd = client.streamDescription.pointee
        let setClient = ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                &asbd)
        guard setClient == noErr else {
            ExtAudioFileDispose(opened)   // never adopted: safe to dispose inline
            MKLog.engine(String(format: "load: EAF client-format err %d for %@ — falling back",
                                 setClient, url.lastPathComponent as NSString))
            return nil
        }
        // Probe read: prove the codec path delivers frames before adopting.
        // Mirrors the reader's list shape (non-interleaved stereo = 2
        // one-channel buffers); heap bytes because the imported struct only
        // models a single-buffer tail.
        let ablBytes = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size
        let probeABL = UnsafeMutableRawPointer.allocate(byteCount: ablBytes,
                                                        alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { probeABL.deallocate() }
        let ablPtr: UnsafeMutablePointer<AudioBufferList> =
            probeABL.assumingMemoryBound(to: AudioBufferList.self)
        let probe = UnsafeMutableAudioBufferListPointer(ablPtr)
        // A 1-frame probe is useless — AAC-family converters buffer
        // internally and legitimately deliver 0 frames. Ask for a chunk.
        probe.count = 2
        let probeFramesWanted: UInt32 = 4096
        let probeStore = UnsafeMutableRawPointer.allocate(byteCount: Int(probeFramesWanted) * 4 * 2,
                                                          alignment: 4)
        defer { probeStore.deallocate() }
        probe[0].mNumberChannels = 1
        probe[1].mNumberChannels = 1
        probe[0].mData = probeStore
        probe[1].mData = probeStore + Int(probeFramesWanted) * 4
        probe[0].mDataByteSize = probeFramesWanted * 4
        probe[1].mDataByteSize = probeFramesWanted * 4
        var probeFrames = probeFramesWanted
        guard ExtAudioFileSeek(opened, 0) == noErr,
              ExtAudioFileRead(opened, &probeFrames, ablPtr) == noErr,
              probeFrames > 0 else {
            ExtAudioFileDispose(opened)
            MKLog.engine("reader: EAF probe read failed for \(url.lastPathComponent) — falling back")
            return nil
        }
        // Length from EAF itself — AVAudioFile.length can report 0 for
        // containers it opens but doesn't grok (FLAC-in-ogg), and a zero
        // length fences every read.
        var eafLen: Int64 = 0
        var lenSize = UInt32(MemoryLayout<Int64>.size)
        if ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames,
                                   &lenSize, &eafLen) != noErr || eafLen <= 0 {
            eafLen = fallbackLen
        }
        if eafLen <= 0 {
            // Containers CoreAudio opens but can't size (vorbis-in-ogg):
            // the probe just PROVED the file decodes — the length must come
            // from the asset layer or every read would be fenced off.
            let secs = CMTimeGetSeconds(AVURLAsset(url: url).duration)
            if secs > 0 { eafLen = Int64((secs * fileSR).rounded()) }
            if eafLen > 0 {
                MKLog.engine("load: length from AVAsset (\(eafLen) frames) for \(url.lastPathComponent)")
            }
        }
        guard eafLen > 0 else {
            // Decodes but nobody can size it — EAF would fence every read on
            // a zero length. Fall through to FFmpeg (which knows vorbis/opus
            // lengths); that restores working ogg playback.
            ExtAudioFileDispose(opened)
            MKLog.engine("load: EAF unsizable for \(url.lastPathComponent) — falling back")
            return nil
        }
        return (EAFHandle(opened), eafLen, fileSR)
    }

    // MARK: - Reader recovery

    /// Health snapshot for the stall watchdog and wake logging.
    struct RingHealth {
        var playing = false, scrubbing = false, settling = false, eof = false
        var eafErrored = false, hasHandle = false
        var readFrame: Double = 0
        var ringStart: Int64 = 0, ringEnd: Int64 = 0
        var filled = 0, readerIters = 0, underruns = 0
        var momentum: Double = 1
    }

    func ringHealth() -> RingHealth {
        lock.lock(); defer { lock.unlock() }
        var h = RingHealth()
        h.playing = st.playing; h.scrubbing = st.scrubbing; h.settling = st.settling; h.eof = st.eof
        h.eafErrored = eafErrored; h.hasHandle = (eaf != nil || ff != nil)
        h.readFrame = st.readFrame; h.ringStart = ringStart; h.ringEnd = ringEndFrame
        h.filled = ringFilled; h.readerIters = readerIters; h.underruns = st.underrunsPub
        h.momentum = st.momentum
        return h
    }

    /// Reopen the decode handle in place, preserving transport position —
    /// the recovery path for a stalled reader. Known trigger: an in-flight
    /// ExtAudioFile read on a descriptor whose volume went away across
    /// sleep blocks in the kernel forever (no return, no error). The frozen
    /// thread is abandoned (one leaked thread beats a dead deck); a fresh
    /// handle + reader take over. Returns false when nothing can reopen
    /// (volume gone) — the caller must stop the transport and surface a
    /// notice instead of a ghost play.
    @discardableResult
    func recoverReader(reason: String) -> Bool {
        guard let url = loadedURL else { return false }
        if let opened = Self.openProvenEAF(url: url, fileSR: sampleRate, fallbackLen: fileFrames) {
            lock.lock()
            let center = Int64(max(0, min(st.readFrame, Double(opened.frames))))
            closeDecodeHandlesLocked()
            eaf = opened.handle
            eafErrored = false
            fileFrames = opened.frames
            mk_at_store_i64(&fileFramesAt, opened.frames)
            channels = 2
            st.eof = false
            st.readFrame = Double(center)
            resetRingLocked(center)
            lock.unlock()
            startReader()
            kickReader()
            MKLog.engine("reader recovered (\(reason)) — EAF reopened at \(center) for \(url.lastPathComponent)")
            return true
        }
        var sr: Double = 0
        var frames: Int64 = 0
        if let c = url.path.cString(using: .utf8),
           let h = mk_ff_open(c, &sr, &frames), h != OpaquePointer(bitPattern: 0) {
            lock.lock()
            let len = frames > 0 ? frames : (Int64.max / 4)
            let center = Int64(max(0, min(st.readFrame, Double(len))))
            closeDecodeHandlesLocked()
            ff = FFHandle(h)
            eafErrored = false
            fileFrames = len
            mk_at_store_i64(&fileFramesAt, len)
            if sr > 0 { sampleRate = sr }
            channels = 2
            st.eof = false
            st.readFrame = Double(center)
            resetRingLocked(center)
            lock.unlock()
            startReader()
            kickReader()
            MKLog.engine("reader recovered (\(reason)) — FFmpeg reopened at \(center)")
            return true
        }
        MKLog.engine("reader recovery FAILED (\(reason)) — no decoder for \(url.path)")
        return false
    }

    /// Probe hook: simulate the frozen-reader failure — kill the
    /// thread and empty the ring ahead of the cursor so the deck parks on
    /// the next render. The real trigger (a reader blocked in kernel I/O on
    /// a stale descriptor) can't be synthesized portably.
    func stallTestFreeze() {
        lock.lock()
        readerGeneration += 1
        let pos = Int64(max(0, min(st.readFrame, Double(fileFrames))))
        resetRingLocked(pos)
        lock.unlock()
        readerSem.signal()
        readerThread = nil
    }

    /// Release whichever decode handle is live (lock held) — ARC disposes
    /// when the last holder (a possibly mid-read, superseded reader) lets
    /// go, so releasing here can never yank a handle out from under I/O.
    /// The FFmpeg handle being freshly opened by load(url:) is preserved by
    /// the caller.
    private func closeDecodeHandlesLocked(keepFF: Bool = false) {
        eaf = nil
        if !keepFF { ff = nil }
    }

    func unload() {
        lock.lock()
        closeDecodeHandlesLocked()
        freshStateLocked()
        // no next track: zero the length mirror too so hot-path clamps die
        mk_at_store_i64(&fileFramesAt, 0)
        fileFrames = 0
        ringFilled = 0
        if let s = stouch { mk_stouch_destroy(s) }
        stouch = nil
        stEngaged = false
        loadedURL = nil
        loopSuspended = false   // preview suspension can't outlive its track
        lock.unlock()
        stopReader()
    }

    // MARK: - Control API (any thread)

    func setPlaying(_ playing: Bool) {
        lock.lock()
        if playing {
            st.eof = false
            if st.readFrame >= Double(fileFrames) {
                st.readFrame = 0
                resetRingLocked(0)
            }
            // One-shot play-start latency probe (host µs) —
            // renderLinear logs the elapsed at the first successful frame
            playStartHostUs = Int64(CFAbsoluteTimeGetCurrent() * 1e6)
            firstFrameLogged = false
        } else {
            st.momentum = 1
            st.momentumToZero = false
        }
        st.playing = playing
        lock.unlock()
        kickReader()
    }

    /// Instant position write — THE seek. A target inside the
    /// ring's filled span costs NOTHING (no reset, no decode wait).
    /// Also lands in the atomic mirror — a seek racing an active
    /// grab must not leave the display pinned to the pre-seek target.
    func seek(toFrame f: Int64) {
        lock.lock()
        let clamped = max(0, min(f, fileFrames))
        st.readFrame = Double(clamped)
        st.eof = false
        if clamped < ringStart || clamped >= ringEndFrame {
            resetRingLocked(clamped)
            lock.unlock()
            mk_at_store_i64(&scrubTargetAt, clamped)
            kickReader()
            return
        }
        lock.unlock()
        mk_at_store_i64(&scrubTargetAt, clamped)
        mk_at_store_i8(&seekLiveAt, 1)   // display pins to target
    }

    func setBaseRate(_ r: Double) {
        lock.lock(); st.baseRate = max(1.0 / 32.0, min(8.0, r)); lock.unlock()
    }

    /// User key shift + keylock mode.
    func setPitch(semitones: Double, keylock: Bool) {
        lock.lock()
        st.userPitchSemitones = max(-24, min(24, semitones))
        st.keylock = keylock
        pitchFactor = pow(2.0, st.userPitchSemitones / 12.0)
        lock.unlock()
    }

    func setMomentum(_ m: Double, toZero: Bool) {
        lock.lock(); st.momentum = m; st.momentumToZero = toZero; lock.unlock()
    }

    /// Grab: the cursor owns the position; audio chases to a stop.
    func scrubBegin() {
        lock.lock()
        st.scrubbing = true
        st.settling = false
        st.chaseRate = 0
        let anchor = Int64(st.readFrame)   // grab anchors at the read position
        lock.unlock()
        mk_at_store_i64(&scrubTargetAt, anchor)
        mk_at_store_i8(&scrubbingAt, 1)
        mk_at_store_i64(&scrubMoveHostAt, Int64(CFAbsoluteTimeGetCurrent() * 1e6))
    }

    /// THE hot path (every mouse-move during a drag): wait-free —
    /// atomics ONLY (no lock, no queue hop), safe to call directly from the
    /// UI gesture thread. The locked st.scrubTarget mirror is deliberately
    /// not written here — the render reads the atomics;
    /// begin/end/load keep the mirror fresh for snapshots.
    func scrubSet(targetFrame: Int64) {
        let len = mk_at_load_i64(&fileFramesAt)
        let clamped = max(0, min(targetFrame, len))
        mk_at_store_i64(&scrubTargetAt, clamped)
        mk_at_store_i8(&scrubbingAt, 1)
        mk_at_store_i64(&scrubMoveHostAt, Int64(CFAbsoluteTimeGetCurrent() * 1e6))
    }

    /// Release with throw: velocity (file-frames/s) × fling gain → momentum
    /// decaying to base rate (playing) or zero (paused) — deck-side timer.
    /// The record is under the finger. If the chase lagged the
    /// cursor (a fast scrub can outrun even the scrub-aware refill), snap
    /// the read position to the cursor BEFORE the throw — release always
    /// starts from where the user let go, never from a stalled ring edge.
    func scrubEnd(velocityFramesPerSec v: Double) {
        let target = mk_at_load_i64(&scrubTargetAt)
        lock.lock()
        let lag = target - Int64(st.readFrame)
        // Momentum = the release rate as a playback-rate
        // multiplier — signed (backward throws legally play in reverse,
        // decaying through 0 back to the transport rate), clamped to the
        // audible/sustainable range (beyond ±8× the refill parks into
        // silence, which reads as a weak throw). Stationary release = the
        // platter resumes transport promptly.
        let rate = v / sampleRate
        if abs(rate) < 0.15 {
            st.momentum = st.playing ? 1 : 0
        } else {
            st.momentum = max(-8, min(8, rate))
        }
        st.momentumToZero = !st.playing
        // Settle: release no longer hard-seeks — the platter FINISHES
        // the trip to the frozen cursor and the release completes when the
        // audio arrives (the display unpins exactly then: nothing to see
        // jump). scrubbing stays live until updateChaseLocked lands; the
        // hard seek survives only as the starve fallback there.
        if abs(lag) > 1024 {
            st.settling = true
            st.settleStartHost = CFAbsoluteTimeGetCurrent()
        } else {
            st.scrubbing = false
            st.settling = false
        }
        let arrived = !st.settling
        lock.unlock()
        if arrived { mk_at_store_i8(&scrubbingAt, 0) }
    }

    func scrubCancel() {
        mk_at_store_i8(&scrubbingAt, 0)
        lock.lock()
        st.scrubbing = false
        st.settling = false
        st.momentum = 1
        st.momentumToZero = false
        lock.unlock()
    }

    /// Whether a settle starved out since the last poll (logged by the
    /// deck's poll timer — the render thread only sets the flag).
    var consumeSettleStarved: Bool {
        lock.lock(); defer { lock.unlock() }
        let v = settleStarvedFlag
        settleStarvedFlag = false
        return v
    }

    /// Seconds since the last gesture write (liveness for the
    /// leaked-grab detector; 0 when nothing has ever touched the deck).
    var scrubIdleSeconds: Double {
        let last = Double(mk_at_load_i64(&scrubMoveHostAt))
        return last > 0 ? CFAbsoluteTimeGetCurrent() - last / 1e6 : 0
    }

    /// Every fresh State() must also reset the gesture atomics —
    /// a leaked scrubbing=1 would otherwise pin displayFrame to a stale
    /// target forever on the NEXT track. fileFrames is set before the call.
    private func resetScrubAtomicsLocked() {
        mk_at_store_i64(&scrubTargetAt, 0)
        mk_at_store_i8(&scrubbingAt, 0)
        mk_at_store_i64(&scrubMoveHostAt, 0)
        mk_at_store_i64(&fileFramesAt, fileFrames)
    }

    func setLoop(start: Int64, end: Int64) {
        lock.lock(); st.loopStart = start; st.loopEnd = end; lock.unlock()
    }

    /// While a cue preview runs, the wrap is SUSPENDED — the
    /// preview plays from the cue through an armed span without capture;
    /// the loop re-arms the moment the preview ends (release or latch).
    private var loopSuspended = false

    func setLoopSuspend(_ on: Bool) {
        lock.lock(); loopSuspended = on; lock.unlock()
    }

    func clearLoop() {
        lock.lock(); st.loopStart = -1; st.loopEnd = -1; lock.unlock()
    }

    // MARK: - Ring (lock held)

    private func resetRingLocked(_ at: Int64) {
        ringStart = at
        ringFilled = 0
        st.epoch &+= 1
    }

    private var ringEndFrame: Int64 { ringStart + Int64(ringFilled) }

    private func sample(channel: Int, frame: Int64) -> Float {
        let i = Int(frame - ringStart)
        guard i >= 0, i < ringFilled else { return 0 }
        return ring[channel * ringFrames + i]
    }

    // MARK: - Reader thread

    private func startReader() {
        stopReader()   // bump generation: any in-flight reader dies at its next guard
        lock.lock()
        readerGeneration += 1
        let gen = readerGeneration
        lock.unlock()
        let t = Thread { [weak self] in
            guard let self else { return }
            Self.readerCountLock.lock(); Self.liveReaderCount += 1; Self.readerCountLock.unlock()
            self.readerLoop(generation: gen)
            Self.readerCountLock.lock(); Self.liveReaderCount -= 1; Self.readerCountLock.unlock()
        }
        t.name = "mkdj.pulldeck.reader"
        t.stackSize = 1 << 19
        t.start()
        readerThread = t
    }

    private func stopReader() {
        lock.lock(); readerGeneration += 1; lock.unlock()
        readerSem.signal()
        readerThread = nil
    }

    private func kickReader() { readerSem.signal() }

    /// Live analysis tap. Called on
    /// the READER thread with a copy of channel 0 right after each ring
    /// commit — the LiveBeatDetector converges while the track plays.
    var chunkObserver: ((UnsafePointer<Float>, Int, Double) -> Void)?
    private var observerScratch = [Float](repeating: 0, count: 16384)

    private func readerLoop(generation gen: Int) {
        let chunk = Self.chunkFrames
        while true {
            // Timed wait: kicks (seek/load) wake instantly; otherwise poll at
            // 250 Hz so the ring TOPS UP continuously while playing.
            _ = readerSem.wait(timeout: .now() + 0.004)
            lock.lock()
            if readerGeneration != gen {
                lock.unlock()
                MKLog.engine("reader: generation \(gen) superseded — exiting")
                return
            }
            if eaf == nil && ff == nil { lock.unlock(); return }
            readerIters += 1   // watchdog heartbeat
            // Capture the decode handle + length under the lock
            // so a track swap can't inject a shorter file under a stale writeAt.
            // The boxed handle keeps the raw ref alive for the whole iteration
            // even if a concurrent load swaps the deck to a new file.
            let eafBox = eaf
            let fLen = fileFrames
            let ffBox = ff
            let epoch = st.epoch
            // While a grab is live, fill AROUND the cursor — ahead
            // for the ±32 chase, behind for reverse scrub. The old forward-
            // only fill from the lagging readFrame made fast scrubs park at
            // the ring edge (display pinned to the cursor, audio stalled).
            let scrubbing = mk_at_load_i8(&scrubbingAt) != 0
            let center = scrubbing ? mk_at_load_i64(&scrubTargetAt) : Int64(st.readFrame)
            let active = st.playing || scrubbing
            let ahead = scrubbing ? 6.0 : (active ? 4.0 : 0.2)
            let behind = scrubbing ? 2.0 : 0.0
            let sr = sampleRate
            let chans = channels
            lock.unlock()

            let fillUntil = center + Int64(ahead * sr)
            let wantStart = max(0, center - Int64(behind * sr))

            while true {
                lock.lock()
                if readerGeneration != gen || (eaf == nil && ff == nil) || st.epoch != epoch {
                    lock.unlock(); break
                }
                if ringFilled == 0 {
                    ringStart = wantStart
                } else if wantStart < ringStart || ringEndFrame < wantStart {
                    // The ring can't serve the window around the center:
                    // either it lacks the history behind the cursor (reverse
                    // scrub) or it lies entirely before the needed span.
                    // Recenter ONCE — after this, ringEnd == wantStart and
                    // the condition is false, so filling proceeds without
                    // discarding the chunks it just wrote.
                    ringStart = wantStart
                    ringFilled = 0
                } else if ringFilled >= ringFrames - chunk {
                    // Full: drop history before the center, keep the rest.
                    let drop = Int(min(Int64(ringFilled), Int64(center) - ringStart))
                    let keep = ringFilled - drop
                    if keep > 0 {
                        for c in 0..<chans {
                            memmove(ring + c * ringFrames,
                                    ring + c * ringFrames + drop,
                                    keep * MemoryLayout<Float>.size)
                        }
                    }
                    ringStart = Int64(center)
                    ringFilled = max(0, keep)
                }
                let space = ringFrames - ringFilled
                let take = min(chunk, space)
                let writeAt = ringEndFrame
                lock.unlock()
                if take <= 0 || writeAt >= fillUntil { break }
                if writeAt > fLen { break }   // never seek past the captured length
                var got = 0
                if let eafBox {
                    // Fence: never seek AT the length estimate of a
                    // CoreAudio-compressed file — decoder-edge territory. (The
                    // FFmpeg path keeps the looser bound: Vorbis files report
                    // no total frame count, EOF arrives via the read return.)
                    if writeAt >= fLen { break }
                    var framesRead: Int64 = 0
                    let list = UnsafeMutableAudioBufferListPointer(readListPtr)
                    readScratch.withUnsafeMutableBufferPointer { scratch in
                        let base = scratch.baseAddress!
                        list[0].mData = UnsafeMutableRawPointer(base)
                        list[1].mData = UnsafeMutableRawPointer(base + chunk)
                        list[0].mDataByteSize = UInt32(take) * 4
                        list[1].mDataByteSize = UInt32(take) * 4
                        let seekStatus = ExtAudioFileSeek(eafBox.ref, writeAt)
                        guard seekStatus == noErr else {
                            if !eafErrored {
                                eafErrored = true
                                MKLog.engine(String(format: "reader: ExtAudio seek err %d at %d/%d",
                                                     seekStatus, writeAt, fLen))
                            }
                            return
                        }
                        var n = UInt32(take)
                        let readStatus = ExtAudioFileRead(eafBox.ref, &n, readListPtr)
                        guard readStatus == noErr else {
                            if !eafErrored {
                                eafErrored = true
                                MKLog.engine(String(format: "reader: ExtAudio read err %d at %d/%d",
                                                     readStatus, writeAt, fLen))
                            }
                            return
                        }
                        framesRead = Int64(n)
                    }
                    guard framesRead > 0 else { break }
                    got = Int(framesRead)
                    lock.lock()
                    if readerGeneration != gen || st.epoch != epoch || ringEndFrame != writeAt {
                        lock.unlock(); break
                    }
                    for c in 0..<chans {
                        let src = readScratch.withUnsafeBufferPointer { $0.baseAddress! + c * chunk }
                        memcpy(ring + c * ringFrames + ringFilled, src,
                               got * MemoryLayout<Float>.size)
                    }
                    ringFilled += got
                    // The observer gets the JUST-COMMITTED chunk
                    // (ring tail), not ring[0] (the oldest buffered audio) —
                    // the stale feed made the live detector converge on a
                    // repeated window. Copy under the lock (the region becomes
                    // movable after), observe outside it.
                    var observe: ((UnsafePointer<Float>, Int, Double) -> Void)?
                    var observeCount = 0
                    let observeSR = sampleRate
                    if let obs = chunkObserver, got <= observerScratch.count {
                        observerScratch.withUnsafeMutableBufferPointer { sp in
                            memcpy(sp.baseAddress!, ring + (ringFilled - got),
                                   got * MemoryLayout<Float>.size)
                        }
                        observe = obs
                        observeCount = got
                    }
                    lock.unlock()
                    if let obs = observe {
                        observerScratch.withUnsafeMutableBufferPointer { sp in
                            obs(sp.baseAddress!, observeCount, observeSR)
                        }
                    }
                } else if let ffBox {
                    // FFmpeg path: read planar stereo into the scratch
                    let n = ffScratch.withUnsafeMutableBufferPointer { raw in
                        mk_ff_read(ffBox.ref, writeAt, Int64(take),
                                    raw.baseAddress!, raw.baseAddress! + take)
                    }
                    if n <= 0 {
                        // decode exhausted at the read position — for
                        // sentinel-length files (no duration metadata) this
                        // is the ONLY end-of-track signal
                        lock.lock()
                        if !st.scrubbing { st.eof = true }
                        lock.unlock()
                        break
                    }
                    got = Int(n)
                    lock.lock()
                    if readerGeneration != gen || st.epoch != epoch || ringEndFrame != writeAt {
                        lock.unlock(); break
                    }
                    ffScratch.withUnsafeMutableBufferPointer { raw in
                        for c in 0..<chans {
                            memcpy(ring + c * ringFrames + ringFilled,
                                   raw.baseAddress! + c * take,
                                   got * MemoryLayout<Float>.size)
                        }
                    }
                    ringFilled += got
                    // same live-tap contract as the EAF path (ogg/opus
                    // tracks used to get no live detection at all)
                    var observe: ((UnsafePointer<Float>, Int, Double) -> Void)?
                    var observeCount = 0
                    let observeSR = sampleRate
                    if let obs = chunkObserver, got <= observerScratch.count {
                        observerScratch.withUnsafeMutableBufferPointer { sp in
                            memcpy(sp.baseAddress!, ring + (ringFilled - got),
                                   got * MemoryLayout<Float>.size)
                        }
                        observe = obs
                        observeCount = got
                    }
                    lock.unlock()
                    if let obs = observe {
                        observerScratch.withUnsafeMutableBufferPointer { sp in
                            obs(sp.baseAddress!, observeCount, observeSR)
                        }
                    }
                } else {
                    break
                }
            }
        }
    }

    // MARK: - Render (source-node block; render thread)

    /// Two paths: VINYL (linear resample at rate × 2^(pitch/12) —
    /// pitch follows speed; instant; scrub/throw/keylock-off) and KEYLOCK
    /// (steady playback with keylock on: SoundTouch in-render, independent
    /// tempo/pitch, ~92 ms latency, bypassed during manipulation).
    func render(into abl: UnsafeMutableAudioBufferListPointer, frames: AVAudioFrameCount) {
        lock.lock()
        updateChaseLocked()
        let rate = effectiveRateLocked()
        // Pre-callback display frame for the anchor (captured
        // BEFORE this callback advances the read position)
        anchorPreFrame = outputThroughStretcher
            ? max(0, Int64(st.readFrame) - stLatencyFrames)
            : Int64(st.readFrame)
        let userPitch = st.userPitchSemitones
        let keylock = st.keylock
        // Symmetric with the gesture hot path — atomic scrubbing.
        let settled = mk_at_load_i8(&scrubbingAt) == 0
            && abs(st.momentum - 1.0) < 0.01 && st.playing
        let useStretcher = keylock && settled && stouch != nil && !st.eof
        // A suspended wrap (cue preview) renders as loopless —
        // the bounds stay armed and return the instant the preview ends.
        let loopStart = loopSuspended ? -1 : st.loopStart
        let loopEnd = loopSuspended ? -1 : st.loopEnd
        let fileEnd = fileFrames
        let n = Int(frames)
        lock.unlock()

        if abs(rate - lastRate) > 0.5 {
            fadeEnv = 0
            fadeRamp = 1 / Self.fadeFrames
        }
        lastRate = rate

        guard abs(rate) > 1e-4 || useStretcher else {
            for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
            fadeEnv = 0
            outputThroughStretcher = false
            publishDisplayAnchor(rate: 0)
            return
        }

        if !useStretcher {
            outputThroughStretcher = false
            let readRate = rate * pitchFactor
            renderLinear(abl: abl, n: n, readRate: readRate,
                         loopStart: loopStart, loopEnd: loopEnd, fileEnd: fileEnd)
            publishDisplayAnchor(rate: rate)
            return
        }
        renderKeylock(abl: abl, n: n, rate: rate, pitch: userPitch,
                      loopStart: loopStart, loopEnd: loopEnd, fileEnd: fileEnd)
        publishDisplayAnchor(rate: rate)
    }

    /// The vinyl path — linear resample with fractional interpolation,
    /// park-on-underrun, loop wrap, EOF.
    private func renderLinear(abl: UnsafeMutableAudioBufferListPointer, n: Int,
                              readRate: Double, loopStart: Int64, loopEnd: Int64,
                              fileEnd: Int64) {
        // Writes go straight into the abl planes — an interleaved
        // `wrote` array would be a heap allocation on the render
        // thread every block. Fade ramp is hoisted out of the sample loop.
        let planeCount = min(2, abl.count)
        var planes = [UnsafeMutablePointer<Float>?](repeating: nil, count: 2)
        for bi in 0..<planeCount {
            planes[bi] = abl[bi].mData!.assumingMemoryBound(to: Float.self)
        }
        lock.lock()
        var pos = st.readFrame
        var eofHit = false
        var renderN = n
        if readRate >= 0 {
            // forward: park before the ring's filled end
            let span = pos + readRate * Double(n)
            let availEnd = Double(ringEndFrame)
            if span > availEnd {
                let framesAvail = max(0, Int((availEnd - pos) / max(readRate, 1e-9)))
                if framesAvail < n {
                    renderN = framesAvail
                }
            }
        } else {
            // Reverse rates consumed past the ring's START used to
            // emit silent zeros with no underrun accounting (the span check
            // was forward-only). Park + kick like the forward case.
            let span = pos + readRate * Double(n)
            if span < Double(ringStart) {
                let framesAvail = max(0, Int((Double(ringStart) - pos) / max(-readRate, 1e-9)))
                renderN = framesAvail
            }
        }
        if renderN <= 0 {
            st.underrunsPub &+= 1
            lock.unlock()
            for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
            kickReader()
            return
        }
        if !firstFrameLogged {
            firstFrameLogged = true
            let elapsedMs = Double(Int64(CFAbsoluteTimeGetCurrent() * 1e6) - playStartHostUs) / 1000
            MKLog.engine(String(format: "first-play frame: %.1f ms after PLAY", elapsedMs))
        }
        var g = min(1, fadeEnv)
        for i in 0..<renderN {
            let idx = Int64(pos)
            let frac = Float(pos - Double(idx))
            for c in 0..<2 {
                let a = sample(channel: c, frame: idx)
                let b = sample(channel: c, frame: idx + 1)
                planes[c]![i] = (a + (b - a) * frac) * g
            }
            g = min(1, g + fadeRamp)
            fadeEnv = g
            pos += readRate
            if loopEnd > 0, pos >= Double(loopEnd) {
                pos = Double(loopStart) + (pos - Double(loopEnd))
            } else if pos >= Double(fileEnd) {
                pos = Double(fileEnd)
                eofHit = true
            } else if pos < 0 {
                pos = 0   // reverse past the track head clamps
            }
        }
        st.readFrame = pos
        if eofHit && !st.scrubbing {
            st.eof = true
            st.playing = false
        }
        lock.unlock()

        if renderN < n {
            for bi in 0..<planeCount {
                memset(planes[bi]! + renderN, 0, (n - renderN) * MemoryLayout<Float>.size)
            }
        }
    }

    /// The keylock path — SoundTouch in-render (independent tempo/pitch).
    private func renderKeylock(abl: UnsafeMutableAudioBufferListPointer, n: Int,
                               rate: Double, pitch: Double,
                               loopStart: Int64, loopEnd: Int64, fileEnd: Int64) {
        outputThroughStretcher = true
        if !stEngaged {
            if let s = stouch { mk_stouch_reset(s) }
            if scratchIn.isEmpty { scratchIn = [Float](repeating: 0, count: Self.chunkFrames * 2) }
            if scratchOut.isEmpty { scratchOut = [Float](repeating: 0, count: 8192 * 2) }
            stEngaged = true
        }
        lock.lock()
        var pos = st.readFrame
        let inputNeeded = min(16384, Int((Double(n) * rate).rounded(.up)) + 2)
        if inputNeeded <= 0 || Int64(pos) + Int64(inputNeeded) > ringEndFrame {
            st.underrunsPub &+= 1
            lock.unlock()
            for b in abl { memset(b.mData, 0, Int(b.mDataByteSize)) }
            kickReader()
            return
        }
        let ringBase = Int(pos - Double(ringStart))
        for c in 0..<channels {
            let src = ring + c * ringFrames + ringBase
            for i in 0..<inputNeeded {
                scratchIn[c * inputNeeded + i] = src[i]
            }
        }
        var stIn: [UnsafePointer<Float>?] = (0..<channels).map { c in
            UnsafePointer(scratchIn.withUnsafeBufferPointer { $0.baseAddress! + c * inputNeeded })
        }
        var stOut: [UnsafeMutablePointer<Float>?] = (0..<channels).map { c in
            scratchOut.withUnsafeMutableBufferPointer { $0.baseAddress! + c * 8192 }
        }
        var got = 0
        stIn.withUnsafeBufferPointer { inBuf in
            stOut.withUnsafeMutableBufferPointer { outBuf in
                if let s = stouch {
                    mk_stouch_set_tempo(s, rate)
                    mk_stouch_set_pitch_semitones(s, pitch)
                    mk_stouch_put(s, inBuf.baseAddress!, Int32(inputNeeded))
                    got = Int(mk_stouch_receive(s, outBuf.baseAddress!, Int32(n)))
                }
            }
        }
        pos += Double(inputNeeded - 2)
        var eofHit = false
        if loopEnd > 0, pos >= Double(loopEnd) {
            pos = Double(loopStart) + (pos - Double(loopEnd))
        } else if pos >= Double(fileEnd) {
            pos = Double(fileEnd)
            eofHit = true
        }
        st.readFrame = pos
        lock.unlock()

        // EOF: drain the stretcher tail once, then declare EOF.
        if eofHit {
            stTail.withUnsafeMutableBufferPointer { tail in
                var ptrs: [UnsafeMutablePointer<Float>?] = [
                    tail.baseAddress, tail.baseAddress! + 1024
                ]
                ptrs.withUnsafeMutableBufferPointer { tp in
                    if let s = stouch { _ = mk_stouch_flush(s, tp.baseAddress!, 1024) }
                }
            }
            lock.lock()
            st.eof = true
            st.playing = false
            lock.unlock()
        }

        for (bi, b) in abl.enumerated() {
            let dst = b.mData!.assumingMemoryBound(to: Float.self)
            let cnt = min(Int(b.mDataByteSize) / MemoryLayout<Float>.size, n)
            var g = min(1, fadeEnv)
            for i in 0..<cnt {
                let s = i < got ? scratchOut[min(bi, channels - 1) * 8192 + i] : 0
                dst[i] = s * g
                g = min(1, g + fadeRamp)
            }
            fadeEnv = g
        }
    }
}
