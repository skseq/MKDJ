import SwiftUI
import AppKit

/// Direct-from-pyramid waveform rendering.
///
/// Architecture (the Mixxx lesson): the whole-track PeakPyramid
/// is the precomputed truth; the view is a POSITION into it. The visible
/// window is rasterized synchronously from the pyramid at draw time —
/// direct RGBA column writes (Quartz stroking was
/// 100% of the old build cost) — so an uncovered frame is impossible by
/// construction: there is no async path and nothing to wait for. Seeks of
/// any depth are instant because position is just an offset into the math.
///
/// The previous async strip cache (bucket keys, coverage margins, kick
/// coalescing, LRU, tolerant re-keys, two-stage publishes) existed only to
/// hide build latency that turned out to be stroke cost — deleted whole.
///
/// The memo renders the window plus a time margin and quantizes the window
/// start, so playback slides inside one memo image for ~0.25 s before the
/// next render (sub-offset blit) — playing re-renders at ~4 Hz, not the
/// clock rate; idle frames are pure memo hits.
final class WaveRenderer {

    struct MemoKey: Hashable {
        let generation: Int
        let sppBucket: Int        // log2(spp) × 16
        let t0Bucket: Int         // window start / 0.25 s
        let columns: Int
        let pxHeight: Int
        let skin: Int             // 6-bit rgb signature
    }

    struct MemoEntry {
        let image: NSImage
        let t0: Double            // exact time of the memo's left edge
        let secondsPerPixel: Double
    }

    private var memo: [MemoKey: MemoEntry] = [:]
    private var order: [MemoKey] = []
    private let maxMemo = 3
    private var generation = 0
    private var lastPyramid: PeakPyramid?
    private var lastDuration: Double = 0
    /// Reused raster buffer — zero allocation steady state.
    private var buf: [UInt8] = []
    private var backingScale: Int = 2

    static let margin = 0.25          // seconds of slide room each side
    static let t0Quantum = 0.25       // memo window-start bucket

