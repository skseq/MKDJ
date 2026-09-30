import SwiftUI
import AppKit
import AVFoundation

// MARK: - Scroll / pinch catcher
// SwiftUI on macOS doesn't route scroll-wheel or magnify events to plain
// views; a transparent NSView overlay does.

struct ScrollCatcher: NSViewRepresentable {
    var onScroll: ((Double) -> Void)?      // Δy in pixels, + = down
    var onMagnify: ((Double) -> Void)?     // pinch factor − 1
    var onShiftScroll: ((Double) -> Void)?

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        v.onShiftScroll = onShiftScroll
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
        nsView.onShiftScroll = onShiftScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((Double) -> Void)?
        var onMagnify: ((Double) -> Void)?
        var onShiftScroll: ((Double) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            if event.modifierFlags.contains(.shift), let cb = onShiftScroll {
                cb(Double(event.scrollingDeltaX + event.scrollingDeltaY))
            } else {
                onScroll?(Double(event.scrollingDeltaY))
            }
        }

        override func magnify(with event: NSEvent) {
            onMagnify?(Double(event.magnification))
        }
    }
}

// MARK: - Grid tick math

enum GridRenderer {
    /// Beat times (with beat index, for downbeat detection) within [start, end).
    static func beatTimes(bpm: Double?, anchor: Double, start: Double, end: Double) -> [(t: Double, k: Int)] {
        guard let bpm, bpm > 20 else { return [] }
        let period = 60.0 / bpm
        var k = Int(ceil((start - anchor) / period))
        var out: [(Double, Int)] = []
        while anchor + Double(k) * period < end {
            out.append((anchor + Double(k) * period, k))
            k += 1
        }
        return out
    }
}

// MARK: - Scrolling (zoomed) waveform

struct ScrollingWaveformView: View {
    @ObservedObject var deck: DeckModel
    @Binding var windowSeconds: Double

    /// CDJ interaction model:
    /// • playing: drag = platter jog (a live rate parameter — never a seek);
    ///   release with velocity = throw, momentum eases back to 1×
    /// • paused:  drag = frozen-mapping scrub (paused seeks are free and
    ///   instant; the mapping is computed once at touch so the moving
    ///   playhead can't feed back into the drag)
    /// • tap:     jump to that time (a real seek — the one case that pays it)
    @State private var dragging = false
    @State private var scrubBase: Double?       // PULL grab anchor (position at press)
    /// x of the press that started the CURRENT gesture. A system-cancelled
    /// drag (key press mid-drag, focus change, view swap without
    /// disappearance) ends WITHOUT onEnded — dragMode and scrubBase then
    /// leak into the NEXT gesture and anchor it to the dead drag's
    /// position ("every drag snaps back to 0:00/cue"). A new press has a
    /// new startLocation; comparing it against this detects the leak.
    @State private var gestureStartX: CGFloat?
    @State private var renderer = WaveRenderer()
    @ObservedObject private var clock = LaneClock.shared

