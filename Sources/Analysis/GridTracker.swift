import Foundation

/// Onset-path beat tracking (the librosa/Ellis-2007 pattern).
///
/// GridEstimator scores CANDIDATE GRIDS against the onset envelope; this
/// tracker instead walks the beat path directly onto transients — dynamic
/// programming picks beat times maximizing onset strength minus a tempo-
/// regularity penalty, so beats land on the actual kicks by construction
/// ("use the visible waveform hits"). The BPM is the median inter-beat
/// interval of the aligned path; the anchor is the strongest-onset beat
/// (the four-on-the-floor downbeat candidate). The tempo hypothesis comes
/// from duration-weighted GLOBAL autocorrelation — a multi-section track
/// answers with its dominant tempo, not its first segment.
enum GridTracker {

    struct TrackResult {
        var bpm: Double
        var beatTimes: [Double]       // the DP path — real transient times
        var anchor: Double            // strongest-onset beat (downbeat)
        var confidence: Double        // spread-aware (a 2% margin ≠ 1.0)
        var candidateSupports: [(bpm: Double, support: Double)] = []
        /// Total onset energy the path explains (mean × count) — the
        /// runoff metric: the grid accounting for MORE of the envelope is
        /// the truth, its mean-scored ghost notwithstanding.
        var explainedEnergy: Double = 0
    }

    // DP transition penalty weight (Ellis λ ≈ 100 on normalized log-ratio)
    private static let lambda = 100.0
    private static let minBPM = 60.0, maxBPM = 190.0

