import AppKit

// Draws the 1024px app icon on Apple's macOS grid: an 824px squircle centred on the canvas.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
squircle.fill()
NSGraphicsContext.current?.restoreGraphicsState()

NSGradient(colors: [
    NSColor(srgbRed: 0.33, green: 0.38, blue: 0.98, alpha: 1),
    NSColor(srgbRed: 0.55, green: 0.30, blue: 0.95, alpha: 1),
    NSColor(srgbRed: 0.96, green: 0.36, blue: 0.62, alpha: 1),
])!.draw(in: squircle, angle: -60)

NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0)])!
    .draw(in: squircle, angle: -90)

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, in box: NSRect, alpha: CGFloat = 1) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(alpha)]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let s = img.size
    let scale = min(box.width / s.width, box.height / s.height)
    let w = s.width * scale, h = s.height * scale
    img.draw(in: NSRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
}

symbol("arrow.triangle.branch", pointSize: 400, weight: .semibold, in: NSRect(x: 262, y: 252, width: 500, height: 520))

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