    var body: some View {
        GeometryReader { geo in
            // .animation only while playing — paused lanes tick at 2 Hz so
            // the app sits near zero CPU when idle; scrub bumps scrubTick
            // to redraw at event rate.
            // LaneClock — a common-run-loop-mode timer that fires during
            // slider/gesture tracking, stepping 0/30/60 Hz by transport
            // state. Deterministic cadence; zero cost when idle.
            // The tick is read for observation-driven invalidation ONLY —
            // never re-key the canvas by identity on the tick: that churn
            // tears down in-flight DragGestures (the drag-loop and dead
            // overview-seek regression).
            let _ = clock.tick
            Canvas { ctx, size in
                let t0 = CFAbsoluteTimeGetCurrent()
                draw(ctx: ctx, size: size, now: Date())
                FrameStats.shared.record((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            }
            .contentShape(Rectangle())
            // No tap action: the overview stripe is the seek surface
            // (standard DJ software layout); a bare click on the moving waveform
            // is a platter touch without rotation, i.e. a no-op. Drags below
            // carry the CDJ behaviors (jog while playing, scrub while paused).
            .gesture(
                // 10 px so trackpad jitter on a click never becomes a
                    // micro-grab — a pure click on the platter is a no-op.
                    DragGesture(minimumDistance: 10)
                    .onChanged { g in
                        // leaked-gesture recovery: this event belongs to a
                        // NEW press (startLocation moved) while state from a
                        // previous, never-ended drag is still live — cancel
                        // the dead grab and fall through to a fresh begin.
                        if dragging, let oldX = gestureStartX,
                           abs(g.startLocation.x - oldX) > 2 {
                            deck.engine.scrubCancel()
                            MKLog.app("wave drag: leaked gesture state reset (stale anchor)")
                            dragging = false
                            scrubBase = nil
                            gestureStartX = nil
                        }
                        if !dragging {
                            gestureStartX = g.startLocation.x
                            // grab in BOTH play states — press stops the audio
                            // under the finger. Anchor on the ENGINE's display
                            // truth: a playing deck's extrapolated cache is up
                            // to 0.2 s stale (and latency-shifted under
                            // keylock), which made grabs jump the lane.
                            deck.engine.scrubBegin()
                            if scrubBase == nil {
                                scrubBase = Double(deck.engine.displayFileFrame()) / deck.engine.sampleRate
                            }
                            dragging = true
                        }
                        // position-domain grab: the target follows the cursor
                        // 1:1 (left = forward); audio chases.
                        if let x0 = gestureStartX, let base = scrubBase {
                            let dt = Double(g.location.x - x0) / geo.size.width * windowSeconds
                            deck.engine.scrubSet(targetFrame: AVAudioFramePosition(
                                max(0, (base - dt)) * deck.engine.sampleRate))
                        }
                    }
                    .onEnded { g in
                        // throw: the cursor's TRUE file-velocity, sign-flipped
                        // (the drag mapping is left = forward while
                        // velocity.width is positive rightward). Raw rate, no
                        // gain: the release momentum IS the hand's speed.
                        let vFps = -Double(g.velocity.width) / geo.size.width * windowSeconds * deck.engine.sampleRate
                        deck.engine.scrubEnd(velocityFramesPerSec: vFps)
                        scrubBase = nil
                        dragging = false
                        gestureStartX = nil
                    }
            )
        }
        .background(ScrollCatcher(
            onScroll: { delta in
                windowSeconds = min(180, max(3, windowSeconds * exp(delta / 14)))
            },
            onMagnify: { m in
                windowSeconds = min(180, max(3, windowSeconds * exp(-m)))
            }
        ))
        .onDisappear {
            // scrubEnd is otherwise reachable only from the gesture's
            // onEnded — never leave the deck grabbed if the lane goes
            // away mid-drag.
            if dragging {
                deck.engine.scrubCancel()
                dragging = false
                scrubBase = nil
                gestureStartX = nil
            }
        }
    }


    private var playheadSeconds: Double { deck.positionSeconds }

    private func draw(ctx: GraphicsContext, size: CGSize, now: Date) {
        let w = size.width, h = size.height
        let mid = h / 2
        let pos = playheadSeconds
        let t0 = pos - windowSeconds / 2
        let t1 = pos + windowSeconds / 2
        let sr = deck.engine.sampleRate

        // background
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)),
                 with: .color(AppSettings.shared.laneBackgroundColor))

        // loop shading
        if let ls = deck.engine.loopStart, let le = deck.engine.loopEnd {
            shadeTime(ctx, size: size, from: Double(ls) / sr, to: Double(le) / sr,
                      color: Theme.accent.opacity(0.13))
        }

