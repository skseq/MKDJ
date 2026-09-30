import Foundation
import Accelerate

/// Native analysis v2 — pipeline structure borrowed from a stem-separation
/// tool studied earlier, no models:
///
/// 1. three one-pole band envelopes (low <200 Hz, mid, high >2 kHz); onset
///    flux per band; **median aggregation** across bands (a mean lets one
///    broadband event — cymbal wash, vinyl click — dominate; the median
///    suppresses it),
/// 2. tempo candidates from onset-envelope autocorrelation + interval
///    histogram, each verified against its 2×/½× variants by ONSET SUPPORT
///    under the implied grid — the explicit answer to the lognormal-prior
///    half-time failure (a 180 BPM track resolving to 90 with high
///    confidence, undetectable after the fact because a half-time grid has
///    a real hit under every beat),
/// 3. phase correction BEFORE refinement (snapping beats onto transients
///    only works if the grid is on the right half of the beat),
/// 4. per-beat refinement within ±0.15 beat; **BPM = median of refined
///    intervals** — never a tracker's raw tempo output,
/// 5. regularity gate → interior gap-fill → consistency, in that order,
/// 6. confidence = onset support under beats, measured BEFORE any grid
///    extension to track edges,
/// 7. sections: novelty curve (onset-density change points) → boundaries →
///    per-section tempo + energy-percentile labels.
enum GridEstimator {

    struct Section: Codable, Equatable {
        var startSeconds: Double
        var endSeconds: Double
        var bpm: Double
        var label: String   // quiet | mid | peak
    }

    struct Result {
        var bpm: Double
        var beatTimes: [Double]      // refined, ascending, within detected span
        var confidence: Double       // 0…1
        var noBeatFound: Bool
        var sections: [Section]
        /// The envelope is the expensive stage — estimate() returns it so
        /// the caller (arbitration) doesn't recompute the whole one-pole
        /// pass a second time.
        var env: [Float] = []
        var times: [Double] = []
    }

    // MARK: - Band envelopes + onset flux

    /// Median-aggregated onset envelope. Frame f covers samples
    /// [f*hop, f*hop+win). Also returns per-frame broadband RMS (sections
    /// labeling) and frame times.
    static func onsetEnvelope(samples: [Float], sampleRate sr: Double,
                              hop: Int = 1024, win: Int = 1024)
        -> (env: [Float], rms: [Float], times: [Double]) {
        let b = onsetEnvelopeBands(samples: samples, sampleRate: sr, hop: hop, win: win)
        return (b.fused, b.rms, b.times)
    }

    /// Per-band flux streams alongside the fused
    /// median. `low` = kick band (<200 Hz) — the DJ pulse; `high` =
    /// hats/shuffle band (>2 kHz) — where metrical RELATIVES of the true
    /// tempo live (the Ace-of-Base failure: the fused stream couldn't
    /// tell 93.1 from its ×8/9 and ×4/3 relatives; the bands can).
    static func onsetEnvelopeBands(samples: [Float], sampleRate sr: Double,
                                   hop: Int = 1024, win: Int = 1024)
        -> (fused: [Float], low: [Float], high: [Float], rms: [Float], times: [Double]) {
        let n = samples.count
        guard n > win else { return ([], [], [], [], []) }
        let frames = (n - win) / hop + 1
        var fused = [Float](repeating: 0, count: frames)
        var low = [Float](repeating: 0, count: frames)
        var high = [Float](repeating: 0, count: frames)
        var rms = [Float](repeating: 0, count: frames)
        var times = [Double](repeating: 0, count: frames)

        // One-pole states per band (low/mid/high), whole-signal continuity.
        var lp1: [Float] = [0, 0, 0]      // first-stage low-pass states
        var band: [Float] = [0, 0, 0]     // current band values
        let a1 = exp(-2.0 * Double.pi * 200.0 / sr)     // low edge
        let a2 = exp(-2.0 * Double.pi * 2000.0 / sr)    // high edge
        var prevEnergy = [Float](repeating: 0, count: 3)
        samples.withUnsafeBufferPointer { sp in
            let base = sp.baseAddress!
            var f = 0
            var i = 0
            while f < frames {
                var e = [Float](repeating: 0, count: 3)
                let end = min(n, i + win)
                var cnt = 0
                while i < end {
                    let x = base[i]
                    // three cascaded one-poles: low = deepest, mid = mid
                    // stage, high = residual
                    lp1[0] += (1 - Float(a1)) * (x - lp1[0])
                    lp1[1] += (1 - Float(a2)) * (lp1[0] - lp1[1])
                    band[0] = lp1[0]
                    band[1] = lp1[1] - lp1[0]
                    band[2] = x - lp1[1]
                    e[0] += band[0] * band[0]
                    e[1] += band[1] * band[1]
                    e[2] += band[2] * band[2]
                    i += 1
                    cnt += 1
                }
                let inv = 1 / Float(max(1, cnt))
                var flux = [Float](repeating: 0, count: 3)
                for b in 0..<3 {
                    let en = log(Float(1e-12) + e[b] * inv)
                    flux[b] = max(0, en - prevEnergy[b])
                    prevEnergy[b] = en
                }
                // MEDIAN across bands, not mean.
                fused[f] = max(flux[0], min(flux[1], flux[2]))
                low[f] = flux[0]
                high[f] = flux[2]
                rms[f] = sqrt(e[0] * inv + e[1] * inv + e[2] * inv)
                times[f] = Double(f * hop + win / 2) / sr
                f += 1
            }
        }
        return (fused, low, high, rms, times)
    }

