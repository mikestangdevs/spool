// Draws the app icon and writes scripts/Spool.icns.  Run: swift scripts/make-icon.swift
// The picture: windows pegged along a thread across a summer sky, running off both edges.
import AppKit

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A point on the sagging thread, and the angle of the thread there. Units are 1024ths of the icon.
func thread(_ t: CGFloat) -> (point: CGPoint, angle: CGFloat) {
    let a = CGPoint(x: 60, y: 742), c = CGPoint(x: 512, y: 560), b = CGPoint(x: 964, y: 742)
    let u = 1 - t
    let point = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    let slope = CGPoint(x: 2 * u * (c.x - a.x) + 2 * t * (b.x - c.x), y: 2 * u * (c.y - a.y) + 2 * t * (b.y - c.y))
    return (point, atan2(slope.y, slope.x))
}

func cloud(_ ctx: CGContext, at origin: CGPoint, scale: CGFloat, alpha: CGFloat) {
    let puffs: [(CGFloat, CGFloat, CGFloat)] = [(0, 0, 90), (95, 38, 118), (215, 22, 100), (310, -6, 78), (150, -30, 96)]
    ctx.setFillColor(rgb(0xFFFFFF, alpha).cgColor)
    for (x, y, r) in puffs {
        ctx.fillEllipse(in: CGRect(x: origin.x + (x - r) * scale, y: origin.y + (y - r) * scale, width: 2 * r * scale, height: 2 * r * scale))
    }
}

/// One window hanging from the thread at `t`, swinging by `swing` radians.
func window(_ ctx: CGContext, t: CGFloat, size: CGSize, tint: UInt32, swing: CGFloat) {
    let (point, angle) = thread(t)
    ctx.saveGState()
    ctx.translateBy(x: point.x, y: point.y)
    ctx.rotate(by: angle * 0.55 + swing)
    let card = CGRect(x: -size.width / 2, y: -size.height - 26, width: size.width, height: size.height)
    let radius = size.width * 0.13

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 46, color: rgb(0x0B2A6B, 0.42).cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(rgb(0xFFFFFF).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Glassy body: white at the top, the faintest blue at the foot.
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let body = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF).cgColor, rgb(0xE9F1FF).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(body, start: CGPoint(x: 0, y: card.maxY), end: CGPoint(x: 0, y: card.minY), options: [])

    // What is in the window: a wash of colour and two lines of "text".
    let inset = size.width * 0.11
    let bar = size.height * 0.2
    let picture = CGRect(x: card.minX + inset, y: card.minY + inset + size.height * 0.2,
                         width: size.width - 2 * inset, height: size.height - bar - 2 * inset - size.height * 0.2)
    ctx.addPath(CGPath(roundedRect: picture, cornerWidth: radius * 0.5, cornerHeight: radius * 0.5, transform: nil))
    ctx.setFillColor(rgb(tint).cgColor)
    ctx.fillPath()
    ctx.setFillColor(rgb(0xFFFFFF, 0.5).cgColor)
    ctx.fillEllipse(in: CGRect(x: picture.maxX - picture.height * 0.62, y: picture.maxY - picture.height * 0.62,
                               width: picture.height * 0.4, height: picture.height * 0.4))
    ctx.setFillColor(rgb(0xC9D6EE).cgColor)
    for (row, share) in [(0, 0.78), (1, 0.5)] as [(CGFloat, CGFloat)] {
        let line = CGRect(x: card.minX + inset, y: card.minY + inset + row * size.height * 0.085,
                          width: (size.width - 2 * inset) * share, height: size.height * 0.045)
        ctx.addPath(CGPath(roundedRect: line, cornerWidth: line.height / 2, cornerHeight: line.height / 2, transform: nil))
        ctx.fillPath()
    }

    for (i, colour) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        let d = size.width * 0.075
        ctx.setFillColor(rgb(UInt32(colour)).cgColor)
        ctx.fillEllipse(in: CGRect(x: card.minX + inset + CGFloat(i) * d * 1.55, y: card.maxY - bar * 0.5 - d / 2 - 4, width: d, height: d))
    }
    ctx.restoreGState()

    // Two pegs holding it to the thread.
    for side in [-1, 1] as [CGFloat] {
        let peg = CGRect(x: side * size.width * 0.27 - 13, y: -58, width: 26, height: 84)
        ctx.addPath(CGPath(roundedRect: peg, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(rgb(0xFFC94D).cgColor)
        ctx.fillPath()
        ctx.addPath(CGPath(roundedRect: peg.insetBy(dx: 7, dy: 0).offsetBy(dx: -4, dy: 0), cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.setFillColor(rgb(0xFFE39A).cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // Apple's icon grid: an 824-point rounded square centred on the canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()

    let sky = CGGradient(colorsSpace: nil, colors: [rgb(0x1668E3).cgColor, rgb(0x2E9BFF).cgColor, rgb(0x9FDCFF).cgColor] as CFArray,
                         locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // Low sun behind everything, off to the upper right.
    let glow = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.55).cgColor, rgb(0xFFFFFF, 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 800, y: 850), startRadius: 0, endCenter: CGPoint(x: 800, y: 850), endRadius: 420, options: [])

    cloud(ctx, at: CGPoint(x: 520, y: 215), scale: 0.95, alpha: 0.4)
    cloud(ctx, at: CGPoint(x: 60, y: 120), scale: 1.05, alpha: 0.92)
    cloud(ctx, at: CGPoint(x: 600, y: 105), scale: 0.9, alpha: 0.92)

    // The thread, with a lighter strand along its top.
    for (colour, width, lift) in [(0xF0453F, 17, 0), (0xFF8A7A, 5, 4)] as [(UInt32, CGFloat, CGFloat)] {
        ctx.move(to: CGPoint(x: 60, y: 742 + lift))
        ctx.addQuadCurve(to: CGPoint(x: 964, y: 742 + lift), control: CGPoint(x: 512, y: 560 + lift))
        ctx.setStrokeColor(rgb(colour).cgColor)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.strokePath()
    }

    window(ctx, t: 0.13, size: CGSize(width: 250, height: 262), tint: 0xFFB8A8, swing: -0.07)
    window(ctx, t: 0.87, size: CGSize(width: 250, height: 262), tint: 0xB9F0C8, swing: 0.08)
    window(ctx, t: 0.5, size: CGSize(width: 330, height: 344), tint: 0xC9B8FF, swing: 0.035)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let scripts = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Spool.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", scripts.appendingPathComponent("Spool.icns").path]
try tool.run()
tool.waitUntilExit()
print(tool.terminationStatus == 0 ? "Wrote scripts/Spool.icns" : "iconutil failed")
