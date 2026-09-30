import Foundation
import Accelerate

// Lightweight online beat tracking (positions, not rate).
//
// Design: a causal phase tracker in the
// Scheirer / Davies & Plumbley lineage, ~zero compute, no model weights, no
// license exposure. The observation is the LOW-band spectral-flux envelope —
// kick-weighted BY CONSTRUCTION, so it does not depend on the instrument
// classifier. The tempo hypothesis comes from the engine's own chunk vote (the
// tempo pipeline stays exactly as-is; the tracker NEVER re-derives tempo from
// beat positions).
//
// Mechanics: a phase oscillator at the segment's BPM marches frame by frame;
// each predicted beat snaps to the strongest local onset within ±3 frames when
// one is loud enough (phase correction), otherwise it coasts on the grid.
// Confidence = recent snap rate (windowed); Smart Skip v2 uses the tracked grid
// as its anchor when confident and falls back to the first-onset anchor
// when not. Period is re-seeded on tempo changes (the segmenter already
// guarantees a constant BPM inside a segment, so no tempo lattice is needed).

struct BeatTracker {

    /// Beats whose predicted time can't snap to a local onset still emit (coasted
    /// grid beats) — that's what makes the grid continuable through dropouts.
    private(set) var beats: [Double] = []
    /// Recent snap rate in [0,1]. 1.0 right after seeding (the seed is onset-backed).
    private(set) var confidence: Float = 1.0

    private var periodFrames: Double = 0
    private var nextBeatFrame: Double = -1 // <0 => not tracking
    private var snaps: [Bool] = []
    private var runningMax: Float = 0
    private var envRateStored: Double = 0

    /// Snap window: ±3 envelope frames (~±35 ms @ 86.1 fps). Keeps the grid
    /// honest without letting distant off-grid onsets hijack the phase.
    static let snapRadius = 3
    /// Minimum onset strength to snap to, relative to the causal running max.
    static let snapThresholdRatio: Float = 0.25
    /// Confidence gate used by Smart Skip v2 anchors (hand-set).
    static let anchorConfidenceGate: Float = 0.4

    var isTracking: Bool { nextBeatFrame >= 0 }

    /// (Re)seed at a known onset. Called at baseline lock and on every tempo
    /// change / re-anchor — the only tempo input the tracker ever gets.
    mutating func start(bpm: Double, anchorSeconds: Double, envRate: Double) {
        guard bpm > 0, envRate > 0 else { stop(); return }
        periodFrames = envRate * 60.0 / bpm
        nextBeatFrame = anchorSeconds * envRate
        envRateStored = envRate
        beats = []
        snaps = []
        confidence = 1.0
        runningMax = 0
    }

    mutating func stop() {
        nextBeatFrame = -1
        confidence = 0
    }

    /// The tracked phase: predicted next-beat time in seconds.
    var gridOriginSeconds: Double? {
        guard isTracking, envRateStored > 0 else { return nil }
        return nextBeatFrame / envRateStored
    }

    /// Coast the grid forward through sub-floor (silent/dropout) chunks WITHOUT
    /// emitting beats — silence has no onsets, so there is nothing to track, but
    /// the grid must stay continuable for the resumption phase check.
    mutating func advanceGrid(throughFrame frame: Double) {
        guard isTracking, periodFrames > 0 else { return }
        while nextBeatFrame < frame { nextBeatFrame += periodFrames }
    }

    /// Feed one energized chunk of the LOW-band envelope. Emits (and returns) the
    /// beat times whose predicted positions fall inside this chunk, in seconds.
    @discardableResult
    mutating func process(chunk: [Float], chunkStartFrame: Int) -> [Double] {
        guard isTracking, periodFrames > 0, envRateStored > 0, !chunk.isEmpty else { return [] }
        if let m = chunk.max() { runningMax = max(runningMax * 0.95, m) }
        var emitted: [Double] = []
        let endFrame = Double(chunkStartFrame + chunk.count)
        while nextBeatFrame < endFrame {
            let predicted = nextBeatFrame
            let ci = Int(predicted.rounded()) - chunkStartFrame
            var beatFrame = predicted
            var snapped = false
            if ci >= 0, ci < chunk.count {
                let lo = max(0, ci - BeatTracker.snapRadius)
                let hi = min(chunk.count - 1, ci + BeatTracker.snapRadius)
                var bestIdx = -1
                var bestVal: Float = 0
                for j in lo...hi where chunk[j] > bestVal { bestVal = chunk[j]; bestIdx = j }
                if bestIdx >= 0, bestVal >= BeatTracker.snapThresholdRatio * runningMax {
                    beatFrame = Double(bestIdx + chunkStartFrame)
                    snapped = true
                    nextBeatFrame = beatFrame + periodFrames // phase correction
                }
            }
            if !snapped { nextBeatFrame = predicted + periodFrames } // coast
            snaps.append(snapped)
            if snaps.count > 16 { snaps.removeFirst() }
            confidence = Float(snaps.filter { $0 }.count) / Float(snaps.count)
            let seconds = beatFrame / envRateStored
            beats.append(seconds)
            emitted.append(seconds)
        }
        return emitted
    }
}