    /// Autocorrelation candidates with metrical expansion — extracted
    /// from estimate() so the probe evidence dump and v3 share ONE
    /// generator (drift between them would be evidence-laundering).
    static func candidates(env: [Float], times: [Double],
                           minBPM: Double, maxBPM: Double) -> [Double] {
        guard env.count > 20, times.count > 1 else { return [] }
        let mean = Double(env.reduce(0, +)) / Double(env.count)
        let centered = env.map { Float(Double($0) - mean) }
        let frameRate = 1.0 / (times[1] - times[0])
        var cands: [Double] = []
        let minLag = max(2, Int(60.0 / maxBPM * frameRate))
        let maxLag = min(env.count - 2, Int(60.0 / max(40, minBPM) * frameRate))
        guard maxLag > minLag else { return [] }
        var bestLags: [(lag: Int, score: Double)] = []
        var lag = minLag
        while lag <= maxLag {
            var acc = 0.0
            var i = lag
            while i < env.count {
                acc += Double(centered[i]) * Double(centered[i - lag])
                i += 1
            }
            acc /= Double(env.count - lag)
            bestLags.append((lag, acc))
            lag += 1
        }
        let peaks = bestLags.enumerated().filter { (idx, e) in
            idx > 0 && idx < bestLags.count - 1 &&
            e.score > bestLags[idx - 1].score && e.score >= bestLags[idx + 1].score
        }.sorted { $0.element.score > $1.element.score }.prefix(4)
        for p in peaks {
            let i = p.offset
            let a = bestLags[i - 1].score, b = bestLags[i].score, c = bestLags[i + 1].score
            let denom = a - 2 * b + c
            var lagD = Double(p.element.lag)
            if abs(denom) > 1e-12 {
                let off = 0.5 * (a - c) / denom
                if abs(off) <= 1 { lagD += off }
            }
            let bpm = 60.0 * frameRate / lagD
            cands.append(contentsOf: [bpm, bpm * 2, bpm / 2,
                                      bpm * 1.5, bpm / 1.5,
                                      bpm * 4.0 / 3.0, bpm * 3.0 / 4.0])
        }
        var uniq: [Double] = []
        for var c in cands {
            while c > 200 { c /= 2 }
            while c < 40 { c *= 2 }
            if c >= minBPM && c <= maxBPM, !uniq.contains(where: { abs($0 - c) / c < 0.03 }) {
                uniq.append(c)
            }
        }
        return uniq
    }

