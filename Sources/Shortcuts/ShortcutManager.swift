import Foundation
import AppKit

// MARK: - Actions

enum DeckAction: String, CaseIterable, Codable, Identifiable {
    case playPause, cueHold, setCue, keylockToggle
    case nudgeMinus, nudgePlus                          // hold
    case bpmDouble, bpmHalve
    case loopRestart
    case volumeUp, volumeDown

    var id: String { rawValue }

    var isHold: Bool {
        self == .cueHold || self == .nudgeMinus || self == .nudgePlus
    }

    var label: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .cueHold: return "CUE (hold)"
        case .setCue: return "Set cue"
        case .keylockToggle: return "Keylock on/off"
        case .nudgeMinus: return "Tempo bend −(hold)"
        case .nudgePlus: return "Tempo bend +(hold)"
        case .bpmDouble: return "BPM ×2"
        case .bpmHalve: return "BPM ÷2"
        case .loopRestart: return "Loop restart (reloop)"
        case .volumeUp: return "Volume +5%"
        case .volumeDown: return "Volume −5%"
        }
    }
}

enum GlobalAction: String, CaseIterable, Codable, Identifiable {
    case focusDeck1, focusDeck2, snapToggle
    case zoomIn, zoomOut   // focused deck's wave zoom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .focusDeck1: return "Focus deck 1"
        case .focusDeck2: return "Focus deck 2"
        case .snapToggle: return "Snap to grid (both decks)"
        case .zoomIn: return "Zoom IN the focused deck's wave"
        case .zoomOut: return "Zoom OUT the focused deck's wave"
        }
    }
}

// MARK: - Key spec

struct KeySpec: Codable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt32   // CANONICAL subset of shift/option/control/command

    /// IINA-patterned normalization: mask modifiers to the
    /// four-function subset in fixed order, so ⇧5 and ⇧% (same keyCode,
    /// stray flag bits or layout-dependent characters) can never compare
    /// unequal. Every construction site funnels through here.
    static func normalized(keyCode: UInt16, modifiers: UInt32) -> KeySpec {
        let relevant: UInt32 = 0x20000 | 0x80000 | 0x10000 | 0x100000  // shift|opt|ctrl|cmd
        return KeySpec(keyCode: keyCode, modifiers: modifiers & relevant)
    }

    static func normalized(keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> KeySpec {
        normalized(keyCode: keyCode, modifiers: UInt32(flags.rawValue))
    }

    var canonical: KeySpec {
        KeySpec.normalized(keyCode: keyCode, modifiers: modifiers)
    }

    /// Human-readable, e.g. "⇧⌥Q".
    var display: String {
        var s = ""
        if modifiers & UInt32(NSEvent.ModifierFlags.shift.rawValue) != 0 { s += "⇧" }
        if modifiers & UInt32(NSEvent.ModifierFlags.option.rawValue) != 0 { s += "⌥" }
        if modifiers & UInt32(NSEvent.ModifierFlags.control.rawValue) != 0 { s += "⌃" }
        if modifiers & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 { s += "⌘" }
        return s + Self.keyString(keyCode)
    }

    static func keyString(_ code: UInt16) -> String {
        switch code {
        case 0: return "A"; case 1: return "S"; case 2: return "D"; case 3: return "F"
        case 4: return "H"; case 5: return "G"; case 6: return "Z"; case 7: return "X"
        case 8: return "C"; case 9: return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"; case 16: return "Y"
        case 17: return "T"; case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 22: return "5"; case 23: return "6"; case 24: return "="
        case 25: return "9"; case 26: return "7"; case 27: return "-"; case 28: return "8"
        case 29: return "0"; case 30: return "]"; case 31: return "O"; case 32: return "U"
        case 33: return "["; case 34: return "I"; case 35: return "P"; case 36: return "↩"
        case 37: return "L"; case 38: return "J"; case 39: return "'"; case 40: return "K"
        case 41: return ";"; case 42: return "\\"; case 43: return ","; case 44: return "/"
        case 45: return "N"; case 46: return "M"; case 47: return "."
        case 49: return "Space"
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        default: return "⌘K\(code)"
        }
    }
}

// MARK: - Manager

/// In-app keyboard shortcuts via NSEvent local monitors:
/// hold-type actions need key-down/key-up semantics, which menu-style
/// shortcuts can't express. Bindings persist to UserDefaults as Codable maps.
final class ShortcutManager: ObservableObject {

