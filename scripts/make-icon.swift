// Draws the Phone Farm app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = roundedRect(body, 185)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0F5132))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [color(0x34C77B), color(0x0E7C5A), color(0x0A4D45)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Rows of soil across the bottom, like a field.
    for (index, y) in [CGFloat(150), 205, 260].enumerated() {
        ctx.setFillColor(color(0x07362F, 0.30 - CGFloat(index) * 0.07))
        ctx.addPath(roundedRect(CGRect(x: 60, y: y, width: 904, height: 26), 13))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Two phones behind, one in front.
    drawPhone(ctx, center: CGPoint(x: 330, y: 520), size: CGSize(width: 220, height: 400), angle: 0.16, front: false)
    drawPhone(ctx, center: CGPoint(x: 694, y: 520), size: CGSize(width: 220, height: 400), angle: -0.16, front: false)
    drawPhone(ctx, center: CGPoint(x: 512, y: 500), size: CGSize(width: 270, height: 490), angle: 0, front: true)
}

func drawPhone(_ ctx: CGContext, center: CGPoint, size: CGSize, angle: CGFloat, front: Bool) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)

    let frame = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let radius = size.width * 0.2

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x022B24, 0.45))
    ctx.addPath(roundedRect(frame, radius))
    ctx.setFillColor(front ? color(0xF7FBF8) : color(0xD7EEE3))
    ctx.fillPath()
    ctx.restoreGState()

    let inset = size.width * 0.075
    let screen = frame.insetBy(dx: inset, dy: inset)
    ctx.addPath(roundedRect(screen, radius - inset))
    ctx.setFillColor(front ? color(0x123B36) : color(0x1F5A4E))
    ctx.fillPath()

    // Speaker slot.
    let slot = CGRect(x: -size.width * 0.12, y: screen.maxY - size.width * 0.09, width: size.width * 0.24, height: size.width * 0.04)
    ctx.addPath(roundedRect(slot, slot.height / 2))
    ctx.setFillColor(color(0xFFFFFF, front ? 0.35 : 0.25))
    ctx.fillPath()

    if front {
        drawSprout(ctx, base: CGPoint(x: 0, y: -size.height * 0.2), scale: size.width / 270)
    } else {
        // Simple feed lines on the phones behind.
        for row in 0..<4 {
            let y = screen.maxY - size.height * 0.22 - CGFloat(row) * size.height * 0.15
            let width = screen.width * (row % 2 == 0 ? 0.72 : 0.5)
            ctx.addPath(roundedRect(CGRect(x: screen.minX + screen.width * 0.14, y: y, width: width, height: size.width * 0.06), size.width * 0.03))
            ctx.setFillColor(color(0x7FE0AE, 0.55))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()
}

func drawSprout(_ ctx: CGContext, base: CGPoint, scale: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: base.x, y: base.y)
    ctx.scaleBy(x: scale, y: scale)

    // Soil mound.
    ctx.addPath(CGPath(ellipseIn: CGRect(x: -78, y: -26, width: 156, height: 44), transform: nil))
    ctx.setFillColor(color(0x8A5A3B))
    ctx.fillPath()

    // Stem.
    let stem = CGMutablePath()
    stem.move(to: CGPoint(x: 0, y: 0))
    stem.addCurve(to: CGPoint(x: 0, y: 190), control1: CGPoint(x: -10, y: 70), control2: CGPoint(x: 10, y: 130))
    ctx.addPath(stem)
    ctx.setStrokeColor(color(0x5BE38F))
    ctx.setLineWidth(18)
    ctx.setLineCap(.round)
    ctx.strokePath()

    // Leaves.
    let leaf = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(0x9CF5B8), color(0x34C77B)] as CFArray,
        locations: [0, 1]
    )!
    for side in [CGFloat(-1), 1] {
        let path = CGMutablePath()
        let root = CGPoint(x: 0, y: side < 0 ? 120 : 160)
        let tip = CGPoint(x: side * 100, y: side < 0 ? 200 : 250)
        path.move(to: root)
        path.addCurve(to: tip, control1: CGPoint(x: side * 20, y: root.y + 90), control2: CGPoint(x: side * 80, y: tip.y + 10))
        path.addCurve(to: root, control1: CGPoint(x: side * 92, y: tip.y - 80), control2: CGPoint(x: side * 40, y: root.y - 10))
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(leaf, start: tip, end: root, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = graphics.cgContext
    ctx.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    ctx.interpolationQuality = .high
    drawIcon(ctx)
    graphics.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try png(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
