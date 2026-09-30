import SwiftUI

struct SettingsView: View {
    /// Visual-gate hook (MKDJ_DEMO precedent): MKDJ_SETTINGS_TAB=1…5 opens
    /// on that tab — mouse CGEventPosts don't reach unsigned apps, so tab
    /// selection can't be driven externally any other way.
    @State private var tab: Int = {
        guard let e = getenv("MKDJ_SETTINGS_TAB"),
              let n = Int(String(cString: e)), (1...5).contains(n) else { return 0 }
        return n - 1
    }()

    var body: some View {
        TabView(selection: $tab) {
            ShortcutSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(0)
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "hifispeaker") }
                .tag(1)
            DecksSettingsView()
                .tabItem { Label("Decks", systemImage: "slider.horizontal.3") }
                .tag(2)
            AnalysisSettingsView()
                .tabItem { Label("Analysis", systemImage: "waveform") }
                .tag(3)
            SkinSettingsView()
                .tabItem { Label("Skin", systemImage: "paintpalette") }
                .tag(4)
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - Skin (live preview card + flat sections)

struct SkinSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                SkinPreviewCard()
                    .frame(height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Section {
                ColorPicker("Waveform", selection: $settings.waveColor)
                ColorPicker("Grid lines", selection: $settings.gridColor)
                ColorPicker("Lane background", selection: $settings.laneBackgroundColor)
                ColorPicker("Playhead", selection: $settings.playheadColor)
                ColorPicker("Cue point", selection: $settings.cueColor)
            }
            Section {
                Button("Reset to defaults") {
                    settings.waveColor = AppSettings.defaultWave
                    settings.gridColor = AppSettings.defaultGrid
                    settings.laneBackgroundColor = AppSettings.defaultLaneBg
                    settings.playheadColor = AppSettings.defaultPlayhead
                    settings.cueColor = AppSettings.defaultCue
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Live skin preview — a synthetic waveform slice in the real lane
/// grammar (mirrored min/max bars over the lane background, downbeat-strong
/// grid, playhead + cue markers), re-rendered on every picker drag. No file
/// decode; the shape is deterministic (hash-jittered envelope pulses).
struct SkinPreviewCard: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let amps: [Double] = (0..<260).map { i in
        let t = Double(i) / 260
        let env = 0.35 + 0.30 * sin(t * .pi)
        let beat = pow(abs(sin(t * 24 * .pi)), 0.6)
        let fine = Double((i &* 2654435761) % 1000) / 1000
        return max(0.05, env * (0.45 + 0.55 * beat) * (0.6 + 0.4 * fine))
    }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, mid = h / 2
            // lane background
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: h)), with: .color(settings.laneBackgroundColor))
            // grid — 16 cells, every 4th a downbeat (lane grammar)
            let cells = 16, cw = w / Double(cells)
            for i in 0...cells {
                let x = Double(i) * cw
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                ctx.stroke(p, with: .color(settings.gridColor.opacity(i % 4 == 0 ? 0.8 : 0.35)),
                           lineWidth: i % 4 == 0 ? 1.2 : 0.8)
            }
            // waveform — mirrored bars
            let n = Self.amps.count, bw = w / Double(n)
            for i in 0..<n {
                let amp = Self.amps[i] * (h / 2 - 4)
                let x = Double(i) * bw
                ctx.fill(Path(CGRect(x: x, y: mid - amp, width: max(0.8, bw - 0.5), height: amp * 2)),
                         with: .color(settings.waveColor))
            }
            // cue marker at ~18%
            var cue = Path()
            cue.move(to: CGPoint(x: w * 0.18, y: 2)); cue.addLine(to: CGPoint(x: w * 0.18, y: h - 2))
            ctx.stroke(cue, with: .color(settings.cueColor), style: StrokeStyle(lineWidth: 1.5))
            ctx.fill(Path { p in
                p.move(to: CGPoint(x: w * 0.18 + 1, y: 2))
                p.addLine(to: CGPoint(x: w * 0.18 + 9, y: 6))
                p.addLine(to: CGPoint(x: w * 0.18 + 1, y: 10))
            }, with: .color(settings.cueColor))
            // playhead at ~42%
            var ph = Path()
            ph.move(to: CGPoint(x: w * 0.42, y: 0)); ph.addLine(to: CGPoint(x: w * 0.42, y: h))
            ctx.stroke(ph, with: .color(settings.playheadColor), style: StrokeStyle(lineWidth: 1.5))
        }
    }
}