    static let shared = ShortcutManager()

    @Published var deckBindings: [Int: [String: KeySpec]]
    @Published var globalBindings: [String: KeySpec]

    /// Set by the app: (deckIndex, action, isKeyDown)
    var dispatch: ((Int, DeckAction, Bool) -> Void)?
    var globalDispatch: ((GlobalAction, Bool) -> Void)?

    /// Non-nil while a recorder UI is listening; key events feed the closure.
    @Published var recordingHandler: ((KeySpec) -> Void)?

    private var activeHolds: Set<String> = []   // "deck:action" currently held
    /// Menu-shortcut signatures ("mods+char") for the ⌘ pass-through test.
    private var menuShortcuts: Set<String>?

    /// Schema v3: NO default bindings — hotkeys are opt-in by design;
    /// users opt in to every hotkey via the recorder. Stored maps from
    /// older schemas (which shipped full default sets) are cleared once.
    static let schemaVersion = 3

    private init() {
        let d = UserDefaults.standard
        let decoder = JSONDecoder()
        let storedV = d.object(forKey: "shortcuts.v") as? Int ?? 0
        deckBindings = [0: Self.defaultDeckBindings(0), 1: Self.defaultDeckBindings(1)]
        globalBindings = Self.defaultGlobalBindings()
        if storedV == Self.schemaVersion {
            if let data = d.data(forKey: "shortcuts.deck.0"),
               let map = try? decoder.decode([String: KeySpec].self, from: data) {
                deckBindings[0] = map
            }
            if let data = d.data(forKey: "shortcuts.deck.1"),
               let map = try? decoder.decode([String: KeySpec].self, from: data) {
                deckBindings[1] = map
            }
            if let data = d.data(forKey: "shortcuts.global"),
               let map = try? decoder.decode([String: KeySpec].self, from: data) {
                globalBindings = map
            }
            // Backfill DEFAULTS for actions absent from the
            // stored maps. Absent = never user-touched (the recorder always
            // writes a spec; there is no clear-to-unbound path), so this is
            // heal-only — it never overwrites a choice. Without it, default
            // actions added AFTER an install's map was persisted (the
            // −/= zoom keys) never reached existing installs: the stored
            // map replaced the whole default map.
            let defG = Self.defaultGlobalBindings()
            for (action, spec) in defG where globalBindings[action] == nil {
                globalBindings[action] = spec
            }
            for deck in 0...1 {
                let defD = Self.defaultDeckBindings(deck)
                for (action, spec) in defD where deckBindings[deck]?[action] == nil {
                    deckBindings[deck]?[action] = spec
                }
            }
            repairConflicts()
        } else {
            MKLog.app("shortcuts schema \(storedV) → \(Self.schemaVersion): opt-in hotkeys — bindings cleared")
            persist()
            d.set(Self.schemaVersion, forKey: "shortcuts.v")
        }
    }

    /// A key bound by two actions breaks whichever loses the
    /// first-match race (the deck-2 CUE loss: cueHold and nudgePlus were
    /// both on L). Any conflicted scope resets to defaults — custom layouts
    /// survive only when unambiguous.
    func repairConflicts() {
        var keyOwner: [KeySpec: String] = [:]
        var conflictedScopes = Set<String>()
        func scan(_ scope: String, _ map: [String: KeySpec]) {
            for (action, spec) in map {
                if let holder = keyOwner[spec] {
                    conflictedScopes.insert(scope)
                    conflictedScopes.insert(holder)
                    MKLog.keys("conflict: \(spec.display) bound in \(holder) and \(scope):\(action)")
                } else {
                    keyOwner[spec] = scope
                }
            }
        }
        scan("global", globalBindings)
        for (deck, map) in deckBindings {
            scan("deck\(deck)", map)
        }
        guard !conflictedScopes.isEmpty else { return }
        if conflictedScopes.contains("global") {
            globalBindings = Self.defaultGlobalBindings()
        }
        for deck in 0...1 where conflictedScopes.contains("deck\(deck)") {
            deckBindings[deck] = Self.defaultDeckBindings(deck)
        }
        persist()
        MKLog.app("shortcuts: conflicted scopes reset to defaults: \(conflictedScopes.sorted().joined(separator: ", "))")
    }

