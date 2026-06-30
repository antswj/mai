// Renders Mai's app icon (a 1024x1024 PNG) with AppKit/CoreGraphics. Run via
// `swift tools/make-icon.swift <output.png>`; make-icon.sh turns it into AppIcon.icns.
// A calm glassy rounded square with a soft gradient and a white spark, matching the
// "sparkles" presence motif used in the app.
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// Rounded-square background with a vertical gradient (indigo to teal).
let inset = 64.0
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = CGPath(roundedRect: rect, cornerWidth: 196, cornerHeight: 196, transform: nil)
ctx.addPath(path); ctx.clip()
let colors = [NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.55, alpha: 1).cgColor,
              NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.55, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// A soft glass highlight across the top.
ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
ctx.fillEllipse(in: CGRect(x: inset - 80, y: size * 0.52, width: size - inset * 2 + 160, height: size * 0.6))
ctx.resetClip()

// A white four-point spark in the center.
func spark(center: CGPoint, radius r: CGFloat, waist w: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: center.x, y: center.y + r))
    p.addLine(to: CGPoint(x: center.x + w, y: center.y + w))
    p.addLine(to: CGPoint(x: center.x + r, y: center.y))
    p.addLine(to: CGPoint(x: center.x + w, y: center.y - w))
    p.addLine(to: CGPoint(x: center.x, y: center.y - r))
    p.addLine(to: CGPoint(x: center.x - w, y: center.y - w))
    p.addLine(to: CGPoint(x: center.x - r, y: center.y))
    p.addLine(to: CGPoint(x: center.x - w, y: center.y + w))
    p.closeSubpath()
    return p
}
let c = CGPoint(x: size / 2, y: size / 2)
ctx.addPath(spark(center: c, radius: 300, waist: 78)); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
ctx.addPath(spark(center: CGPoint(x: c.x + 250, y: c.y + 250), radius: 92, waist: 24)); ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor); ctx.fillPath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
