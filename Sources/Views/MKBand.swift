import SwiftUI
import UniformTypeIdentifiers

// The MKDJ band shell (from an earlier UI study) bound to the REAL MKDJ
// engine. Deck 1 | volume column | deck 2; every control wired to
// DeckModel/AppModel. Typography law: size/weight/color only — no
// monospace; labels fixedSize, readouts minimumScaleFactor; one
// rowButton factory for uniform heights.

// MARK: - Uniform button factory

/// Slider-row label — hover turns it white, single click resets that
/// control to its default (same path as the slider's double-click).
/// Optional right-click-HOLD — momentary full cut (−12 dB); releasing (anywhere)
/// restores the value held before the press. No double-right action.
/// SwiftUI has no right-mouse gesture, so a native tracker view rides
/// behind the text.
struct MKSliderLabel: View {
    let text: String
    let reset: () -> Void
    var holdKill: (() -> Void)? = nil
    var holdRestore: (() -> Void)? = nil
    @State private var hover = false

    var body: some View {
        Text(text)
            .font(.system(size: 9).weight(.medium))
            .foregroundStyle(hover ? Color.primary : Color.secondary.opacity(0.7))
            .fixedSize()
            .padding(.horizontal, 2).padding(.vertical, 1)
            // the tracker rides ON TOP, claiming right-mouse events only —
            // in .background() it sat UNDER the SwiftUI text layer and
            // never saw a single event.
            .overlay(RightHoldTracker(onDown: holdKill, onUp: holdRestore))
            .onHover { hover = $0 }
            .onTapGesture { reset() }
            .help(holdKill != nil
                  ? "Click to reset · right-click HOLD for a momentary full cut"
                  : "Click to reset")
    }
}

/// Native right-mouse hold tracking (rightMouseDown … rightMouseUp/exited).
/// HOLD THRESHOLD — the kill engages only after ~0.15 s of sustained
/// hold; a quicker release does NOTHING (no cut, no flicker, no tween).
/// Spam and double-right-click are inert by construction, and the
/// spam-drift path (capturing a mid-tween value as the restore target)
/// is unreachable through the threshold.
struct RightHoldTracker: NSViewRepresentable {
    let onDown: (() -> Void)?
    let onUp: (() -> Void)?
    var holdThreshold: Double = 0.15

    final class TrackerView: NSView {
        var onDown: (() -> Void)?
        var onUp: (() -> Void)?
        var holdThreshold: Double = 0.15
        var downCount = 0   // probe gate diagnostics
        private var holding = false
        private var engaged = false
        private var holdTimer: Timer?

        /// Button-aware hit test: this overlay sees ONLY right-mouse
        /// events — left clicks (the label's tap-reset) and hover fall
        /// through to the SwiftUI layer underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            downCount += 1
            holding = true
            engaged = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
                guard let self, self.holding else { return }
                self.engaged = true   // the cut is real from here on
                self.onDown?()
            }
            RunLoop.main.add(holdTimer!, forMode: .common)
            // swallow: no NSMenu contextual behavior during the hold
        }
        override func rightMouseUp(with event: NSEvent) {
            holdTimer?.invalidate(); holdTimer = nil
            let wasEngaged = engaged
            holding = false
            engaged = false
            // below threshold: nothing happened — fidelity over reactivity
            if wasEngaged { onUp?() }
        }
        override func mouseExited(with event: NSEvent) {
            holdTimer?.invalidate(); holdTimer = nil
            // leaving the label while still holding: release = restore
            let wasEngaged = engaged
            holding = false
            engaged = false
            if wasEngaged { onUp?() }
        }
    }

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.onDown = onDown
        v.onUp = onUp
        return v
    }

    func updateNSView(_ v: TrackerView, context: Context) {
        v.onDown = onDown
        v.onUp = onUp
    }
}

struct MKRowButton: View {
    var label: String = ""
    var systemImage: String? = nil
    var active = false
    var help: String
    /// Skinny variant for short glyphs (numbers, M, ×2/÷2) — they should
    /// read as a cluster, not match the wide LOOP/BPM buttons.
    var compact = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                } else {
                    Text(label)
                }
            }
            .frame(minWidth: compact ? 22 : 30, minHeight: compact ? 14 : 16)
        }
        .controlSize(compact ? .mini : .small)
        .buttonStyle(.bordered)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1)
        )
        .help(help)
    }
}