    /// The binding a key belongs to, if any: "Deck 1 · Play / Pause" or "Global · …".
    /// The ONE source of truth for conflict checks.
    func bindingOwner(_ spec: KeySpec) -> String? {
        let spec = spec.canonical
        if let raw = globalBindings.first(where: { $0.value.canonical == spec })?.key,
           let action = GlobalAction(rawValue: raw) {
            return "Global · \(action.label)"
        }
        for d in 0...1 {
            if let map = deckBindings[d], let raw = map.first(where: { $0.value.canonical == spec })?.key,
               let action = DeckAction(rawValue: raw) {
                return "Deck \(d + 1) · \(action.label)"
            }
        }
        return nil
    }

    /// Recorder guard: can `action` in `scope` take `spec`? Only the exact
    /// binding being REPLACED is excluded — same-scope steals are conflicts
    /// too (a within-deck duplicate would trip the load-time repair and
    /// reset the whole scope — the "can't change my hotkeys" trap).
    func canBind(_ spec: KeySpec, to action: String, in scope: Int) -> Bool {
        if scope == 2 {
            if globalBindings[action] == spec { return true }
        } else if let map = deckBindings[scope], map[action] == spec {
            return true
        }
        return bindingOwner(spec) == nil
    }

    func persist() {
        let encoder = JSONEncoder()
        let d = UserDefaults.standard
        d.set(try? encoder.encode(deckBindings[0] ?? [:]), forKey: "shortcuts.deck.0")
        d.set(try? encoder.encode(deckBindings[1] ?? [:]), forKey: "shortcuts.deck.1")
        d.set(try? encoder.encode(globalBindings), forKey: "shortcuts.global")
        d.set(Self.schemaVersion, forKey: "shortcuts.v")
    }

    // MARK: Defaults (mirrored two-hand layout)

    private static func key(_ keyCode: UInt16, _ mods: NSEvent.ModifierFlags = []) -> KeySpec {
        KeySpec.normalized(keyCode: keyCode, mods)
    }

    static func defaultDeckBindings(_ deck: Int) -> [String: KeySpec] {
        // Opt-in hotkeys — decks start with NOTHING bound. The old
        // full default sets made the whole keyboard "taken", so the
        // duplicate-guard rejected nearly every recording attempt.
        [:]
    }





    static func defaultGlobalBindings() -> [String: KeySpec] {
        [
            // Documented exception to the opt-in schema: these zoom
            // defaults ship bound (rebindable/clearable like any binding).
            GlobalAction.zoomIn.rawValue: KeySpec(keyCode: 24, modifiers: 0),    // =
            GlobalAction.zoomOut.rawValue: KeySpec(keyCode: 27, modifiers: 0),   // -
            GlobalAction.focusDeck1.rawValue: key(18, .shift),// ⇧1
            GlobalAction.focusDeck2.rawValue: key(19, .shift),// ⇧2
        ]
    }

    // MARK: Decision engine (called from MKApplication.sendEvent)

    enum EventDecision {
        case consume   // ours: never reaches menus/responders — can't beep
        case pass      // genuinely someone else's (our text fields, real menu items)
    }

