import AppKit

// Renders docs/banner.png: the app icon, name and tagline on the icon's gradient.
let w: CGFloat = 1280, h: CGFloat = 400
let image = NSImage(size: NSSize(width: w, height: h))
image.lockFocus()

let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 28, yRadius: 28)
NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.38, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.30, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.96, green: 0.36, blue: 0.62, alpha: 1),
])!.draw(in: bg, angle: -20)

// Faint branch glyphs in the background for texture.
func glyph(_ name: String, _ rect: NSRect, _ alpha: CGFloat) {
    let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)?.draw(in: rect)
}
glyph("arrow.triangle.branch", NSRect(x: 1010, y: -40, width: 300, height: 330), 0.10)
glyph("arrow.triangle.branch", NSRect(x: 880, y: 250, width: 140, height: 155), 0.07)

let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 30
shadow.shadowOffset = NSSize(width: 0, height: -10)
NSGraphicsContext.current?.saveGraphicsState()
shadow.set()
icon.draw(in: NSRect(x: 70, y: 70, width: 260, height: 260))
NSGraphicsContext.current?.restoreGraphicsState()

func text(_ s: String, _ font: NSFont, _ alpha: CGFloat, _ point: NSPoint) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(alpha)]).draw(at: point)
}
text("Sweeper", .systemFont(ofSize: 96, weight: .bold), 1, NSPoint(x: 370, y: 205))
text("Clear stale git worktrees, build output and dev caches.", .systemFont(ofSize: 30, weight: .medium), 0.92, NSPoint(x: 374, y: 160))
text("In one click, without losing work.", .systemFont(ofSize: 30, weight: .medium), 0.92, NSPoint(x: 374, y: 122))

var x: CGFloat = 374
for chip in ["Worktrees", "Caches", "Disk", "Auto-sweep"] {
    let font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    let size = (chip as NSString).size(withAttributes: [.font: font])
    let rect = NSRect(x: x, y: 56, width: size.width + 32, height: 40)
    NSColor.white.withAlphaComponent(0.18).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 20, yRadius: 20).fill()
    text(chip, font, 1, NSPoint(x: x + 16, y: 64))
    x += rect.width + 12
}

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