// MARK: - Audio (bend, output device)

struct AudioSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var devices: [AudioOutputDevices.Device] = []

    private var recordingsPathLabel: String {
        settings.recordingsDirectoryPath.isEmpty
            ? EngineRecorder.defaultDirectory().path
            : settings.recordingsDirectoryPath
    }

    var body: some View {
        Form {
            // Audio = HARDWARE only (cue behavior + tempo bend moved to
            // Decks — 4 sections here is what scrolled).
            Section("Output device") {
                Picker("Output", selection: Binding(
                    get: { settings.outputDeviceID },
                    set: {
                        AudioController.shared.setOutputDevice(id: $0)
                    })) {
                    Text("System Default").tag(0)
                    ForEach(devices) { dev in
                        Text(dev.name)
                            .tag(Int(dev.id))
                    }
                }
                Button("Refresh device list") { devices = AudioOutputDevices.list() }
            }

            Section("Recordings") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Recordings folder")
                        Text(recordingsPathLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            settings.recordingsDirectoryPath = url.path
                        }
                    }
                    Button("Reset") {
                        settings.recordingsDirectoryPath = ""
                    }
                }
                Text("REC writes YY.MMDD-id-00m00s.wav here. Default: Documents/MKDJ Output")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioOutputDevices.list() }
    }
}

// MARK: - Decks (feel: tempo family, cue, snapback)

