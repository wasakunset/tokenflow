// Generates the TokenFlow app icon: a "TF" monogram with a coral→teal
// gradient on a dark squircle. Run:
//   swift scripts/make-icon.swift <output.iconset>
import AppKit
import CoreText

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

let coral = NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let teal = NSColor(calibratedRed: 0.063, green: 0.639, blue: 0.498, alpha: 1)

/// Combined glyph outline for `text`, with baseline at the origin.
func monogramPath(_ text: String, font: NSFont) -> CGPath {
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attr)
    let combined = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let ctFont = font as CTFont
        for i in 0..<count {
            guard let gp = CTFontCreatePathForGlyph(ctFont, glyphs[i], nil) else { continue }
            let t = CGAffineTransform(translationX: positions[i].x, y: positions[i].y)
            combined.addPath(gp, transform: t)
        }
    }
    return combined
}

func drawIcon(px: CGFloat, ctx: CGContext) {
    let size = px
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
    NSGraphicsContext.current?.restoreGraphicsState()

    // "TF" monogram, gradient-filled coral → teal.
    let font = NSFont.systemFont(ofSize: size * 0.5, weight: .heavy)
    let path = monogramPath("TF", font: font)
    let bb = path.boundingBoxOfPath
    let tx = rect.midX - bb.midX
    let ty = rect.midY - bb.midY

    let cgGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [coral.cgColor, teal.cgColor] as CFArray,
        locations: [0, 1]
    )!

    ctx.saveGState()
    ctx.translateBy(x: tx, y: ty)
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(
        cgGradient,
        start: CGPoint(x: bb.minX, y: bb.maxY),
        end: CGPoint(x: bb.maxX, y: bb.minY),
        options: []
    )
    ctx.restoreGState()
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