    /// Z-scored support — the candidate's best-phase support
    /// measured against a jittered-phase NULL (supports at scrambled
    /// phases). Raw support structurally favors slow grids (a half grid
    /// sits on a subset of the same onsets); z-scores don't.
    static func zSupport(bpm: Double, env: [Float], times: [Double],
                         phases: Int = 16) -> (z: Double, support: Double, phase: Double) {
        guard times.count > 1, let t0 = times.first, let t1 = times.last, t1 > t0 else {
            return (0, 0, 0)
        }
        let envMean = Double(env.reduce(0, +)) / Double(env.count)
        guard envMean > 0 else { return (0, 0, t0) }
        let step = 60.0 / bpm
        var best = -1.0
        var bestPhase = t0
        var nulls: [Double] = []
        for k in 0..<max(phases, 32) {
            let phase = t0 + Double(k) / Double(max(phases, 32)) * step
            let sv = support(beats: gridTimes(bpm: bpm, phase: phase, from: t0, to: t1),
                             env: env, times: times, envMean: envMean)
            if sv > best { best = sv; bestPhase = phase }
            if k % 2 == 1 { nulls.append(sv) }   // half the phases = the null
        }
        let nm = nulls.reduce(0, +) / Double(nulls.count)
        let nv = nulls.reduce(0) { $0 + ($1 - nm) * ($1 - nm) } / Double(max(1, nulls.count - 1))
        let sd = max(sqrt(nv), 1e-9)
        return ((best - nm) / sd, best, bestPhase)
    }

    /// Ellis log-normal tempo prior (~120, σ≈0.9 octaves) — the
    /// corpus-free human tie-break, replacing the old ≤8% nudge.
    static func ellisPrior(_ bpm: Double) -> Double {
        exp(-0.5 * pow(log2(bpm / 120.0) / 0.9, 2))
    }

    // MARK: - Support scoring

    /// Mean envelope value at grid points, normalized by the global mean.
    /// >1 means the grid sits on real onsets. `beats` are seconds.
    static func support(beats: [Double], env: [Float], times: [Double],
                        envMean: Double? = nil) -> Double {
        guard !env.isEmpty, beats.count > 3, let tMax = times.last, tMax > 0 else { return 0 }
        let mean = envMean ?? (Double(env.reduce(0, +)) / Double(env.count))
        guard mean > 0 else { return 0 }
        var total = 0.0
        var n = 0
        for b in beats where b >= times.first! && b <= tMax {
            let fi = Int(((b - times.first!) / (tMax - times.first!)) * Double(env.count - 1) + 0.5)
            let i0 = max(0, min(env.count - 1, fi))
            // ±1-frame tolerance: onset peaks straddle frames whenever the
            // beat spacing × frame rate isn't integral (nearest-frame alone
            // loses ~half the grid's hits)
            let v = max(env[i0],
                       max(i0 > 0 ? env[i0 - 1] : 0,
                           i0 < env.count - 1 ? env[i0 + 1] : 0))
            total += Double(v)
            n += 1
        }
        guard n > 0 else { return 0 }
        return (total / Double(n)) / mean
    }

    static func gridTimes(bpm: Double, phase: Double, from: Double, to: Double) -> [Double] {
        let step = 60.0 / bpm
        var t = from + fmod(phase - from, step)
        if t < from { t += step }
        var out: [Double] = []
        while t <= to {
            out.append(t)
            t += step
        }
        return out
    }

    /// Best phase (coarse scan) for a BPM on the envelope.
    static func bestPhase(bpm: Double, env: [Float], times: [Double]) -> Double {
        let step = 60.0 / bpm
        guard let t0 = times.first, let t1 = times.last, t1 > t0 else { return 0 }
        var bestPhase = 0.0
        var best = -1.0
        for k in 0..<32 {
            let phase = t0 + Double(k) / 32.0 * step
            let s = support(beats: gridTimes(bpm: bpm, phase: phase, from: t0, to: t1),
                            env: env, times: times)
            if s > best { best = s; bestPhase = phase }
        }
        return bestPhase
    }

    // MARK: - Main estimate