struct DecksSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            // the tempo family REUNITED — bend amount and fader range are
            // both "how much does tempo move" dials.
            Section("Tempo") {
                Picker("Bend amount", selection: $settings.nudgePercent) {
                    ForEach([2.0, 4.0, 6.0, 8.0], id: \.self) { p in
                        Text(String(format: "±%.0f%%", p)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Fader range", selection: $settings.tempoRangePercent) {
                    ForEach([8.0, 16.0, 32.0], id: \.self) { p in
                        Text(String(format: "±%.0f%%", p)).tag(p)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Cue behavior") {
                Picker("", selection: $settings.cueMode) {
                    Text("Hold to preview").tag("hold")
                    Text("Press to play").tag("press")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Section("Snapback") {
                Picker("Curve", selection: $settings.snapEaseRaw) {
                    ForEach(SnapEase.allCases) { e in
                        Text(e.name).tag(e.rawValue)
                    }
                }
                HStack {
                    Slider(value: $settings.snapSeconds, in: 0...0.5)
                    Text(String(format: "%.2f s", settings.snapSeconds))
                        .font(.system(.callout).weight(.medium))
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

struct ShortcutSettingsView: View {
    @ObservedObject private var manager = ShortcutManager.shared
    @State private var scope: Int = 0   // 0 = deck 1, 1 = deck 2, 2 = global
    @State private var recordingAction: String?
    @State private var duplicateFlash: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scope) {
                Text("Deck 1").tag(0)
                Text("Deck 2").tag(1)
                Text("Global").tag(2)
            }
            .pickerStyle(.segmented)
            .padding()

            ScrollView {
                VStack(spacing: 0) {
                    if let flash = duplicateFlash {
                        Text(flash)
                            .font(.system(size: 11, weight: .semibold, design: .default))
                            .foregroundColor(.orange)
                            .padding(.vertical, 6)
                    }
                    if scope == 2 {
                        shortcutList(global: true)
                    } else {
                        shortcutList(global: false)
                    }
                }
                .padding(.horizontal)
            }

            HStack {
                Button("Reset \(scope == 2 ? "global" : "deck \(scope + 1)") to defaults") {
                    if scope == 2 {
                        manager.globalBindings = ShortcutManager.defaultGlobalBindings()
                    } else {
                        manager.deckBindings[scope] = ShortcutManager.defaultDeckBindings(scope)
                    }
                    manager.persist()
                }
                Spacer()
                Text("Click Record, then press a key. Opt-in: unbound keys pass through.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func shortcutList(global: Bool) -> some View {
        if global {
            ForEach(GlobalAction.allCases) { action in
                shortcutRow(label: action.label,
                            key: Binding(
                                get: { manager.globalBindings[action.rawValue] },
                                set: { manager.globalBindings[action.rawValue] = $0 }),
                            global: global)
            }
        } else {
            ForEach(DeckAction.allCases) { action in
                shortcutRow(label: action.label,
                            key: Binding(
                                get: { manager.deckBindings[scope]?[action.rawValue] },
                                set: { manager.deckBindings[scope]?[action.rawValue] = $0 }),
                            global: global)
            }
        }
    }

    private func shortcutRow(label: String, key: Binding<KeySpec?>, global: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(key.wrappedValue?.display ?? "—")
                .font(.system(size: 12, weight: .semibold, design: .default))
                .frame(width: 90)
                .foregroundColor(key.wrappedValue == nil ? .secondary : .orange)
            Button {
                // arming a new recording while another row waits stranded
                // the old row at "press a key…" forever (its handler was
                // replaced). One armed row at a time.
                recordingAction = label
                let actionRaw = actionRawValue(for: label, global: global)
                let armedAt = Date()
                ShortcutManager.shared.recordingHandler = { [weak manager] spec in
                    // stale arm (superseded or timed out): ignore
                    guard recordingAction == label, Date().timeIntervalSince(armedAt) < 5 else { return }
                    // a key means one action, everywhere; the only
                    // exemption is re-recording the binding being replaced.
                    if manager?.canBind(spec, to: actionRaw, in: scope) == false {
                        recordingAction = nil
                        duplicateFlash = "\(spec.display) is already bound: \(manager?.bindingOwner(spec) ?? "?")"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            duplicateFlash = nil
                        }
                        return
                    }
                    key.wrappedValue = spec
                    recordingAction = nil
                    manager?.persist()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) {
                    if recordingAction == label, ShortcutManager.shared.recordingHandler != nil {
                        ShortcutManager.shared.recordingHandler = nil
                        recordingAction = nil
                    }
                }
            } label: {
                Text(recordingAction == label ? "press a key…" : "Record")
                    .font(.system(size: 10))
                    .frame(width: 96)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(recordingAction == label ? Color.orange.opacity(0.18) : Color.clear)
        )
    }

    private func actionRawValue(for label: String, global: Bool) -> String {
        if global {
            return GlobalAction.allCases.first { $0.label == label }?.rawValue ?? ""
        }
        return DeckAction.allCases.first { $0.label == label }?.rawValue ?? ""
    }
}

// MARK: - Analysis + cache

struct AnalysisSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section("BPM analysis") {
                LabeledContent("Detection range") {
                    // fields fixedSize so LabeledContent can't compress
                    // them into wrapping; the unit rides the help tooltip
                    // instead of a trailing "BPM" that wrapped.
                    HStack(spacing: 4) {
                        TextField("min", value: $settings.minBPM, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .fixedSize()
                        Text("–").foregroundStyle(.secondary).fixedSize()
                        TextField("max", value: $settings.maxBPM, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                            .fixedSize()
                    }
                    .fixedSize()
                }
                .help("Grid search range in BPM; values outside it are projected into it by ×(½,⅔,1½,2). Re-analyze to apply.")
            }

            Section("Analysis cache") {
                LabeledContent("Cache size") {
                    HStack(spacing: 8) {
                        Text(byteString(cacheSize))
                        Button("Refresh") { cacheSize = AnalysisCache.shared.totalSizeBytes() }
                        Button("Clear", role: .destructive) {
                            AnalysisCache.shared.clear()
                            cacheSize = AnalysisCache.shared.totalSizeBytes()
                        }
                    }
                }
                Picker("Budget", selection: $settings.analysisCacheLimitMB) {
                    ForEach([500, 1024, 1536, 2048], id: \.self) { mb in
                        Text(Self.budgetLabel(mb)).tag(mb)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onAppear { cacheSize = AnalysisCache.shared.totalSizeBytes() }
    }

    /// The old label did integer division — 1536 MB rendered as "1 GB"
    /// (a second 1 GB next to 1024's).
    static func budgetLabel(_ mb: Int) -> String {
        if mb < 1024 { return "\(mb) MB" }
        let gb = Double(mb) / 1024
        return gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        return formatter.string(fromByteCount: bytes)
    }
}