    /// Completed renders (diagnostics).
    private(set) static var renderCount = 0
    private static let lock = NSLock()
    /// Temporary spike instrumentation (from a profiling pass).
    static var dbgPhaseMinus1: Double = 0   // whole call
    static var dbgPhase0: Double = 0   // memset
    static var dbgPhase1: Double = 0   // column loop
    static var dbgPhase2: Double = 0   // CGImage wrap
    /// Backing scale cached at first use and refreshed only on
    /// didChangeScreenParameters — NSScreen.main costs tens of ms in some
    /// contexts (the probe measured 43 ms PER RENDER through it).
    private static let scaleLock = NSLock()
    private static var _backingScale = 2
    private static var scaleRead = false
    static var backingScale: Int {
        scaleLock.lock(); defer { scaleLock.unlock() }
        if !scaleRead {
            scaleRead = true
            _backingScale = readBackingScaleCG()
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { _ in
                scaleLock.lock()
                _backingScale = readBackingScaleCG()
                scaleLock.unlock()
            }
        }
        return _backingScale
    }
    /// Pure-CG scale read — NSScreen.main stalls ~25 ms in some contexts
    /// (this was the whole "first render is slow" mystery).
    private static func readBackingScaleCG() -> Int {
        var maxDisplays: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &maxDisplays)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var actual: UInt32 = 0
        CGGetActiveDisplayList(maxDisplays, &ids, &actual)
        for id in ids.prefix(Int(actual)) {
            let pts = CGDisplayBounds(id).width
            let px = Double(CGDisplayPixelsWide(id))
            if pts > 0, px > 0 {
                return max(2, Int((px / pts).rounded()))
            }
        }
        return 2
    }

    /// Returns an image whose POINT size is `columns × pxHeight/scale`,
    /// covering [t0 − margin, t0 + columns·spp + margin]; draw it at
    /// x = (entry.t0 − t0)/spp. Nil only for degenerate inputs.
    func renderWindow(pyramid: PeakPyramid?, sampleRate: Double, duration: Double,
                      t0: Double, secPerPx: Double, columns: Int, pxHeight: Int,
                      alpha: Double = 0.75,
                      rgb: (Double, Double, Double)) -> MemoEntry? {
        let entryT0 = CFAbsoluteTimeGetCurrent()
        defer { Self.dbgPhaseMinus1 = (CFAbsoluteTimeGetCurrent() - entryT0) * 1000 }
        guard let pyramid, columns > 8, pxHeight > 8, secPerPx > 0,
              sampleRate > 0, duration > 0 else { return nil }
        if pyramid != lastPyramid || duration != lastDuration {
            lastPyramid = pyramid
            lastDuration = duration
            generation &+= 1
            memo.removeAll()          // new analysis data — old renders are wrong
            order.removeAll()
        }
        let key = MemoKey(generation: generation,
                          sppBucket: Int((log2(secPerPx) * 16).rounded()),
                          t0Bucket: Int(t0 / Self.t0Quantum),
                          columns: columns, pxHeight: pxHeight,
                          skin: Self.skinBucket(rgb))
        if let hit = memo[key] { return hit }

        let scale = Self.backingScale
        // memo covers the window plus slide margin on both sides
        let marginCols = Int(Self.margin / secPerPx)
        let totalCols = columns + 2 * marginCols
        let imgT0 = t0 - Double(marginCols) * secPerPx
        let pxW = totalCols * scale
        let pxH = pxHeight * scale
        guard pxW > 16, pxW * pxH <= 4_000_000 else { return nil }

        // reused buffer: realloc only on size change, RAW memset otherwise —
        // Array.resetBytes is NOT a memset (measured 288 ms per 1.9 MB;
        // raw memset: 0.02 ms)
        let phaseT0 = CFAbsoluteTimeGetCurrent()
        if buf.count != pxW * pxH * 4 {
            buf = [UInt8](repeating: 0, count: pxW * pxH * 4)
        } else {
            buf.withUnsafeMutableBytes { memset($0.baseAddress, 0, buf.count) }
        }
        Self.dbgPhase0 = (CFAbsoluteTimeGetCurrent() - phaseT0) * 1000
        let a8 = UInt8(max(0, min(255, alpha * 255).rounded()))
        let pr = UInt8(max(0, min(255, rgb.0 * alpha * 255).rounded()))   // premultipliedLast
        let pg = UInt8(max(0, min(255, rgb.1 * alpha * 255).rounded()))
        let pb = UInt8(max(0, min(255, rgb.2 * alpha * 255).rounded()))
        let mid = CGFloat(pxH) / 2
        let amp = mid * 0.94
        let secPerPxPx = secPerPx / Double(scale)
        let rowStep = pxW * 4
        for x in 0..<pxW {
            let t = imgT0 + Double(x) * secPerPxPx
            // outside the track renders NOTHING (transparent) — clamping
            // pre-head columns to t=0 drew the first bucket's amplitude
            // as a constant slab before the file head at full zoom-out.
            // Past EOF, range() already returns nil.
            guard t >= 0 else { continue }
            let ta = t, tb = max(ta + min(secPerPxPx, 0.05), t + secPerPxPx)
            guard let r = pyramid.range(sampleStart: Int(ta * sampleRate),
                                        sampleEnd: Int(tb * sampleRate)) else { continue }
            // CG bitmap rows are bottom-origin (same flip as always)
            let yTopF = CGFloat(pxH) - (mid - CGFloat(min(1, r.max)) * amp)
            let yBotF = CGFloat(pxH) - (mid - CGFloat(max(-1, r.min)) * amp)
            let y0 = max(0, min(yTopF, yBotF).rounded())
            let y1 = min(CGFloat(pxH - 1), max(yTopF, yBotF).rounded())
            guard y1 >= y0 else { continue }
            var base = Int(y0) * rowStep + x * 4
            for _ in Int(y0)...Int(y1) {
                buf[base] = pr
                buf[base + 1] = pg
                buf[base + 2] = pb
                buf[base + 3] = a8
                base += rowStep
            }
        }
        let loopMs = (CFAbsoluteTimeGetCurrent() - phaseT0) * 1000 - Self.dbgPhase0
        let wrapT0 = CFAbsoluteTimeGetCurrent()
        let cgImage: CGImage? = buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: pxW, height: pxH,
                                      bitsPerComponent: 8, bytesPerRow: rowStep,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        let wrapMs = (CFAbsoluteTimeGetCurrent() - wrapT0) * 1000
        Self.dbgPhase1 = loopMs
        Self.dbgPhase2 = wrapMs
        guard let cgImage else { return nil }
        let entry = MemoEntry(image: NSImage(cgImage: cgImage,
                                             size: NSSize(width: CGFloat(totalCols),
                                                          height: CGFloat(pxHeight))),
                              t0: imgT0,
                              secondsPerPixel: secPerPx)
        memo[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > maxMemo { memo.removeValue(forKey: order.removeFirst()) }
        Self.lock.lock(); Self.renderCount += 1; Self.lock.unlock()
        return entry
    }

    private static func skinBucket(_ rgb: (Double, Double, Double)) -> Int {
        (min(63, max(0, Int(rgb.0 * 63))) << 12)
            | (min(63, max(0, Int(rgb.1 * 63))) << 6)
            | min(63, max(0, Int(rgb.2 * 63)))
    }
}