    static func track(env: [Float], times: [Double], bpmHint: Double?) -> TrackResult? {
        guard env.count > 32, let t0 = times.first, let t1 = times.last, t1 > t0,
              env.count > 8 else { return nil }
        let fps = Double(env.count - 1) / (t1 - t0)
        let mean = Double(env.reduce(0, +)) / Double(env.count)
        guard mean > 0 else { return nil }

        // ── tempo induction: comb-filtered autocorrelation over the WHOLE
        //    envelope (lag + 2×lag reinforce; halves/quarters of a true
        //    tempo also peak, resolved later by the DP octave check)
        var scored: [(bpm: Double, s: Double)] = []
        let lagLo = Int(60.0 / maxBPM * fps), lagHi = Int(60.0 / minBPM * fps)
        guard lagHi > lagLo, lagHi < env.count / 2 else { return nil }
        var autoc = [Double](repeating: 0, count: lagHi + 1)
        for lag in lagLo...lagHi {
            var acc = 0.0
            let n = env.count - lag
            let step = max(1, n / 4000)   // subsample very long tracks
            var cnt = 0
            var i = 0
            while i < n {
                acc += Double(env[i]) * Double(env[i + lag])
                i += step
                cnt += 1
            }
            autoc[lag] = cnt > 0 ? acc / Double(cnt) : 0
        }
        for lag in lagLo...lagHi {
            let comb = autoc[lag]
                + 0.5 * (lag * 2 <= lagHi ? autoc[lag * 2] : 0)
                + 0.25 * ((lag / 2) >= lagLo ? autoc[lag / 2] : 0)
            let bpm = 60.0 * fps / Double(lag)
            scored.append((bpm, comb * tempoPrior(bpm)))
        }
        if let hint = bpmHint, hint >= minBPM, hint <= maxBPM {
            let lag = max(lagLo, min(lagHi, Int(60.0 / hint * fps)))
            scored.append((hint, autoc[lag] * tempoPrior(hint)))   // let the DP test it
        }
        scored.sort { $0.s > $1.s }

        // ── TEMPO DECISION from the tempogram (comb × prior), the librosa
        //    structure, non-transitive: the TOP peak's exact metrical
        //    partners (×2, ×½, ×1.5, ×⅔, ×4/3, ×¾, ×3, ×⅓) each score by
        //    their OWN comb energy × dancing prior — the answer must carry
        //    evidence (transitive family chaining swallowed whole
        //    tempograms into one blob electing fictional representatives).
        guard let top = scored.first else { return nil }
        var members: [(bpm: Double, comb: Double)] = [(top.bpm, top.s)]
        for r in [2.0, 0.5, 1.5, 2.0 / 3.0, 4.0 / 3.0, 0.75, 3.0, 1.0 / 3.0] {
            let x = top.bpm * r
            if x >= minBPM, x <= maxBPM {
                let comb = scored.first { abs($0.bpm - x) / x < 0.04 }?.s ?? 0
                members.append((x, comb))
            }
        }
        var chosen = top
        // shortlist the two best-evidenced members, then a DP RUNOFF by
        // total explained onset energy — the mean-normalized comb can rank
        // a ghost (⅔ of the truth) above the truth; the grid that explains
        // MORE of the envelope cannot be a subset ghost of the other.
        let evidenced = members.filter { $0.comb > 0 }
        let shortlist = Array(evidenced.sorted {
            $0.comb * tempoPrior($0.bpm) > $1.comb * tempoPrior($1.bpm)
        }.prefix(2).map(\.bpm) + [top.bpm])
        var runoff: [(bpm: Double, energy: Double)] = []
        for bpm in shortlist {
            if let r = dpTrack(bpm: bpm, env: env, fps: fps, t0: times.first!, t1: times.last!, mean: mean) {
                runoff.append((r.bpm, r.explainedEnergy * tempoPrior(r.bpm)))
            }
        }
        if let winner = runoff.max(by: { $0.energy < $1.energy }) {
            chosen = (winner.bpm, top.s)
        }
        var candidates = [chosen.bpm]
        // also DP the octave family + runners-up for the midpoint guard
        for s in scored.prefix(6) where !candidates.contains(where: { abs($0 - s.bpm) / s.bpm < 0.03 }) {
            candidates.append(s.bpm)
        }
        for factor in [2.0, 0.5] {
            let alt = chosen.bpm * factor
            if alt >= minBPM, alt <= maxBPM,
               !candidates.contains(where: { abs($0 - alt) / alt < 0.03 }) {
                candidates.append(alt)
            }
        }

        var results: [(r: TrackResult, q: Double)] = []
        for bpm in candidates {
            guard let r = dpTrack(bpm: bpm, env: env, fps: fps, t0: t0, t1: t1, mean: mean) else { continue }
            results.append((r, r.candidateSupports[0].support * tempoPrior(r.bpm)))
        }
        guard !results.isEmpty else { return nil }
        results.sort { $0.q > $1.q }
        // the tempogram winner's DP result IS the answer (if its DP failed,
        // fall back to the best DP path)
        var best: TrackResult
        if let chosenDP = results.first(where: { abs($0.r.bpm - chosen.bpm) / chosen.bpm < 0.05 }) {
            best = chosenDP.r
        } else {
            best = results[0].r
        }

        // ── octave guard: midpoints of the slow path, SAME support scale
        //    both sides (a DP path's own beats sit ON peaks — scoring them
        //    against sampled midpoints is 4× inflated and never fires);
        //    calibration = the estimator's midpoint test
        if let fastIdx = results.firstIndex(where: { abs($0.r.bpm - best.bpm * 2) / best.bpm < 0.06 }),
           fastIdx > 0 {
            let slow = best, fast = results[fastIdx].r
            let envMean = Double(env.reduce(0, +)) / Double(env.count)
            let slowPhase = GridEstimator.bestPhase(bpm: slow.bpm, env: env, times: times)
            let synthSlow = GridEstimator.support(
                beats: GridEstimator.gridTimes(bpm: slow.bpm, phase: slowPhase,
                                               from: times.first!, to: times.last!),
                env: env, times: times, envMean: envMean)
            let midS = GridEstimator.support(beats: slow.beatTimes.map { $0 + 30.0 / slow.bpm },
                                             env: env, times: times, envMean: envMean)
            MKLog.engine(String(format: "DP octave test: slow %.1f synth s%.3f, fast %.1f, mid s%.3f",
                                 slow.bpm, synthSlow, fast.bpm, midS))
            if midS > 0.8 * synthSlow && midS > 1.05 { best = fast }
        }

        // spread-aware confidence: a near-tied top-2 is not certainty
        var out = best
        let topSupports = results.prefix(5).map { ($0.r.bpm, $0.r.candidateSupports[0].support) }
        out.candidateSupports = topSupports
        if topSupports.count >= 2 {
            let spread = topSupports[1].1 / max(topSupports[0].1, 1e-9)
            out.confidence = min(best.confidence, 0.5 + 0.5 * (1.0 - spread))
        }
        return out
    }

    /// Gentle log-normal dancing-tempo prior (librosa's beat_track does the
    /// same with std=1 around 120) — breaks slow-grid ties without banning
    /// 70-BPM halftime music (a 70 track scores ~0.78 vs 140's ~0.93).
    private static func tempoPrior(_ bpm: Double) -> Double {
        let x = log2(bpm / 122.0)
        return exp(-0.5 * x * x / (1.1 * 1.1))
    }

