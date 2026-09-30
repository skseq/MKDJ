import Foundation
import AVFoundation
import Accelerate

// Components 3 + 4: hybrid multi-band DSP (Accelerate/vDSP) and Smart Skip v2 rolling-window logic.
// Audio is read with AVAudioFile strictly for PCM extraction. Files up to ~12 minutes are loaded
// whole (mono, float); longer files are truncated at that cap. Chunks never reload from disk.

enum BPMError: Error {
    case unreadableAudio
    case noOnsets
}

extension BPMError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreadableAudio: return "couldn't decode audio (unsupported or damaged file)"
        case .noOnsets: return "no analyzable rhythm found (silence, noise, or too short)"
        }
    }
}

struct SegmentInfo: Equatable, Sendable {
    var bpm: Double
    var startTime: Double
    var duration: Double
    /// Band whose reading this segment carries (0 = LOW/kick, 1 = MID, 2 = HIGH).
    /// Powers the multi-tempo gate's band-character check.
    var band: Int = 0
}

/// Full analysis product: winning BPM plus the segment map (multi-tempo surfacing).
struct BPMAnalysis: Sendable {
    let bpm: Double
    let segments: [SegmentInfo]
    /// Whole-track autocorr peak evidence. Each inner array is one band
    /// (LOW, MID, HIGH) of `(bpm, frac)` peaks sorted by `frac` desc.
    /// - `bandPeaksRaw`: the values the verdict pipeline consumes.
    /// - `bandPeaksRoleWeighted`: instrument-aware re-weighting;
    ///   surfaced for diagnostics (probe only), not used by the verdict rules.
    var bandPeaksRaw: [[(bpm: Double, frac: Float)]] = []
    var bandPeaksRoleWeighted: [[(bpm: Double, frac: Float)]] = []
    /// Online beat tracker — beat positions in seconds from the
    /// LOW-band phase tracker. Evidence only; never re-derives tempo.
    var beatTimes: [Double] = []
    /// Confidence score in [0, 1]. Aggregates bandFracs,
    /// cluster dominance, segment count, MID+HIGH backbeat at T/2, and
    /// BeatTracker snap rate. NEVER overrides the verdict — display only.
    /// Thresholds: <0.40 LOW, 0.40-0.70 MEDIUM, ≥0.70 HIGH.
    /// Weights are heuristics; calibration lives in the corpus gate.
    var confidence: Double = 0
    /// Raw backbeat strength at the verdict tempo — sum of
    /// MID+HIGH peak fracs at T/2, range [0, 2]. Diagnostic; confidence
    /// aggregates it internally.
    var backbeatStrength: Float = 0
    /// Multi-candidate grid-stability scores. One entry
    /// per bounded candidate tempo (verdict, ×3/4, ×2/3, ×4/3, ×3/2, ×2,
    /// ×½), each reporting snapRate / gridStability / coverageSeconds /
    /// beatCount. Read by the Move 4 flip rule and the probe tool.
    var multiCandidateScores: [MultiCandidateScore] = []
    /// Ambient / no-beat-found flag. Set when the
    /// engine's detectAmbient() heuristic fires: no band's top peak in
    /// 70-180 BPM with frac ≥ 0.8, AND the largest tempo cluster
    /// covers < 40% of total segments. The UI shows a gray "no beat"
    /// badge; the file write is skipped unless the user has opted in
    /// via `writeNullBpmForAmbient` (default off).
    var noBeatFound: Bool = false
}

struct BPMEngine {

    static let windowSize = 1024
    static let hopSize = 512
    static let chunkSeconds: Double = 8.0
    static let maxAnalysisSeconds: Double = 720.0
    static let energyFloorRatio: Float = 0.08   // chunk silence threshold relative to loudest chunk
    static let barTolerance: Double = 0.06      // fraction of bar-multiple length
    static let phaseTolerance: Double = 0.12    // fraction of beat period
    static let bpmMatchTolerance: Double = 0.03 // fraction

    // MARK: - Public API





