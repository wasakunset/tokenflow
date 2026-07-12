// Generates the TokenFlow app icon: two flowing streams (coral = Claude,
// teal = Codex) weaving across a dark squircle. Run:
//   swift scripts/make-icon.swift <output.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

let coral = NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let teal = NSColor(calibratedRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)

func drawIcon(px: CGFloat, ctx: CGContext) {
    let size = px
    // macOS icon grid: artwork sits inside ~90% of the canvas.
    let inset = size * 0.05
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.2237

    // Squircle background, deep slate gradient.
    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.current?.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.17, blue: 0.22, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.11, alpha: 1),
    ])!.draw(in: rect, angle: -90)

    // Faint top-edge highlight for a glassy feel.
    NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.10),
        NSColor.white.withAlphaComponent(0.0),
    ])!.draw(
        in: CGRect(x: rect.minX, y: rect.maxY - rect.height * 0.25,
                   width: rect.width, height: rect.height * 0.25),
        angle: -90
    )

    // Two streams flowing left → right, weaving once in the middle.
    let lineWidth = rect.width * 0.095
    let x0 = rect.minX + rect.width * 0.14
    let x1 = rect.maxX - rect.width * 0.14
    let yHigh = rect.midY + rect.height * 0.155
    let yLow = rect.midY - rect.height * 0.155

    func stream(from yStart: CGFloat, to yEnd: CGFloat, color: NSColor) {
        ctx.saveGState()
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color.cgColor)
        // Soft glow in the stream's own color.
        ctx.setShadow(
            offset: .zero, blur: rect.width * 0.05,
            color: color.withAlphaComponent(0.55).cgColor
        )
        ctx.move(to: CGPoint(x: x0, y: yStart))
        ctx.addCurve(
            to: CGPoint(x: x1, y: yEnd),
            control1: CGPoint(x: rect.minX + rect.width * 0.48, y: yStart),
            control2: CGPoint(x: rect.maxX - rect.width * 0.48, y: yEnd)
        )
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Teal first so the coral stream crosses over it.
    stream(from: yLow, to: yHigh, color: teal)
    stream(from: yHigh, to: yLow, color: coral)

    NSGraphicsContext.current?.restoreGraphicsState()
}

func render(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    drawIcon(px: CGFloat(px), ctx: gctx.cgContext)
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try render(px: base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try render(px: base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("wrote \(outDir)")
