import Foundation

/// Genre BPM-range presets with octave/triplet projection (a reference DJ
/// player's pattern) — a BPM already in range WINS outright; otherwise
/// ×(½,⅔,1½,2) candidates compete by distance to the range midpoint.
/// Covers the classic half-time DnB (174→87) and triplet Psy (146→97.7)
/// estimator errors without touching in-range results.
enum BPMGenrePreset: String, CaseIterable {
    case universal, house, dnb, hipHop, psy, disco

    var range: ClosedRange<Double> {
        switch self {
        case .universal: return 75...185
        case .house: return 115...135
        case .dnb: return 140...185
        case .hipHop: return 75...110
        case .psy: return 135...165
        case .disco: return 105...130
        }
    }

    var displayName: String {
        switch self {
        case .universal: return "Universal (75–185)"
        case .house: return "House (115–135)"
        case .dnb: return "DnB (140–185)"
        case .hipHop: return "HipHop (75–110)"
        case .psy: return "Psy-Trance (135–165)"
        case .disco: return "Disco (105–130)"
        }
    }

    static func corrected(_ bpm: Double, genre raw: String) -> Double {
        let preset = BPMGenrePreset(rawValue: raw) ?? .universal
        return projected(bpm, into: preset.range)
    }

    /// The projection's range comes from the user's detection
    /// inputs (single source of truth) — same rule: in-range wins outright,
    /// else ×(½,⅔,1½,2) compete by distance to the range midpoint.
    static func projected(_ bpm: Double, into r: ClosedRange<Double>) -> Double {
        guard bpm > 0, !r.contains(bpm) else { return bpm }
        let factors: [Double] = [0.5, 2.0 / 3.0, 1.5, 2.0]
        let candidates = factors.map { bpm * $0 }.filter { r.contains($0) }
        guard !candidates.isEmpty else { return bpm }
        let target = (r.lowerBound + r.upperBound) / 2
        return candidates.min(by: { abs($0 - target) < abs($1 - target) }) ?? bpm
    }
}

/// Grid anchor derivation: median beat phase from the tracker's
/// beatTimes, resolved to the earliest tracked beat carrying that phase —
/// a musically sane anchor near the track start.
enum GridMath {

    /// Returns the anchor in seconds, or nil when there aren't enough beats.
    static func anchor(beatTimes: [Double], bpm: Double) -> Double? {
        guard beatTimes.count >= 4, bpm > 20, bpm < 400 else { return nil }
        let period = 60.0 / bpm
        let twoPi = 2.0 * Double.pi

        // Circular mean phase via vector sum (robust against phase wrap).
        var sx = 0.0, sy = 0.0
        for t in beatTimes {
            let a = fmod(t, period) / period * twoPi
            sx += cos(a)
            sy += sin(a)
        }
        guard sx * sx + sy * sy > 0.01 else { return nil }   // beats scatter across phases
        var phase = atan2(sy, sx) / twoPi * period
        if phase < 0 { phase += period }

        // Earliest tracked beat within 20% of the period of that phase.
        let tolerance = period * 0.2
        func circularDelta(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b)
            if d > period / 2 { d = period - d }
            return d
        }
        return beatTimes
            .filter { circularDelta(fmod($0, period), phase) < tolerance }
            .min() ?? beatTimes[0]
    }

    /// Distinct tempo clusters covering ≥ 15% of analyzed time → multi-tempo.
    static func isMultiTempo(_ segments: [SegmentInfo]) -> Bool {
        let clusters = BPMEngine.tempoClusters(segments)
        let total = clusters.map({ $0.duration }).reduce(0, +)
        guard total > 0 else { return false }
        return clusters.filter { $0.duration / total >= 0.15 }.count > 1
    }
}

/// Background analysis orchestrator: one decode per track feeding
/// both the peak pyramid and the BPMPLS verdict; results cached and applied
/// to the deck model on the main actor. Tasks are cancellable on track change.
@MainActor
final class AnalysisService {

    static let shared = AnalysisService()
    private init() {}