    static func estimate(samples: [Float], sampleRate sr: Double,
                         minBPM: Double, maxBPM: Double) -> Result {
        let empty = Result(bpm: 0, beatTimes: [], confidence: 0,
                           noBeatFound: true, sections: [], env: [], times: [])
        guard samples.count > Int(sr * 4) else { return empty }
        let (env, rms, times) = onsetEnvelope(samples: samples, sampleRate: sr)
        guard env.count > 20, let t0 = times.first, let t1 = times.last, t1 > t0 else {
            return empty
        }

        // --- candidates: autocorrelation peaks of the (mean-removed) env
        let mean = Double(env.reduce(0, +)) / Double(env.count)
        let centered = env.map { Float(Double($0) - mean) }
        let frameRate = 1.0 / ((times[1] - times[0]))
        var cands: [Double] = []
        let minLag = max(2, Int(60.0 / maxBPM * frameRate))
        let maxLag = min(env.count - 2, Int(60.0 / max(40, minBPM) * frameRate))
        if maxLag > minLag {
            var bestLags: [(lag: Int, score: Double)] = []
            var lag = minLag
            while lag <= maxLag {
                var acc = 0.0
                var i = lag
                while i < env.count {
                    acc += Double(centered[i]) * Double(centered[i - lag])
                    i += 1
                }
                acc /= Double(env.count - lag)
                bestLags.append((lag, acc))
                lag += 1
            }
            // local maxima, top-4 by score, PARABOLIC lag refinement —
            // integer lags quantize tempo by frameRate/lag (a 120 BPM truth
            // at lag 21.5 becomes 123.1 or 117.5; both drift off the beat
            // lattice and lose to unrelated near-lattice tempos)
            let peaks = bestLags.enumerated().filter { (idx, e) in
                idx > 0 && idx < bestLags.count - 1 &&
                e.score > bestLags[idx - 1].score && e.score >= bestLags[idx + 1].score
            }.sorted { $0.element.score > $1.element.score }.prefix(4)
            for p in peaks {
                let i = p.offset
                let a = bestLags[i - 1].score, b = bestLags[i].score, c = bestLags[i + 1].score
                let denom = a - 2 * b + c
                var lagD = Double(p.element.lag)
                if abs(denom) > 1e-12 {
                    let off = 0.5 * (a - c) / denom
                    if abs(off) <= 1 { lagD += off }
                }
                let bpm = 60.0 * frameRate / lagD
                // Explicit METrical relatives, not just octaves —
                // swung house locks autocorrelation onto the 1.5× dotted
                // grid; without ×3/2 (and ×4/3) relatives in the set, the
                // true pulse never gets scored at all.
                cands.append(contentsOf: [bpm, bpm * 2, bpm / 2,
                                          bpm * 1.5, bpm / 1.5,
                                          bpm * 4.0 / 3.0, bpm * 3.0 / 4.0])
            }
        }
        // octave-normalize + filter to range, dedupe
        var uniq: [Double] = []
        for var c in cands {
            while c > 200 { c /= 2 }
            while c < 40 { c *= 2 }
            if c >= minBPM && c <= maxBPM, !uniq.contains(where: { abs($0 - c) / c < 0.03 }) {
                uniq.append(c)
            }
        }
        if ProcessInfo.processInfo.environment["MKDJ_GRID_DEBUG"] != nil {
            print("grid candidates (pre-score): " + uniq.map { String(format: "%.1f", $0) }.joined(separator: "  "))
        }
        guard !uniq.isEmpty else {
            if ProcessInfo.processInfo.environment["MKDJ_GRID_DEBUG"] != nil { print("grid: NO CANDIDATES") }
            return empty
        }

        // --- octave verification by support, prior favoring 70–180
        // Two scores per candidate: ABSOLUTE support (mean onset strength
        // under the grid — prefers grids on the STRONGEST hits, which kills
        // sub-lattice impostors like every-third-eighth) and CONTRAST
        // (best phase vs phase mean — what noise cannot fake). Rank by
        // absolute × prior; gate existence on contrast.
        let envMean = Double(env.reduce(0, +)) / Double(env.count)   // computed once
        var scored: [(bpm: Double, phase: Double, support: Double, contrast: Double)] = []
        for c in uniq {
            let step = 60.0 / c
            var best = -1.0
            var bestPhase = t0
            var meanS = 0.0
            for k in 0..<32 {
                let phase = t0 + Double(k) / 32.0 * step
                let s = support(beats: gridTimes(bpm: c, phase: phase, from: t0, to: t1),
                                env: env, times: times, envMean: envMean)
                meanS += s
                if s > best { best = s; bestPhase = phase }
            }
            meanS /= 32.0
            let contrast = best / max(meanS, 1e-9)
            var prior: Double = (c >= 70 && c <= 180) ? 1.0 : 0.75
            // Gentle 120 affinity (≤8%) — the classic DJ-tempo
            // center. Subtle by design: support must still decide hard
            // cases (a 176 punk grid wins on support); this only breaks
            // near-ties between 3:2 relatives (dotted 81 vs pulse 122).
            if c >= 70 && c <= 180 {
                let octavesFrom120 = abs(log2(c / 120.0))
                prior *= max(0.92, 1.0 - 0.08 * octavesFrom120)
            }
            scored.append((c, bestPhase, best * prior, contrast))
        }
        scored.sort { $0.support > $1.support }
        if ProcessInfo.processInfo.environment["MKDJ_GRID_DEBUG"] != nil {
            let dbg = scored.prefix(10).map { String(format: "%.1f(s%.2f,c%.2f)", $0.bpm, $0.support, $0.contrast) }
            print("grid scored: " + dbg.joined(separator: "  "))
        }
        // Gate on SUPPORT (grid points carry N× the average
        // onset energy — the actual question) with only a whisper of
        // contrast (1.05, enough to kill phase-fishing on noise). The old
        // 1.35 contrast gate false-rejected dense productions: real house
        // puts onsets at EVERY phase (offbeat hats, pads, vocals), so even
        // the correct grid's contrast collapses (~1.1) while its support
        // is excellent (~2.7). Found on a real MAW mix that returned
        // noBeat with the true grid ranked FIRST.
        guard let win0 = scored.first,
              win0.support > 1.75, win0.contrast > 1.05 else {
            if ProcessInfo.processInfo.environment["MKDJ_GRID_DEBUG"] != nil {
                print(String(format: "grid: gate fail — top %@ (need s>1.75 c>1.05)",
                             scored.first.map { String(format: "%.1f s%.2f c%.2f", $0.bpm, $0.support, $0.contrast) } ?? "none"))
            }
            return empty
        }
        var winner = win0
        // internal octave resolution: a half-time grid sits on REAL onsets,
        // so absolute support can't choose — but its MIDPOINTS tell the
        // truth. If the midpoints carry near-full-strength onsets (≥0.85×
        // the beat support — weaker 8th-note ticks don't qualify), the true
        // pulse is double.
        while winner.bpm * 2 <= min(maxBPM, 180) {
            let halfStep = 30.0 / winner.bpm
            let beatS = support(beats: gridTimes(bpm: winner.bpm, phase: winner.phase,
                                                 from: t0, to: t1),
                                env: env, times: times, envMean: envMean)
            let midS = support(beats: gridTimes(bpm: winner.bpm, phase: winner.phase + halfStep,
                                                from: t0, to: t1),
                               env: env, times: times, envMean: envMean)
            if midS > 1.05 && midS > 0.85 * beatS {
                winner.bpm *= 2
            } else {
                break
            }
        }

        // --- phase-corrected grid → per-beat refinement (±0.15 beat)
        let step = 60.0 / winner.bpm
        var beats = gridTimes(bpm: winner.bpm, phase: winner.phase, from: t0, to: t1)
        var refined: [Double] = []
        let frameDt = times.count > 1 ? times[1] - times[0] : 1.0
        for b in beats {
            let lo = max(t0, b - 0.15 * step)
            let hi = min(t1, b + 0.15 * step)
            let span = t1 - t0
            let iLo = max(0, Int((lo - t0) / span * Double(env.count - 1)))
            let iHi = min(env.count - 1, Int((hi - t0) / span * Double(env.count - 1)))
            var bi = iLo
            var bv: Float = -1
            for i in iLo...max(iLo, iHi) where env[i] > bv {
                bv = env[i]
                bi = i
            }
            var t = times[bi]
            // parabolic sub-frame peak (23 ms frames alone quantize the
            // median interval to ~0.8% error; this gets ~2 ms)
            if bi > 0, bi < env.count - 1 {
                let a = Double(env[bi - 1]), c = Double(bv), d = Double(env[bi + 1])
                let denom = a - 2 * c + d
                if abs(denom) > 1e-9 {
                    let off = 0.5 * (a - d) / denom
                    if abs(off) <= 1 { t += off * frameDt }
                }
            }
            refined.append(t)
        }
        beats = refined.sorted()
        // Sample-domain polish: frame-domain snapping is quantized to the
        // 23 ms envelope hop (≈0.8% interval error, worse than the 0.3%
        // bar) — refine each beat against the raw waveform's energy peak.
        beats = sampleRefine(beats, samples: samples, sr: sr)

        // --- regularity gate → interior gap fill → consistency
        var intervals: [Double] = []
        for i in 1..<beats.count { intervals.append(beats[i] - beats[i - 1]) }
        let medInterval = median(intervals)
        guard medInterval > 0 else { return empty }
        let spread = iqr(intervals) / medInterval
        if spread < 0.25 {
            beats = fillInteriorGaps(beats)
            beats = enforceConsistency(beats)
        }
        intervals = []
        for i in 1..<beats.count { intervals.append(beats[i] - beats[i - 1]) }
        guard !intervals.isEmpty else { return empty }
        let bpm = 60.0 / median(intervals)

        // --- confidence: support under refined beats, PRE edge-extension
        let conf = min(1.0, max(0, (winner.support - 1.2) / 1.5))
        let noBeat = beats.count < 8

        // --- sections: novelty = |density(+2s) − density(−2s)|
        let sections = segment(env: env, rms: rms, times: times, beats: beats, bpm: bpm)

        return Result(bpm: bpm, beatTimes: beats, confidence: conf,
                      noBeatFound: noBeat, sections: sections,
                      env: env, times: times)
    }

