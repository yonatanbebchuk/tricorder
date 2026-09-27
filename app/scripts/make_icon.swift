// Renders the app icon: warm paper, a faint 1 m grid, a terracotta yard outline with surveyed corners, a north arrow.
//   swift scripts/make_icon.swift out.png
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let s = CGFloat(size)
let paper = NSColor(srgbRed: 0.980, green: 0.976, blue: 0.961, alpha: 1)
let line = NSColor(srgbRed: 0.894, green: 0.886, blue: 0.847, alpha: 1)
let terracotta = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let ink = NSColor(srgbRed: 0.098, green: 0.098, blue: 0.094, alpha: 1)

// squircle-ish rounded rect, transparent outside
let inset: CGFloat = 100
let shape = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset), xRadius: 185, yRadius: 185)
ctx.saveGState()
shape.addClip()
paper.setFill(); shape.fill()
// grid
ctx.setStrokeColor(line.cgColor); ctx.setLineWidth(3)
for i in stride(from: inset + 51, to: s - inset, by: 102.4) {
    ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i, y: s))
    ctx.move(to: CGPoint(x: 0, y: i)); ctx.addLine(to: CGPoint(x: s, y: i))
}
ctx.strokePath()
// yard outline
let pts: [CGPoint] = [(260, 300), (700, 300), (700, 520), (800, 520), (800, 760), (380, 760), (260, 640)].map { CGPoint(x: $0.0, y: $0.1) }
let poly = NSBezierPath(); poly.move(to: pts[0]); for p in pts.dropFirst() { poly.line(to: p) }; poly.close()
poly.lineJoinStyle = .round; poly.lineWidth = 26
terracotta.withAlphaComponent(0.13).setFill(); poly.fill()
terracotta.setStroke(); poly.stroke()
// surveyed corners
for p in pts {
    let r: CGFloat = 24
    let dot = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    paper.setFill(); dot.fill()
    dot.lineWidth = 12; terracotta.setStroke(); dot.stroke()
}
// north arrow
let n = NSBezierPath(); n.move(to: CGPoint(x: 820, y: 190)); n.line(to: CGPoint(x: 780, y: 100)); n.line(to: CGPoint(x: 820, y: 125)); n.line(to: CGPoint(x: 860, y: 100)); n.close()
ink.setFill(); n.fill()
ctx.restoreGState()
NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