    /// MKDJ addition: the same verdict pipeline over an existing mono decode,
    /// so MKDJ reads each file once (the samples also feed the waveform peaks).
    /// Identical body to the old inline pipeline; the skip lists still key on
    /// the file path.
    static func analyzeSamples(_ samples: [Float], sampleRate: Double, url: URL,
                                minBPM: Double, maxBPM: Double) throws -> BPMAnalysis {
        try Task.checkCancellation()
        LogService.shared.log("  pcm: \(samples.count) samples @ \(Int(sampleRate)) Hz (\(String(format: "%.1f", Double(samples.count) / sampleRate))s)")
        let (segments, bandPeaks, roleBandPeaks, beatTimes, trackerFinalConfidence, multiCandidateScores) = try analyzeSegments(samples: samples, sampleRate: sampleRate,
                                                        minBPM: minBPM, maxBPM: maxBPM)
        // The per-Move skip lists key on the file path (Sources/SkipList.swift).
        // `resolved6aOr6c` blocks Move 6b whenever Move 6a/6c already fired:
        // 6a (×3/2-LOW lift UP) and 6b (×2/×3/2 fold-DOWN) are mutually
        // exclusive in direction — letting 6b run after a 6a/6c lift would
        // cancel that lift in the wrong direction. 6b must still be allowed
        // to run after Move 4 alone (Move 4's lift can NEED 6b's fold).
        var resolved6aOr6c = false
        // The verdict is the largest tempo CLUSTER's weighted mean, not the single
        // longest segment — one steady 56s stretch can't outvote the track's other 110s.
        let clusters = tempoClusters(segments)
        guard let top = clusters.first else { throw BPMError.noOnsets }
        var winner = top
        var resolved = false
        // ×4/3 resolution: when the top two clusters are near-tied on duration
        // AND related by ×4/3, one is a dotted-note (3-against-4) pattern-period
        // artifact of the other (a dotted-8th bass ostinato at 121 reads as 161.3
        // in the LOW band and near-ties the true 121 cluster). Backbeat booleans
        // can't separate them — the ostinato's own fundamental sits at T_hi/2 and
        // passes as a fake backbeat. Instead score both candidates against the
        // whole-track band peaks (direct support at exactly T, summed across
        // bands): the true pulse shows up across bands, the artifact only in
        // the band(s) playing the pattern. Flip only on a clear margin.
        if clusters.count > 1, clusters[1].duration >= top.duration / 1.3 {
            let r43 = 4.0 / 3.0
            let ratio = max(top.bpm, clusters[1].bpm) / min(top.bpm, clusters[1].bpm)
            if abs(ratio - r43) <= bpmMatchTolerance * r43 {
                let topScore = Self.directSupport(top.bpm, bandPeaks: bandPeaks)
                let secondScore = Self.directSupport(clusters[1].bpm, bandPeaks: bandPeaks)
                if secondScore > topScore * 1.15 {
                    LogService.shared.log("  ×4/3 resolution: \(String(format: "%.2f", top.bpm)) -> \(String(format: "%.2f", clusters[1].bpm)) BPM (cross-band support \(String(format: "%.2f", secondScore)) vs \(String(format: "%.2f", topScore)))")
                    winner = clusters[1]
                    resolved = true
                }
            }
        }
        // Zero-support veto: a dotted-8th pattern period can win nearly every
        // chunk yet leave NO trace in the whole-track band peaks, while the true
        // tempo (winner×3/4) is visible in all three bands. When the dominant
        // verdict is invisible at whole-track scale AND its ×3/4 relative has
        // unanimous band support, the verdict is the pattern artifact — flip
        // down. Safe because the conditions are stark: a real tempo that covers
        // ≥50% of a track always shows up in at least one band's whole-track
        // autocorrelation.
        if !resolved {
            func bandFracs(_ t: Double) -> [Float] {
                bandPeaks.map { peaks in
                    peaks.first(where: { abs($0.bpm - t) <= bpmMatchTolerance * t })?.frac ?? 0
                }
            }
            let totalDur = clusters.reduce(0.0) { $0 + $1.duration }
            let candidate = top.bpm * 0.75
            if top.duration >= totalDur * 0.5, candidate >= minBPM, candidate <= maxBPM,
               bandFracs(top.bpm).allSatisfy({ $0 < 0.25 }),
               bandFracs(candidate).allSatisfy({ $0 >= 0.25 }) {
                LogService.shared.log("  zero-support veto: \(String(format: "%.2f", top.bpm)) -> \(String(format: "%.2f", candidate)) BPM (verdict absent from whole-track band peaks; ×3/4 relative present in all bands)")
                winner = (bpm: candidate, duration: top.duration)
                resolved = true
            }
        }
        // Shared arbiter: backbeat STRENGTH — sum of MID+HIGH peak fracs at T/2.
        // The snare/hat half-tempo rate is evidence; strength comparison decides.
        func backbeatStrength(_ t: Double) -> Float {
            let half = t / 2
            let tol = max(1.5, bpmMatchTolerance * half)
            return bandPeaks.dropFirst().reduce(0) { sum, peaks in
                sum + (peaks.first(where: { abs($0.bpm - half) <= tol })?.frac ?? 0)
            }
        }
        // ×4/3 backbeat flip-down: the ×4/3 artifact can win chunks AND show up
        // in MID's whole-track peaks, so direct support can't convict it — but
        // its own "backbeat" (T/2 in MID+HIGH) is weaker than the true tempo's.
        // When the runner-up cluster is LOWER, ×4/3-related, and substantial,
        // and its backbeat strength beats the winner's by a clear margin, flip
        // down. Direction is down-only — ×4/3 artifacts read HIGH.
        if !resolved, clusters.count > 1, clusters[1].bpm < top.bpm {
            let r43 = 4.0 / 3.0
            let ratio = top.bpm / clusters[1].bpm
            if abs(ratio - r43) <= bpmMatchTolerance * r43,
               clusters[1].duration >= max(12.0, top.duration / 4.0) {
                let loStrength = backbeatStrength(clusters[1].bpm)
                let hiStrength = backbeatStrength(top.bpm)
                if loStrength > hiStrength * 1.25 {
                    LogService.shared.log("  ×4/3 backbeat flip: \(String(format: "%.2f", top.bpm)) -> \(String(format: "%.2f", clusters[1].bpm)) BPM (backbeat strength \(String(format: "%.2f", loStrength)) vs \(String(format: "%.2f", hiStrength)))")
                    winner = clusters[1]
                    resolved = true
                }
            }
        }
        // ×3/2 resolution: a 3-beat pattern period reads as tempo×⅔ and can
        // outlast the true tempo on duration. Family pattern across all cases:
        // ×4/3 artifacts read HIGH (dotted subdivisions, truth lower), ×3/2
        // artifacts read LOW (3-beat periods, truth higher). The arbiter is
        // backbeat STRENGTH — the sum of MID+HIGH peak fracs at T/2 — and the
        // flip only ever goes UP, so it can never recreate the founding
        // fold-down disasters (122→81, 119→79). A genuine slow track keeps
        // its reading because a phantom ×1.5 challenger can't win the
        // backbeat comparison.
        if !resolved, clusters.count > 1, clusters[1].bpm > top.bpm {
            let r32 = 1.5
            let ratio = clusters[1].bpm / top.bpm
            if abs(ratio - r32) <= bpmMatchTolerance * r32,
               clusters[1].duration >= max(12.0, top.duration / 3.0) {
                let hiStrength = backbeatStrength(clusters[1].bpm)
                let loStrength = backbeatStrength(top.bpm)
                if hiStrength > loStrength * 1.3 {
                    LogService.shared.log("  ×3/2 resolution: \(String(format: "%.2f", top.bpm)) -> \(String(format: "%.2f", clusters[1].bpm)) BPM (backbeat strength \(String(format: "%.2f", hiStrength)) vs \(String(format: "%.2f", loStrength)))")
                    winner = clusters[1]
                    resolved = true
                }
            }
        }
        // Backbeat corroboration: when the top two clusters are near-tied on
        // duration, prefer the candidate whose T/2 backbeat (snare/hat rate) shows
        // up in MID or HIGH. Corroboration-only — absence never penalizes. Note
        // this tiebreak deliberately does NOT set `resolved`: it only nudges the
        // winner, and the later Moves still run against the nudged verdict.
        if !resolved, clusters.count > 1, clusters[1].duration >= top.duration / 1.3 {
            let topBB = backbeatSupport(bandPeaks: bandPeaks, for: top.bpm)
            let secondBB = backbeatSupport(bandPeaks: bandPeaks, for: clusters[1].bpm)
            if secondBB && !topBB {
                LogService.shared.log("  backbeat tiebreak: \(String(format: "%.2f", top.bpm)) -> \(String(format: "%.2f", clusters[1].bpm)) BPM (T/2 snare evidence in MID/HIGH)")
                winner = clusters[1]
            }
        }
        // Move 4: cross-band direct-support flip. The multi-candidate
        // tracker (MultiCandidateTracker.swift) accumulates per-candidate
        // grid-stability + snap-rate evidence in `multiCandidateScores` (the
        // diagnostic surface); the verdict rule itself uses cross-band direct
        // support from `bandPeaks` — the same signal the ×4/3 direct-support
        // rule above uses, but lifted out of the "runner-up cluster with
        // near-tied duration" precondition that excludes known-failures whose
        // truth covers only 2–32% of segments.
        //
        // For each candidate in the bounded candidate set (verdict + ×3/4,
        // ×2/3, ×4/3, ×3/2, ×2, ×½), directSupport = sum of whole-track peak
        // strengths within bpmMatchTolerance of the candidate, summed across
        // the three bands. The truth is visible in MULTIPLE bands at high
        // strength; the artifact is band-specific.
        //
        // Family-gated (×4/3 or ×3/2), direction-constrained (×4/3 artifacts
        // only flip DOWN, ×3/2 only UP), minimum-support floor (≥0.5 in
        // cross-band sum ensures the candidate is "really there").
        if !resolved {
            let verdictSupport = Self.directSupport(winner.bpm, bandPeaks: bandPeaks)
            let r43 = 4.0 / 3.0
            let r32 = 1.5
            let tol = BPMEngine.bpmMatchTolerance
            // Bounded candidate set from the verdict itself (see candidateSet).
            let candList = candidateSet(for: winner.bpm, minBPM: minBPM, maxBPM: maxBPM)
            for cand in candList where abs(cand - winner.bpm) > 0.5 {
                let candSupport = Self.directSupport(cand, bandPeaks: bandPeaks)
                let candLowSupport = bandPeaks[0].first(where: { abs($0.bpm - cand) <= bpmMatchTolerance * cand })?.frac ?? 0
                let ratio = max(cand, winner.bpm) / min(cand, winner.bpm)
                // Minimum cross-band support.
                guard candSupport >= move4MinDirectSupport else { continue }
                // Must exceed the verdict's cross-band support.
                guard Double(candSupport) > Double(verdictSupport) * move4DirectSupportMargin else { continue }
                if cand < winner.bpm, abs(ratio - r43) <= tol * r43 {
                    // ×4/3 artifact (verdict HIGH); candidate LOWER. Flip DOWN.
                    LogService.shared.log("  Move 4 cross-band flip: \(String(format: "%.2f", winner.bpm)) -> \(String(format: "%.2f", cand)) BPM (×4/3 family, direct-support \(String(format: "%.2f", candSupport)) vs verdict \(String(format: "%.2f", verdictSupport)), LOW \(String(format: "%.2f", candLowSupport)))")
                    winner = (bpm: cand, duration: Double(candSupport))
                    resolved = true
                    break
                } else if cand > winner.bpm, abs(ratio - r32) <= tol * r32 {
                    // ×3/2 artifact (verdict LOW); candidate HIGHER. Flip UP.
                    LogService.shared.log("  Move 4 cross-band flip: \(String(format: "%.2f", winner.bpm)) -> \(String(format: "%.2f", cand)) BPM (×3/2 family, direct-support \(String(format: "%.2f", candSupport)) vs verdict \(String(format: "%.2f", verdictSupport)), LOW \(String(format: "%.2f", candLowSupport)))")
                    winner = (bpm: cand, duration: Double(candSupport))
                    resolved = true
                    break
                }
            }
        }
        // Move 6a: chunk-vote ratio lift for ×3/2-low. Reads the
        // multi-candidate tracker's per-candidate beatCount and compares it
        // to the verdict's. The chunk-vote signal is the discriminator Move 4
        // cross-band couldn't see: the truth can accumulate more beats than
        // the verdict even though the cross-band directSupport ratio is below
        // Move 4's 1.15× margin. The chunk-vote ratio alone doesn't
        // discriminate; the cross-band directSupport floor does.
        //
        // Skip-list check: if the file path is in the Move 6a skip list,
        // the rule won't fire on it — the per-Move mechanism for handling
        // false positives without killing the rule globally.
        if !resolved {
            for score in multiCandidateScores {
                let cand = score.bpm
                // Family check: ×3/2 only (cand > verdict, ratio ~1.5)
                let ratio = cand / winner.bpm
                let r32 = 1.5
                let tol = BPMEngine.bpmMatchTolerance
                guard abs(ratio - r32) <= tol * r32 else { continue }
                // Direction: cand HIGHER (lift UP). ×3/2-low is the
                // engine-low-truth-high direction.
                guard cand > winner.bpm else { continue }
                // Find the verdict's beatCount in the multi-candidate table
                guard let verdictScore = multiCandidateScores.first(where: {
                    abs($0.bpm - winner.bpm) <= bpmMatchTolerance * winner.bpm
                }) else { continue }
                // Skip-list check (per-Move). Entries are listed in
                // ~/Library/Application Support/BPMPLS/skip_lists.json and
                // can be edited by hand.
                if SkipListStore.shared.isSkipped(path: url.path, for: .move6a) {
                    LogService.shared.log("  Move 6a SKIPPED (skip list): \(url.lastPathComponent) at \(String(format: "%.2f", winner.bpm)) BPM")
                    break
                }
                // Chunk-vote ratio check
                let beatRatio = Double(score.beatCount) / Double(verdictScore.beatCount)
                guard beatRatio >= move6aChunkVoteRatio else { continue }
                // Snap-rate tolerance
                let snapDiff = abs(Double(score.snapRate) - Double(verdictScore.snapRate))
                guard snapDiff < move6aSnapTolerance else { continue }
                // Cross-band directSupport floor — the additional guard
                // that protects against mid-tempo false positives (e.g.
                // an 82-BPM breakbeat track where the ×3/2 candidate at 123 has
                // 1.49× more beats at similar snap, but candSupport is
                // only 0.35 — below the 0.5 floor).
                let candSupport = Self.directSupport(cand, bandPeaks: bandPeaks)
                guard candSupport >= move6aMinDirectSupport else { continue }
                LogService.shared.log("  Move 6a chunk-vote lift: \(String(format: "%.2f", winner.bpm)) -> \(String(format: "%.2f", cand)) BPM (cand beats \(score.beatCount) / verdict beats \(verdictScore.beatCount) = \(String(format: "%.2f", beatRatio))×, snap diff \(String(format: "%.3f", snapDiff)), directSupport \(String(format: "%.2f", candSupport)))")
                winner = (bpm: cand, duration: Double(score.beatCount))
                resolved = true
                resolved6aOr6c = true
                break
            }
        }
        // Move 6c: extend the Move 4 cross-band flip to include ×2
        // (octave-UP) and ×½ (octave-DOWN) families. Same directSupport
        // check as Move 4, but direction-constrained: ×½ with cand < winner
        // folds DOWN (engine too high, truth at half-tempo), ×2 with
        // cand > winner folds UP (engine too low, truth at double-tempo).
        // Octave-feel cases whose verdict cross-band already dominates
        // don't fire here — those need Move 6b instead.
        if !resolved {
            let verdictSupport6c = Self.directSupport(winner.bpm, bandPeaks: bandPeaks)
            let r2 = 2.0
            let tol = BPMEngine.bpmMatchTolerance
            // Same bounded candidate set as Move 4 (includes ×2 and ×½).
            let candList = candidateSet(for: winner.bpm, minBPM: minBPM, maxBPM: maxBPM)
            for cand in candList where abs(cand - winner.bpm) > 0.5 {
                let ratio = max(cand, winner.bpm) / min(cand, winner.bpm)
                // Only ×2 / ×½ families
                guard abs(ratio - r2) <= tol * r2 else { continue }
                // Skip-list check (per-Move); entries live in
                // ~/Library/Application Support/BPMPLS/skip_lists.json.
                if SkipListStore.shared.isSkipped(path: url.path, for: .move6c) {
                    LogService.shared.log("  Move 6c SKIPPED (skip list): \(url.lastPathComponent) at \(String(format: "%.2f", winner.bpm)) BPM")
                    break
                }
                let candSupport = Self.directSupport(cand, bandPeaks: bandPeaks)
                guard candSupport >= move6cMinDirectSupport else { continue }
                guard Double(candSupport) > Double(verdictSupport6c) * move6cDirectSupportMargin else { continue }
                if cand < winner.bpm, abs(ratio - r2) <= tol * r2 {
                    // ×2 candidate (LOWER, ratio 2.0) → engine is at ×2 of truth. Fold DOWN.
                    LogService.shared.log("  Move 6c ×½ cross-band flip: \(String(format: "%.2f", winner.bpm)) -> \(String(format: "%.2f", cand)) BPM (×½ family, directSupport \(String(format: "%.2f", candSupport)) vs verdict \(String(format: "%.2f", verdictSupport6c)))")
                    winner = (bpm: cand, duration: Double(candSupport))
                    resolved = true
                    resolved6aOr6c = true
                    break
                } else if cand > winner.bpm, abs(ratio - r2) <= tol * r2 {
                    // ×2 candidate (HIGHER, ratio 2.0) → engine is at ×½ of truth. Fold UP.
                    LogService.shared.log("  Move 6c ×2 cross-band flip: \(String(format: "%.2f", winner.bpm)) -> \(String(format: "%.2f", cand)) BPM (×2 family, directSupport \(String(format: "%.2f", candSupport)) vs verdict \(String(format: "%.2f", verdictSupport6c)))")
                    winner = (bpm: cand, duration: Double(candSupport))
                    resolved = true
                    resolved6aOr6c = true
                    break
                }
            }
        }
        // Move 6b: grid-stability fold-DOWN for ×2 and ×3/2 families.
        // Targets octave-feel cases where the engine is reading the 2× or
        // 1.5× of the truth. Move 6a's chunk-vote ratio doesn't fire on
        // these because the verdict's beatCount is comparable to (or higher
        // than) the cand's — the discriminator is grid-stability
        // (1 − IBI variance over emitted beats), not beat volume.
        //
        // Order: runs after Move 4 but NOT after 6a/6c (see the
        // `resolved6aOr6c` note above): a Move 4 lift can still NEED 6b's
        // fold, but a 6a/6c lift would be cancelled by 6b's fold-DOWN.
        //
        // Both ×0.5 and ×2/3 are folded in the same `for` loop (×0.5
        // first, ×2/3 second); both log as "fold-DOWN" with the family.
        if !resolved6aOr6c { // run after Move 4 but not after 6a/6c
            for mult in move6bFoldMultipliers {
                let cand = winner.bpm * mult
                guard cand >= 70, cand <= 180 else { continue }
                // Skip-list check (per-Move); entries live in
                // ~/Library/Application Support/BPMPLS/skip_lists.json.
                if SkipListStore.shared.isSkipped(path: url.path, for: .move6b) {
                    LogService.shared.log("  Move 6b SKIPPED (skip list): \(url.lastPathComponent) at \(String(format: "%.2f", winner.bpm)) BPM")
                    break
                }
                // Find cand + verdict in multi-candidate scores (within ±3% tol)
                guard let candScore = multiCandidateScores.first(where: {
                    abs($0.bpm - cand) <= bpmMatchTolerance * cand
                }) else { continue }
                guard let verdictScore = multiCandidateScores.first(where: {
                    abs($0.bpm - winner.bpm) <= bpmMatchTolerance * winner.bpm
                }) else { continue }
                // Grid-stability check: cand must be MORE stable than verdict
                // by at least the margin. This is the core discriminator.
                guard candScore.gridStability >= verdictScore.gridStability + move6bGridStabilityMargin else { continue }
                // Minimum data for the cand's gridStability to be meaningful.
                guard candScore.beatCount >= move6bMinBeatCount else { continue }
                // Family label for the log line
                let familyLabel = (mult < 0.6) ? "×2" : "×3/2"
                LogService.shared.log("  Move 6b fold-DOWN: \(String(format: "%.2f", winner.bpm)) -> \(String(format: "%.2f", cand)) BPM (\(familyLabel) family, gridStab \(String(format: "%.3f", candScore.gridStability)) vs verdict \(String(format: "%.3f", verdictScore.gridStability)), cand beats \(candScore.beatCount))")
                winner = (bpm: cand, duration: Double(candScore.beatCount))
                resolved = true
                break
            }
        }
        LogService.shared.log("  winner: \(String(format: "%.2f", winner.bpm)) BPM covering \(String(format: "%.1f", winner.duration))s (\(segments.count) segment\(segments.count == 1 ? "" : "s"))")
        // Compute confidence from bandFracs + cluster dominance +
        // segment count + backbeat strength + tracker snap rate. NEVER overrides verdict.
        let bb = backbeatStrength(winner.bpm)
        let totalDur = segments.reduce(0.0) { $0 + $1.duration }
        let tol = max(1.5, BPMEngine.bpmMatchTolerance * winner.bpm)
        let winnerSegs = segments.filter { abs($0.bpm - winner.bpm) <= tol }
        let winnerDur = winnerSegs.reduce(0.0) { $0 + $1.duration }
        let clusterDurRatio = totalDur > 0 ? min(1.0, winnerDur / totalDur) : 0
        let segCountRatio = segments.isEmpty ? 0 : Double(winnerSegs.count) / Double(segments.count)
        var bandFracSum: Float = 0
        for bandPeaksList in bandPeaks {
            let frac = bandPeaksList.first(where: { abs($0.bpm - winner.bpm) <= tol })?.frac ?? 0
            bandFracSum += frac
        }
        let bandFracsAvg = Double(bandFracSum / 3.0)
        let bbNorm = Double(bb) / 2.0
        let trackerConf = Double(trackerFinalConfidence)
        let score = confidenceWeightBandFracs * bandFracsAvg
                   + confidenceWeightClusterDur * clusterDurRatio
                   + confidenceWeightSegCount * segCountRatio
                   + confidenceWeightBackbeat * bbNorm
                   + confidenceWeightTracker * trackerConf
        let level = confidenceLevel(score)
        LogService.shared.log(String(format: "  confidence: %@ (%.2f) [bandFracs=%.2f clusterDur=%.2f segCount=%.2f backbeat=%.2f tracker=%.2f]",
                                     level, score, bandFracsAvg, clusterDurRatio, segCountRatio, bbNorm, trackerConf))
        // Ambient detection heuristic — if no band has its top
        // autocorrelation peak in the 70-180 BPM range above 0.8 strength,
        // the track has no clear beat. Set noBeatFound so the UI can show
        // a "no beat" badge and (if opted in) the file is left without a
        // BPM tag. The corpus's ambient row catches; regular rows don't.
        let noBeat = detectAmbient(analysis: BPMAnalysis(
            bpm: winner.bpm, segments: segments,
            bandPeaksRaw: bandPeaks, bandPeaksRoleWeighted: roleBandPeaks,
            beatTimes: beatTimes,
            confidence: score,
            backbeatStrength: bb,
            multiCandidateScores: multiCandidateScores
        ))
        if noBeat {
            LogService.shared.log("  ambient: no band's top peak in 70-180 range above 0.8 strength — (no beat found)")
        }
        return BPMAnalysis(bpm: winner.bpm, segments: segments,
                           bandPeaksRaw: bandPeaks, bandPeaksRoleWeighted: roleBandPeaks,
                           beatTimes: beatTimes,
                           confidence: score,
                           backbeatStrength: bb,
                           multiCandidateScores: multiCandidateScores,
                           noBeatFound: noBeat)
    }