        // direct-from-pyramid — the visible window is rasterized
        // synchronously (sub-ms class; the memo slides playback inside a
        // margin). Nothing async, nothing to miss: seeks of any depth are
        // visible on the very next frame by construction.
        if let pyramid = deck.peaks {
            let spp = windowSeconds / w
            if let e = renderer.renderWindow(pyramid: pyramid, sampleRate: sr,
                                             duration: deck.duration,
                                             t0: t0, secPerPx: spp,
                                             columns: max(1, Int(w)),
                                             pxHeight: max(1, Int(h)),
                                             alpha: 0.75,
                                             rgb: AppSettings.shared.waveRGB) {
                // whole-point blit offset — fractional offsets resample
                // the bitmap every frame (the shimmer)
                let x = ((e.t0 - t0) / spp).rounded()
                ctx.draw(Image(nsImage: e.image),
                         in: CGRect(x: x, y: 0,
                                    width: CGFloat(e.image.size.width),
                                    height: h))
            }
        } else if deck.hasTrack {
            // analysis pending: thin center line
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: mid)); p.addLine(to: CGPoint(x: w, y: mid))
            }, with: .color(Color.primary.opacity(0.15)), lineWidth: 1)
        }

        // beat grid ticks (subdued when low confidence)
        let tickAlpha = min(0.8, max(0.18, deck.gridConfidence + 0.18))
        let beats = GridRenderer.beatTimes(bpm: deck.baseBPM, anchor: deck.gridAnchorSeconds,
                                           start: max(0, t0), end: t1)
        // one Path per emphasis level, two strokes total — a Path+stroke
        // per beat tick was dozens of allocations per frame
        var downbeats = Path()
        var offbeats = Path()
        for beat in beats {
            let x = (beat.t - t0) / windowSeconds * w
            if beat.k.isMultiple(of: 4) {
                downbeats.move(to: CGPoint(x: x, y: h * 0.02))
                downbeats.addLine(to: CGPoint(x: x, y: h * 0.98))
            } else {
                offbeats.move(to: CGPoint(x: x, y: h * 0.12))
                offbeats.addLine(to: CGPoint(x: x, y: h * 0.86))
            }
        }
        // grid lines follow the skin (downbeat strong, offbeat at ×0.45 —
        // the existing grammar, re-tinted)
        let grid = AppSettings.shared.gridColor
        ctx.stroke(downbeats, with: .color(grid.opacity(tickAlpha)), lineWidth: 1)
        ctx.stroke(offbeats, with: .color(grid.opacity(tickAlpha * 0.45)), lineWidth: 1)

        // cue marker
        if let cue = deck.engine.cueFrame {
            let t = Double(cue) / sr
            let x = (t - t0) / windowSeconds * w
            if x >= 0, x <= w {
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                }, with: .color(AppSettings.shared.cueColor), lineWidth: 2)
            }
        }

        // loop boundary lines
        if let ls = deck.engine.loopStart, let le = deck.engine.loopEnd {
            lineTime(ctx, size: size, at: Double(ls) / sr, color: Theme.accent)
            lineTime(ctx, size: size, at: Double(le) / sr, color: Theme.accent)
        }

        // playhead (center) — amber while a grab/throw is live
        let manipulating = deck.engine.isScrubbing || abs(deck.engine.pullDeck.momentumSnapshot - 1) > 0.01
        let headColor = manipulating ? Theme.amber : AppSettings.shared.playheadColor
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: w / 2, y: 0)); p.addLine(to: CGPoint(x: w / 2, y: h))
        }, with: .color(headColor), lineWidth: 2)
        // faint halo for legibility over dense peaks
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: w / 2 - 2, y: 0)); p.addLine(to: CGPoint(x: w / 2 - 2, y: h))
        }, with: .color(headColor.opacity(0.25)), lineWidth: 1)
    }

    private func shadeTime(_ ctx: GraphicsContext, size: CGSize, from: Double, to: Double,
                           color: Color) {
        let w = size.width
        let t0 = playheadSeconds - windowSeconds / 2
        let x0 = (from - t0) / windowSeconds * w
        let x1 = (to - t0) / windowSeconds * w
        guard x1 > 0, x0 < w else { return }
        ctx.fill(Path(CGRect(x: max(0, x0), y: 0,
                             width: min(w, x1) - max(0, x0), height: size.height)),
                 with: .color(color))
    }

    private func lineTime(_ ctx: GraphicsContext, size: CGSize, at t: Double, color: Color) {
        let w = size.width
        let t0 = playheadSeconds - windowSeconds / 2
        let x = (t - t0) / windowSeconds * w
        guard x >= 0, x <= w else { return }
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
        }, with: .color(color), lineWidth: 1.5)
    }


}

// MARK: - Overview strip