    /// One DP pass at `bpm`: beats follow onsets with a tempo-regularity
    /// penalty; returns the refined (median-IPI) result and its quality.
    private static func dpTrack(bpm: Double, env: [Float], fps: Double,
                                t0: Double, t1: Double, mean: Double) -> TrackResult? {
        let n = env.count
        let period = 60.0 / bpm * fps                       // frames per beat
        guard period > 2, n > Int(period) else { return nil }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let win = Int(period * 1.9)                          // predecessor window
        for i in 1..<n {
            let jStart = max(0, i - win)
            guard jStart < i else { continue }
            var bestJ = -1
            var bestV = -Double.infinity
            for j in stride(from: i - 1, through: jStart, by: -1) {
                let ratio = log(Double(i - j) / period)
                let penalty = lambda * ratio * ratio
                let v = score[j] - penalty
                if v > bestV { bestV = v; bestJ = j }
            }
            score[i] = Double(env[i]) / mean + max(0, bestV)
            back[i] = bestJ
        }
        // backtrace from the best-scoring tail
        var bestEnd = 0
        var bestScore = -Double.infinity
        for i in (n - Int(period))..<n where i >= 0 {
            if score[i] > bestScore { bestScore = score[i]; bestEnd = i }
        }
        var path: [Int] = []
        var i = bestEnd
        while i >= 0 {
            path.append(i)
            i = back[i]
        }
        path.reverse()
        guard path.count >= 8 else { return nil }

        var beats = path.map { t0 + Double($0) / fps }
        // refine: median inter-beat interval → rerun once at the refined period
        let ipis = zip(beats, beats.dropFirst()).map { $1 - $0 }
        let sortedI = ipis.sorted()
        let medianI = sortedI[sortedI.count / 2]
        var refined = 60.0 / medianI
        if abs(refined - bpm) / bpm > 0.02, refined >= minBPM, refined <= maxBPM {
            if let second = dpPath(bpm: refined, env: env, fps: fps, t0: t0) {
                beats = second
                let ipis2 = zip(beats, beats.dropFirst()).map { $1 - $0 }
                let s2 = ipis2.sorted()
                refined = 60.0 / s2[s2.count / 2]
            }
        }

        // path quality: mean normalized onset strength at beats + hit rate.
        // A doubled grid over half-rate onsets explains the same TOTAL
        // energy (half the beats hit × twice the beats) — the hit-rate
        // factor breaks that tie toward the grid whose beats are real.
        var strength = 0.0
        var hits = 0
        for b in beats {
            let f = Int((b - t0) * fps + 0.5)
            if f >= 0, f < n {
                strength += Double(env[f])
                if Double(env[f]) > mean { hits += 1 }
            }
        }
        let hitRate = Double(hits) / Double(beats.count)
        let pathSupport = strength / Double(beats.count) / mean

        // anchor = strongest beat (the kick that leads the bar)
        var anchor = beats[0]
        var peak: Float = 0
        for b in beats {
            let f = Int((b - t0) * fps + 0.5)
            if f >= 0, f < n, env[f] > peak { peak = env[f]; anchor = b }
        }

        return TrackResult(bpm: refined, beatTimes: beats, anchor: anchor,
                           confidence: min(1, max(0.1, pathSupport / 2)),
                           candidateSupports: [(refined, pathSupport)],
                           explainedEnergy: strength * hitRate)
    }

    /// Path extraction only (second pass at the refined period).
    private static func dpPath(bpm: Double, env: [Float], fps: Double, t0: Double) -> [Double]? {
        let n = env.count
        let period = 60.0 / bpm * fps
        guard period > 2, n > Int(period) else { return nil }
        var score = [Double](repeating: 0, count: n)
        var back = [Int](repeating: -1, count: n)
        let win = Int(period * 1.9)
        for i in 1..<n {
            var bestV = -Double.infinity
            var bestJ = -1
            for j in max(0, i - win)..<i {
                let ratio = log(Double(i - j) / period)
                let v = score[j] - lambda * ratio * ratio
                if v > bestV { bestV = v; bestJ = j }
            }
            score[i] = Double(env[i]) + max(0, bestV)
            back[i] = bestJ
        }
        var bestEnd = 0
        var bestScore = -Double.infinity
        for i in max(0, n - Int(period))..<n {
            if score[i] > bestScore { bestScore = score[i]; bestEnd = i }
        }
        var path: [Int] = []
        var i = bestEnd
        while i >= 0 { path.append(i); i = back[i] }
        path.reverse()
        guard path.count >= 8 else { return nil }
        return path.map { t0 + Double($0) / fps }
    }
}