    /// Group segments into tempo clusters using the same ±3% closeness the segmenter
    /// uses, so a track hovering 97–103 forms ONE ~100 cluster instead of seven
    /// rounded buckets. Each cluster reports its duration-weighted mean BPM and total
    /// covered seconds, most-covered first.
    static func tempoClusters(_ segments: [SegmentInfo]) -> [(bpm: Double, duration: Double)] {
        var clusters: [(weighted: Double, duration: Double)] = []
        for s in segments where s.duration > 0 {
            if let i = clusters.firstIndex(where: {
                abs($0.weighted / $0.duration - s.bpm) <= max(1.5, bpmMatchTolerance * s.bpm)
            }) {
                clusters[i].weighted += s.bpm * s.duration
                clusters[i].duration += s.duration
            } else {
                clusters.append((s.bpm * s.duration, s.duration))
            }
        }
        return clusters.map { (bpm: $0.weighted / $0.duration, duration: $0.duration) }
            .sorted { $0.duration > $1.duration }
    }


    // MARK: - Multi-tempo gate


    // MARK: - Range parsing & octave constraint

    /// Clean whole-number BPM for display/tagging (122.16 -> 122, 121.69 -> 122).
    static func roundedBPM(_ bpm: Double) -> Int {
        guard bpm.isFinite, bpm > 0 else { return 0 }
        return max(1, Int(bpm.rounded()))
    }


    // MARK: - Confidence

    /// Threshold for the "low" band (< this). Below this the engine's verdict is
    /// deemed high-risk and the UI surfaces a gray badge.
    static let confidenceLowThreshold: Double = 0.40
    /// Threshold for the "med" band (< this; otherwise "high").
    static let confidenceHighThreshold: Double = 0.70
    /// Aggregation weights (sum to 1.0). Tunable against corpus calibration.
    static let confidenceWeightBandFracs: Double = 0.25
    static let confidenceWeightClusterDur: Double = 0.25
    static let confidenceWeightSegCount:   Double = 0.15
    static let confidenceWeightBackbeat:   Double = 0.20
    static let confidenceWeightTracker:    Double = 0.15

    // MARK: - Move 4 (cross-band flip)

    /// Move 4 cross-band direct-support flip margin. A candidate's
    /// cross-band direct support (sum of whole-track peak strengths across
    /// the three bands, within bpmMatchTolerance) must exceed the verdict's
    /// by at least this multiple. 1.15× by corpus calibration: at 1.0× the
    /// rule over-fires on coincidental cross-band peaks (gap ~1.07×); at
    /// 1.15× it still fires on the genuine truth matches (gap ≥ 1.2×).
    static let move4DirectSupportMargin: Double = 1.15
    /// Minimum cross-band direct support for a candidate to qualify for the
    /// Move 4 flip. Below this, the candidate is too weak in the whole-track
    /// peaks to be a real tempo.
    static let move4MinDirectSupport: Float = 0.5
    // MARK: - Move 6a / 6c — chunk-vote lift + ×2/×½ extension

