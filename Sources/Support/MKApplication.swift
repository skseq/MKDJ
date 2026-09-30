import AppKit
import ObjectiveC

/// Keyboard choke point: every key event passes ShortcutManager
/// BEFORE menus, responders, or anything else that could beep. Consumed
/// events never reach `super.sendEvent`.
///
/// Route A: `NSPrincipalClass = MKApplication` in Info.plist (the AppKit
/// bootstrap instantiates this subclass — verified at runtime). The explicit
/// @objc name is REQUIRED: without it the Swift mangled runtime name makes
/// the bootstrap exit with "Unable to find class: MKApplication".
/// Route B: if SwiftUI's bootstrap ignored the principal class, the
/// `sendEvent` method itself is swizzled — identical behavior, guaranteed.
@objc(MKApplication)
final class MKApplication: NSApplication {

    override func sendEvent(_ event: NSEvent) {
        // Delivery-timing instrument: a key delivered while a mouse button
        // is held is the signature that separates "starved until release"
        // from "delivered live mid-drag".
        if event.type == .keyDown, NSEvent.pressedMouseButtons != 0 {
            MKLog.keys("\(KeySpec.keyString(event.keyCode)) ↓ delivered WITH mouse held")
        }
        if let decision = ShortcutManager.shared.decide(event), decision == .consume {
            return
        }
        super.sendEvent(event)
    }

    /// Tracking pumps (NSSlider drags and friends) pull events with a
    /// mouse-only mask; keyboard events would sit in the queue until the
    /// drag ends — every hotkey dead mid-drag, and a key held when the
    /// drag started leaks its hold (its key-up starves too; Shift pressed
    /// mid-drag never reaches the fine-drag detent). Rescue them here:
    /// dequeue and run them through the same decision engine sendEvent
    /// uses. Strictly gated on the pump's mask EXCLUDING the event type —
    /// normal pumping, menu type-ahead, and peek calls (dequeue false)
    /// are untouched.
    override func nextEvent(matching mask: NSEvent.EventTypeMask,
                            until expiration: Date?,
                            inMode mode: RunLoop.Mode,
                            dequeue deqFlag: Bool) -> NSEvent? {
        if deqFlag {
            if NSEvent.pressedMouseButtons != 0 {
                TrackingKeyRescue.census(mask: mask, mode: mode)
            }
            let starved = NSEvent.EventTypeMask([.keyDown, .keyUp, .flagsChanged])
                .subtracting(mask)
            if !starved.isEmpty {
                var rescued = 0
                while rescued < 32,
                      let peek = super.nextEvent(matching: starved, until: Date.distantPast,
                                                 inMode: mode, dequeue: false) {
                    let one = NSEvent.EventTypeMask(rawValue: 1 << UInt64(bitPattern: Int64(peek.type.rawValue)))
                    guard let ev = super.nextEvent(matching: one, until: Date.distantPast,
                                                   inMode: mode, dequeue: true) else { break }
                    rescued += 1
                    let arrow: String
                    switch ev.type {
                    case .keyDown: arrow = "↓"
                    case .keyUp: arrow = "↑"
                    default: arrow = "⇧"
                    }
                    if ShortcutManager.shared.decide(ev) == .consume {
                        MKLog.keys("rescued-from-tracking \(KeySpec.keyString(ev.keyCode)) \(arrow) — consumed")
                    } else {
                        // Original dispatch only — decide() already ran once.
                        MKLog.keys("rescued-from-tracking \(KeySpec.keyString(ev.keyCode)) \(arrow) — passed through")
                        super.sendEvent(ev)
                    }
                }
            }
        }
        return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: deqFlag)
    }
}

enum SendEventGuard {

    static func ensureInstalled() {
        if NSApp is MKApplication {
            MKLog.app("sendEvent route A active (NSPrincipalClass honored)")
            return
        }
        let orig = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.sendEvent(_:)))
        let repl = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.mk_sendEvent(_:)))
        guard let orig, let repl else {
            MKLog.app("sendEvent guard FAILED — no route available", error: true)
            return
        }
        method_exchangeImplementations(orig, repl)
        MKLog.app("sendEvent route B active (sendEvent swizzle; NSApp is \(type(of: NSApp)))")
    }
}

/// Keyboard rescue for tracking pumps that starve key events (slider
/// drags), plus a pump census. An earlier version ALSO drained events from
/// a 16 ms NSEventTrackingRunLoopMode timer — that re-entrant event
/// pumping inside SwiftUI's gesture-tracking loop derailed DragGestures
/// (onEnded never fired → leaked-gesture reset loop); the timer is gone.
/// Placement of any further rescue layer is driven by the census below.
enum TrackingKeyRescue {

    private static var lastCensus = Date.distantPast

    /// Called from the nextEvent override while a mouse button is held:
    /// record (rate-limited) which mask/mode each real pump requests —
    /// the map of how slider drags vs gestures actually pump events.
    static func census(mask: NSEvent.EventTypeMask, mode: RunLoop.Mode) {
        guard Date().timeIntervalSince(lastCensus) > 1.0 else { return }
        lastCensus = Date()
        let kb: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        MKLog.keys("pump census: mode=\(mode.rawValue) keyboardInMask=\(!mask.intersection(kb).isEmpty)")
    }
}

extension NSApplication {
    /// Post-swap this is the original implementation.
    @objc func mk_sendEvent(_ event: NSEvent) {
        if let decision = ShortcutManager.shared.decide(event), decision == .consume {
            return
        }
        mk_sendEvent(event)
    }
}
