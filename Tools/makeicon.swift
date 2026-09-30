import AppKit

// MKDJ app icon generator (headless, no Xcode asset catalog).
// Family style shared with BPMPLS's Tools/makeicon.swift: dark rounded
// rect + one tinted SF Symbol. Colors are MKDJ's own theme tokens:
// background #090b0d (Theme.bg), glyph green #00bc66 (Theme.accent).
// Glyph: "slider.horizontal.3" — the mixer fader.
// Usage: swift makeicon.swift <output.iconset>  — then: iconutil -c icns <output.iconset>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let bg = NSColor(calibratedRed: 0x09 / 255.0, green: 0x0B / 255.0, blue: 0x0D / 255.0, alpha: 1)
let accent = NSColor(calibratedRed: 0x00 / 255.0, green: 0xBC / 255.0, blue: 0x66 / 255.0, alpha: 1)
let symbolName = "slider.horizontal.3"

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

guard let baseSymbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    FileHandle.standardError.write("symbol \(symbolName) unavailable\n".data(using: .utf8)!)
    exit(1)
}

/// Symbol rendered into a transparent canvas and overpainted via .sourceIn,
/// so the tint lands only on glyph pixels.
func tintedGlyph(canvas: CGFloat) -> NSImage {
    let pointSize = canvas * 0.55
    let configured = baseSymbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)) ?? baseSymbol
    configured.isTemplate = true
    let img = NSImage(size: NSSize(width: canvas, height: canvas))
    img.lockFocus()
    let symSize = configured.size
    let rect = NSRect(x: (canvas - symSize.width) / 2, y: (canvas - symSize.height) / 2,
                      width: symSize.width, height: symSize.height)
    configured.draw(in: rect)
    if let ctx = NSGraphicsContext.current?.cgContext {
        ctx.setBlendMode(.sourceIn)
        ctx.setFillColor(accent.cgColor)
        ctx.fill(NSRect(x: 0, y: 0, width: canvas, height: canvas))
    }
    img.unlockFocus()
    return img
}

func render(pixels: Int) -> NSImage {
    let s = CGFloat(pixels)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    bg.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                 xRadius: s * 0.225, yRadius: s * 0.225).fill()
    tintedGlyph(canvas: s).draw(in: NSRect(x: 0, y: 0, width: s, height: s),
                                from: .zero, operation: .sourceOver, fraction: 1)
    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, pixels: Int, to path: String) {
    var rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil),
          let rep = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG encode failed for \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    try? rep.write(to: URL(fileURLWithPath: path))
}

// (points, scale): icon_<points>x<points>[ @2x].png rendered at points*scale pixels.
let entries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]
for e in entries {
    let pixels = e.points * e.scale
    let name = e.scale == 1 ? "icon_\(e.points)x\(e.points).png" : "icon_\(e.points)x\(e.points)@2x.png"
    writePNG(render(pixels: pixels), pixels: pixels, to: "\(outDir)/\(name)")
}
print("iconset written to \(outDir)")
