import SwiftUI
import AppKit

/// Click-to-edit numeric readout (commit clamps upstream).
struct NumericField: View {
    let value: Double
    var format: String = "%.2f"
    var font: Font = .system(size: 11, design: .default)
    var color: Color = Theme.ink
    /// Reports focus in/out so ShortcutManager passes typing (replaces
    /// responder sniffing, which leaked invisible field editors).
    var onFocusChange: ((Bool) -> Void)? = nil
    var onCommit: (Double) -> Void

    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(font)
                    .multilineTextAlignment(.center)
                    .frame(width: 58)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07)))
                    .focused($focused)
                    .onChange(of: focused) { _, focused in onFocusChange?(focused) }
                    // if the field unmounts while focused, the
                    // balance-based focus counter never saw a focus-OUT and
                    // hotkeys silently passed to text forever
                    .onDisappear {
                        if focused { onFocusChange?(false) }
                    }
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
            } else {
                Text(String(format: format, value))
                    .font(font)
                    .foregroundColor(color)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        text = String(format: "%.3f", value)
                        editing = true
                        focused = true
                    }
            }
        }
        .help("Click to type a value")
    }

    private func commit() {
        defer { editing = false }
        guard let v = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
        onCommit(v)
    }
}

// MARK: - Shift-key tracking for gestures
// DragGesture.Value carries no modifier flags; a flagsChanged monitor does.

final class ShiftKeyMonitor: ObservableObject {
    static let shared = ShiftKeyMonitor()
    @Published var isShift = false
    private var local: Any?
    private var global: Any?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.isShift = e.modifierFlags.contains(.shift)
            return e
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.isShift = e.modifierFlags.contains(.shift)
        }
    }
}

/// Numeric readout that tracks a control atom LIVE while the control is
/// dragged; tap-to-edit and commit semantics unchanged.
struct LiveNumericField: View {
    @ObservedObject var atom: ControlAtom
    let format: String
    let font: Font
    let color: Color
    var onFocusChange: ((Bool) -> Void)? = nil
    let onCommit: (Double) -> Void

    var body: some View {
        NumericField(value: atom.v, format: format, font: font, color: color,
                     onFocusChange: onFocusChange, onCommit: onCommit)
    }
}

/// One control's live value as its own observable: a drag publishes HERE
/// at event rate — invalidating only the views that observe this atom —
/// while the deck model is written once, on release.
final class ControlAtom: ObservableObject {
    @Published var v: Double
    init(_ v: Double) { self.v = v }
}

// MARK: - DJ knob (coarse/fine/scroll, double-click reset, mouse only)

/// Manual double-tap detection that survives `DragGesture(minimumDistance: 0)`
/// (SwiftUI taps never fire alongside a zero-distance drag).
struct DoubleTapDetector {
    var pressStart: Date?
    var pressAt: CGPoint?
    var lastTap: Date?

    mutating func began(at point: CGPoint) {
        if pressStart == nil {
            pressStart = Date()
            pressAt = point
        }
    }

    /// Returns true when this gesture-end completes a double-click.
    mutating func ended(at point: CGPoint, translation: CGSize) -> Bool {
        defer { pressStart = nil; pressAt = nil }
        guard let t0 = pressStart, let p0 = pressAt else { return false }
        guard Date().timeIntervalSince(t0) < 0.3,
              abs(translation.width) < 4, abs(translation.height) < 4,
              hypot(point.x - p0.x, point.y - p0.y) < 6 else { return false }
        if let last = lastTap, Date().timeIntervalSince(last) < 0.35 {
            lastTap = nil
            return true
        }
        lastTap = Date()
        return false
    }
}

