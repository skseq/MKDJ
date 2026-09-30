import Foundation
import Combine
import SwiftUI
import AppKit

/// App-wide settings persisted to UserDefaults.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let d = UserDefaults.standard

    // Skin: waveform + grid colors, persisted as "r,g,b" (0–1).
    // Defaults: mint wave (the calibration color) + white grid.
    @Published var waveColor: Color {
        didSet { d.set(Self.componentsString(waveColor), forKey: "skin.wave") }
    }
    @Published var gridColor: Color {
        didSet { d.set(Self.componentsString(gridColor), forKey: "skin.grid") }
    }
    /// Lane background, playhead, cue markers.
    @Published var laneBackgroundColor: Color {
        didSet { d.set(Self.componentsString(laneBackgroundColor), forKey: "skin.laneBg") }
    }
    @Published var playheadColor: Color {
        didSet { d.set(Self.componentsString(playheadColor), forKey: "skin.playhead") }
    }
    @Published var cueColor: Color {
        didSet { d.set(Self.componentsString(cueColor), forKey: "skin.cue") }
    }
    // Scheme-aware defaults — mint wave (a touch darker on
    // light for data contrast), white/black grid ink, dynamic lane LCD.
    // Stored custom colors stay literal: Skin overrides theme by design.
    static let defaultWave = Color(nsColor: NSColor(name: nil) { ap in
        (ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil)
            ? NSColor(srgbRed: 0.0, green: 0.737, blue: 0.4, alpha: 1)
            : NSColor(srgbRed: 0.0, green: 0.55, blue: 0.31, alpha: 1)
    })
    static let defaultGrid = Theme.gridInk
    static let defaultLaneBg = Theme.lcd
    static let defaultPlayhead = Theme.playheadRed
    static let defaultCue = Theme.cueBlue
    /// Strip-cache rgb tuple for the wave color.
    var waveRGB: (Double, Double, Double) {
        let a = Self.components(waveColor); return (a[0], a[1], a[2])
    }
    static func componentsString(_ c: Color) -> String {
        guard let ns = NSColor(c).usingColorSpace(.deviceRGB) else { return "0,0.737,0.4" }
        return String(format: "%.4f,%.4f,%.4f", ns.redComponent, ns.greenComponent, ns.blueComponent)
    }
    static func components(_ c: Color) -> [Double] {
        guard let ns = NSColor(c).usingColorSpace(.deviceRGB) else { return [0, 0.737, 0.4] }
        return [Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent)]
    }
    private static func color(fromString s: String?) -> Color? {
        guard let s else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0) }
        guard p.count == 3 else { return nil }
        return Color(red: p[0], green: p[1], blue: p[2])
    }

    @Published var tempoRangePercent: Double { didSet { d.set(tempoRangePercent, forKey: "tempoRangePercent") } }
    @Published var nudgePercent: Double { didSet { d.set(nudgePercent, forKey: "nudgePercent") } }
    @Published var snapEnabled: Bool { didSet { d.set(snapEnabled, forKey: "snapEnabled") } }
    /// Jog sensitivity: pixels of waveform drag per doubling of rate
    /// (higher = coarser; 120 fine … 220 default … 480 coarse).
    /// 0 = system default; otherwise a CoreAudio AudioDeviceID.
    @Published var outputDeviceID: Int { didSet { d.set(outputDeviceID, forKey: "outputDeviceID") } }
    /// Human name of the chosen device at pick time (IINA-patterned):
    /// lets the picker show a ghost "(missing)" row after the
    /// device vanishes, instead of silently emptying.
    @Published var outputDeviceName: String { didSet { d.set(outputDeviceName, forKey: "outputDeviceName") } }
    /// v2-only BPM analysis — skip the BPMPLS tracker entirely (no
    /// cross-check, no arbitration). The lane status tags results "v2-solo".
    @Published var analysisV2Solo = UserDefaults.standard.bool(forKey: "analysisV2Solo") {
        didSet { UserDefaults.standard.set(analysisV2Solo, forKey: "analysisV2Solo") }
    }

    @Published var minBPM: Double { didSet { d.set(minBPM, forKey: "minBPM") } }
    @Published var maxBPM: Double { didSet { d.set(maxBPM, forKey: "maxBPM") } }
    /// Analysis-cache budget in MB (500…2048); AnalysisCache's
    /// background store reads this key directly from defaults.
    @Published var analysisCacheLimitMB: Int { didSet { d.set(analysisCacheLimitMB, forKey: "analysisCacheLimitMB") } }
    /// Recordings output directory ("" = default Documents/MKDJ Output).
    @Published var recordingsDirectoryPath: String { didSet { d.set(recordingsDirectoryPath, forKey: "recordingsDirectory") } }
    /// Cue behavior — "hold" (CDJ preview, release snaps back)
    /// or "press" (hit = jump to cue and play continuously).
    @Published var cueMode: String { didSet { d.set(cueMode, forKey: "cueMode") } }
    /// Slider snapback ease — curve (default smooth in-out) and
    /// duration 0…0.5 s. 0 s (the shipped default) = instant.
    @Published var snapEaseRaw: String { didSet { d.set(snapEaseRaw, forKey: "snapEase") } }
    @Published var snapSeconds: Double { didSet { d.set(snapSeconds, forKey: "snapSeconds") } }
    var snapEase: SnapEase { SnapEase(rawValue: snapEaseRaw) ?? .inOutCubic }

    /// Global snap-to-grid: one setting for both decks.
    func applySnapToDecks() {
        AudioController.shared.decks.forEach { $0.snapEnabled = snapEnabled }
    }

    var tempoRange: Double {
        get { tempoRangePercent / 100.0 }
    }

    private init() {
        let d = UserDefaults.standard
        waveColor = Self.color(fromString: d.string(forKey: "skin.wave")) ?? Self.defaultWave
        gridColor = Self.color(fromString: d.string(forKey: "skin.grid")) ?? Self.defaultGrid
        laneBackgroundColor = Self.color(fromString: d.string(forKey: "skin.laneBg")) ?? Self.defaultLaneBg
        playheadColor = Self.color(fromString: d.string(forKey: "skin.playhead")) ?? Self.defaultPlayhead
        cueColor = Self.color(fromString: d.string(forKey: "skin.cue")) ?? Self.defaultCue
        tempoRangePercent = d.object(forKey: "tempoRangePercent") as? Double ?? 16
        nudgePercent = d.object(forKey: "nudgePercent") as? Double ?? 4
        minBPM = d.object(forKey: "minBPM") as? Double ?? 70
        maxBPM = d.object(forKey: "maxBPM") as? Double ?? 180
        analysisCacheLimitMB = d.object(forKey: "analysisCacheLimitMB") as? Int ?? 1024
        recordingsDirectoryPath = d.string(forKey: "recordingsDirectory") ?? ""
        snapEnabled = d.object(forKey: "snapEnabled") as? Bool ?? false   // default off
        outputDeviceID = d.object(forKey: "outputDeviceID") as? Int ?? 0
        outputDeviceName = d.string(forKey: "outputDeviceName") ?? ""
        snapEaseRaw = d.string(forKey: "snapEase") ?? SnapEase.inOutCubic.rawValue
        cueMode = d.string(forKey: "cueMode") ?? "hold"
        snapSeconds = d.object(forKey: "snapSeconds") as? Double ?? 0
        if minBPM >= maxBPM { minBPM = 70; maxBPM = 180 }
        // one-time migration: the tempo-range default moved 8 → 16, and the
        // legacy ±50 range was remapped to ±32
        if d.object(forKey: "tempoRangeMigrated") == nil {
            if tempoRangePercent == 8 { tempoRangePercent = 16 }
            d.set(true, forKey: "tempoRangeMigrated")
        }
        if tempoRangePercent == 50 { tempoRangePercent = 32 }
    }
}
