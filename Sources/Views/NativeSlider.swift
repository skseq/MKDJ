import SwiftUI
import AppKit

/// Native NSSlider wrappers: AppKit's tracking loop is immune to main-thread
/// render pressure (the custom gesture sliders starved during two-lane
/// 60 fps playback — sticky, sometimes stuck). Double-click resets to a
/// default; live audio via callbacks at tracking rate, one commit on
/// release.
///
/// Additions:
/// - `fineControl`: Shift held during a drag scales deltas to 1/10
///   (the old drag-slider's finePerPx pattern). The cell tracks from its
///   own mouseDown anchor, so fine mode applies an accumulated offset —
///   the knob never snaps back toward the raw mapping.
/// - `centerDetent`: bipolar sliders snap to range center inside a small
///   sticky zone (~0.8% of range) — easy to find 0, easy to leave.
final class MKSlider: NSSlider {
    var onLive: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    var onDoubleClick: (() -> Void)?

    var onTrackingChanged: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        // mark tracking for the whole cell-tracking loop — without this,
        // any SwiftUI re-render mid-drag calls updateNSView, which snaps
        // the knob back to the stale committed value (the "tempo slider
        // doesn't change" bug).
        onTrackingChanged?(true)
        // no onLive on the press — it fired a spurious live event carrying
        // the PRE-drag value on every click; live events come from the
        // tracking action as the knob actually moves.
        super.mouseDown(with: event)   // blocks through mouseUp
        onTrackingChanged?(false)
        onEnd?(doubleValue)
    }
}

struct NativeSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var vertical: Bool = false
    var onLive: ((Double) -> Void)? = nil
    /// Double-click resets to this value (nil = no reset).
    var doubleClickReset: Double? = nil
    /// Visual tick marks (e.g. crossfader center detent).
    var tickMarks: Int = 0
    /// Shift during a drag = micro control (deltas × 1/10).
    var fineControl = false
    /// Sticky snap to range center inside ±0.8% of range.
    var centerDetent = false

    /// 0.15 — 0.04 was below the sense threshold and the center detent
    /// re-pinned fine drags (dead middle). 4× the travel, still 7× finer
    /// than raw.
    static let fineFraction = 0.15

    /// The fine/detent math as a PURE function — the probe gates drive it
    /// directly (AppKit's tracking loop can't be driven by synthetic drag
    /// events). Same semantics as the old inline changed() logic.
    static func processedValue(raw v: Double, range: ClosedRange<Double>,
                               emitted: Double?, fineOffset: Double,
                               shift: Bool, detentEnabled: Bool)
        -> (value: Double, fineOffset: Double) {
        var value = v
        var offset = fineOffset
        if shift {
            let last = emitted ?? v
            let desired = last + (v - last) * fineFraction
            offset += desired - v
            value = desired
        } else if offset != 0 {
            value += offset
        }
        if detentEnabled && !shift {
            let c = (range.lowerBound + range.upperBound) / 2
            let w = (range.upperBound - range.lowerBound) * detentWidth
            if abs(value - c) < w { value = c }
        }
        value = max(range.lowerBound, min(range.upperBound, value))
        return (value, offset)
    }
    static let detentWidth = 0.008   // fraction of full range

    func makeNSView(context: Context) -> MKSlider {
        let s = MKSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound,
                          target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        s.onTrackingChanged = { tracking in
            context.coordinator.isTracking = tracking
            if tracking {   // fresh gesture — clear fine/detent bookkeeping
                context.coordinator.emitted = nil
                context.coordinator.fineOffset = 0
                // a grab is human intent — snapbacks stand down
                Snapback.cancelAll()
            }
        }
        s.isContinuous = true
        s.controlSize = .small
        s.numberOfTickMarks = tickMarks
        s.allowsTickMarkValuesOnly = false
        if vertical {
            // NSSlider picks orientation from its frame — set it BEFORE the
            // SwiftUI sizing lands (tall + narrow), or it renders horizontal.
            s.frame = NSRect(x: 0, y: 0, width: 24, height: 92)
            s.isVertical = true
        }
        wire(s, context: context)
        context.coordinator.slider = s
        return s
    }

    /// One place for the mutable callbacks so makeNSView and every
    /// updateNSView stay identical (duplicated wiring could drift).
    private func wire(_ s: MKSlider, context: Context) {
        context.coordinator.parent = self
        s.onLive = { v in
            context.coordinator.parent.onLive?(v)
        }
        s.onEnd = { v in
            context.coordinator.parent.value = v
        }
        if let reset = doubleClickReset {
            s.onDoubleClick = { [weak s] in
                MainActor.assumeIsolated {
                    let c = context.coordinator
                    c.isTracking = false
                    guard AppSettings.shared.snapSeconds > 0 else {
                        // instant reset (0 s) — the knob moves in the SAME
                        // event as the value (don't rely on a later SwiftUI
                        // re-render to reposition it), + the self-verifying
                        // reset below.
                        s?.doubleValue = reset
                        s?.needsDisplay = true
                        c.parent.onLive?(reset)
                        c.parent.value = reset
                        DispatchQueue.main.async {
                            guard let s else { return }
                            if abs(s.doubleValue - reset) > 1e-9 {
                                MKLog.app(String(format: "slider knob moved post-reset to %.3f — forcing", s.doubleValue))
                                s.doubleValue = reset
                                s.needsDisplay = true
                            }
                        }
                        return
                    }
                    // eased snapback — ticks write knob + live + binding
                    // together; the tween self-cancels if anything else
                    // writes the value (no post-reset forcing here: the
                    // knob is SUPPOSED to be mid-flight between ticks).
                    Snapback.reset(current: c.parent.value, to: reset,
                                   apply: { v in
                        s?.doubleValue = v
                        s?.needsDisplay = true
                        c.parent.onLive?(v)
                        c.parent.value = v
                    },
                                   read: { c.parent.value })
                }
            }
        }
    }

    func updateNSView(_ s: MKSlider, context: Context) {
        wire(s, context: context)
        if !context.coordinator.isTracking, abs(s.doubleValue - value) > 1e-9 {
            MKLog.app(String(format: "slider resync: %.3f → %.3f (tracking=%d, obj %x)",
                              s.doubleValue, value, context.coordinator.isTracking ? 1 : 0,
                              UInt(bitPattern: ObjectIdentifier(s).hashValue)))
            s.doubleValue = value
        }
    }

    final class Coordinator {
        var parent: NativeSlider
        var slider: MKSlider?
        var isTracking = false
        /// Last value emitted in the current drag (fine-mode anchor).
        var emitted: Double?
        /// Accumulated raw→fine correction for this drag (constant offset
        /// after Shift is released mid-drag, so coarse resumes 1:1 from the
        /// knob's current position).
        var fineOffset: Double = 0
        init(_ parent: NativeSlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            let r = NativeSlider.processedValue(
                raw: sender.doubleValue, range: parent.range,
                emitted: emitted, fineOffset: fineOffset,
                shift: parent.fineControl && ShiftKeyMonitor.shared.isShift,
                detentEnabled: parent.centerDetent)
            let v = r.value
            fineOffset = r.fineOffset
            if v != sender.doubleValue { sender.doubleValue = v }
            emitted = v
            parent.onLive?(v)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
}