    // MARK: - Sections

    static func segment(env: [Float], rms: [Float], times: [Double],
                        beats: [Double], bpm: Double) -> [Section] {
        guard times.count > 10, let t1 = times.last, t1 > 8 else { return [] }
        let frameDt = times[1] - times[0]
        let winFrames = max(1, Int(2.0 / frameDt))             // ±2 s density window
        var density = [Double](repeating: 0, count: env.count)
        for i in 0..<env.count {
            let lo = max(0, i - winFrames), hi = min(env.count - 1, i + winFrames)
            var sum = 0.0
            for j in lo...hi { sum += Double(env[j]) }
            density[i] = sum / Double(hi - lo + 1)
        }
        // novelty[i] = |density(+2s) − density(−2s)| — spikes at CHANGE
        var novelty = [Double](repeating: 0, count: env.count)
        for i in 0..<env.count {
            let a = density[max(0, i - winFrames)]
            let b = density[min(env.count - 1, i + winFrames)]
            novelty[i] = abs(b - a)
        }
        let maxNov = novelty.max() ?? 0
        guard maxNov > 0 else { return [] }
        let minGapFrames = max(1, Int(8.0 / frameDt))
        // local-max window ±1 s: the novelty curve carries beat-rate ripple
        // (the density windows are only ±2 s) — a ±2-frame window mistakes
        // ripple spikes on rising slopes for section boundaries
        let peakHalf = max(2, Int(1.0 / frameDt))
        var boundaries: [Double] = [0]
        var i = winFrames
        while i < env.count - winFrames {
            let n = novelty[i]
            if n > 0.35 * maxNov,
               n >= novelty[max(0, i - peakHalf)...min(env.count - 1, i + peakHalf)].max()! {
                let t = times[i]
                if t - boundaries.last! > 8.0 { boundaries.append(t) }
                i += minGapFrames
                continue
            }
            i += 1
        }
        boundaries.append(t1)
        guard boundaries.count >= 2 else { return [] }

        // per-section tempo (median refined intervals inside) + energy
        // label by RANK: sections in the bottom/top tercile of section
        // energies are quiet/peak — thresholds tied to an energy model are
        // hostage to material; ranks are not.
        var out: [Section] = []
        var energies: [Double] = []
        for b in 0..<(boundaries.count - 1) {
            let s0 = boundaries[b], s1 = boundaries[b + 1]
            var energySum = 0.0
            var energyN = 0
            for f in 0..<times.count where times[f] >= s0 && times[f] < s1 {
                energySum += Double(rms[f]); energyN += 1
            }
            energies.append(energyN > 0 ? energySum / Double(energyN) : 0)
        }
        let byEnergy = energies.sorted()
        let q33 = byEnergy[byEnergy.count / 3]
        let q66 = byEnergy[byEnergy.count * 2 / 3]
        for b in 0..<(boundaries.count - 1) {
            let s0 = boundaries[b], s1 = boundaries[b + 1]
            var iv: [Double] = []
            for j in 1..<beats.count where beats[j] > s0 && beats[j] <= s1 {
                iv.append(beats[j] - beats[j - 1])
            }
            let secBPM = iv.isEmpty ? bpm : 60.0 / median(iv)
            let e = energies[b]
            let label = e <= q33 ? "quiet" : (e >= q66 ? "peak" : "mid")
            out.append(Section(startSeconds: s0, endSeconds: s1, bpm: secBPM, label: label))
        }
        return out
    }