struct DJKnob: View {
    let label: String
    @Binding var value: Double
    var lo: Double = -1
    var hi: Double = 1
    var defaultReset: Double = 0
    var coarsePerPx: Double? = nil      // defaults: range/120 per px
    var finePerPx: Double? = nil        // defaults: range/1200 per px
    var scrollStep: Double? = nil       // defaults: range/20 per notch
    var fineScrollStep: Double? = nil   // defaults: range/200 per notch
    var accent: Color = Theme.accent
    var display: (Double) -> String = { String(format: "%.2f", $0) }
    var displayColor: Color = Theme.muted
    /// Called at gesture rate with no SwiftUI publishing — the direct audio
    /// path while dragging. The binding stays the committed value, written
    /// once on release.
    var onLive: ((Double) -> Void)? = nil
    /// Event-rate UI mirror for mid-drag readouts elsewhere (observers of
    /// this atom re-render; the deck model does not).
    var atom: ControlAtom? = nil

    @State private var dragStart: Double?
    @State private var gestureStartX: CGFloat?
    @State private var hover = false
    @State private var taps = DoubleTapDetector()
    @State private var liveValue: Double?

    /// Live value while dragging; the atom or committed binding otherwise.
    private var shown: Double { liveValue ?? atom?.v ?? value }

    /// Per-event: drive audio + the atom immediately; the committed binding
    /// is written ONCE, on release (deck-model publishes were the frame-skip
    /// source).
    private func applyLive(_ v: Double) {
        liveValue = v
        onLive?(v)
        atom?.v = v
    }

    private var range: Double { hi - lo }

    private func clamp(_ v: Double) -> Double { max(lo, min(hi, v)) }

    private var angle: Double {
        let f = (shown - lo) / range          // 0...1
        return -135 + f * 270
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .fill(hover ? Color.white.opacity(0.06) : Theme.surface)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                AngularGradient(
                                    gradient: Gradient(colors: [Theme.rule, Color.white.opacity(0.16), Theme.rule]),
                                    center: .center,
                                    startAngle: .degrees(-135),
                                    endAngle: .degrees(135)),
                                lineWidth: 1.5)
                    )
                Capsule()
                    .fill(accent)
                    .frame(width: 2, height: 12)
                    .offset(y: -11)
                    .rotationEffect(.degrees(angle))
                // center detent tick
                if lo < defaultReset && defaultReset < hi {
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 1.5, height: 3)
                        .offset(y: 17)
                }
            }
            .frame(width: 44, height: 42)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        taps.began(at: g.startLocation)
                        // leaked-gesture recovery (same class as the wave
                        // lane's fix) — a system-cancelled drag ends
                        // without onEnded and left a stale dragStart, so
                        // the next press jumped from the dead drag's base.
                        if dragStart != nil, let x = gestureStartX,
                           abs(g.startLocation.x - x) > 2 {
                            dragStart = nil
                        }
                        if dragStart == nil {
                            dragStart = value
                            gestureStartX = g.startLocation.x
                        }
                        let base = dragStart ?? value
                        let px = Double(-g.translation.height)
                        let perPx = ShiftKeyMonitor.shared.isShift
                            ? (finePerPx ?? range / 1200)
                            : (coarsePerPx ?? range / 120)
                        applyLive(clamp(base + px * perPx))
                    }
                    .onEnded { g in
                        if taps.ended(at: g.location, translation: g.translation) {
                            liveValue = nil
                            atom?.v = defaultReset
                            onLive?(defaultReset)
                            value = defaultReset
                        } else if let v = liveValue {
                            value = v    // single commit on release
                        }
                        liveValue = nil
                        dragStart = nil
                        gestureStartX = nil
                    }
            )
            .onHover { hover = $0 }
            .background(
                ScrollCatcher(
                    onScroll: { delta in
                        let step = delta <= 0 ? 1.0 : -1.0   // scroll up = increase
                        applyLive(clamp(shown + step * (scrollStep ?? range / 20)))
                    },
                    onShiftScroll: { delta in
                        let step = delta <= 0 ? 1.0 : -1.0
                        applyLive(clamp(shown + step * (fineScrollStep ?? range / 200)))
                    }
                )
            )
            .help("\(label): drag coarse · Shift-drag fine · scroll step · double-click reset")
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .tracking(0.4)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: true, vertical: false)
            Text(display(shown))
                .font(Theme.monoSmall)
                .foregroundColor(displayColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - Vertical fader (absolute drag, detent snap, double-click reset)

// DJFader deleted — all faders are native NSSliders (NativeSlider);
// the build fails if this type returns.