/// The permanent loop channel between the BPM row and the wave.
/// Fixed height, ALWAYS rendered — no layout ever changes height. Shows
/// the ACTIVE loop's shaded span (any mode); in M mode also the draggable
/// IN/OUT handles. The mapping mirrors the wave lane exactly (same
/// display source, same `t0 = pos − window/2`) so the strip stays glued
/// to the waveform beneath at every zoom.
///
/// Zoom law: points live in the TIME domain (DeckModel seconds) — the
/// mapping below is computed fresh every tick, so zooming can never
/// move or lose a point. Out-of-window points PIN to the strip edge
/// (arrow shows which way); pinning is visual only — dragging maps the
/// finger's ABSOLUTE x to time per event, so a pinned grab sets the
/// point to the edge time and then it follows the finger.
struct ManualLoopStrip: View {
    @ObservedObject var deck: DeckModel
    @Binding var windowSeconds: Double
    @ObservedObject private var clock = LaneClock.shared
    /// Whole-window drag anchor (finger time + IN at grab). Cleared on
    /// gesture end AND unmount — a stale anchor would map the next drag's
    /// first event against a dead reference.
    @State private var spanGrab: (fingerT: Double, in0: Double)?

    /// Time → strip x (unclamped; callers pin for display).
    static func x(for t: Double, t0: Double, window: Double, width: Double) -> Double {
        (t - t0) / window * width
    }

    /// Strip x → time. Absolute mapping per event — never accumulate
    /// deltas, so zoom keys mid-drag stay coherent.
    static func time(at x: Double, t0: Double, window: Double, width: Double) -> Double {
        t0 + x / width * window
    }

    var body: some View {
        GeometryReader { geo in
            let _ = clock.tick   // observation-driven invalidation only
            let w = geo.size.width
            let h = geo.size.height
            let sr = max(deck.engine.sampleRate, 1)
            let pos = Double(deck.engine.displayFileFrame()) / sr
            let t0 = pos - windowSeconds / 2
            ZStack(alignment: .topLeading) {
                if let ls = deck.engine.loopStart, let le = deck.engine.loopEnd {
                    let x0 = max(0, Self.x(for: Double(ls) / sr, t0: t0, window: windowSeconds, width: w))
                    let x1 = min(w, Self.x(for: Double(le) / sr, t0: t0, window: windowSeconds, width: w))
                    if x1 > x0 {
                        Rectangle()
                            .fill(Theme.accent.opacity(0.18))
                            .frame(width: x1 - x0, height: h)
                            .offset(x: x0)
                            .contentShape(Rectangle())
                            // grab the shaded body → translate the whole
                            // window (span preserved; model clamps to the
                            // track). Manual mode only — beats windows
                            // belong to the number buttons. Locations read
                            // in strip space, absolute per event.
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named("loopStrip"))
                                    .onChanged { g in
                                        let t = Self.time(at: g.location.x, t0: t0, window: windowSeconds, width: w)
                                        if spanGrab == nil { spanGrab = (fingerT: t, in0: deck.manualIn) }
                                        deck.dragManualSpan(spanGrab!.in0 + (t - spanGrab!.fingerT))
                                    }
                                    .onEnded { _ in
                                        spanGrab = nil
                                        deck.commitManualSpan()
                                    }
                            )
                            .help(deck.manualLoopActive
                                  ? "Loop window — drag to move it (IN and OUT travel together)"
                                  : "Loop span")
                            .allowsHitTesting(deck.manualLoopActive)
                    }
                }
                if deck.manualLoopActive {
                    handle(tag: "IN", isIn: true, t: deck.manualIn, t0: t0, w: w, h: h)
                    handle(tag: "OUT", isIn: false, t: deck.manualOut, t0: t0, w: w, h: h)
                }
            }
            .coordinateSpace(name: "loopStrip")
            .onDisappear { spanGrab = nil }   // leaked-gesture recovery (house pattern)
        }
    }

    private func handle(tag: String, isIn: Bool, t: Double, t0: Double, w: Double, h: Double) -> some View {
        let raw = Self.x(for: t, t0: t0, window: windowSeconds, width: w)
        let pinned = raw < 1 || raw > w - 1
        let px = max(14, min(w - 14, raw))
        return Text(pinned ? (raw < 1 ? "\(tag)◂" : "▸\(tag)") : tag)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 24, minHeight: 13)
            .contentShape(Rectangle())
            .background(Theme.accent.opacity(0.92), in: RoundedRectangle(cornerRadius: 3))
            .position(x: px, y: h / 2)
            // coordinateSpace: the tag MOVES with the model while dragged —
            // gesture locations must read in strip space, not tag space.
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("loopStrip"))
                    .onChanged { g in
                        let t = Self.time(at: g.location.x, t0: t0, window: windowSeconds, width: w)
                        if isIn { deck.dragManualIn(t) } else { deck.dragManualOut(t) }
                    }
                    .onEnded { _ in deck.commitManualSpan() }
            )
            .help(isIn ? "Loop IN — drag to set the start point" : "Loop OUT — drag to set the end point")
    }
}