    /// Sub-ms beat polish against the raw waveform: grain (64-sample)
    /// energy envelope within ±35 ms, quadratic peak. Accepted only when it
    /// does not worsen interval regularity.
    static func sampleRefine(_ beats: [Double], samples: [Float], sr: Double) -> [Double] {
        let win = Int(0.035 * sr)
        let grain = 64
        let n = samples.count
        guard beats.count > 3 else { return beats }
        let before = iqr(pairwise(beats)) / max(median(pairwise(beats)), 1e-9)
        var out: [Double] = []
        out.reserveCapacity(beats.count)
        samples.withUnsafeBufferPointer { sp in
            let base = sp.baseAddress!
            for b in beats {
                let c = Int(b * sr)
                let lo = max(0, c - win), hi = min(n, c + win)
                guard hi - lo > 2 * grain else { out.append(b); continue }
                var energies: [Double] = []
                energies.reserveCapacity((hi - lo) / grain + 1)
                var g0 = lo
                while g0 + grain <= hi {
                    var e: Double = 0
                    for i in g0..<(g0 + grain) {
                        let x = Double(base[i])
                        e += x * x
                    }
                    energies.append(e)
                    g0 += grain
                }
                guard !energies.isEmpty else { out.append(b); continue }
                var bestG = 0
                var bestE = energies[0]
                for g in 1..<energies.count where energies[g] > bestE {
                    bestE = energies[g]
                    bestG = g
                }
                var peak = Double(lo + bestG * grain + grain / 2) / sr
                if bestG > 0, bestG + 1 < energies.count {
                    let a = energies[bestG - 1], bb = energies[bestG], c2 = energies[bestG + 1]
                    let den = a - 2 * bb + c2
                    if abs(den) > 1e-12 {
                        let off = 0.5 * (a - c2) / den
                        if abs(off) <= 1 { peak += off * Double(grain) / sr }
                    }
                }
                out.append(peak)
            }
        }
        let cand = out.sorted()
        let after = iqr(pairwise(cand)) / max(median(pairwise(cand)), 1e-9)
        return after <= max(before * 1.5, 0.05) ? cand : beats
    }

