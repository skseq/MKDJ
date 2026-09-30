import Foundation

// Multi-candidate grid-stability tracker.
//
// The verdict pipeline's flip rules (zero-support veto, ×4/3 backbeat flip-down,
// ×3/2 backbeat lift-up) all gate on segment coverage: the truth's segment
// cluster must clear a "substantial" threshold (≥top/4 or ≥top/3 of segment
// coverage) before any flip is considered. Known-failure families exist where
// the truth sits at only 2–32% of segment coverage — the engine is honestly
// picking the dominant; the user-ear truth is a smaller cluster that segment
// coverage alone can never elevate.
//
// This file implements the structural answer: a SEPARATE signal that's
// independent of segment coverage. For each candidate tempo (verdict + ×3/4 +
// ×2/3 + ×4/3 + ×3/2 + ×2 + ×½, bounded to the BPM range), instantiate a fresh
// BeatTracker at that candidate's BPM, feed the LOW-band envelope chunk by
// chunk (re-seeded at every chunk so each candidate is evaluated independently),
// and accumulate two metrics per candidate across the whole track:
//
//   - snapRate:     the tracker's rolling-window snap rate (mean over chunks).
//                   A high snap rate at a candidate means onsets align with
//                   that candidate's predicted grid — a kick really lives there.
//   - gridStability: 1 − normalized IBI variance over the candidate's emitted
//                   beat times. A stable grid at a candidate means beat periods
//                   are uniformly spaced — a metronome really lives there.
//
// These are orthogonal to segment coverage: a 5% segment can still produce a
// stable 94 BPM grid if those 5% of segments have a strong kick pattern at 94
// (one calibration track read across 7 candidate variants). The dominant's 126 grid, by
// contrast, would be busy/noisy at half the candidate's grid-stability.
//
// Compute budget: 7 candidates × ~1 ms per chunk (re-seed + process 690 frames)
// × ~50 energized chunks per 5-minute track = ~350 ms total. Negligible.
//
// Public API:
//   - `MultiCandidateScore` — one row in the diagnostic table; a single (bpm,
//     snapRate, gridStability, coverageSeconds, beatCount) tuple.
//   - `MultiCandidateAccumulator` — accumulates per-chunk evaluations and emits
//     the final scoreboard via `.scores()`.
//   - `candidateSet(for:minBPM:maxBPM:)` — pure function returning the bounded
//     candidate list from a verdict tempo. Reused by both the accumulator and
//     the verdict rule.

/// One row in the multi-candidate diagnostic table.
struct MultiCandidateScore: Sendable, Equatable {
    /// Candidate tempo (rounded to 0.01 BPM for table keying; the actual grid
    /// is the exact float passed in).
    var bpm: Double
    /// Mean per-chunk tracker confidence in [0, 1]. The tracker's confidence
    /// is its rolling 16-beat snap rate; averaging across chunks smooths it.
    var snapRate: Float
    /// 1 − normalized IBI variance over all beats the tracker emitted at this
    /// candidate. Higher = more stable grid. 0 if the tracker emitted fewer
    /// than 4 beats (can't compute variance).
    var gridStability: Float
    /// Total seconds of LOW-band envelope this candidate was evaluated over
    /// (sum of energized chunk durations).
    var coverageSeconds: Double
    /// Total beats emitted by the tracker at this candidate across all chunks.
    /// Used to gate the verdict rule (need enough data to trust the score).
    var beatCount: Int
}

/// Per-track accumulator. Mutated in-place during `analyzeSegments`; produces
/// the final scoreboard via `.scores()`. NOT thread-safe; intended to be
/// owned by a single analyze call.
struct MultiCandidateAccumulator {

    /// Per-candidate internal state.
    private struct Acc {
        var totalConfidence: Double = 0     // sum of per-chunk tracker.confidence
        var chunksEvaluated: Int = 0
        var beatTimes: [Double] = []        // all beats emitted, for IBI variance
        var coverage: Double = 0
    }

    /// Keyed by candidate BPM (rounded to 0.01 for float keying).
    private var accs: [Double: Acc] = [:]
    private var envRate: Double = 0

    init(envRate: Double) {
        self.envRate = envRate
    }