/// Minimal-width tab for the loop numbers, M, and BPM ×2/÷2 — AppKit's
/// mini bordered chrome pads every side (22 pt min still renders ~30 pt
/// wide). This draws the chrome itself: text + 8 pt total, hairline
/// border, accent border + tint when active (MKRowButton's active grammar).
struct MKTinyTab: View {
    let label: String
    var active = false
    var help: String = ""
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 4)
                .frame(minHeight: 16)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Color.accentColor.opacity(0.18)
                                     : Color.primary.opacity(0.06))
                )
                .overlay(
                    // active only — the inactive hairline was dropped by design
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(active ? Color.accentColor : .clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }
}

/// SNAP state badge — visible only while grid snap is on (global
/// setting, both decks).
struct SnapBadge: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        if settings.snapEnabled {
            Text("SNAP")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .fixedSize()
                .help("Grid snap is ON — loop points and seeks land on beats (Settings ▸ Audio ▸ Snap to grid)")
        }
    }
}

// MARK: - Tick marks (shared by pitch/tempo/EQ)

struct MKTicks: View {
    var count = 5
    var centerIndex = 2

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Rectangle()
                    .fill(.tertiary.opacity(0.6))
                    .frame(width: 1, height: i == centerIndex ? 6 : 4)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 6)
        .allowsHitTesting(false)
    }
}

// MARK: - Deck band

struct MKDeckBand: View {
    @ObservedObject var deck: DeckModel
    @EnvironmentObject var app: AppModel
    var windowSeconds: Binding<Double>

