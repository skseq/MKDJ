import Foundation

/// In-stream beat estimation: the pull reader feeds decoded
/// chunks here as audio streams through the ring, so the estimate
/// CONVERGES while the track plays — a second, independent measurement
/// that cross-checks the offline analyzer (octave errors in either become
/// visible). Same shape as Mixxx's engine-side analysis consumers.
///
/// Thread-safe: `feed` is called on the reader thread; reads poll from main.
final class LiveBeatDetector {

    private let lock = NSLock()
    private var lp1a: Float = 0
    private var lp1b: Float = 0
    private var prevEnergy = [Float](repeating: 0, count: 3)
    private var windowE = [Float](repeating: 0, count: 3)
    private var windowN = 0
    private var prevNovelty: Double = 0
    private let windowFrames = 512
    private var lastOnsetFrame: Int64 = -1
    private var framesAtWindowStart: Int64 = 0
    private var fluxHistory: [Double] = []
    private var intervals: [Double] = []       // AUDIO seconds, most recent last
    private let maxIntervals = 24
    private(set) var framesFed: Int64 = 0

    /// Feed one chunk of decoded mono-ish audio (channel 0) at sampleRate.
    /// ~30 lines of arithmetic per 512 frames — noise against decode cost.
    func feed(samples: UnsafePointer<Float>, count: Int, sampleRate sr: Double) {
        guard sr > 0, count > 0 else { return }
        let a1 = exp(-2.0 * Double.pi * 200.0 / sr)
        let a2 = exp(-2.0 * Double.pi * 2000.0 / sr)
        lock.lock()
        let chunkStart = framesFed
        framesFed &+= Int64(count)
        for i in 0..<count {
            let x = samples[i]
            lp1a += (1 - Float(a1)) * (x - lp1a)
            lp1b += (1 - Float(a2)) * (lp1a - lp1b)
            let b0 = lp1a, b1 = lp1b - lp1a, b2 = x - lp1b
            windowE[0] += b0 * b0
            windowE[1] += b1 * b1
            windowE[2] += b2 * b2
            windowN += 1
            if windowN == 1 { framesAtWindowStart = chunkStart + Int64(i) }
            if windowN >= windowFrames {
                // LINEAR energy ratio, median-aggregated: log-domain flux
                // has a fat noise tail (one spurious supra-threshold window
                // per feed chunk); beats move energy by orders of magnitude,
                // noise by tens of percent.
                var ratio: [Double] = [0, 0, 0]
                for b in 0..<3 {
                    let e = Double(windowE[b] / Float(max(1, windowN)))
                    ratio[b] = max(0, e / max(1e-12, Double(prevEnergy[b])) - 1)
                    prevEnergy[b] = Float(e)
                }
                let novelty = max(ratio[0], min(ratio[1], ratio[2]))
                windowE = [0, 0, 0]
                windowN = 0
                // adaptive threshold vs the local noise floor (median of
                // recent novelty — robust to the spikes it must exclude)
                // + EDGE trigger (onset must exceed the previous window).
                fluxHistory.append(novelty)
                if fluxHistory.count > 16 { fluxHistory.removeFirst(fluxHistory.count - 16) }
                let sortedHist = fluxHistory.sorted()
                let med = sortedHist[sortedHist.count / 2]
                let threshold = max(3.0, 6.0 * med)
                // intervals in AUDIO time (Δ frames ÷ sr), not wall time:
                // decode is chunked and runs AHEAD of playback — wall
                // intervals inherit chunk quantization (and mean nothing
                // under scrubbing); audio intervals are exact.
                let onsetFrame = framesAtWindowStart
                let debounceFrames = Int64(0.12 * sr)
                if novelty > threshold, novelty > prevNovelty,
                   lastOnsetFrame < 0 || onsetFrame - lastOnsetFrame > debounceFrames {
                    if lastOnsetFrame >= 0 {
                        intervals.append(Double(onsetFrame - lastOnsetFrame) / sr)
                        if intervals.count > maxIntervals { intervals.removeFirst(intervals.count - maxIntervals) }
                    }
                    lastOnsetFrame = onsetFrame
                }
                prevNovelty = novelty
            }
        }
        lock.unlock()
    }

    /// Live BPM estimate (octave-normalized into 70–180), or nil while
    /// too few intervals have accumulated.
    var liveBPM: Double? {
        lock.lock(); defer { lock.unlock() }
        guard intervals.count >= 6 else { return nil }
        // median-of-intervals, then outlier-trimmed mean for stability
        let sorted = intervals.sorted()
        let med = sorted[sorted.count / 2]
        let keep = intervals.filter { abs($0 - med) / med < 0.25 }
        guard !keep.isEmpty else { return nil }
        var bpm = 60.0 / (keep.reduce(0, +) / Double(keep.count))
        while bpm > 180 { bpm /= 2 }
        while bpm < 70 { bpm *= 2 }
        return bpm
    }

    var intervalCount: Int {
        lock.lock(); defer { lock.unlock() }
        return intervals.count
    }

    var debugIntervals: [Double] {
        lock.lock(); defer { lock.unlock() }
        return intervals
    }

    func reset() {
        lock.lock()
        lp1a = 0; lp1b = 0
        prevEnergy = [0, 0, 0]
        windowE = [0, 0, 0]
        windowN = 0
        prevNovelty = 0
        lastOnsetFrame = -1
        framesAtWindowStart = 0
        prevNovelty = 0
        fluxHistory.removeAll()
        intervals.removeAll()
        framesFed = 0
        lock.unlock()
    }
}
