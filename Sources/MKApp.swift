import SwiftUI
import AppKit
import AVFoundation

@main
struct MKApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppModel()

    /// nil = follow the SYSTEM appearance (the app used to be pinned
    /// dark). Set only for visual checks / A-B testing via
    /// MKDJ_APPEARANCE=light|dark.
    private static let schemeOverride: ColorScheme? = {
        guard let e = getenv("MKDJ_APPEARANCE") else { return nil }
        return String(cString: e) == "light" ? .light : .dark
    }()

    var body: some Scene {
        WindowGroup("MKDJ") {
            RootView()
                .environmentObject(app)
                .onAppear { AppModelHolder.shared = app }
                .preferredColorScheme(Self.schemeOverride)
                // RootView owns the band geometry (min 1600×540); an outer
                // min here would only fight it (the old 1240×760 forced a
                // too-tall window with dead bottom space).
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}   // no File→New
            // No Help menu: the app has no help book, and macOS would
            // otherwise insert an empty stub with just a search field.
            CommandGroup(replacing: .help) { }
        }
        Window("About MKDJ", id: "about") {
            AboutView()
                .preferredColorScheme(Self.schemeOverride)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        Settings {
            SettingsView()
                .preferredColorScheme(Self.schemeOverride)
        }
        Window("Diagnostics", id: "mkdj-diagnostics") {
            DiagnosticsView()
                .preferredColorScheme(Self.schemeOverride)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Earliest interception: keys die in sendEvent before anything can
        // beep; the alert sound itself is a logged no-op.
        SendEventGuard.ensureInstalled()
        BeepGuard.install()
        // Window-frame ghost home #2: SwiftUI's NSWindow frame autosave in
        // defaults restores frames minWidth cannot veto — scrub every
        // stale key before any window is created. MKWindowFrame owns the
        // frame from here on (ghost home #1, Saved Application State, is
        // declined in applicationShouldRestoreState below).
        let defaults = UserDefaults.standard
        var scrubbed = 0
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("NSWindow Frame SwiftUI.") {
            defaults.removeObject(forKey: k)
            scrubbed += 1
        }
        if scrubbed > 0 { MKLog.app("scrubbed \(scrubbed) stale NSWindow-frame autosave key(s)") }
    }

    /// The MKDJ band has one correct shape — no AppKit state restoration.
    func applicationShouldRestoreState(_ app: NSApplication) -> Bool { false }
    func applicationShouldSaveState(_ app: NSApplication) -> Bool { false }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // SwiftUI rewrites its "NSWindow Frame …" autosave key during the
        // session no matter what we clear — scrub again on the way out so
        // the next launch (which also scrubs pre-window) never reads one.
        let defaults = UserDefaults.standard
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("NSWindow Frame SwiftUI.") {
            defaults.removeObject(forKey: k)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if let w = NSApp.keyWindow, w.title == "MKDJ" { MKWindowFrame.remember(w) }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The old vibrantDark pin overrode the SYSTEM appearance for every
        // window — nil = follow the system; the dynamic MKDJ tokens
        // live-resolve on flips.
        NSApp.appearance = nil
        ShiftKeyMonitor.shared.install()
        // Touch the audio graph early so the engine is warm before first load.
        _ = AudioController.shared
        if ProcessInfo.processInfo.environment["MKDJ_DEMO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.runDemo() }
        }
    }

    /// UI verification mode: two synthetic tracks, a cue, +2% tempo, one deck
    /// playing — screenshot fodder for loaded-state layout checks. Launch
    /// with MKDJ_DEMO=1.
    private func runDemo() {
            let a = DemoTrack.write(bpm: 124, freq: 330, name: "Funky Break — Demo A")
            let b = DemoTrack.write(bpm: 98, freq: 220, name: "Deep Cut — Demo B")
            Task { @MainActor in
                // AppModelHolder is set in the band's onAppear — that races our
                // +0.8s deadline on cold launches. Poll up to 5 s instead of
                // silently no-op'ing the whole demo.
                var app = AppModelHolder.shared
                for _ in 0..<50 where app == nil {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    app = AppModelHolder.shared
                }
                guard let app else {
                    MKLog.app("demo skipped — AppModelHolder still nil after 5 s", error: true)
                    return
                }
                MKLog.app("demo: loading synthetic decks")
                app.deckA.loadFile(a)
            app.deckB.loadFile(b)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            app.deckA.setCue()
            app.deckA.setTempoRate(1.02)
            app.deckA.togglePlayPause()
            // Manual loop engaged + spread handles for the screenshot
            // check (strip channel, IN/OUT tags, shading).
            app.deckA.toggleManualLoop()
            app.deckA.dragManualOut(6.5)
            app.focusedDeck = 0
        }
    }
}

/// AppModelHolder now lives in AppModel.swift: the probe target
/// compiles everything EXCEPT this file, and DeckModel needs the handle.

enum DemoTrack {
    static func write(bpm: Double, freq: Double, name: String) -> URL {
        let sr = 44100.0
        let seconds = 90.0
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name.replacingOccurrences(of: " ", with: "_") + ".wav")
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(seconds * sr)) else {
            return url
        }
        buf.frameLength = AVAudioFrameCount(seconds * sr)
        let l = buf.floatChannelData![0]
        let r = buf.floatChannelData![1]
        let beat = 60.0 / bpm
        for i in 0..<Int(seconds * sr) {
            let t = Double(i) / sr
            var v = Float(0.22 * sin(2 * .pi * freq * t) * sin(2 * .pi * (freq / 2) * t * 0.5 + t))
            // kick-ish click every beat, shimmer every half beat
            let beatPhase = t.truncatingRemainder(dividingBy: beat)
            if beatPhase < 0.012 { v += Float(0.55 * (1 - beatPhase / 0.012)) }
            let halfPhase = t.truncatingRemainder(dividingBy: beat / 2)
            if abs(halfPhase) < 0.004 { v += Float(0.10 * sin(2 * .pi * 8000 * t)) }
            l[i] = v
            r[i] = v
        }
        try? file.write(from: buf)
        return url
    }
}