    /// Move 6a chunk-vote ratio threshold. The candidate's beatCount (from
    /// the multi-candidate tracker) must exceed the verdict's by at least
    /// this multiple for the rule to fire. Genuine ×3/2-low positives show
    /// ratios ~1.47-1.50×, well above the 1.3× floor; near-miss negatives
    /// land in the same ratio band and are gated by the directSupport
    /// floor below.
    static let move6aChunkVoteRatio: Double = 1.3
    /// Move 6a snap-rate tolerance. The candidate's snap rate must be
    /// within this absolute difference of the verdict's. 0.1 was chosen
    /// by calibration: too tight and we miss cases where the
    /// tracker has slightly different confidence at the two tempos; too
    /// loose and we false-fire on tracks where the candidate is just
    /// noise (snap ~0).
    static let move6aSnapTolerance: Double = 0.1
    /// Move 6a minimum cross-band directSupport for the candidate.
    /// 0.7, not the 0.5 Move 4 uses: the ×3/2-lift positives all clear
    /// 0.7, but a listening-review false positive sat at 0.58 (an
    /// over-lift from the true 98 to 156). Raising the floor keeps the
    /// true positives and drops that case; remaining false positives
    /// live in the move6a skip list.
    static let move6aMinDirectSupport: Float = 0.7
    /// Move 6c — when extending the family gate to include ×2/×½, use
    /// the same Move 4 cross-band margin (1.15) and same directSupport
    /// floor (0.5). Direction-constrained: ×½ with cand < winner flips
    /// DOWN, ×2 with cand > winner folds UP.
    static let move6cDirectSupportMargin: Double = 1.15
    static let move6cMinDirectSupport: Float = 0.5

    // MARK: - Move 6b — grid-stability fold-DOWN (×2/×3/2)

    /// Move 6b grid-stability margin. The cand's gridStability (1 − IBI
    /// variance over emitted beats) must exceed the verdict's by at least
    /// this much. 0.01 is the calibrated value: the differences between
    /// octave-feel truths and their ×2/×3/2 artifacts cluster in
    /// 0.01-0.10; anything tighter over-fires on near-equal-grid pairs
    /// (a cand that isn't clearly the truth shouldn't fire). Known false
    /// positives are enumerated in the move6b skip list at
    /// `~/Library/Application Support/BPMPLS/skip_lists.json`.
    static let move6bGridStabilityMargin: Float = 0.01
    /// Move 6b minimum beatCount for the cand. 100 beats ≈ 60-90s of
    /// tracker data, enough for gridStability to be meaningful. Lower
    /// and we'd fire on candidates that the tracker only saw for a
    /// handful of chunks (false confidence from sparse data).
    static let move6bMinBeatCount: Int = 100
    /// Move 6b max family multipliers. We fold-DOWN by ×0.5 (×2 family)
    /// and ×2/3 (×3/2 family). The reverse directions are already handled
    /// by Move 6a (×3/2-LOW lift UP). Locked: do not add ×4/3 here
    /// (Move 4 cross-band already handles that direction).
    static let move6bFoldMultipliers: [Double] = [0.5, 2.0/3.0]

    // MARK: - Ambient detection

    /// Folder-affinity flip margin. A track's verdict must be in a
    /// pattern-period family (×4/3 or ×3/2) with the folder anchor for
    /// the prior to fire. Aligned with Move 4's margin (1.15) for
    /// consistency — the same gap test rejects coincidental
    /// filtered-house-style peaks.
    // (deleted: move5FolderAffinityMargin — orphaned)
    // swiftlint:disable:next unused: Double = 1.15
    /// Minimum peak strength (frac of band best) for a peak to count as
    /// "real" in the ambient detection. Below this the peak is noise.
    static let move5AmbientMinPeakFrac: Float = 0.8
    /// Maximum fraction of track that the largest tempo cluster can
    /// cover and still be flagged as ambient. Below this, the verdict
    /// is "unstable" (chunks vote for many different tempos, no clear
    /// pulse) — the signal of a real ambient track. Above this, the
    /// track has a stable tempo cluster even if the whole-track
    /// autocorrelation is weak (real tracks can have weak
    /// autocorr but stable clusters covering >40% of the track).
    /// Calibration: 0.40 catches the hardest ambient case (largest
    /// cluster ~35% of a 136 s track) while not catching slow-tempo
    /// tracks with >40% cluster coverage.
    static let move5AmbientMaxClusterFraction: Double = 0.40
    /// Ambient detection heuristic. A track is "no beat found"
    /// when BOTH conditions hold:
    ///   1. NO band has its top peak (the first entry in bandPeaks, which
    ///      is the strongest) in the 70-180 BPM range above 0.8 strength.
    ///   2. The largest tempo cluster covers < 40% of total segment
    ///      duration (verdict is "unstable" — no clear pulse).
    /// Why both: real beat-driven tracks usually have a strong auto-
    /// correlation peak in the musical range OR a stable tempo cluster
    /// covering most of the track. Ambient tracks have neither (all band
    /// tops outside 70-180; largest cluster only a small share of the
    /// track).
    static func detectAmbient(analysis: BPMAnalysis) -> Bool {
        // Check 1: no band's top peak is in 70-180 above 0.8.
        for peaks in analysis.bandPeaksRaw {
            if let top = peaks.first {
                if top.bpm >= 70, top.bpm <= 180, top.frac >= move5AmbientMinPeakFrac {
                    return false  // has a strong top in the BPM range
                }
            }
        }
        // Check 2: largest tempo cluster covers < 40% of total segments.
        let clusters = tempoClusters(analysis.segments)
        let totalDuration = analysis.segments.reduce(0.0) { $0 + $1.duration }
        if totalDuration > 0, let largest = clusters.first {
            if largest.duration / totalDuration >= move5AmbientMaxClusterFraction {
                return false  // has a stable cluster
            }
        }
        return true  // both conditions hold → ambient
    }

    /// 3-state confidence label from a score in [0,1]. Pure function; safe for tests.
    static func confidenceLevel(_ score: Double) -> String {
        if score < confidenceLowThreshold { return "low" }
        if score < confidenceHighThreshold { return "med" }
        return "high"
    }


    static func foldToRange(_ rawBPM: Double, minBPM: Double, maxBPM: Double) -> Double {
        guard rawBPM.isFinite, rawBPM > 0 else { return rawBPM }
        var bpm = rawBPM
        var guardCount = 0
        while bpm < minBPM && guardCount < 16 { bpm *= 2.0; guardCount += 1 }
        while bpm > maxBPM && guardCount < 32 { bpm /= 2.0; guardCount += 1 }
        return bpm
    }

    /// Consensus-aware fold: a raw autocorrelation reading can sit at a
    /// pattern-level period (e.g. 3 beats = tempo/3), where the plain octave fold
    /// strands it at 2/3 of the true tempo (40.6 -> 81.2 while MID says 122).
    /// Try x2/x3/x4 (and down-folds); a candidate landing within ±3% of another
    /// band's reading wins; otherwise the plain octave fold stands.
    /// ×1.5/⅔ folds are FORBIDDEN: a 3-beat pattern period can octave-fold to
    /// a value that then "corroborates" ×1.5 candidates from the same pattern
    /// family — circular reinforcement that grows a phantom cluster and flips
    /// the verdict (a documented trap-case in calibration). That failure family is handled at
    /// verdict level instead (zero-support veto, see analyzeDetailedSync).
    static func foldWithConsensus(raw: Double, selfIndex: Int, raws: [Double?],
                                  minBPM: Double, maxBPM: Double) -> Double {
        let fallback = foldToRange(raw, minBPM: minBPM, maxBPM: maxBPM)
        guard raw.isFinite, raw > 0 else { return fallback }
        let candidates = [0.25, 1.0 / 3.0, 0.5, 1.0, 2.0, 3.0, 4.0]
            .map { raw * $0 }
            .filter { $0 >= minBPM && $0 <= maxBPM }
        var others: [Double] = []
        for (i, r) in raws.enumerated() where i != selfIndex {
            if let r = r, r.isFinite, r > 0 {
                others.append(foldToRange(r, minBPM: minBPM, maxBPM: maxBPM))
            }
        }
        var best = fallback
        var bestSupport = 0
        for cand in candidates {
            let support = others.filter { abs($0 - cand) <= bpmMatchTolerance * cand }.count
            if support > bestSupport {
                bestSupport = support
                best = cand
            }
        }
        return best
    }

    // MARK: - Audio loading (AVAudioFile -> mono Float, whole file up to cap)

    /// Streaming decode with AVAudioFile → AVAssetReader
    /// fallback (a reference DJ player's PCM-loader order); feeds the
    /// peak builder block by block so the waveform can grow during load.
    /// Returns the full mono samples for the BPM verdict as before.
    static func streamMonoSamples(
        url: URL,
        onPartialPeaks: ((PeakPyramid) -> Void)? = nil,
        partialInterval: Double = 0.2
    ) throws -> ([Float], Double) {
        var mono: [Float] = []
        var sampleRate: Double = 0
        final class BuilderBox {
            var builder: PeakPyramid.StreamingBuilder?
        }
        let box = BuilderBox()
        var lastEmit = Date()

        func ensure(rate: Double) {
            if box.builder == nil || box.builder?.sampleRate != rate {
                box.builder = PeakPyramid.StreamingBuilder(sampleRate: rate)
                mono.removeAll(keepingCapacity: true)
            }
        }
        func absorb(_ buffer: AVAudioPCMBuffer, channels: Int) {
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { return }
            if channels == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
                box.builder?.append(UnsafeBufferPointer(start: data[0], count: n))
            } else {
                var sum = [Float](repeating: 0, count: n)
                for ch in 0..<channels {
                    sum.withUnsafeMutableBufferPointer { sp in
                        vDSP_vadd(sp.baseAddress!, 1, data[ch], 1, sp.baseAddress!, 1, vDSP_Length(n))
                    }
                }
                var inv = 1.0 / Float(channels)   // channel-average in place
                sum.withUnsafeMutableBufferPointer { sp in
                    vDSP_vsmul(sp.baseAddress!, 1, &inv, sp.baseAddress!, 1, vDSP_Length(n))
                    mono.append(contentsOf: UnsafeBufferPointer(start: sp.baseAddress!, count: n))
                    box.builder?.append(UnsafeBufferPointer(start: sp.baseAddress!, count: n))
                }
            }
            if let b = box.builder, let onPartialPeaks,
               Date().timeIntervalSince(lastEmit) >= partialInterval {
                lastEmit = Date()
                onPartialPeaks(b.partial())
            }
        }

