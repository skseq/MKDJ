import SwiftUI
import AppKit

/// "Studio Lanes" root: horizontal deck bands rendered with
/// mac materials — full-width wave lanes up top, deck strips mid, mixer
/// console along the bottom, native window toolbar.
struct RootView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var waveWindowA: Double = 15
    @State private var waveWindowB: Double = 15

    var body: some View {
        // MKDJ band — deck 1 | volume column | deck 2
        HStack(alignment: .top, spacing: 14) {
            MKDeckBand(deck: app.deckA, windowSeconds: $app.waveWindows[0])
                .frame(maxWidth: .infinity)
            MKVolumeColumn(deckA: app.deckA, deckB: app.deckB)
                .frame(width: 190)
            MKDeckBand(deck: app.deckB, windowSeconds: $app.waveWindows[1])
                .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 1600, minHeight: 540)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(14)
        .background(Theme.bg)
        .onAppear {
            app.applyMixer()
            wireShortcuts()
            _ = WaveRenderer.backingScale   // one-time display-services read, off the render path
            // AppKit restoration is declined and autosave keys scrubbed at
            // launch; MKWindowFrame owns the geometry from here (validated
            // stored frame or centered default, min enforced).
            DispatchQueue.main.async {
                for w in NSApp.windows where w.isVisible && w.title == "MKDJ" {
                    MKWindowFrame.enforce(on: w)
                }
            }
            // Visual-gate hook (MKDJ_DEMO precedent): MKDJ_SETTINGS_TAB also
            // OPENS Settings on that tab — Cmd+, and showSettingsWindow:
            // can't drive a SwiftUI Settings scene from outside.
            if getenv("MKDJ_SETTINGS_TAB") != nil {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    openSettings()
                }
            }
        }
    }

private func wireShortcuts() {
        let manager = ShortcutManager.shared
        manager.dispatch = { deckIndex, action, down in
            app.perform(deck: deckIndex, action: action, down: down)
        }
        manager.globalDispatch = { action, down in
            guard down else { return }
            switch action {
            case .focusDeck1: app.focusedDeck = 0
            case .focusDeck2: app.focusedDeck = 1
            case .zoomIn: app.zoomFocusedDeck(1.0 / 1.5)
            case .zoomOut: app.zoomFocusedDeck(1.5)
            case .snapToggle:
                AppSettings.shared.snapEnabled.toggle()
                AppSettings.shared.applySnapToDecks()
            }
        }
    }
}