struct OverviewWaveformView: View {
    @ObservedObject var deck: DeckModel
    @State private var renderer = WaveRenderer()
    @ObservedObject private var clock = LaneClock.shared

    /// Target marker while a drag is active (draw-only; the seeks
    /// themselves fire live on every gesture event).
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            // observation-driven invalidation only — identity churn at
            // frame rate kills gestures (see the zoomed lane).
            let _ = clock.tick
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
                if let f = dragFraction {
                    let x = f * size.width
                    ctx.stroke(Path { p in
                        p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                    }, with: .color(.white.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .contentShape(Rectangle())
            // Timeline model learned from a stem-separation tool studied
            // earlier — ONE gesture, no tap/drag split: the press itself
            // seeks, the drag keeps seeking live. The old
            // ghost-then-release design was a push-era guard (live
            // scrubbing from the overview would have thrashed the segment
            // scheduler); under pull an in-ring seek is a state write and
            // an out-of-ring one is an async ring refill.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // canonical mapping: this fraction→time math is the
                        // single source for both hit-test and marker draw
                        let f = max(0, min(1, Double(g.location.x / max(1, geo.size.width))))
                        dragFraction = f
                        deck.seekLive(to: f * deck.duration)
                    }
                    .onEnded { g in
                        dragFraction = nil
                        // commit — one queued seek for the queue-owned
                        // bookkeeping (pausedFile et al)
                        let f = max(0, min(1, Double(g.location.x / max(1, geo.size.width))))
                        deck.seek(to: f * deck.duration)
                    }
            )
        }
        .background(AppSettings.shared.laneBackgroundColor)
        .onDisappear { dragFraction = nil }
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let duration = max(0.001, deck.duration)
        let sr = deck.engine.sampleRate

        if let pyramid = deck.peaks {
            let spp = duration / w
            if let e = renderer.renderWindow(pyramid: pyramid, sampleRate: sr,
                                             duration: duration,
                                             t0: 0, secPerPx: spp,
                                             columns: max(1, Int(w)),
                                             pxHeight: max(1, Int(h)),
                                             alpha: 0.4,
                                             rgb: AppSettings.shared.waveRGB) {
                let x = CGFloat(e.t0 / spp)
                ctx.draw(Image(nsImage: e.image),
                         in: CGRect(x: x, y: 0,
                                    width: CGFloat(e.image.size.width),
                                    height: h))
            }
        }

        // section boundaries (native novelty-curve segmentation)
        for sec in deck.sections where sec.startSeconds > 0.5 {
            let x = sec.startSeconds / duration * w
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
            }, with: .color(.white.opacity(sec.label == "peak" ? 0.35 : 0.18)), lineWidth: 1)
        }

        // loop shading
        if let ls = deck.engine.loopStart, let le = deck.engine.loopEnd {
            let x0 = Double(ls) / sr / duration * w
            let x1 = Double(le) / sr / duration * w
            ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0), height: h)),
                     with: .color(Theme.accent.opacity(0.22)))
        }

        // cue marker
        if let cue = deck.engine.cueFrame {
            let x = Double(cue) / sr / duration * w
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
            }, with: .color(AppSettings.shared.cueColor), lineWidth: 1.5)
        }

        // playhead
        let px = deck.positionSeconds / duration * w
        ctx.stroke(Path { p in
            p.move(to: CGPoint(x: px, y: 0)); p.addLine(to: CGPoint(x: px, y: h))
        }, with: .color(AppSettings.shared.playheadColor), lineWidth: 1.5)
    }
}