        // primary: AVAudioFile (existing semantics, incl. the analysis cap)
        do {
            let file = try AVAudioFile(forReading: url)
            let fmt = file.processingFormat
            sampleRate = fmt.sampleRate
            let channels = Int(fmt.channelCount)
            guard sampleRate > 0, channels > 0 else { throw BPMError.unreadableAudio }
            ensure(rate: sampleRate)
            var framesToRead = min(file.length,
                                   AVAudioFramePosition(maxAnalysisSeconds * sampleRate))
            guard framesToRead > 0 else { throw BPMError.unreadableAudio }
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 65536)!
            while framesToRead > 0 {
                let n = AVAudioFrameCount(min(65536, framesToRead))
                try file.read(into: buf, frameCount: n)
                if buf.frameLength == 0 { break }
                absorb(buf, channels: channels)
                framesToRead -= AVAudioFramePosition(buf.frameLength)
            }
            if var b = box.builder { onPartialPeaks?(b.finish()) }
            return (mono, sampleRate)
        } catch {
            LogService.shared.log("  AVAudioFile path failed (\(error.localizedDescription)); AVAssetReader fallback")
        }

        // fallback: AVAssetReader — handles some formats the file API
        // rejects. Return the FALLBACK's samples — the old code
        // discarded them and returned the failed path's (empty) mono.
        if let (samples, rate) = try? readMonoViaAssetReaderFallback(url: url) {
            if var b = box.builder { onPartialPeaks?(b.finish()) }
            return (samples, rate)
        }

        throw BPMError.unreadableAudio
    }


    private final class LockedBox<T> {
        private var value: T?
        private let lock = NSLock()
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Public wrapper for PullDeck's loader chain.
    static func readMonoViaAssetReaderPublic(url: URL) throws -> ([Float], Double) {
        try readMonoViaAssetReaderFallback(url: url)
    }

    static func readMonoViaAssetReaderFallback(url: URL) throws -> ([Float], Double) {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        let box = LockedBox<AVAssetTrack?>()
        Task {
            let t = try? await asset.loadTracks(withMediaType: .audio).first
            box.set(t)
            sem.signal()
        }
        sem.wait()
        guard let track = box.get(), let t = track else { throw BPMError.unreadableAudio }
        return try readMonoViaAssetReader(asset: asset, track: t) { _, _ in }
    }

    /// AVAssetReader body: Float32/2ch output, streamed in blocks. The
    /// modern API: the TRACK OUTPUT owns copyNextSampleBuffer; wrap the
    /// CMSampleBuffer into an AVAudioPCMBuffer via its AudioBufferList.
    private static func readMonoViaAssetReader(
        asset: AVURLAsset, track: AVAssetTrack,
        onBlock: (AVAudioPCMBuffer, Int) -> Void
    ) throws -> ([Float], Double) {
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        guard reader.startReading() else { throw BPMError.unreadableAudio }

        var mono: [Float] = []
        var rate: Double = 44100
        var pcmFmt: AVAudioFormat? = nil
        while let sample = output.copyNextSampleBuffer() {
            var abl = AudioBufferList()
            var blockBuf: CMBlockBuffer? = nil
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: nil, bufferListOut: &abl,
                bufferListSize: MemoryLayout<AudioBufferList>.size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuf)
            guard status == noErr, let data = abl.mBuffers.mData else { continue }
            let ch = Int(abl.mNumberBuffers)
            let floats = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self),
                                            count: Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size)
            if ch <= 1 {
                mono.append(contentsOf: floats)
            } else {
                // interleaved stereo → mono downmix
                mono.reserveCapacity(mono.count + floats.count / 2)
                var i = 0
                while i + 1 < floats.count {
                    mono.append((floats[i] + floats[i + 1]) * 0.5)
                    i += 2
                }
            }
            rate = CMSampleBufferGetPresentationTimeStamp(sample).isValid
                ? track.nominalFrameRate > 0 ? Double(track.nominalFrameRate) : rate
                : rate
            pcmFmt = pcmFmt ?? AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: rate, channels: 1, interleaved: false)
        }
        guard !mono.isEmpty else { throw BPMError.unreadableAudio }
        return (mono, rate)
    }

    static func readMonoSamples(url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let sampleRate = srcFormat.sampleRate
        let channels = Int(srcFormat.channelCount)
        guard sampleRate > 0, channels > 0 else { throw BPMError.unreadableAudio }
        var framesToRead = file.length
        let cap = AVAudioFramePosition(maxAnalysisSeconds * sampleRate)
        if framesToRead > cap {
            LogService.shared.log("  note: file truncated to \(Int(maxAnalysisSeconds))s analysis cap")
            framesToRead = cap
        }
        guard framesToRead > 0 else { throw BPMError.unreadableAudio }

        let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: srcFormat.channelCount, interleaved: false)!
        var mono: [Float] = []
        mono.reserveCapacity(Int(framesToRead))
        let chunkFrames: AVAudioFrameCount = 65536

        func appendDownmix(_ buffer: AVAudioPCMBuffer) {
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { return }
            if channels == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
            } else {
                var sum = [Float](repeating: 0, count: n)
                for ch in 0..<channels {
                    sum.withUnsafeMutableBufferPointer { sp in
                        vDSP_vadd(sp.baseAddress!, 1, data[ch], 1, sp.baseAddress!, 1, vDSP_Length(n))
                    }
                }
                var scale = Float(channels)
                var divided = [Float](repeating: 0, count: n)
                vDSP_vsdiv(sum, 1, &scale, &divided, 1, vDSP_Length(n))
                mono.append(contentsOf: divided)
            }
        }

        /// A sloppy final MP3 packet can make AVAudioFile.read throw on
        /// the last few frames even though 99.99% decoded fine. Tolerate the failure
        /// once we already hold >= 60s of audio; only early failures are fatal.
        func readChunk(into buffer: AVAudioPCMBuffer) throws -> Bool {
            let want = AVAudioFrameCount(min(Int64(chunkFrames), framesToRead - file.framePosition))
            do {
                try file.read(into: buffer, frameCount: want)
            } catch {
                guard Double(mono.count) / sampleRate >= 60 else { throw BPMError.unreadableAudio }
                LogService.shared.log("  note: undecodable tail skipped at frame \(file.framePosition)/\(framesToRead) — analyzing what decoded")
                return false
            }
            return true
        }

        if srcFormat.commonFormat == .pcmFormatFloat32 && !srcFormat.isInterleaved {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
                throw BPMError.unreadableAudio
            }
            while file.framePosition < framesToRead {
                guard try readChunk(into: buffer) else { break }
                if buffer.frameLength == 0 { break }
                appendDownmix(buffer)
            }
        } else {
            // Non-float / interleaved source: convert to float32 first.
            guard let converter = AVAudioConverter(from: srcFormat, to: floatFormat),
                  let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: chunkFrames) else {
                throw BPMError.unreadableAudio
            }
            while file.framePosition < framesToRead {
                guard try readChunk(into: inBuf) else { break }
                if inBuf.frameLength == 0 { break }
                var convError: NSError?
                var consumed = false
                let status = converter.convert(to: outBuf, error: &convError) { _, statusPtr in
                    if consumed {
                        statusPtr.pointee = .endOfStream
                        return nil
                    }
                    consumed = true
                    statusPtr.pointee = .haveData
                    return inBuf
                }
                if status == .error { throw convError ?? BPMError.unreadableAudio }
                appendDownmix(outBuf)
                if status == .endOfStream { break }
            }
        }
        guard !mono.isEmpty else { throw BPMError.unreadableAudio }
        return (mono, sampleRate)
    }

    // MARK: - Component 3 step 1: multi-band split (4th-order Butterworth biquads)

    static func butterworthLowPass(cutoff: Double, sampleRate: Double, q: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw0 = cos(w0)
        let a0 = 1.0 + alpha
        let b0 = (1.0 - cosw0) / 2.0 / a0
        return [b0, (1.0 - cosw0) / a0, b0, -2.0 * cosw0 / a0, (1.0 - alpha) / a0]
    }

    static func butterworthHighPass(cutoff: Double, sampleRate: Double, q: Double) -> [Double] {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let alpha = sin(w0) / (2.0 * q)
        let cosw0 = cos(w0)
        let a0 = 1.0 + alpha
        let b0 = (1.0 + cosw0) / 2.0 / a0
        return [b0, -(1.0 + cosw0) / a0, b0, -2.0 * cosw0 / a0, (1.0 - alpha) / a0]
    }

    // Two cascaded biquads with these Q values make a true 4th-order Butterworth.
    static let butterworthQ: [Double] = [0.54119610, 1.3065630]

    static func applyFilter(_ coeffs: [Double], to samples: [Float]) -> [Float] {
        let sections = coeffs.count / 5
        guard sections > 0,
              var biquad = vDSP.Biquad(coefficients: coeffs, channelCount: 1,
                                       sectionCount: vDSP_Length(sections), ofType: Float.self) else {
            return samples
        }
        return biquad.apply(input: samples)
    }

    /// Low (<150 Hz), Mid (150 Hz–2 kHz), High (>2 kHz).
    static func splitBands(samples: [Float], sampleRate: Double) -> [[Float]] {
        var low: [Double] = []
        var mid: [Double] = []
        var high: [Double] = []
        for q in butterworthQ {
            low += butterworthLowPass(cutoff: 150, sampleRate: sampleRate, q: q)
            mid += butterworthHighPass(cutoff: 150, sampleRate: sampleRate, q: q)
            mid += butterworthLowPass(cutoff: 2000, sampleRate: sampleRate, q: q)
            high += butterworthHighPass(cutoff: 2000, sampleRate: sampleRate, q: q)
        }
        return [applyFilter(low, to: samples), applyFilter(mid, to: samples), applyFilter(high, to: samples)]
    }

    // MARK: - Component 3 step 2: spectral-flux onset envelope (vDSP.FFT per band)

    static func onsetEnvelope(samples: [Float], sampleRate: Double) -> [Float] {
        onsetEnvelopeAndEnergies(samples: samples, sampleRate: sampleRate).envelope
    }

    /// Spectral-flux onset envelope PLUS per-frame sub-band energy sums
    /// ([low <150 Hz, mid 150 Hz–2 kHz, presence 2–5 kHz, air >5 kHz]) captured
    /// from the same STFT frames — the feature source for instrument
    /// classification. Because the input is already band-filtered, only the
    /// band's passband carries energy; summing across bands reconstructs the
    /// full-spectrum signature at each frame.
    static func onsetEnvelopeAndEnergies(samples: [Float], sampleRate: Double) -> (envelope: [Float], energies: [[Float]]) {
        let n = windowSize, hop = hopSize, halfN = n / 2
        guard samples.count >= n,
              let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) else { return ([], []) }
        let binHz = sampleRate / Double(n)
        let lowEnd = min(halfN, max(1, Int((150.0 / binHz).rounded(.up))))
        let midEnd = min(halfN, max(lowEnd + 1, Int((2000.0 / binHz).rounded(.up))))
        let presEnd = min(halfN, max(midEnd + 1, Int((5000.0 / binHz).rounded(.up))))
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var prevLogMag = [Float](repeating: 0, count: halfN)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        var envelope: [Float] = []
        envelope.reserveCapacity(samples.count / hop + 1)
        var energies: [[Float]] = []
        energies.reserveCapacity(samples.count / hop + 1)
        var pos = 0
        while pos + n <= samples.count {
            let windowed = vDSP.multiply(samples[pos..<(pos + n)], window)
            for i in 0..<n { real[i] = windowed[i]; imag[i] = 0 }
            var mags = [Float](repeating: 0, count: halfN)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    fft.forward(input: split, output: &split)
                    mags.withUnsafeMutableBufferPointer { mp in
                        vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(halfN))
                    }
                }
            }
            let roots = vForce.sqrt(mags)
            var flux: Float = 0 // half-wave rectified log-magnitude difference
            for i in 0..<halfN {
                let l = log1p(roots[i])
                let d = l - prevLogMag[i]
                if d > 0 { flux += d }
                prevLogMag[i] = l
            }
            envelope.append(flux)
            // Sub-band energy sums for onset classification (bin 0/DC skipped).
            var e = [Float](repeating: 0, count: 4)
            for i in 1..<lowEnd { e[0] += roots[i] }
            for i in lowEnd..<midEnd { e[1] += roots[i] }
            for i in midEnd..<presEnd { e[2] += roots[i] }
            if presEnd < halfN { for i in presEnd..<halfN { e[3] += roots[i] } }
            energies.append(e)
            pos += hop
        }
        return (smoothEnvelope(envelope), energies)
    }

    /// 5-tap triangular smoothing so the autocorrelation peak is interpolable.
    static func smoothEnvelope(_ x: [Float]) -> [Float] {
        guard x.count >= 5 else { return x }
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var s: Float = 3 * x[i]
            if i >= 1 { s += 2 * x[i - 1] }
            if i >= 2 { s += x[i - 2] }
            if i + 1 < x.count { s += 2 * x[i + 1] }
            if i + 2 < x.count { s += x[i + 2] }
            out[i] = s / 9.0
        }
        return out
    }

    // MARK: - Component 3 step 3: regularity scoring (normalized IOI variance)

    static func pickPeaks(envelope: [Float], envRate: Double) -> [Double] {
        let count = envelope.count
        guard count > 4, envRate > 0 else { return [] }
        let mean = vDSP.mean(envelope)
        var meanSquare: Float = 0
        vDSP_measqv(envelope, 1, &meanSquare, vDSP_Length(count))
        let sd = max(0, meanSquare - mean * mean).squareRoot()
        guard sd > 1e-9 else { return [] }
        let threshold = mean + 1.5 * sd
        let minDist = max(1, Int(0.25 * envRate))
        var peaks: [(index: Int, amp: Float)] = []
        var i = 1
        while i < count - 1 {
            let v = envelope[i]
            if v > threshold && v >= envelope[i - 1] && v >= envelope[i + 1] {
                if let last = peaks.last, i - last.index < minDist {
                    if v > last.amp { peaks[peaks.count - 1] = (i, v) }
                } else {
                    peaks.append((i, v))
                }
            }
            i += 1
        }
        return peaks.map { Double($0.index) / envRate }
    }

    /// Coefficient-of-variation squared of inter-onset intervals (nil if < 4 peaks).
    static func normalizedIOIVariance(peaks: [Double]) -> Double? {
        guard peaks.count >= 4 else { return nil }
        var iois: [Double] = []
        iois.reserveCapacity(peaks.count - 1)
        for i in 1..<peaks.count { iois.append(peaks[i] - peaks[i - 1]) }
        let mean = iois.reduce(0, +) / Double(iois.count)
        guard mean > 0 else { return nil }
        let variance = iois.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(iois.count)
        return variance / (mean * mean)
    }


    /// Band indices sorted by per-chunk IOI regularity (best first); unmeasurable
    /// bands last, ordered by energy. Replaces single-band selection for robustness.
    static func bandVarianceOrder(chunks: [[Float]], envRate: Double) -> [Int] {
        chunks.indices.sorted { a, b in
            let va = chunks[a].isEmpty ? nil : normalizedIOIVariance(peaks: pickPeaks(envelope: chunks[a], envRate: envRate))
            let vb = chunks[b].isEmpty ? nil : normalizedIOIVariance(peaks: pickPeaks(envelope: chunks[b], envRate: envRate))
            switch (va, vb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let ea = chunks[a].isEmpty ? Float(0) : vDSP.mean(chunks[a])
                let eb = chunks[b].isEmpty ? Float(0) : vDSP.mean(chunks[b])
                return ea > eb
            }
        }
    }

    /// Ratios where a LOW-vs-nominee disagreement means "same groove, different
    /// metrical depth" and the kick wins. ×3/2 is deliberately absent: a 3-beat
    /// pattern period reads as tempo ×2/3, and legitimizing it pulled true house
    /// tempos down (both real-world ×3/2 firings were wrong). ×4/3 (dotted-8th
    /// hat artifact) and ×2 (half-time feel) remain, evidence-backed.
    static let metricalRatios = [2.0, 4.0 / 3.0]

    /// Full harmonic family (incl. x3/2 and x5/4) — used only to SUPPRESS false
    /// multi-tempo flags, never to move a verdict. Same groove at another metrical
    /// depth is not a tempo change. x5/4: a 5-beat pattern period reads as tempo x 4/5
    /// (e.g. Raze "Bass Power" 119 vs 95.2 — exactly x5/4, same groove).
    static let harmonicRatios = [2.0, 1.5, 4.0 / 3.0, 5.0 / 4.0]

    /// Kick tiebreak (in practice the low end does carry the tempo): when
    /// the winning band and the LOW band land on
    /// harmonic relatives (x2 / x4/3), the LOW band's reading is the tempo a
    /// listener taps — kicks state the pulse, hats and snares subdivide it. Returns the
    /// low-band reading in that case, the nominee otherwise.
    static func metricalTiebreak(nominee: Double, lowBand: Double) -> Double {
        guard nominee.isFinite, nominee > 0, lowBand.isFinite, lowBand > 0 else { return nominee }
        let ratio = nominee / lowBand
        if abs(ratio - 1.0) <= bpmMatchTolerance { return nominee } // bands agree
        let r = max(nominee, lowBand) / min(nominee, lowBand)
        for m in metricalRatios where abs(r - m) <= bpmMatchTolerance * m {
            LogService.shared.log("  kick tiebreak: \(String(format: "%.2f", nominee)) -> \(String(format: "%.2f", lowBand)) BPM (low band carries the pulse)")
            return lowBand
        }
        return nominee
    }

    /// Every band proposes its own tempo: autocorrelation top-1, consensus-folded into
    /// range (foldWithConsensus repairs 3-beat pattern periods). The nominee is the
    /// first success in regularity order, falling back through the remaining bands when
    /// a band's autocorrelation can't produce a BPM (regular-but-periodicity-free
    /// content, e.g. an atmospheric intro pad). When the nominee comes from MID/HIGH
    /// but the LOW band locked onto a harmonic relative (x2 / x4/3), the kick wins —
    /// fixes dotted-8th (3/4-beat) hat/snare periodicity outvoting the real pulse
    /// (e.g. 110 over 82.5, 134 over 100). Returns the value AND the band it came from
    /// (0 after a kick tiebreak — the value is the LOW band's).
    static func bpmFromBandChunks(_ chunks: [[Float]], envRate: Double,
                                  minBPM: Double, maxBPM: Double) -> (bpm: Double, band: Int)? {
        var raws = [Double?](repeating: nil, count: chunks.count)
        for index in chunks.indices where !chunks[index].isEmpty {
            raws[index] = bpmFromEnvelope(chunks[index], envRate: envRate)
        }
        var perBand = [Double?](repeating: nil, count: chunks.count)
        for index in chunks.indices {
            if let raw = raws[index] {
                perBand[index] = foldWithConsensus(raw: raw, selfIndex: index, raws: raws,
                                                   minBPM: minBPM, maxBPM: maxBPM)
            }
        }
        for index in bandVarianceOrder(chunks: chunks, envRate: envRate) {
            guard let nominee = perBand[index] else { continue }
            if index != 0, let low = perBand[0] {
                let verdict = metricalTiebreak(nominee: nominee, lowBand: low)
                return (verdict, verdict == low && verdict != nominee ? 0 : index)
            }
            return (nominee, index)
        }
        return nil
    }

    // MARK: - Component 3 step 4/5: autocorrelation BPM (+ parabolic interpolation)

    static func bpmFromEnvelope(_ envelope: [Float], envRate: Double) -> Double? {
        let count = envelope.count
        guard count > 64, envRate > 0 else { return nil }
        let mean = vDSP.mean(envelope)
        let centered = vDSP.add(-mean, envelope)
        let lagMin = max(2, Int((envRate * 60.0 / 300.0).rounded(.down)))
        let lagMax = min(count - 2, Int((envRate * 60.0 / 40.0).rounded(.up)))
        guard lagMax > lagMin else { return nil }
        var values = [Float](repeating: 0, count: lagMax + 1)
        var bestLag = lagMin
        var bestVal = -Float.infinity
        centered.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for lag in lagMin...lagMax {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(count - lag))
                values[lag] = dot
                if dot > bestVal { bestVal = dot; bestLag = lag }
            }
        }
        guard bestVal > 0 else { return nil }
        var lagF = Double(bestLag)
        if bestLag > lagMin && bestLag < lagMax {
            let y0 = Double(values[bestLag - 1]), y1 = Double(values[bestLag]), y2 = Double(values[bestLag + 1])
            let denom = y0 - 2.0 * y1 + y2
            if abs(denom) > 1e-9 { lagF += 0.5 * (y0 - y2) / denom }
        }
        guard lagF > 0 else { return nil }
        return 60.0 * envRate / lagF
    }

    // MARK: - Backbeat corroboration

    /// Top-K autocorrelation local maxima of a whole-band envelope, strongest first, as
    /// (bpm, fraction of the band's best peak). Used for backbeat evidence, not for picking
    /// a tempo. With `fold` true (default) each peak is folded into [minBPM, maxBPM]; with
    /// `fold` false the raw BPM is reported (scan floor widened to 30 BPM) so half-tempo
    /// backbeat evidence below the slider minimum survives instead of folding onto the
    /// tempo itself and vanishing in dedupe.
    static func topEnvelopePeaks(_ envelope: [Float], envRate: Double, k: Int = 6,
                                 minBPM: Double, maxBPM: Double, fold: Bool = true) -> [(bpm: Double, frac: Float)] {
        let count = envelope.count
        guard count > 64, envRate > 0 else { return [] }
        let mean = vDSP.mean(envelope)
        let centered = vDSP.add(-mean, envelope)
        let lagMin = max(2, Int((envRate * 60.0 / 300.0).rounded(.down)))
        let lagFloor = fold ? 40.0 : 30.0
        let lagMax = min(count - 2, Int((envRate * 60.0 / lagFloor).rounded(.up)))
        guard lagMax > lagMin else { return [] }
        var values = [Float](repeating: 0, count: lagMax + 1)
        centered.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            for lag in lagMin...lagMax {
                var dot: Float = 0
                vDSP_dotpr(base, 1, base + lag, 1, &dot, vDSP_Length(count - lag))
                values[lag] = dot
            }
        }
        var bestVal: Float = 0
        for lag in lagMin...lagMax { bestVal = max(bestVal, values[lag]) }
        guard bestVal > 0 else { return [] }
        var peaks: [(lag: Int, value: Float)] = []
        for lag in (lagMin + 1)..<lagMax {
            let v = values[lag]
            if v > 0, v >= values[lag - 1], v >= values[lag + 1] {
                peaks.append((lag, v))
            }
        }
        peaks.sort { $0.value > $1.value }
        var out: [(bpm: Double, frac: Float)] = []
        for p in peaks.prefix(k) {
            let raw = 60.0 * envRate / Double(p.lag)
            let bpm = fold ? foldToRange(raw, minBPM: minBPM, maxBPM: maxBPM) : raw
            // dedupe near-identical readings
            if !out.contains(where: { abs($0.bpm - bpm) <= bpmMatchTolerance * bpm }) {
                out.append((bpm, p.value / bestVal))
            }
        }
        return out
    }

    /// Cross-band direct support: sum of whole-track peak strengths within
    /// bpmMatchTolerance of `t`, across all bands. The core evidence signal
    /// shared by the ×4/3 resolution, Move 4, Move 6a/6c, and folder affinity:
    /// the truth tempo shows up across bands; artifacts stay band-specific.
    static func directSupport(_ t: Double, bandPeaks: [[(bpm: Double, frac: Float)]]) -> Float {
        bandPeaks.reduce(0) { sum, peaks in
            sum + (peaks.first(where: { abs($0.bpm - t) <= bpmMatchTolerance * t })?.frac ?? 0)
        }
    }

    /// "2 and 4" evidence: a backbeat (snare/clap/hat on beats 2 & 4) shows up as a
    /// MID or HIGH periodicity at exactly HALF the true tempo — and it must be a real
    /// peak (>= 25% of the band's best), not a weak subharmonic of the kick. Whole
    /// genres have no backbeat (half-time trap snare on 3, 2-step, ambient), so this
    /// corroborates but never penalizes.
    static func backbeatSupport(bandPeaks: [[(bpm: Double, frac: Float)]], for bpm: Double) -> Bool {
        guard bpm > 0 else { return false }
        let half = bpm / 2.0
        let tol = max(1.5, bpmMatchTolerance * half)
        return bandPeaks.dropFirst().contains { peaks in
            peaks.contains { abs($0.bpm - half) <= tol && $0.frac >= 0.25 }
        }
    }

    // MARK: - Component 4 helpers: bar multiples & beat-grid phase

    /// Silence counts as a musical dropout only at 4/8/16/32 bars (4 beats/bar) within tolerance.
    static func isBarMultiple(_ seconds: Double, bpm: Double) -> Bool {
        guard bpm > 0, seconds > 0 else { return false }
        let bar = 4.0 * 60.0 / bpm
        for k in [4.0, 8.0, 16.0, 32.0] {
            let target = k * bar
            if abs(seconds - target) <= barTolerance * target + 0.05 { return true }
        }
        return false
    }

    /// Is `time` on the beat grid defined by `origin` + k * (60/bpm)?
    static func isPhaseAligned(_ time: Double, bpm: Double, origin: Double) -> Bool {
        guard bpm > 0 else { return false }
        let beat = 60.0 / bpm
        var offset = (time - origin).truncatingRemainder(dividingBy: beat)
        if offset < 0 { offset += beat }
        let tol = phaseTolerance * beat
        return offset <= tol || offset >= beat - tol
    }

    // MARK: - Component 4: Smart Skip v2 rolling-window analysis

    /// `computeRoleEvidence` runs the parked instrument classifier
    /// (OnsetClassification.swift) to build the role-weighted evidence
    /// product. Production analysis leaves it off — the classifier's
    /// output feeds ONLY the probe's diagnostics table and the verdict
    static func analyzeSegments(samples: [Float], sampleRate: Double,
                                minBPM: Double, maxBPM: Double) throws -> (segments: [SegmentInfo], bandPeaks: [[(bpm: Double, frac: Float)]], roleBandPeaks: [[(bpm: Double, frac: Float)]], beatTimes: [Double], trackerFinalConfidence: Float, multiCandidateScores: [MultiCandidateScore]) {
        let bands = splitBands(samples: samples, sampleRate: sampleRate)
        // Envelopes + per-frame sub-band energies in one STFT pass.
        let envPairs = bands.map { onsetEnvelopeAndEnergies(samples: $0, sampleRate: sampleRate) }
        let envelopes = envPairs.map { $0.envelope }
        let frameEnergies = envPairs.map { $0.energies }
        let envRate = sampleRate / Double(hopSize)
        guard let envCount = envelopes.map({ $0.count }).max(), envCount > 0 else { throw BPMError.noOnsets }
        let chunkEnv = max(8, Int(chunkSeconds * envRate))
        let totalChunks = max(1, (envCount + chunkEnv - 1) / chunkEnv)

        func rangeFor(_ c: Int, count: Int) -> Range<Int> {
            let lo = min(c * chunkEnv, count)
            let hi = min((c + 1) * chunkEnv, count)
            return lo..<hi
        }
        func energy(_ env: [Float], _ c: Int) -> Float {
            let r = rangeFor(c, count: env.count)
            guard !r.isEmpty else { return 0 }
            return vDSP.mean(env[r])
        }

        var energies = [Float](repeating: 0, count: totalChunks)
        for c in 0..<totalChunks {
            if c % 2 == 0, Task.isCancelled { throw CancellationError() }
            energies[c] = envelopes.map { energy($0, c) }.max() ?? 0
        }
        guard let maxEnergy = energies.max(), maxEnergy > 0 else { throw BPMError.noOnsets }
        let floorE = maxEnergy * energyFloorRatio

        func masterBand(_ c: Int) -> Int {
            var best = -1
            var bestVar = Double.greatestFiniteMagnitude
            for (index, env) in envelopes.enumerated() {
                let r = rangeFor(c, count: env.count)
                guard !r.isEmpty else { continue }
                if let v = normalizedIOIVariance(peaks: pickPeaks(envelope: Array(env[r]), envRate: envRate)),
                   v < bestVar {
                    bestVar = v
                    best = index
                }
            }
            if best >= 0 { return best }
            var bestIdx = 0
            var bestE = -Float.infinity
            for (index, env) in envelopes.enumerated() {
                let e = energy(env, c)
                if e > bestE { bestE = e; bestIdx = index }
            }
            return bestIdx
        }

        func chunkBPM(_ c: Int) -> (bpm: Double, band: Int)? {
            let chunks = envelopes.map { env -> [Float] in
                let r = rangeFor(c, count: env.count)
                return r.isEmpty ? [] : Array(env[r])
            }
            return bpmFromBandChunks(chunks, envRate: envRate, minBPM: minBPM, maxBPM: maxBPM)
        }

        func firstOnsetTime(_ c: Int) -> Double? {
            let env = envelopes[masterBand(c)]
            let r = rangeFor(c, count: env.count)
            guard !r.isEmpty, let first = pickPeaks(envelope: Array(env[r]), envRate: envRate).first else { return nil }
            return Double(r.lowerBound) / envRate + first
        }

        func closeBPM(_ a: Double, _ b: Double) -> Bool {
            abs(a - b) <= max(1.5, bpmMatchTolerance * b)
        }

        // 1. Intro skip: walk past low-energy AND non-analyzable chunks (a chunk whose
        // bands all fail autocorrelation is skipped, not fatal) to the first confident one.
        var first = 0
        var basePick: (bpm: Double, band: Int)? = nil
        while first < totalChunks {
            if energies[first] >= floorE, let b = chunkBPM(first) { basePick = b; break }
            first += 1
        }
        guard let basePick = basePick else { throw BPMError.noOnsets }
        if first > 0 { LogService.shared.log("  intro skip: \(first) low-energy chunk\(first == 1 ? "" : "s") (\(String(format: "%.0f", Double(first) * chunkSeconds))s)") }
        LogService.shared.log("  baseline: \(String(format: "%.2f", basePick.bpm)) BPM locked @ chunk \(first)")

        var segments: [SegmentInfo] = []
        var segBPM = basePick.bpm // BaselineBPM
        var segBand = basePick.band
        var segStartChunk = first
        var segEndChunk = first + 1
        var segAnchor = firstOnsetTime(first) ?? (Double(first) * chunkSeconds)

        // Online beat tracker on the LOW-band envelope. Seeded at the
        // baseline onset; thereafter Smart Skip anchors come from the TRACKED
        // grid when confident, falling back to the first-onset anchor when not.
        var tracker = BeatTracker()
        var allBeatTimes: [Double] = []
        tracker.start(bpm: segBPM, anchorSeconds: segAnchor, envRate: envRate)
        // Feed the baseline chunk too so beats start from the anchor onward.
        if !envelopes[0].isEmpty {
            let r = rangeFor(first, count: envelopes[0].count)
            tracker.process(chunk: Array(envelopes[0][r]), chunkStartFrame: r.lowerBound)
        }

        /// LOW-band envelope slice for chunk c (the tracker's kick-weighted observation).
        func lowChunk(_ c: Int) -> (chunk: [Float], startFrame: Int) {
            guard !envelopes[0].isEmpty else { return ([], 0) }
            let r = rangeFor(c, count: envelopes[0].count)
            return (Array(envelopes[0][r]), r.lowerBound)
        }

        /// Anchor rule: coast the grid to chunk c, then use the tracked grid
        /// when confident, else the first-onset anchor.
        func trackedAnchor(_ c: Int) -> Double {
            tracker.advanceGrid(throughFrame: Double(c * chunkEnv))
            if tracker.confidence >= BeatTracker.anchorConfidenceGate,
               let grid = tracker.gridOriginSeconds {
                return grid
            }
            return firstOnsetTime(c) ?? (Double(c) * chunkSeconds)
        }

        func closeSegment(endChunk: Int, extraSilence: Double) {
            let start = Double(segStartChunk) * chunkSeconds
            let end = min(Double(endChunk) * chunkSeconds, Double(envCount) / envRate)
            let dur = max(0, end - start) + extraSilence
            if dur > 0 {
                segments.append(SegmentInfo(bpm: segBPM, startTime: start, duration: dur, band: segBand))
            }
        }

        var i = first + 1
        while i < totalChunks {
            if Task.isCancelled { throw CancellationError() }
            if energies[i] >= floorE {
                if let b = chunkBPM(i), !closeBPM(b.bpm, segBPM) {
                    // Tempo change without silence: close current segment, start a new one.
                    LogService.shared.log("  tempo change @ chunk \(i): \(String(format: "%.2f", segBPM)) -> \(String(format: "%.2f", b.bpm)) BPM (no silence)")
                    closeSegment(endChunk: i, extraSilence: 0)
                    segBPM = b.bpm
                    segBand = b.band
                    segStartChunk = i
                    // Re-seed the tracker at the new tempo; anchor stays onset-backed.
                    allBeatTimes.append(contentsOf: tracker.beats)
                    let reAnchor = firstOnsetTime(i) ?? (Double(i) * chunkSeconds)
                    tracker.start(bpm: segBPM, anchorSeconds: reAnchor, envRate: envRate)
                    segAnchor = reAnchor
                }
                // Feed every energized chunk of the current segment to the tracker.
                let lc = lowChunk(i)
                tracker.process(chunk: lc.chunk, chunkStartFrame: lc.startFrame)
                segEndChunk = i + 1
                i += 1
            } else {
                // 2. Dropout detection: measure the silent run.
                let silStart = i
                while i < totalChunks && energies[i] < floorE { i += 1 }
                let silSeconds = Double(i - silStart) * chunkSeconds
                let barOK = isBarMultiple(silSeconds, bpm: segBPM)
                if i < totalChunks, barOK, let retPick = chunkBPM(i) {
                    // 3. Resumption & phase check against the baseline beat grid.
                    let retOnset = firstOnsetTime(i) ?? Double(i) * chunkSeconds
                    // Coast the tracked grid through the gap (no emission), then
                    // check the OBSERVED resumption onset against the TRACKED grid
                    // origin when confident.
                    tracker.advanceGrid(throughFrame: Double(i * chunkEnv))
                    if let grid = tracker.gridOriginSeconds,
                       tracker.confidence >= BeatTracker.anchorConfidenceGate {
                        segAnchor = grid
                    }
                    if isPhaseAligned(retOnset, bpm: segBPM, origin: segAnchor), closeBPM(retPick.bpm, segBPM) {
                        // Scenario A (mute/drop): on-grid, same tempo -> keep BaselineBPM.
                        LogService.shared.log("  dropout \(String(format: "%.1f", silSeconds))s @ chunk \(silStart): on-grid resume, keep \(String(format: "%.2f", segBPM)) BPM (scenario A)")
                        let lc = lowChunk(i)
                        tracker.process(chunk: lc.chunk, chunkStartFrame: lc.startFrame)
                        segEndChunk = i + 1
                        i += 1
                        continue
                    }
                    // Scenario B (tempo change/off-grid): close old segment, establish new BPM.
                    LogService.shared.log("  dropout \(String(format: "%.1f", silSeconds))s @ chunk \(silStart): off-grid/new tempo, re-anchor \(String(format: "%.2f", retPick.bpm)) BPM (scenario B)")
                    closeSegment(endChunk: silStart, extraSilence: silSeconds)
                    segBPM = retPick.bpm
                    segBand = retPick.band
                    segStartChunk = i
                    segAnchor = retOnset
                    // Re-seed the tracker at the resumed tempo/onset.
                    allBeatTimes.append(contentsOf: tracker.beats)
                    tracker.start(bpm: segBPM, anchorSeconds: retOnset, envRate: envRate)
                    let lcB = lowChunk(i)
                    tracker.process(chunk: lcB.chunk, chunkStartFrame: lcB.startFrame)
                    segEndChunk = i + 1
                    i += 1
                } else {
                    // Trailing silence or non-musical gap: close; restart if audio returns.
                    closeSegment(endChunk: silStart, extraSilence: 0)
                    if i >= totalChunks {
                        segStartChunk = totalChunks
                        segEndChunk = totalChunks
                        break
                    }
                    if let b = chunkBPM(i) {
                        segBPM = b.bpm
                        segBand = b.band
                        segStartChunk = i
                        // Re-seed on restart-after-gap.
                        allBeatTimes.append(contentsOf: tracker.beats)
                        let reAnchor = trackedAnchor(i)
                        tracker.start(bpm: segBPM, anchorSeconds: reAnchor, envRate: envRate)
                        let lcR = lowChunk(i)
                        tracker.process(chunk: lcR.chunk, chunkStartFrame: lcR.startFrame)
                        segAnchor = reAnchor
                        segEndChunk = i + 1
                        i += 1
                    } else {
                        segStartChunk = totalChunks
                        segEndChunk = totalChunks
                        break
                    }
                }
            }
        }
        if segEndChunk > segStartChunk {
            closeSegment(endChunk: segEndChunk, extraSilence: 0)
        }
        let bandPeaks = envelopes.map { topEnvelopePeaks($0, envRate: envRate, minBPM: minBPM, maxBPM: maxBPM, fold: false) }
        // Harvest the final tracker run's beats.
        allBeatTimes.append(contentsOf: tracker.beats)
        // Multi-candidate grid-stability evaluation. For every
        // energized chunk, evaluate the bounded candidate set (verdict tempo + its
        // ×3/4, ×4/3, ×2/3, ×3/2, ×2, ×½ relatives — clipped to the BPM range)
        // by re-seeding a fresh BeatTracker at each candidate's BPM with the
        // chunk's first-onset anchor, and feed the chunk's LOW-band envelope.
        //
        // Why LOW not broadband: a broadband (per-frame max across bands)
        // envelope is so dense that phantom trackers (e.g. 126 BPM tracker on
        // a 94 BPM track) find local maxima within ±3 frames of most
        // predictions, inflating snap rates to ~0.95 for ALL candidates and
        // destroying discrimination. The LOW band is sparse and kick-weighted
        // — the 94 BPM tracker DOES snap less well in LOW (snap rate ~0.51
        // vs the 126 phantom's ~0.41), but that's the trade-off: the
        // discrimination is real (10 percentage points), and combined with
        // the grid-stability guard, it's enough to fire the rule.
        //
        // The per-candidate accumulators aggregate snap rate (mean tracker
        // confidence per chunk) and grid stability (1 − IBI variance over all
        // emitted beats) across the whole track. The verdict pipeline's Move 4
        // rule reads this table. Bounded cost: 7 candidates × ~1 ms per chunk
        // × ~50 chunks per 5-minute track ≈ 350 ms.
        var multiAcc = MultiCandidateAccumulator(envRate: envRate)
        // Use the dominant cluster's BPM (not the baseline) so the candidate set
        // reflects the actual verdict. If segments are empty (rare), fall back
        // to the first-chunk baseline BPM.
        // Use the dominant cluster's BPM (not the baseline) so the candidate set
        // reflects the actual verdict. basePick is guaranteed non-nil here.
        let dominantBPM = tempoClusters(segments).first?.bpm ?? basePick.bpm
        let candidates = candidateSet(for: dominantBPM, minBPM: minBPM, maxBPM: maxBPM)
        if !envelopes[0].isEmpty, !candidates.isEmpty {
            for c in 0..<totalChunks where energies[c] >= floorE {
                let r = rangeFor(c, count: envelopes[0].count)
                guard !r.isEmpty else { continue }
                let chunkLow = Array(envelopes[0][r])
                let anchor = firstOnsetTime(c) ?? (Double(c) * chunkSeconds)
                multiAcc.evaluateChunk(chunk: chunkLow, chunkStartFrame: r.lowerBound,
                                        chunkAnchor: anchor, candidates: candidates)
            }
        }
        return (segments, bandPeaks, [], allBeatTimes, tracker.confidence, multiAcc.scores())
    }
}
