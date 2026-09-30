import AppKit

/// Deterministic window geometry for the MKDJ band.
///
/// Two AppKit homes restored stale frames that SwiftUI's minWidth/minHeight
/// cannot veto (macOS Saved Application State + the "NSWindow Frame …"
/// autosave key in defaults — which SwiftUI keeps REWRITING during the
/// session under a key derived from the module name, so it cannot be
/// suppressed, only scrubbed before window creation each launch).
/// Policy: restoration is declined outright (AppDelegate), autosave keys
/// are scrubbed at applicationWillFinishLaunching and on terminate, and
/// this keeper owns the frame — one validated defaults key, minimums
/// enforced at the NSWindow level, and a clamped-and-centered default
/// when nothing valid is stored. The band's fixed labels make SwiftUI's
/// ideal width exceed 1600; the default path clamps the ideal instead of
/// fighting it.
enum MKWindowFrame {
    static let storeKey = "MKDJ.windowFrame"
    static let minW: CGFloat = 1600
    static let minH: CGFloat = 540
    /// Cold-launch height band (content; window title bar adds its own).
    private static let defaultH: CGFloat = 700
    private static let defaultMaxH: CGFloat = 780

    /// Call once the band's window exists (RootView.onAppear). Idempotent.
    static func enforce(on window: NSWindow) {
        window.setFrameAutosaveName("")
        window.contentMinSize = NSSize(width: minW, height: minH)

        if let f = storedFrame(), valid(f) {
            if window.frame != f { window.setFrame(f, display: true) }
            MKLog.app("MKWindowFrame: stored frame applied \(NSStringFromRect(window.frame))")
        } else {
            // No stored frame: the SwiftUI-chosen frame is ideal-sized by
            // the band's fixed labels (can exceed 1600) but is NOT trusted —
            // clamp into the sane band (floors a clipped ghost, ceilings a
            // stale tall restore) and center on the window's screen.
            let vis = (window.screen ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let cur = window.frame
            let w = min(max(cur.width, minW), vis.width)
            let h = min(max(cur.height, defaultH), defaultMaxH, vis.height)
            var f = NSRect(x: 0, y: 0, width: w, height: h)
            f.origin.x = vis.midX - w / 2
            f.origin.y = vis.midY - h / 2
            window.setFrame(f, display: true)
            MKLog.app(String(format: "MKWindowFrame: default applied %.0f×%.0f (swiftui %.0f×%.0f) on %@",
                              f.width, f.height, cur.width, cur.height,
                              window.screen?.localizedName ?? "?"))
        }

        // Persist user moves/resizes in OUR key (AppKit state saving is off).
        // App-lifetime observers on a single long-lived window — no removal.
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { _ in
            remember(window)
        }
        nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { _ in
            remember(window)
        }
    }

    /// Terminate hook — belt to the notification suspenders.
    static func remember(_ window: NSWindow) {
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: storeKey)
    }

    private static func storedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: storeKey) else { return nil }
        let r = NSRectFromString(s)
        guard r.width > 0, r.height > 0 else { return nil }
        return r
    }

    /// A stored frame is usable only if it meets the minimums and its
    /// center lands on a connected screen (rejects stale multi-monitor
    /// geometry and anything a ghost home could have written).
    private static func valid(_ f: NSRect) -> Bool {
        guard f.width >= minW - 0.5, f.height >= minH else { return false }
        let c = NSPoint(x: f.midX, y: f.midY)
        return NSScreen.screens.contains { $0.frame.contains(c) }
    }
}
