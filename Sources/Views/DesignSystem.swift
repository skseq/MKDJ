import SwiftUI

// MARK: - Theme
// Palette lifted from the dark theme the colors came from: near-black
// blue-tinted base, soft off-white ink, hairline rules, green primary
// accent + amber secondary. Marker colors ride the same family: red
// playhead, cyan cue.

enum Theme {
    // every surface/ink token is a DYNAMIC light/dark pair (was
    // dark-only — the app was pinned dark). Accents stay single:
    // they read on both appearances.
    private static let _darkAppearance: (NSAppearance) -> Bool = { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    }
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            _darkAppearance(ap) ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    static let bg = dyn(0x090b0d, 0xf4f5f7)              // near-black base / paper
    static let surface = dyn(0x0a0a0a, 0xffffff)         // base surface
    static let raised = dyn(0x161616, 0xededf0)          // hover-level surface
    static let ink = dyn(0xd9d9d9, 0x1d1f21)             // primary text
    static let inkBright = dyn(0xf4f4f4, 0x0a0a0a)
    static let muted = dyn(0x7d7d7d, 0x6e6e73)           // secondary text
    static let faint = dyn(0x585858, 0x8e8e93)           // tertiary text
    static let rule = Color(nsColor: NSColor(name: nil) { ap in   // hairlines
        _darkAppearance(ap) ? NSColor.white.withAlphaComponent(0.07)
                            : NSColor.black.withAlphaComponent(0.10)
    })
    /// Grid ink — the waveform grid default: white on dark lanes,
    /// black on light (a fixed white would vanish on light).
    static let gridInk = Color(nsColor: NSColor(name: nil) { ap in
        _darkAppearance(ap) ? NSColor.white : NSColor.black
    })
    static let accent = Color(hex: 0x00bc66)      // green primary accent
    static let accentFill = Color(hex: 0x00bc66).opacity(0.12)
    static let amber = Color(hex: 0xffb400)       // amber secondary accent
    static let cueBlue = Color(hex: 0x00baff)     // cyan accent (light skin) → cue markers
    static let playheadRed = Color(hex: 0xe84a5e) // red marker (playhead/rejection)
    static let lcd = dyn(0x050607, 0xe9ebee)      // waveform LCD inset

    static let mono: Font = .system(size: 11, design: .default)
    static let monoSmall: Font = .system(size: 9, design: .default)
    static let monoBig: Font = .system(size: 15, weight: .semibold, design: .default)

    static func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - LCD inset (readouts, waveform zones — Logic-style dark display)

struct LCDInset: ViewModifier {
    var corner: CGFloat = 5
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: corner)
                .fill(AppSettings.shared.laneBackgroundColor))   // skin
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(Theme.rule, lineWidth: 1))
    }
}

extension View {
    func lcdInset(corner: CGFloat = 5) -> some View { modifier(LCDInset(corner: corner)) }
}

// MARK: - Buttons
// Mac behaviors (hover, pressed, focus-ability, disabled dimming, tooltips)
// with quiet surfaces: no boxes until hovered, accent fill when active.

/// Press-and-HOLD button: pressed = `onHold(true)` immediately,
/// release/cancel = `onHold(false)`. SwiftUI has no native hold button,
/// and the leaked-press hazard applies harder here — a leaked press on a
/// tempo-bend button is an AUDIBLE stuck bend — so release fires on end,
/// disappear, AND a press-location-change recovery.
struct HoldButton: View {
    let label: String
    var active = false
    var helpText: String? = nil
    let onHold: (Bool) -> Void

    @State private var pressX: CGFloat?

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 20)
            .frame(minWidth: 28)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Theme.accent.opacity(0.35) :
                          (hover ? Color.white.opacity(0.12) : Color.white.opacity(0.06)))
            )
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(active ? Theme.accent : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        // leaked-press recovery: a new press (location moved)
                        // while an un-released hold is live — restart clean
                        if pressX != nil, let x = pressX, abs(g.startLocation.x - x) > 2 {
                            onHold(false)
                            pressX = nil
                        }
                        if pressX == nil {
                            pressX = g.startLocation.x
                            onHold(true)
                        }
                    }
                    .onEnded { _ in
                        pressX = nil
                        onHold(false)
                    }
            )
            .onDisappear {
                if pressX != nil {
                    pressX = nil
                    onHold(false)
                }
            }
            .help(helpText ?? "")
    }

    @State private var hover = false
}

struct MKButton: View {
    let label: String
    var active = false
    var accent: Color = Theme.accent
    var prominent = false
    var helpText: String? = nil
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: prominent ? 11 : 10, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, prominent ? 12 : 8)
                .padding(.vertical, prominent ? 7 : 4)
                .frame(minHeight: prominent ? 30 : 20)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(border, lineWidth: 1)
                )
                .foregroundColor(foreground)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(helpText ?? "")
        .disabled(helpText == nil)
    }

    private var background: Color {
        if active { return accent.opacity(0.22) }
        if hover { return Color.white.opacity(0.06) }
        return Color.white.opacity(0.025)
    }

    private var border: Color {
        active ? accent.opacity(0.65) : (hover ? Color.white.opacity(0.14) : Theme.rule)
    }

    private var foreground: Color {
        active ? accent : Theme.ink
    }
}

/// Press-and-hold button (CUE, tempo bend): fires `press` on mouse-down,
/// `release` on mouse-up. Keyboard holds route through the shortcut system.
struct MKHoldButton: View {
    let label: String
    var active = false
    var accent: Color = Theme.accent
    var helpText: String? = nil
    let press: () -> Void
    let release: () -> Void

    @State private var hover = false
    @State private var down = false

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: 20)
            .frame(minWidth: 28)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1))
            .foregroundColor(foreground)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !down {
                            down = true
                            press()
                        }
                    }
                    .onEnded { _ in
                        down = false
                        release()
                    }
            )
            .help(helpText ?? "")
    }

    private var background: Color {
        if active { return accent.opacity(0.22) }
        if hover || down { return Color.white.opacity(0.06) }
        return Color.white.opacity(0.025)
    }

    private var border: Color {
        active ? accent.opacity(0.65) : (hover || down ? Color.white.opacity(0.14) : Theme.rule)
    }

    private var foreground: Color {
        active ? accent : Theme.ink
    }
}

// MARK: - Compact segmented picker (loop size, move amount)

struct MiniSegmented<Value: Hashable>: View {
    let title: String
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.mini)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Mini switch toggle (snap, keylock — native control, mac feel)

struct MiniSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 9, weight: .semibold))
            .tint(Theme.accent)
    }
}