    // MARK: - Grid hygiene (fill BEFORE consistency)

    static func fillInteriorGaps(_ beats: [Double]) -> [Double] {
        guard beats.count > 2 else { return beats }
        // The median interval is loop-invariant — recomputing it
        // (allocate + sort) inside the per-gap loop would be O(n² log n)
        let medPeriod = 60.0 / median(pairwise(beats))
        let med = medPeriod * 1.6
        var out: [Double] = [beats[0]]
        for i in 1..<beats.count {
            let gap = beats[i] - beats[i - 1]
            if gap > med {
                let n = Int((gap / (med / 1.6)).rounded()) - 1
                if n > 0, n < 64 {
                    for k in 1...n {
                        out.append(beats[i - 1] + gap * Double(k) / Double(n + 1))
                    }
                }
            }
            out.append(beats[i])
        }
        return out
    }

    static func enforceConsistency(_ beats: [Double]) -> [Double] {
        guard beats.count > 3 else { return beats }
        let iv = pairwise(beats)
        let med = median(iv)
        var out = beats
        for i in 1..<(out.count - 1) {
            let predicted = out[i - 1] + med
            if abs(out[i] - predicted) > 0.25 * med {
                out[i] = predicted      // wild outlier → back onto the pulse
            }
        }
        return out
    }