    /// Which time reading is primary (app-wide, persisted).
    @AppStorage("lcdElapsedPrimary") private var elapsedPrimary = true
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 10) {
            lcdHeader
            bpmControlRow
            Divider().padding(.vertical, 1)

            // the wave stack renders UNCONDITIONALLY — strip, wave zone,
            // zoom row, overview all present (blank) on empty decks;
            // loading changes CONTENT, never geometry (the fixed-geometry
            // law, extended to load state).
            ManualLoopStrip(deck: deck, windowSeconds: windowSeconds)
                .frame(height: 20)
                .lcdInset(corner: 3)
            Group {
                if deck.hasTrack {
                    ScrollingWaveformView(deck: deck, windowSeconds: windowSeconds)
                } else {
                    dropHint
                }
            }
            .frame(minHeight: 96)
            .frame(maxHeight: .infinity)
            .lcdInset()
            zoomRow
            Group {
                if deck.hasTrack {
                    OverviewWaveformView(deck: deck)
                } else {
                    Color.clear
                }
            }
            .frame(height: 22)
            .lcdInset(corner: 3)

            Divider()
            loopTransportRow
            pitchRow
            tempoRow
            eqBlock
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onDrop(of: [.fileURL], delegate: DeckDropDelegate(model: deck, hover: { dropHover = $0 }))
        // the pointer picks the active deck — −/= zoom and deck keys act
        // on whichever panel the mouse is over. Hover alone: a panel-wide
        // tap gesture competed with NSSlider mouseDowns and ate
        // double-click resets, and the pointer must hover the deck before
        // any click can land anyway.
        .onHover { if $0 { app.focusedDeck = deck.index } }
        .overlay(
            // the whole deck panel is the drop target — accent ring on hover
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(dropHover ? Color.accentColor : .clear, lineWidth: 2)
        )
        .overlay(alignment: .top) {
            if let notice = deck.rejectionNotice {
                Text(notice)
                    .font(.system(size: 10))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.playheadRed.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundColor(.white)
                    .padding(.top, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: deck.rejectionNotice)
    }

    /// Empty deck: quiet placeholder — the LCD already says Untitled; the
    /// old "Drop an audio file" text is gone. Frames are owned by the
    /// unconditional wave-stack slot.
    private var dropHint: some View {
        Color.clear
    }

    // MARK: LCD

    private var lcdHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            // bold track TOTAL rides beside the deck badge
            HStack(spacing: 6) {
                Text("DECK \(deck.index + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(app.focusedDeck == deck.index && app.appActive
                                     ? Color.accentColor : .secondary)
                    .fixedSize()
                Text(String(format: "%d:%02d", Int(deck.duration) / 60, Int(deck.duration) % 60))
                    .font(.system(.footnote).weight(.bold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Spacer(minLength: 0)
                // eject-to-swap — loaded: unload + picker; empty: picker.
                // Right-aligned above the time stack.
                MKRowButton(label: deck.hasTrack ? "EJECT" : "LOAD",
                            help: deck.hasTrack
                                ? "Eject this track and load a new one"
                                : "Load a track") {
                    deck.ejectOrLoad()
 }
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    // "no metadata" voice — italic light-grey Untitled
                    // for empty decks; a no-ID3 file keeps its filename,
                    // styled the same way.
                    Text(deck.hasTrack ? deck.title : "Untitled")
                        .font(.system(.title3).weight(deck.hasTrack ? .semibold : .regular))
                        .italic(deck.hasTrack ? deck.titleIsFilename : true)
                        .foregroundStyle(deck.hasTrack && !deck.titleIsFilename ? .primary : Color.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // filename-as-title = no metadata — the artist slot
                    // stays BLANK; a tagged file shows its artist here.
                    Text(deck.titleIsFilename ? "" : (deck.hasTrack ? deck.artist : "Untitled"))
                        .font(.callout)
                        .italic(!deck.hasTrack)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // elapsed vs time-left, one click swaps the order
                VStack(alignment: .trailing, spacing: 1) {
                    Button { elapsedPrimary.toggle() } label: {
                        LiveTimeText(deck: deck, mode: elapsedPrimary ? .elapsed : .remaining)
                    }
                    .buttonStyle(.plain)
                    .help("Click to swap elapsed / time-left")
                    LiveTimeText(deck: deck, mode: elapsedPrimary ? .remaining : .elapsed, small: true)
                        .foregroundStyle(.secondary)
                        .onTapGesture { elapsedPrimary.toggle() }
                }
            }
            Divider().padding(.vertical, 1)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Text(readoutLine)
                    .font(.system(.caption).weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
    }

    /// The LCD time, LIVE — observes the LaneClock + positionTick so
    /// elapsed and remaining tick with playback. Modes: elapsed /
    /// remaining / total (total moved beside the deck badge).
    private struct LiveTimeText: View {
        enum Mode { case elapsed, remaining }
        @ObservedObject var deck: DeckModel
        let mode: Mode
        var small = false
        @ObservedObject private var clock = LaneClock.shared

        var body: some View {
            let _ = clock.tick
            let _ = deck.positionTick
            let pos = deck.positionSeconds
            let text: String
            switch mode {
            case .elapsed:
                // whole seconds — centiseconds read as noise
                text = String(format: "%d:%02d", Int(pos) / 60, Int(pos) % 60)
            case .remaining:
                let remain = max(0, deck.duration - pos)
                text = String(format: "−%d:%02d", Int(remain) / 60, Int(remain) % 60)
            }
            return Text(text)
                .font(small ? .system(.caption) : .system(.title3).weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var readoutLine: String {
        // the AUDIBLE tempo change — vinyl pitch (keylock off) multiplies
        // speed by 2^(st/12), so pitch drags move this live; keylock on =
        // pure transposition, the fader % alone shows.
        var parts = [String(format: "tempo %+.1f%%",
                            (deck.tempoRate * deck.vinylPitchFactor - 1) * 100)]
        if deck.keylock || abs(deck.pitchSemitones) > 0.005 {
            parts.append(String(format: "pitch %+.2f st", deck.pitchSemitones))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: BPM control row

    private var bpmControlRow: some View {
        HStack(spacing: 4) {
            HoldButton(label: "−", helpText: "Tempo bend −(hold)") { down in
                deck.nudge(active: down, sign: -1)
            }
            HoldButton(label: "+", helpText: "Tempo bend +(hold)") { down in
                deck.nudge(active: down, sign: 1)
            }
            Divider().frame(height: 14)
            MKTinyTab(label: "×2", help: "Base BPM ×2 (grid)") { deck.bpmMultiply(2) }
            MKTinyTab(label: "÷2", help: "Base BPM ÷2 (grid)") { deck.bpmMultiply(0.5) }
            MKRowButton(label: "BPM", help: "Recompute BPM with MKDJ's own analysis (bypasses cache)") {
                deck.reanalyzeBPM()
            }
            MKRowButton(label: "SYNC",
                       active: app.syncedDeck == deck.index,
                       help: "Sync — match the other deck's BPM") {
                app.toggleSync(deck.index)
            }
            Spacer(minLength: 0)
            bigBPM
        }
        .padding(.horizontal, 2)
    }

    /// The current-BPM readout, title-sized and right-aligned on the BPM
    /// row. ALWAYS engine truth at 10 Hz — a held bend AND the sync phase
    /// trim ride on currentRate and are published nowhere else, so the
    /// number must never disagree with the audio. Amber while a bend is
    /// held; tap = tap-BPM.
    private var bigBPM: some View {
        Group {
            if deck.baseBPM != nil {
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    Text(String(format: "%.1f", deck.audibleBPM ?? 0))
                        .font(.system(.title3).weight(.semibold))
                        .foregroundStyle(deck.nudgeActiveUI ? Theme.amber : .primary)
                }
            } else {
                Text("—")
                    .font(.system(.title3).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .fixedSize()
        .lineLimit(1)
        .onTapGesture { deck.tapBPM() }
        .help("Current BPM (tap in time to re-fit the grid)")
    }

    // MARK: Zoom row

    private var zoomRow: some View {
        HStack(spacing: 4) {
            ForEach([5.0, 15.0, 60.0], id: \.self) { w in
                Button {
                    windowSeconds.wrappedValue = w
                } label: {
                    Text("\(Int(w))s")
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(abs(windowSeconds.wrappedValue - w) < 1
                                               ? Color.accentColor : Color.secondary.opacity(0.35),
                                               lineWidth: 1)
                        )
                }
                .controlSize(.small)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Zoom \(Int(w)) seconds")
            }
            Spacer()
            Button { windowSeconds.wrappedValue = max(3, windowSeconds.wrappedValue / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .controlSize(.small).buttonStyle(.borderless).help("Zoom in")
            Button { windowSeconds.wrappedValue = min(180, windowSeconds.wrappedValue * 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .controlSize(.small).buttonStyle(.borderless).help("Zoom out")
        }
    }

    // MARK: Loop + transport

    private var loopTransportRow: some View {
        HStack(spacing: 8) {
            ForEach([1, 2, 4, 8, 16, 32], id: \.self) { b in
                MKTinyTab(label: "\(b)", active: deck.loopBeats == b,
                          help: "Loop \(b) beats (resizes the active loop live)") {
                    deck.selectLoopBeats(b)
                }
            }
            // manual loop — arbitrary in/out via the drag handles
            MKTinyTab(label: "M", active: deck.manualLoopActive,
                      help: "Manual loop (M) — custom in/out; drag the IN and OUT handles in the strip above the wave; drag the shaded span to move the window") {
                deck.toggleManualLoop()
            }
            MKRowButton(label: deck.loopActive ? "EXIT" : "LOOP", active: deck.loopActive,
                       help: deck.loopActive ? "Exit loop" : "Set loop at playhead (beats, grid)") {
                deck.loopSetExit()
            }
            // ×2/÷2/↺ buttons removed by design — the engine paths stay
            // (probe gates + API); loop restart keeps its opt-in keybind.
            // quiet context — armed span + snap state.
            Text(loopSpanText)
                .font(.system(size: 8).weight(.medium))
                .foregroundStyle(.tertiary)
                .fixedSize()
                .help("Armed loop length (follows the number buttons, M drags, and live resizes)")
            SnapBadge()
            Spacer(minLength: 12)
            Button { deck.togglePlayPause() } label: {
                Text(deck.isPlaying ? "PAUSE" : "PLAY")
                    .frame(minWidth: 64)
            }
            .controlSize(.regular)
            .buttonStyle(.bordered)
            .fixedSize()
            .help(deck.isPlaying ? "Pause" : "Play")
            HoldButton(label: "CUE", helpText: "CUE — hold to preview, release to return") { down in
                if down { deck.cueDown() } else { deck.cueUp() }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 2)
    }

    /// Armed-span readout — beats + seconds (grid), or the manual span
    /// in seconds.
    private var loopSpanText: String {
        if deck.manualLoopActive {
            return String(format: "M · %.1f s", max(0, deck.manualOut - deck.manualIn))
        }
        guard deck.engine.beatFrames > 0 else { return "\(deck.loopBeats) beats" }
        let secs = Double(deck.loopBeats) * deck.engine.beatFrames / max(1, deck.engine.sampleRate)
        return String(format: "%d · %.1f s", deck.loopBeats, secs)
    }

    // MARK: Pitch / Tempo
    private var pitchRow: some View {
        // ticks live INSIDE the slider column — alignment by construction
        // (the old 132/60pt magic paddings drifted with any label
        // change). Readout zone fixed-width; both deck rows mirror.
        HStack(spacing: 8) {
            MKSliderLabel(text: "PITCH") {
                Snapback.reset(current: deck.pitchSemitones, to: 0,
                               apply: { deck.pitchLive($0) },
                               read: { deck.pitchSemitones })
            }
            Toggle(isOn: $deck.keylock) {
                Image(systemName: deck.keylock ? "lock.fill" : "lock.open")
                    .foregroundStyle(deck.keylock ? .primary : .secondary)
            }
            .controlSize(.small)
            .toggleStyle(.button)
            .fixedSize()
            .help("Keylock ON — pitch transposes only (speed locked). OFF — vinyl: pitch also speeds up / slows down the deck")
            VStack(spacing: 1) {
                NativeSlider(value: Binding(
                    get: { deck.pitchSemitones },
                    set: { deck.pitchLive($0) }
                ), range: -24...24,
                   onLive: { deck.pitchLive($0) },
                   doubleClickReset: 0,
                   fineControl: true, centerDetent: true)
                HStack(spacing: 8) {
                    Text("+24").font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize()
                    MKTicks(count: 9, centerIndex: 4)
                    Text("−24").font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            Text(String(format: "%+.2f st", deck.pitchSemitones))
                .font(.system(.caption).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                .fixedSize()
        }
    }

    private var tempoRow: some View {
        HStack(spacing: 8) {
            MKSliderLabel(text: "TEMPO") {
                Snapback.reset(current: deck.tempoRate, to: 1.0,
                               apply: { deck.tempoLive($0) },
                               read: { deck.tempoRate })
            }
            // invisible lock slot — pitch's keylock toggle occupies this
            // width one row up; the placeholder keeps both rows' sliders
            // starting at the same x (uniform positioning)
            Color.clear.frame(width: 28, height: 1)
            VStack(spacing: 1) {
                NativeSlider(value: Binding(
                    get: { deck.tempoRate },
                    set: { deck.tempoLive($0) }
                ), range: 1.0 - AppSettings.shared.tempoRange...1.0 + AppSettings.shared.tempoRange,
                   onLive: { deck.tempoLive($0) },
                   doubleClickReset: 1.0,
                   fineControl: true, centerDetent: true)
                HStack(spacing: 8) {
                    Text("−8").font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize()
                    MKTicks(count: 5, centerIndex: 2)
                    Text("+8").font(.system(size: 8)).foregroundStyle(.tertiary).fixedSize()
                }
            }
            .frame(maxWidth: .infinity)
            Text(String(format: "%+.1f%%", (deck.tempoRate - 1) * 100))
                .font(.system(.caption).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
                .fixedSize()
        }
    }

    // MARK: EQ (under tempo)

    private var eqBlock: some View {
        VStack(spacing: 5) {
            Divider().padding(.vertical, 3)
            // 2×2 grid — LOW HIGH over MID GAIN — + full-width FILTER row.
            // Every cell carries the pitch/tempo zone grammar (fixed label
            // zone / slider zone with ticks INSIDE / fixed readout zone)
            // and one SHARED label width, so all five rows' sliders start
            // at the same x.
            HStack(spacing: 10) {
                eqCell("LOW", value: Binding(get: { deck.eqLowDb }, set: { deck.eqLowLive($0) }), momentaryKill: true)
                eqCell("HIGH", value: Binding(get: { deck.eqHighDb }, set: { deck.eqHighLive($0) }), momentaryKill: true)
            }
            HStack(spacing: 10) {
                eqCell("MID", value: Binding(get: { deck.eqMidDb }, set: { deck.eqMidLive($0) }), momentaryKill: true)
                eqCell("GAIN", value: Binding(get: { deck.trimDb }, set: { deck.trimLive($0) }), dbRange: true)
            }
            filterRow
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    /// One EQ cell: label zone (40pt) · slider zone (flex, ticks under
    /// the slider) · readout zone (34pt). Identical structure per cell =
    /// the 2×2 columns align by construction.
    private func eqCell(_ label: String, value: Binding<Double>,
                        dbRange: Bool = false, momentaryKill: Bool = false) -> some View {
        HStack(spacing: 6) {
            Group {
                if momentaryKill {
                    EQKillHoldLabel(label: label, value: value)
                } else {
                    MKSliderLabel(text: label) {
                        Snapback.reset(current: value.wrappedValue, to: 0,
                                       apply: { value.wrappedValue = $0 },
                                       read: { value.wrappedValue })
                    }
                }
            }
            .frame(width: 40, alignment: .leading)
            VStack(spacing: 1) {
                NativeSlider(value: value, range: -1...1,
                             onLive: { value.wrappedValue = $0 },
                             doubleClickReset: 0,
                             fineControl: true, centerDetent: true)
                MKTicks(count: 5, centerIndex: 2)
            }
            .frame(maxWidth: .infinity)
            Text(eqReadout(value.wrappedValue, dbRange: dbRange, bipolar: false))
                .font(.system(size: 9).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }

    /// The filter row — SAME zone grammar at full width; the slider spans
    /// the row (granular travel) with a 9-tick ruler.
    private var filterRow: some View {
        HStack(spacing: 6) {
            MKSliderLabel(text: "FILTER") {
                Snapback.reset(current: deck.filterKnob, to: 0,
                               apply: { deck.filterLive($0) },
                               read: { deck.filterKnob })
            }
            .frame(width: 40, alignment: .leading)
            VStack(spacing: 1) {
                NativeSlider(value: Binding(
                    get: { deck.filterKnob },
                    set: { deck.filterLive($0) }
                ), range: -1...1,
                   onLive: { deck.filterLive($0) },
                   doubleClickReset: 0,
                   fineControl: true, centerDetent: true)
                MKTicks(count: 9, centerIndex: 4)
            }
            .frame(maxWidth: .infinity)
            Text(eqReadout(deck.filterKnob, dbRange: false, bipolar: true))
                .font(.system(size: 9).weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
                .fixedSize()
        }
    }

    /// LOW/MID/HIGH label — click resets to 0; right-click HOLD momentarily
    /// cuts the band fully (−1 → −12 dB), release restores the held value.
    /// @State carries the saved value across the re-renders the kill itself
    /// triggers (a captured local would be rebuilt and lose it).
    struct EQKillHoldLabel: View {
        let label: String
        let value: Binding<Double>
        @State private var saved: Double?

        var body: some View {
            MKSliderLabel(text: label,
                          reset: {
                              Snapback.reset(current: value.wrappedValue, to: 0,
                                             apply: { value.wrappedValue = $0 },
                                             read: { value.wrappedValue })
                          },
                          holdKill: {
                              // freeze any in-flight restore so `saved`
                              // captures the honest audible value
                              Snapback.cancelAll()
                              saved = value.wrappedValue
                              value.wrappedValue = -1
                          },
                          holdRestore: {
                              // the return rides the snapback ease (down
                              // stays instant — a cut must be heard the
                              // moment it's pressed)
                              if let s = saved {
                                  Snapback.reset(current: value.wrappedValue, to: s,
                                                 apply: { value.wrappedValue = $0 },
                                                 read: { value.wrappedValue })
                              }
                              saved = nil
                          })
        }
    }

    private func eqReadout(_ v: Double, dbRange: Bool, bipolar: Bool) -> String {
        if bipolar {
            return v < -0.02 ? "LP" : (v > 0.02 ? "HP" : "off")
        }
        return String(format: "%+.0f", DeckModel.eqKnobToDb(v))
    }
}

// MARK: - Volume column (master horizontal + two full-height verticals)

/// Native-feeling vertical fader. NOT a rotated stock Slider — rotation
/// lies about the hit area and its AppKit tracking loop leaked mouse-ups
/// (which starved ALL keyboard events). A drag gesture writes the value
/// directly; the whole track is the hit target.
struct MKFader: View {
    @Binding var value: Double
    private let thumbH: CGFloat = 18
    /// Double-tap (two clicks, no drag) resets to this.
    var doubleTapReset: Double? = nil
    @State private var lastTap: Date?
    /// Fine-drag — Shift scales deltas to 1/10 from the press anchor
    /// (the old codebase's finePerPx feel).
    @State private var fineBase: Double?
    @State private var fineStartY: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let h = max(thumbH, geo.size.height)
            let usable = h - thumbH
            let y = thumbH / 2 + usable * (1 - CGFloat(value))
            ZStack {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 4, height: h)
                    .position(x: geo.size.width / 2, y: h / 2)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.75))
                    .frame(width: 28, height: thumbH - 4)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .position(x: geo.size.width / 2, y: y)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if Snapback.activeCount > 0 { Snapback.cancelAll() }
                        if ShiftKeyMonitor.shared.isShift {
                            if fineBase == nil {
                                fineBase = value
                                fineStartY = g.location.y
                            }
                            // the shared slider fraction
                            let dy = Double((fineStartY ?? g.location.y) - g.location.y)
                            value = max(0, min(1, (fineBase ?? value)
                                        + dy * NativeSlider.fineFraction / max(1, Double(usable))))
                        } else {
                            fineBase = nil
                            fineStartY = nil
                            let t = 1 - (g.location.y - thumbH / 2) / max(1, usable)
                            value = Double(max(0, min(1, t)))
                        }
                    }
                    .onEnded { g in
                        fineBase = nil
                        fineStartY = nil
                        // click without movement — pair two within 0.35 s = reset
                        guard let reset = doubleTapReset,
                              abs(g.translation.width) < 3, abs(g.translation.height) < 3 else { return }
                        let now = Date()
                        if let last = lastTap, now.timeIntervalSince(last) < 0.35 {
                            // eased when Settings say so (0 s = the instant
                            // write); the read-back self-cancels the tween
                            // if the fader is grabbed mid-flight.
                            Snapback.reset(current: value, to: reset,
                                           apply: { value = $0 },
                                           read: { value })
                            lastTap = nil
                        } else {
                            lastTap = now
                        }
                    }
            )
        }
    }
}

/// Deck-volume label — the FULL slider-label grammar: click = snapback
/// reset to 100%; right-click HOLD (past the 0.15 s threshold) = momentary
/// silence, release restores through the ease. Quick right-clicks do
/// nothing (fidelity).
struct VolumeLabel: View {
    let text: String
    @ObservedObject var deck: DeckModel
    @State private var saved: Double?
    @State private var hover = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(hover ? Color.primary : Color.secondary)
            .fixedSize()
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .overlay(RightHoldTracker(
                onDown: {
                    Snapback.cancelAll()   // capture the honest audible value
                    saved = deck.volume
                    deck.volumeLive(0)
                },
                onUp: {
                    if let s = saved {
                        Snapback.reset(current: deck.volume, to: s,
                                       apply: { deck.volumeLive($0) },
                                       read: { deck.volume })
                    }
                    saved = nil
                }))
            .onHover { hover = $0 }
            .onTapGesture {
                Snapback.reset(current: deck.volume, to: 1.0,
                               apply: { deck.volumeLive($0) },
                               read: { deck.volume })
            }
            .help("Click to reset to 100% · right-click HOLD to kill momentarily")
    }
}

/// One deck's level meter — green→amber→red with a decaying peak-hold
/// line, driven by its own 30 Hz ticker (independent of the lane clock).
struct MKMeter: View {
    let feed: LevelFeed

    private static func norm(_ v: Double) -> Double {
        guard v > 1e-5 else { return 0 }
        let db = 20 * log10(v)
        return max(0, min(1, (db + 48) / 48))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            // read the feed HERE, not inside the GeometryReader — the
            // GR's only input is its (never-changing) size, so a read
            // inside it never re-evaluates and the fill freezes at its
            // first value. The tick re-evaluates this closure; rmsN/peakN
            // then flow down as fresh captured values.
            let rmsN = Self.norm(feed.rms)
            let peakN = Self.norm(feed.peak)
            GeometryReader { geo in
                let h = geo.size.height
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                        .frame(width: 8).frame(maxHeight: .infinity)
                    // zones: green → amber (−12 dB) → red (−3 dB)
                    VStack(spacing: 0) {
                        Rectangle().fill(Color.red.opacity(0.18)).frame(height: h * 0.0625)
                        Rectangle().fill(Color.yellow.opacity(0.16)).frame(height: h * 0.1875)
                        Rectangle().fill(Color.green.opacity(0.14))
                    }
                    .clipShape(Capsule())
                    .frame(width: 8).frame(maxHeight: .infinity)
                    if rmsN > 0 {
                        Capsule()
                            .fill(rmsN > 0.9375 ? Color.red : (rmsN > 0.75 ? Color.yellow : Color.green))
                            .frame(width: 8, height: max(2, h * rmsN))
                    }
                    if peakN > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.8))
                            .frame(width: 10, height: 1.5)
                            .offset(y: -h * peakN + 0.75)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// REC — PLAY-width toggle; active = red outline + red text.
struct RecButton: View {
    @State private var armed = false

    /// mm:ss.t segments — FIXED frames per segment so digit shapes
    /// (1 vs 8 vs 0) can never shift layout. No monospace (typography
    /// law: size/weight/color only); pure + probed.
    static func timecodeParts(_ t: Double) -> (mm: String, ss: String, tenth: String) {
        // round in tenths FIRST — 61.9 is 61.8999… in binary and a naive
        // truncation prints .8
        let totalTenths = max(0, Int((t * 10).rounded()))
        let mm = totalTenths / 600
        let ss = (totalTenths / 10) % 60
        let tenth = totalTenths % 10
        return (String(format: "%02d", mm), String(format: "%02d", ss), "\(tenth)")
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let on = EngineRecorder.shared.isRecording
            Button {
                EngineRecorder.shared.toggle()
                armed = EngineRecorder.shared.isRecording
            } label: {
                Group {
                    if on {
                        let tc = Self.timecodeParts(EngineRecorder.shared.elapsedSeconds)
                        HStack(spacing: 0) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                                .padding(.trailing, 4)
                            Text(tc.mm).frame(width: 15, alignment: .leading)
                            Text(":").frame(width: 4)
                            Text(tc.ss).frame(width: 15)
                            Text(".").frame(width: 3)
                            Text(tc.tenth).frame(width: 7, alignment: .trailing)
                        }
                        .font(.system(size: 11).weight(.semibold))
                        .foregroundStyle(Color.red)
                    } else {
                        Text("REC")
                            .font(.system(size: 11).weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                }
                .frame(minWidth: 78, minHeight: 18)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(on ? Color.red : .clear, lineWidth: 1.5)
            )
            .help(on ? "Stop recording (saves the WAV; takes cap at 10:00)"
                     : "Record the master output to a WAV (max 10:00 per take)")
        }
        .onAppear { armed = EngineRecorder.shared.isRecording }
        .padding(.bottom, 4)
    }
}

struct MKVolumeColumn: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var deckA: DeckModel
    @ObservedObject var deckB: DeckModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                MKSliderLabel(text: "MASTER") {
                    Snapback.reset(current: app.masterAtom.v, to: 1.0,
                                   apply: { app.setMasterVolume($0) },
                                   read: { app.masterAtom.v })
                }
                NativeSlider(value: Binding(
                    get: { app.masterAtom.v },
                    set: { app.setMasterVolume($0) }
                ), range: 0...2,
                   onLive: { app.setMasterVolume($0) },
                   doubleClickReset: 1.0,
                   fineControl: true)
                Text(String(format: "%d%%", Int(app.masterAtom.v * 100)))
                    .font(.system(.caption).weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .fixedSize()
            }
            .padding(.horizontal, 4)

            Divider().frame(width: 120)

            // deck meters, one per deck over its fader
            HStack(alignment: .top, spacing: 20) {
                MKMeter(feed: AudioController.shared.levelFeeds[0])
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
                MKMeter(feed: AudioController.shared.levelFeeds[1])
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
            }

            HStack(alignment: .top, spacing: 20) {
                volumeColumn("1", deck: deckA)
                volumeColumn("2", deck: deckB)
            }

            RecButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.vertical, 12)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Symmetric column: full-height fader, deck numeral, volume number
    /// BELOW it (by design — no side guide, no side captions).
    private func volumeColumn(_ n: String, deck: DeckModel) -> some View {
        VStack(spacing: 6) {
            MKFader(value: Binding(
                get: { deck.atoms.volume.v },
                set: { deck.volumeLive($0) }
            ), doubleTapReset: 1.0)
            .frame(width: 34)
            .frame(maxHeight: .infinity)
            VolumeLabel(text: n, deck: deck)
            Text("\(Int(deck.volume * 100))%")
                .font(.system(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(width: 44)
        .padding(.bottom, 8)
        .help("Deck \(n) volume")
    }
}

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop delegate (one file per drag, accept-then-notice for rejects)

struct DeckDropDelegate: DropDelegate {
    let model: DeckModel
    /// Optional hover feedback for the host view (drop ring).
    var hover: ((Bool) -> Void)? = nil

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [.fileURL]).isEmpty
    }

    func dropEntered(info: DropInfo) { hover?(true) }
    func dropExited(info: DropInfo) { hover?(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        hover?(false)
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            DispatchQueue.main.async {
                model.handleDroppedURL(url as URL?)
            }
        }
        return true
    }
}

/// Live BPM text observing only the tempo atom: tempo drags re-render
/// this text, not the whole lane.
private struct LiveBPMText: View {
    @ObservedObject var tempo: ControlAtom
    let base: Double?
    let tapActive: Bool
    /// While a tempo bend is held, show base × the ACTUAL transport rate
    /// (the bend lives in engine.currentRate, which nothing publishes) on
    /// a fast tick; the static view otherwise.
    var bending = false
    var liveRate: Double = 1.0

    var body: some View {
        if bending, let base {
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Text(String(format: "%.1f", base * liveRate))
                    .font(Theme.monoBig)
                    .foregroundColor(Theme.amber)
            }
        } else {
            staticText
        }
    }

    private var staticText: some View {
        let text: String = {
            guard let base else { return "—" }
            return String(format: "%.1f", base * tempo.v)
        }()
        return Text(text)
            .font(Theme.monoBig)
            .foregroundColor(tapActive ? Theme.accent : (base == nil ? Theme.faint : Theme.ink))
    }
}

// MARK: - Wave lane (waveform display, one deck)
// Text display (title · BPM · time) + full-width zoomed waveform + overview.
// The lane is the deck's drop target.
