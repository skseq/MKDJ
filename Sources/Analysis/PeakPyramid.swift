import Foundation
import Accelerate

/// Precomputed min/max peak pyramid over the mono analysis decode
/// (never recompute peaks on the UI thread).
///
/// Levels at 256 / 1024 / 4096 / 16384 samples per bucket:
/// the scrolling view uses the finest level whose bucket is ≤ one pixel,
/// the overview uses a coarse level with multi-bucket aggregation.
struct PeakLevel: Codable, Equatable {
    let bucketSamples: Int
    let mins: [Float]
    let maxs: [Float]
}

struct PeakPyramid: Codable, Equatable {
    let sampleRate: Double
    var levels: [PeakLevel]   // sorted fine → coarse

    static let bucketSizes = [256, 1024, 4096, 16384]

    /// Streaming builder — append decoded blocks, publish partial
    /// pyramids (finest level filled as far as decoded), finalize once.
    /// Nothing whole-file needs to be in memory beyond the finest arrays.
    struct StreamingBuilder {
        private var mins: [Float] = []
        private var maxs: [Float] = []
        private var carry = [Float]()
        private let bucket = bucketSizes[0]
        let sampleRate: Double

        init(sampleRate: Double) { self.sampleRate = sampleRate }

        mutating func append(_ block: UnsafeBufferPointer<Float>) {
            carry.append(contentsOf: block)
            var offset = 0
            carry.withUnsafeBufferPointer { ptr in
                guard let base = ptr.baseAddress else { return }
                while offset + bucket <= ptr.count {
                    var lo: Float = 0, hi: Float = 0
                    vDSP_minv(base + offset, 1, &lo, vDSP_Length(bucket))
                    vDSP_maxv(base + offset, 1, &hi, vDSP_Length(bucket))
                    mins.append(lo)
                    maxs.append(hi)
                    offset += bucket
                }
            }
            if offset > 0 { carry.removeFirst(offset) }
        }

        /// Partial pyramid: finest level as far as decoded; coarser levels
        /// derived from what exists (good enough for a growing lane).
        func partial() -> PeakPyramid {
            pyramid(fromFinest: mins, maxs: maxs)
        }

        mutating func finish() -> PeakPyramid {
            if !carry.isEmpty {
                var lo: Float = 0, hi: Float = 0
                carry.withUnsafeBufferPointer { ptr in
                    vDSP_minv(ptr.baseAddress!, 1, &lo, vDSP_Length(ptr.count))
                    vDSP_maxv(ptr.baseAddress!, 1, &hi, vDSP_Length(ptr.count))
                }
                mins.append(lo)
                maxs.append(hi)
                carry.removeAll()
            }
            return pyramid(fromFinest: mins, maxs: maxs)
        }

        private func pyramid(fromFinest mins: [Float], maxs: [Float]) -> PeakPyramid {
            var levels: [PeakLevel] = [
                PeakLevel(bucketSamples: bucket, mins: mins, maxs: maxs)
            ]
            for b in bucketSizes.dropFirst() {
                let count = (mins.count + b / bucket - 1) / (b / bucket)
                var cm = [Float](repeating: 0, count: count)
                var cx = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let s = i * (b / bucket)
                    let e = min(mins.count, s + b / bucket)
                    if s < e {
                        cm[i] = mins[s..<e].min() ?? 0
                        cx[i] = maxs[s..<e].max() ?? 0
                    }
                }
                levels.append(PeakLevel(bucketSamples: b, mins: cm, maxs: cx))
            }
            return PeakPyramid(sampleRate: sampleRate, levels: levels)
        }
    }

    static func build(samples: [Float], sampleRate: Double) -> PeakPyramid {
        var levels: [PeakLevel] = []
        let n = samples.count
        guard n > 0 else { return PeakPyramid(sampleRate: sampleRate, levels: levels) }
        samples.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            for bucket in bucketSizes {
                let count = (n + bucket - 1) / bucket
                var mins = [Float](repeating: 0, count: count)
                var maxs = [Float](repeating: 0, count: count)
                for i in 0..<count {
                    let start = i * bucket
                    let len = min(bucket, n - start)
                    var lo: Float = 0
                    var hi: Float = 0
                    vDSP_minv(base + start, 1, &lo, vDSP_Length(len))
                    vDSP_maxv(base + start, 1, &hi, vDSP_Length(len))
                    mins[i] = lo
                    maxs[i] = hi
                }
                levels.append(PeakLevel(bucketSamples: bucket, mins: mins, maxs: maxs))
            }
        }
        return PeakPyramid(sampleRate: sampleRate, levels: levels)
    }

    /// Min/max over the sample range [start, end) at whatever resolution the
    /// pyramid supports. Chooses the finest level whose bucket fits the span
    /// (aggregating buckets as needed); below finest-bucket resolution it
    /// returns the containing bucket (zoom floor is ~256 samples/px anyway).
    /// Returns nil when the range starts past the end of the pyramid (the
    /// scrolling view overruns the track end when the playhead nears EOF).
    ///
    /// A pixel span smaller than one bucket lands in a single bucket (i0 == i1)
    /// — the aggregation loop must be guarded, since `(i0 + 1)...i1` with
    /// i0 == i1 constructs an invalid ClosedRange and traps.
    func range(sampleStart: Int, sampleEnd: Int) -> (min: Float, max: Float)? {
        guard let finest = levels.first else { return nil }
        let totalSamples = finest.mins.count * finest.bucketSamples
        guard sampleStart < totalSamples else { return nil }
        let span = max(1, sampleEnd - sampleStart)
        let level = levels.last(where: { $0.bucketSamples <= span }) ?? finest
        let b = level.bucketSamples
        let i0 = min(max(0, sampleStart / b), level.mins.count - 1)
        let i1 = min(level.mins.count - 1, max(i0, (sampleEnd - 1) / b))
        var lo = level.mins[i0]
        var hi = level.maxs[i0]
        if i1 > i0 {
            for i in (i0 + 1)...i1 {
                lo = min(lo, level.mins[i])
                hi = max(hi, level.maxs[i])
            }
        }
        return (lo, hi)
    }
}