    /// Evaluate one chunk's LOW-band envelope at every candidate tempo. Each
    /// candidate gets a fresh tracker (re-seeded at the chunk's first-onset
    /// anchor); chunks don't share state across candidates. The accumulator
    /// only collects summaries, not the trackers themselves — cost is bounded
    /// to per-chunk × per-candidate tracker lifetime.
    ///
    /// - Parameters:
    ///   - chunk: LOW-band envelope slice for this chunk (length <= 8 s).
    ///   - chunkStartFrame: envelope frame index where this chunk starts.
    ///   - chunkAnchor: seconds-from-track-start of the chunk's first onset,
    ///     used as the seed anchor for every candidate tracker. Falls back to
    ///     chunk start (in seconds) if the first onset is unknown.
    ///   - candidates: bounded set of BPMs to evaluate at this chunk.
    mutating func evaluateChunk(chunk: [Float],
                                 chunkStartFrame: Int,
                                 chunkAnchor: Double,
                                 candidates: [Double]) {
        guard !chunk.isEmpty, envRate > 0, !candidates.isEmpty else { return }
        let dur = Double(chunk.count) / envRate
        for bpm in candidates {
            var tr = BeatTracker()
            tr.start(bpm: bpm, anchorSeconds: chunkAnchor, envRate: envRate)
            let emitted = tr.process(chunk: chunk, chunkStartFrame: chunkStartFrame)
            var ac = accs[bpm] ?? Acc()
            ac.totalConfidence += Double(tr.confidence)
            ac.chunksEvaluated += 1
            ac.coverage += dur
            ac.beatTimes.append(contentsOf: emitted)
            accs[bpm] = ac
        }
    }

    /// Final scoreboard, sorted by `gridStability × coverageSeconds` descending
    /// (display order for the diagnostic table; the verdict rules look
    /// candidates up by BPM, not by rank). Ties broken by `snapRate`.
    func scores() -> [MultiCandidateScore] {
        accs.map { (bpm, ac) in
            let snapRate: Float
            if ac.chunksEvaluated > 0 {
                snapRate = Float(ac.totalConfidence / Double(ac.chunksEvaluated))
            } else {
                snapRate = 0
            }
            var stability: Float = 0
            if ac.beatTimes.count >= 4 {
                let ibis: [Double] = (1..<ac.beatTimes.count).map { ac.beatTimes[$0] - ac.beatTimes[$0 - 1] }
                let mean = ibis.reduce(0, +) / Double(ibis.count)
                if mean > 0 {
                    let variance = ibis.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ibis.count)
                    let normalized = variance / (mean * mean)
                    // normalized IOI variance is typically 0 (perfect) to ~1 (bad);
                    // clamp and invert. A 0.5 normalized IBI variance => 0.5 stability.
                    stability = Float(max(0.0, 1.0 - normalized))
                }
            }
            return MultiCandidateScore(
                bpm: bpm,
                snapRate: snapRate,
                gridStability: stability,
                coverageSeconds: ac.coverage,
                beatCount: ac.beatTimes.count
            )
        }
        .sorted { (a, b) in
            let sa = Double(a.gridStability) * a.coverageSeconds
            let sb = Double(b.gridStability) * b.coverageSeconds
            if sa != sb { return sa > sb }
            return a.snapRate > b.snapRate
        }
    }
}

/// The bounded candidate set evaluated at every chunk. Always includes the
/// verdict tempo itself (for baseline comparison) plus its six nearest
/// pattern-period / harmonic relatives. Out-of-range candidates are dropped.
///
/// Why these seven ratios:
///   - ×2 / ×½: octave — covers the half/double ambiguity.
///   - ×4/3 / ×3/4: dotted-8th family (BPMPLS's most frequent pattern-period
///     adversary; dotted-note bass ostinatos and disco four-on-the-floor readings).
///   - ×3/2 / ×2/3: 3-beat family (breakbeat-period readings).
///
/// The subdominant-truth family is NOT addressed here — its truth has
/// no clean pattern-period relationship. Parked for a future move.
func candidateSet(for verdictBPM: Double, minBPM: Double, maxBPM: Double) -> [Double] {
    let multipliers: [Double] = [1.0, 4.0/3.0, 3.0/2.0, 2.0/3.0, 3.0/4.0, 2.0, 0.5]
    var seen: Set<Double> = []
    var out: [Double] = []
    for m in multipliers {
        let raw = verdictBPM * m
        guard raw >= minBPM, raw <= maxBPM else { continue }
        // Round to 0.01 to dedupe near-identical candidates (e.g. ×4/3 of 120
        // and ×2/×3 of 120 both yield ~160).
        let key = (raw * 100.0).rounded() / 100.0
        if !seen.contains(key) {
            seen.insert(key)
            out.append(key)
        }
    }
    return out
}
