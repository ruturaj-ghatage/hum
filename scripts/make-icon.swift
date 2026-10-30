// Draws Hum's app icon: a dark squircle with the notch at the top and glowing
// sound bars underneath. Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered in 1024, ~185pt corner radius.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill()
squircle.fill()
ctx.restoreGState()

// Background: deep night gradient.
ctx.saveGState()
squircle.addClip()
NSGradient(colors: [NSColor(red: 0.16, green: 0.10, blue: 0.30, alpha: 1),
                    NSColor(red: 0.04, green: 0.03, blue: 0.08, alpha: 1)])!
    .draw(in: body, angle: -90)

// Soft warm glow rising from the bars.
let glowCenter = CGPoint(x: body.midX, y: body.minY + 300)
NSGradient(colors: [NSColor(red: 1.0, green: 0.38, blue: 0.45, alpha: 0.45),
                    NSColor(red: 1.0, green: 0.38, blue: 0.45, alpha: 0)])!
    .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: 420, options: [])

// The notch: black tab hanging from the top edge, with concave ears.
let notchW: CGFloat = 400, notchH: CGFloat = 150, ear: CGFloat = 34, br: CGFloat = 60
let top = body.maxY, left = body.midX - notchW / 2, right = body.midX + notchW / 2
let notch = NSBezierPath()
notch.move(to: CGPoint(x: left - ear, y: top + 1))
notch.curve(to: CGPoint(x: left, y: top - ear), controlPoint1: CGPoint(x: left - ear / 3, y: top), controlPoint2: CGPoint(x: left, y: top - ear / 3))
notch.line(to: CGPoint(x: left, y: top - notchH + br))
notch.curve(to: CGPoint(x: left + br, y: top - notchH), controlPoint1: CGPoint(x: left, y: top - notchH + br * 0.45), controlPoint2: CGPoint(x: left + br * 0.45, y: top - notchH))
notch.line(to: CGPoint(x: right - br, y: top - notchH))
notch.curve(to: CGPoint(x: right, y: top - notchH + br), controlPoint1: CGPoint(x: right - br * 0.45, y: top - notchH), controlPoint2: CGPoint(x: right, y: top - notchH + br * 0.45))
notch.line(to: CGPoint(x: right, y: top - ear))
notch.curve(to: CGPoint(x: right + ear, y: top + 1), controlPoint1: CGPoint(x: right, y: top - ear / 3), controlPoint2: CGPoint(x: right + ear / 3, y: top))
notch.close()
NSColor.black.setFill()
notch.fill()

// Tiny camera dot in the notch.
NSColor(white: 0.16, alpha: 1).setFill()
NSBezierPath(ovalIn: CGRect(x: body.midX - 13, y: top - notchH / 2 - 13, width: 26, height: 26)).fill()

// Sound bars: pink → orange, centered, varied heights.
let heights: [CGFloat] = [150, 270, 390, 300, 200]
let barW: CGFloat = 62, gap: CGFloat = 34
let totalW = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
let midY = body.minY + 330
let barGradient = NSGradient(colors: [NSColor(red: 1.0, green: 0.30, blue: 0.55, alpha: 1),
                                      NSColor(red: 1.0, green: 0.62, blue: 0.30, alpha: 1)])!
for (i, h) in heights.enumerated() {
    let x = body.midX - totalW / 2 + CGFloat(i) * (barW + gap)
    let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
    let bar = NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: NSColor(red: 1, green: 0.4, blue: 0.5, alpha: 0.8).cgColor)
    NSColor.white.setFill()
    bar.fill()
    ctx.restoreGState()
    barGradient.draw(in: bar, angle: 90)
}

// Subtle top highlight on the edge.
NSColor(white: 1, alpha: 0.08).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
rim.lineWidth = 3
rim.stroke()
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