    /// In-flight dedup (a reference DJ player's waveform-cache pattern):
    /// two loads of the same URL share one decode task; partial observers
    /// fan out to every interested deck.
    private var inflight: [String: Task<Void, Never>] = [:]

    /// `force`: recompute with MKDJ's own analyzer even when a cache entry
    /// exists (the MKDJ-BPM button) — the fresh result still replaces it.

    /// v3 verdict — ONE ENGINE: tempogram hints (low + fused,
    /// z-scored × Ellis prior), the DP's onset-path measurement DECIDES,
    /// the user's detection range octave-FOLDS the result. Pure w.r.t.
    /// the envelope inputs; --filebpm runs the same code.
    nonisolated static func v3Verdict(v2: GridEstimator.Result,
                          bands: (fused: [Float], low: [Float], high: [Float],
                                  rms: [Float], times: [Double]),
                          samples: [Float], sr: Double)
        -> (bpm: Double, beats: [Double], conf: Double, tag: String) {
        var hints: [Double] = []
        if !v2.noBeatFound && v2.bpm > 0 { hints.append(v2.bpm) }
        for stream in [bands.low, v2.env] {
            let cands = GridEstimator.candidates(env: stream, times: bands.times,
                                                 minBPM: 70, maxBPM: 200)
            let ranked = cands.map { c -> (Double, Double) in
                let z = GridEstimator.zSupport(bpm: c, env: stream, times: bands.times).z
                return (c, z * GridEstimator.ellisPrior(c))
            }.sorted { $0.1 > $1.1 }
            for (c, _) in ranked.prefix(4)
            where !hints.contains(where: { abs($0 - c) / c < 0.03 }) {
                hints.append(c)
            }
        }
        let envMean = v2.env.isEmpty ? 0 : Double(v2.env.reduce(0, +)) / Double(v2.env.count)
        var bestTrack: GridTracker.TrackResult?
        var bestScore = -1.0
        for h in hints {
            guard let t = GridTracker.track(env: v2.env, times: v2.times, bpmHint: h),
                  t.beatTimes.count > 32 else { continue }
            let sv = GridEstimator.support(beats: t.beatTimes, env: v2.env,
                                           times: v2.times, envMean: envMean)
                * max(0.2, t.confidence)
            if sv > bestScore { bestScore = sv; bestTrack = t }
        }
        guard let t = bestTrack else {
            if !v2.noBeatFound {
                return (v2.bpm, v2.beatTimes, v2.confidence, "v2-grid")
            }
            MKLog.engine(String(format: "analysis: v3 abstain — v2 gate-fail (bpm %.2f, conf %.2f), %d hints, none tracked past 32 beats",
                                v2.bpm, v2.confidence, hints.count))
            return (0, [], 0, "none")
        }
        // The DP's REPORTED tempo can drift ~1.5% from its own path (the
        // Ace-of-Base case: reported 184.57, path LSQ 187.49 → truth 93.7).
        // The beats are onset-snapped and precise — fit a least-squares
        // slope over the whole path and use THAT as the tempo.
        var bpm = t.bpm
        if t.beatTimes.count > 64 {
            let n = Double(t.beatTimes.count)
            let xs = (0..<t.beatTimes.count).map(Double.init)
            let mx = xs.reduce(0, +) / n
            let my = t.beatTimes.reduce(0, +) / n
            var num = 0.0, den = 0.0
            for i in 0..<t.beatTimes.count {
                num += (xs[i] - mx) * (t.beatTimes[i] - my)
                den += (xs[i] - mx) * (xs[i] - mx)
            }
            if den > 0 {
                let lsq = 60.0 / (num / den)
                // sanity: the LSQ fit must agree with the reported tempo at
                // the octave level (same path!) — guards against pathological
                // fits (missing-beat runs skewing the slope)
                let half = min(abs(lsq - t.bpm), abs(lsq / 2 - t.bpm), abs(lsq * 2 - t.bpm))
                if half / t.bpm < 0.03 { bpm = lsq }
            }
        }
        let ud = UserDefaults.standard
        let lo = ud.object(forKey: "minBPM") as? Double ?? 70
        let hi = ud.object(forKey: "maxBPM") as? Double ?? 180
        while bpm > hi && bpm / 2 > lo * 0.9 { bpm /= 2 }
        while bpm < lo && bpm * 2 < hi * 1.1 { bpm *= 2 }
        var beats: [Double] = []
        if let t0 = v2.times.first, let t1 = v2.times.last {
            let phase = GridEstimator.bestPhase(bpm: bpm, env: v2.env, times: v2.times)
            var grid = GridEstimator.gridTimes(bpm: bpm, phase: phase, from: t0, to: t1)
            grid = GridEstimator.sampleRefine(grid, samples: samples, sr: sr)
            beats = grid
            let iv = GridEstimator.pairwise(grid)
            let med = iv.isEmpty ? 0 : GridEstimator.median(iv)
            if med > 0.2 && med < 1.5 {
                let refined = 60.0 / med
                if abs(refined - bpm) / bpm < 0.03 { bpm = refined }
            }
        }
        MKLog.engine(String(format: "analysis: v3 DP %.2f → fold/refine %.2f (%d beats, hints %@)",
                             t.bpm, bpm, beats.count,
                             hints.map { String(format: "%.0f", $0) }.joined(separator: "/")))
        return (bpm, beats, t.confidence, "v3")
    }