    static func pairwise(_ t: [Double]) -> [Double] {
        (1..<t.count).map { t[$0] - t[$0 - 1] }
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func iqr(_ v: [Double]) -> Double {
        guard v.count > 4 else { return 0 }
        let s = v.sorted()
        return s[s.count * 3 / 4] - s[s.count / 4]
    }

    // MARK: - Arbitration (cross-check vs BPMPLS)

    /// Two independent measurements of the same audio. Near-2×/½×
    /// disagreements are octave errors. CAUTION (a documented trap from a
    /// stem-separation tool studied earlier): a half-time grid puts a
    /// REAL hit under every one of its beats, so beat-support alone
    /// cannot pick the octave — the tell is whether the FASTER grid's
    /// midpoints also carry onsets.
        static func arbitrate(v2: Result, v1BPM: Double, env: [Float], times: [Double]) -> Result {
        guard !v2.noBeatFound, v1BPM > 0 else { return v2 }
        let rel = abs(v2.bpm - v1BPM) / max(v2.bpm, 1)
        if rel < 0.03 { return v2 }                      // agree — done
        // Simple METrical ratios only (2:1, 3:2, 4:3 and
        // reciprocals). Anything else is not a meter relation — keep v2.
        let ratio = v1BPM / v2.bpm
        let metrical = [2.0, 0.5, 1.5, 2.0 / 3.0, 4.0 / 3.0, 0.75]
            .contains { abs(ratio - $0) < 0.08 }
        guard metrical, !env.isEmpty, let t0 = times.first, let t1 = times.last else {
            MKLog.engine(String(format: "analysis: v2 %.2f vs BPMPLS %.2f — keeping v2",
                                 v2.bpm, v1BPM))
            return v2
        }
        let envMean = Double(env.reduce(0, +)) / Double(env.count)
        // score v2's OWN grid — if the Result carries no usable beats
        // (caller-constructed), derive the grid from its bpm + best phase
        let v2Beats = v2.beatTimes.count >= 4
            ? v2.beatTimes
            : gridTimes(bpm: v2.bpm, phase: bestPhase(bpm: v2.bpm, env: env, times: times),
                        from: t0, to: t1)
        let v2Support = support(beats: v2Beats, env: env, times: times, envMean: envMean)
        let v1Phase = bestPhase(bpm: v1BPM, env: env, times: times)
        let v1Grid = gridTimes(bpm: v1BPM, phase: v1Phase, from: t0, to: t1)

        // OCTAVE ratios (2:1/½): the midpoint test is the sensitive one —
        // a half-time grid sits on REAL onsets (subset), so direct support
        // comparison can't separate it; its midpoints tell the truth.
        if abs(ratio - 2.0) < 0.08 || abs(ratio - 0.5) < 0.08 {
            let slow = min(v2.bpm, v1BPM)
            let fast = max(v2.bpm, v1BPM)
            let slowPhase = bestPhase(bpm: slow, env: env, times: times)
            let slowGrid = gridTimes(bpm: slow, phase: slowPhase, from: t0, to: t1)
            let halfStep = 30.0 / slow
            let beatS = support(beats: slowGrid, env: env, times: times, envMean: envMean)
            let midS = support(beats: slowGrid.map { $0 + halfStep },
                               env: env, times: times, envMean: envMean)
            let midIsReal = midS > 0.8 * max(beatS, 1e-9) && midS > 1.05
            let wantFast = (v1BPM > v2.bpm)
            if midIsReal == wantFast {
                // v1 (fast) is right / v1 (slow) half-time wrong → adopt v1
                MKLog.engine(String(format: "analysis: octave arbitration favors %.2f (mid support %.2f vs beat %.2f)",
                                     fast, midS, beatS))
                var r = v2
                r.bpm = fast
                r.beatTimes = gridTimes(bpm: fast, phase: slowPhase, from: t0, to: t1)
                r.sections = []
                return r
            }
            MKLog.engine(String(format: "analysis: octave arbitration keeps v2 %.2f over BPMPLS %.2f (mid support %.2f)",
                                 v2.bpm, v1BPM, midS))
            return v2
        }

        // NON-OCTAVE metrical ratios (3:2, 4:3): direct grid-support
        // comparison. v2 is primary: BPMPLS's grid must be ≥10% STRONGER.
        let v1Support = support(beats: v1Grid, env: env, times: times, envMean: envMean)
        if v1Support > v2Support * 1.10 {
            MKLog.engine(String(format: "analysis: metrical arbitration favors BPMPLS %.2f (support %.2f) over v2 %.2f (%.2f)",
                                 v1BPM, v1Support, v2.bpm, v2Support))
            var r = v2
            r.bpm = v1BPM
            r.beatTimes = v1Grid
            r.sections = []
            return r
        }
        MKLog.engine(String(format: "analysis: metrical arbitration keeps v2 %.2f (support %.2f) over BPMPLS %.2f (%.2f)",
                             v2.bpm, v2Support, v1BPM, v1Support))
        return v2
    }
}