    /// Central, earliest-possible interception point. Nil for non-keyboard
    /// events (caller forwards untouched).
    func decide(_ event: NSEvent) -> EventDecision? {
        switch event.type {
        case .keyDown, .keyUp:
            break
        case .flagsChanged:
            releaseHoldsBrokenByModifiers(event.modifierFlags)
            return .pass
        default:
            return nil
        }
        let isDown = event.type == .keyDown

        // Recorder UI gets first pick.
        if let recorder = recordingHandler {
            if isDown, !event.isARepeat {
                recorder(KeySpec.normalized(keyCode: event.keyCode,
                                            modifiers: relevantModifiers(event.modifierFlags)))
                recordingHandler = nil
                MKLog.keys("recorder captured \(KeySpec.keyString(event.keyCode))")
                return .consume
            }
            return .consume   // swallow the rest of the modifier chord
        }

        // Our own text fields own the keyboard while focused — counted
        // explicitly, NOT by sniffing firstResponder (SwiftUI can leave an
        // invisible field editor as first responder, which used to open a
        // pass-through hole straight to AppKit beeps).
        if textFocusCount > 0 {
            MKLog.keys("pass text-focus \(KeySpec.keyString(event.keyCode)) \(isDown ? "↓" : "↑")")
            return .pass
        }

        // ⌘-combos pass only when a real menu item matches them; unmatched
        // ones are the primary NSBeep producer (menu-equivalent miss).
        if event.modifierFlags.contains(.command) {
            if eventHasMenuItem(event) {
                MKLog.keys("pass ⌘\(event.charactersIgnoringModifiers ?? "?") (menu item)")
                return .pass
            }
            MKLog.keys("consume ⌘\(event.charactersIgnoringModifiers ?? "?") (no menu item — would beep)")
            return .consume
        }

        let spec = KeySpec.normalized(keyCode: event.keyCode,
                                      modifiers: relevantModifiers(event.modifierFlags))

        for deck in 0...1 {
            guard let map = deckBindings[deck] else { continue }
            if let (raw, _) = map.first(where: { $0.value == spec }),
               let action = DeckAction(rawValue: raw) {
                if isDown && event.isARepeat { return .consume }   // repeats consumed, not re-fired
                fire(deck: deck, action: action, down: isDown)
                MKLog.keys("d\(deck + 1) \(action.rawValue) \(isDown ? "↓" : "↑")")
                return .consume
            }
        }
        if let (raw, _) = globalBindings.first(where: { $0.value == spec }),
           let action = GlobalAction(rawValue: raw) {
            if isDown && event.isARepeat { return .consume }
            globalDispatch?(action, isDown)
            MKLog.keys("global \(action.rawValue) \(isDown ? "↓" : "↑")")
            return .consume
        }
        // The keyboard belongs to the shortcut engine: unconsumed keys never
        // reach the responder chain (that path is what NSBeeps).
        MKLog.keys("unbound \(spec.display) \(isDown ? "↓" : "↑") → consumed")
        return .consume
    }

    /// Text-focus bookkeeping: NumericField & friends report
    /// focus changes; while any is focused, typing passes through.
    private var textFocusCount = 0
    func textFocus(_ focused: Bool) {
        textFocusCount = max(0, textFocusCount + (focused ? 1 : -1))
        MKLog.keys("textFocus \(focused ? "gained" : "lost") (count \(textFocusCount))")
    }


    private func eventHasMenuItem(_ event: NSEvent) -> Bool {
        if menuShortcuts == nil {
            var set = Set<String>()
            func walk(_ menu: NSMenu?) {
                guard let menu else { return }
                for item in menu.items {
                    if !item.keyEquivalent.isEmpty {
                        set.insert(Self.signature(chars: item.keyEquivalent.lowercased(),
                                                  mask: item.keyEquivalentModifierMask))
                    }
                    if item.hasSubmenu { walk(item.submenu) }
                }
            }
            walk(NSApp.mainMenu)
            menuShortcuts = set
        }
        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              !chars.isEmpty, chars.count == 1 else { return false }
        return menuShortcuts?.contains(Self.signature(chars: chars,
                                                      mask: event.modifierFlags)) ?? false
    }

    private static func signature(chars: String, mask: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if mask.contains(.shift) { parts.append("s") }
        if mask.contains(.option) { parts.append("a") }
        if mask.contains(.control) { parts.append("c") }
        return parts.joined(separator: "+") + "+" + chars
    }

    // MARK: Hold bookkeeping

    private func relevantModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        UInt32(flags.intersection([.shift, .option, .control]).rawValue)
    }

    private func fire(deck: Int, action: DeckAction, down: Bool) {
        let token = "\(deck):\(action.rawValue)"
        if action.isHold {
            if down {
                activeHolds.insert(token)
            } else {
                activeHolds.remove(token)
            }
        } else if !down {
            return   // one-shot actions fire on key-down only
        }
        dispatch?(deck, action, down)
    }

    /// A held action whose modifiers are no longer down must release.
    private func releaseHoldsBrokenByModifiers(_ flags: NSEvent.ModifierFlags) {
        let current = relevantModifiers(flags)
        let held = activeHolds
        for token in held {
            let parts = token.split(separator: ":")
            guard parts.count == 2, let deck = Int(parts[0]),
                  let action = DeckAction(rawValue: String(parts[1])) else { continue }
            guard let map = deckBindings[deck],
                  let spec = map[action.rawValue] else { continue }
            if spec.modifiers & ~current != 0 {
                activeHolds.remove(token)
                dispatch?(deck, action, false)
            }
        }
    }
}