    /// Abstention ≠ contradiction: when the DP fails to produce a track
    /// ("none") the verdict falls back to the BPMPLS engine's reading —
    /// but only when that reading carries real support (confidence ≥ 0.5,
    /// BPMPLS's own LOW/MEDIUM boundary). The DP keeps its full authority
    /// when it actually decides; this only rescues its abstentions.
    nonisolated static func v1FallbackWanted(v3Tag: String, v1: BPMAnalysis) -> Bool {
        let confidenceFloor = 0.5
        return v3Tag == "none" && v1.bpm > 1 && v1.confidence >= confidenceFloor
    }

    func analyze(deck: DeckModel, url: URL, force: Bool = false) {
        // Dedup: if a decode for this URL is already running (e.g. a deck
        // was unloaded+reloaded quickly), don't start a second full decode —
        // the running task already applies to whichever deck asked last.
        let key = url.path
        if !force, let running = inflight[key] {
            deck.analysisTask = running
            return
        }
        deck.analysisTask?.cancel()
        deck.analysisTask = nil

        if !force, let cached = AnalysisCache.shared.load(url: url) {
            apply(cached, to: deck)
            return
        }

        deck.analysisState = .running
        let range = (AppSettings.shared.minBPM, AppSettings.shared.maxBPM)
        let solo = AppSettings.shared.analysisV2Solo   // captured off-MainActor

        let task = Task.detached(priority: .userInitiated) { [weak deck] in
            defer { Task { @MainActor in AnalysisService.shared.inflight[key] = nil } }
            do {
                try Task.checkCancellation()
                // Streaming decode — partial pyramids surface a
                // growing waveform on the lane while the analysis continues.
                var finalPeaks: PeakPyramid? = nil
                let (samples, sampleRate): ([Float], Double) = try BPMEngine.streamMonoSamples(url: url) { partial in
                    guard !Task.isCancelled else { return }
                    finalPeaks = partial   // each partial supersedes; the last is complete
                    Task { @MainActor [weak deck] in
                        guard let deck, deck.analysisState != .ready,
                              deck.peaks == nil else { return }
                        deck.peaks = partial
                    }
                }
                try Task.checkCancellation()
                // SOLO mode skips the BPMPLS tracker entirely —
                // GridEstimator alone, tagged "v2-solo" (also skips the
                // second STFT pass, so analysis is faster). The default
                // remains the two-measurement cross-check.
                let v2 = GridEstimator.estimate(samples: samples, sampleRate: sampleRate,
                                                minBPM: range.0, maxBPM: range.1)
                var finalBPM = 0.0
                var finalBeats: [Double] = []
                var finalConf = 0.0
                var analyzerTag = "none"
                var v1MultiTempo = false
                var sections: [GridEstimator.Section] = []
                do {
                    // ── v3: ONE ENGINE (solo/non-solo merged — the
                    // v1 tracker is decode-only now, so the fast toggle's
                    // reason to exist is gone). The tempogram ranks HINTS;
                    // the DP's onset-path measurement DECIDES; the user's
                    // detection range octave-FOLDS the verdict (the standard
                    // DJ-player BPM-range shape — a SEARCH bound, not a
                    // projector).
                    let bands = GridEstimator.onsetEnvelopeBands(samples: samples, sampleRate: sampleRate)
                    let v3 = Self.v3Verdict(v2: v2, bands: bands, samples: samples, sr: sampleRate)
                    finalBPM = v3.bpm
                    finalBeats = v3.beats
                    finalConf = v3.conf
                    analyzerTag = v3.tag
                    sections = v2.sections
                    if v3.tag == "none" {
                        // The DP abstained: the BPMPLS engine gets the last
                        // word when it is confident (abstention ≠
                        // contradiction). analyzeSamples re-checks
                        // cancellation internally.
                        if let v1 = try? BPMEngine.analyzeSamples(samples, sampleRate: sampleRate,
                                                                  url: url, minBPM: range.0, maxBPM: range.1),
                           Self.v1FallbackWanted(v3Tag: v3.tag, v1: v1) {
                            finalBPM = v1.bpm
                            finalBeats = v1.beatTimes
                            finalConf = v1.confidence
                            analyzerTag = "v1-fallback"
                            MKLog.engine(String(format: "analysis: v1-fallback %.2f BPM (conf %.2f) after v3 abstain",
                                                v1.bpm, v1.confidence))
                        }
                    }
                }
                let anchor = GridMath.anchor(beatTimes: finalBeats, bpm: finalBPM) ?? 0
                let cached = CachedAnalysis(
                    path: url.path,
                    mtime: 0, size: 0,   // informational; the key already encodes them
                    sampleRate: sampleRate,
                    analyzedSeconds: Double(samples.count) / sampleRate,
                    bpm: finalBPM,
                    anchorSeconds: anchor,
                    confidence: finalConf,
                    noBeatFound: solo ? v2.noBeatFound : (v2.noBeatFound && finalBPM <= 1),
                    multiTempo: v1MultiTempo
                        || sections.dropFirst().contains { abs($0.bpm - finalBPM) / finalBPM > 0.04 },
                    peaks: finalPeaks ?? PeakPyramid.build(samples: samples, sampleRate: sampleRate),
                    beatTimes: Array(finalBeats.prefix(2000)),
                    analyzer: analyzerTag,
                    sections: sections)
                AnalysisCache.shared.store(cached, url: url)

                guard let deck else { return }
                await MainActor.run { self.apply(cached, to: deck) }
            } catch is CancellationError {
                // deck changed under us; the new load runs its own analysis
            } catch {
                guard let deck else { return }
                let message = error.localizedDescription
                MKLog.engine("analysis failed for \(url.lastPathComponent) — \(message)")
                await MainActor.run {
                    deck.analysisState = .failed(message)
                }
            }
        }
        deck.analysisTask = task
        inflight[key] = task
    }

    private func apply(_ cached: CachedAnalysis, to deck: DeckModel) {
        deck.gridConfidence = cached.confidence
        deck.noBeatFound = cached.noBeatFound
        deck.multiTempo = cached.multiTempo
        deck.peaks = cached.peaks
        deck.analyzedBeatTimes = cached.beatTimes
        deck.analyzedSeconds = cached.analyzedSeconds
        if cached.noBeatFound || cached.bpm <= 1 {
            deck.baseBPM = nil
            deck.engine.clearGrid()
        } else {
            deck.applyGrid(bpm: cached.bpm, anchorSeconds: cached.anchorSeconds)
        }
        deck.sections = cached.sections ?? []
        deck.analyzer = cached.analyzer ?? "v1"
        deck.analysisState = .ready
    }
}
