import AppKit
import CoreGraphics

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downwards (easier to think in).
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func grad(_ cols: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
  CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
}
func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect { CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r) }

// Squircle tile (macOS icon grid: 824 pt body, centred), with a soft shadow.
let tile = CGRect(x: 100, y: 92, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: c(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(c(0x15121F)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
ctx.drawLinearGradient(grad([c(0x2A2140), c(0x0E0C16)]), start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
// Purple glow behind the deck.
ctx.drawRadialGradient(grad([c(0xE040FB, 0.35), c(0xE040FB, 0)]), startCenter: CGPoint(x: 450, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 450, y: 540), endRadius: 420, options: [])

// Platter and record.
let cx: CGFloat = 448, cy: CGFloat = 540
ctx.setFillColor(c(0x2E2B36)); ctx.fillEllipse(in: circle(cx, cy, 300))
ctx.setFillColor(c(0x08080B)); ctx.fillEllipse(in: circle(cx, cy, 282))
ctx.setLineWidth(1.6)
var r: CGFloat = 125
while r < 276 {
  ctx.setStrokeColor(c(0xFFFFFF, r.truncatingRemainder(dividingBy: 36) < 9 ? 0.10 : 0.05))
  ctx.strokeEllipse(in: circle(cx, cy, r)); r += 9
}
// Light sheen across the grooves (two opposite wedges).
for a0 in [CGFloat.pi * 1.15, CGFloat.pi * 0.15] {
  ctx.saveGState()
  let p = CGMutablePath(); p.move(to: CGPoint(x: cx, y: cy))
  p.addArc(center: CGPoint(x: cx, y: cy), radius: 280, startAngle: a0, endAngle: a0 + 0.42, clockwise: false); p.closeSubpath()
  ctx.addPath(p); ctx.clip()
  ctx.drawRadialGradient(grad([c(0xFFFFFF, 0.0), c(0xFFFFFF, 0.16)]), startCenter: CGPoint(x: cx, y: cy), startRadius: 110,
                         endCenter: CGPoint(x: cx, y: cy), endRadius: 280, options: [])
  ctx.restoreGState()
}
// Label.
ctx.saveGState()
ctx.addEllipse(in: circle(cx, cy, 108)); ctx.clip()
ctx.drawLinearGradient(grad([c(0xF06BFF), c(0x8E3BFF)]), start: CGPoint(x: cx - 108, y: cy - 108), end: CGPoint(x: cx + 108, y: cy + 108), options: [])
// A little waveform on the label.
ctx.setFillColor(c(0xFFFFFF, 0.92))
let bars: [CGFloat] = [18, 34, 54, 30, 66, 42, 24, 48, 28, 14]
for (i, h) in bars.enumerated() {
  let x = cx - 66 + CGFloat(i) * 14
  ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: cy - h / 2, width: 8, height: h), cornerWidth: 4, cornerHeight: 4, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()
ctx.setFillColor(c(0x15121F)); ctx.fillEllipse(in: circle(cx, cy, 9))

// Tonearm: pivot top right, arm down onto the outer grooves.
let pivot = CGPoint(x: 790, y: 250)
let elbow = CGPoint(x: 760, y: 560)
let head = CGPoint(x: 640, y: 690)
ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 6, height: -10), blur: 14, color: c(0x000000, 0.6))
ctx.setStrokeColor(c(0xC9C6D3)); ctx.setLineWidth(22)
ctx.move(to: pivot); ctx.addLine(to: elbow); ctx.addLine(to: head); ctx.strokePath()
// Headshell.
ctx.translateBy(x: head.x, y: head.y); ctx.rotate(by: atan2(head.y - elbow.y, head.x - elbow.x))
ctx.setFillColor(c(0xE6E3EE))
ctx.addPath(CGPath(roundedRect: CGRect(x: -10, y: -26, width: 70, height: 52), cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
ctx.restoreGState()
ctx.setStrokeColor(c(0xFFFFFF, 0.5)); ctx.setLineWidth(5)
ctx.move(to: CGPoint(x: pivot.x - 4, y: pivot.y + 62)); ctx.addLine(to: CGPoint(x: elbow.x - 5, y: elbow.y - 8)); ctx.strokePath()
// Pivot base and counterweight.
ctx.setFillColor(c(0x3A3645)); ctx.fillEllipse(in: circle(pivot.x, pivot.y, 58))
ctx.drawRadialGradient(grad([c(0xF2F0F7), c(0x9C98A8)]), startCenter: CGPoint(x: pivot.x - 12, y: pivot.y - 12), startRadius: 2,
                       endCenter: pivot, endRadius: 38, options: [])
ctx.setFillColor(c(0xE040FB)); ctx.fillEllipse(in: circle(pivot.x, pivot.y, 10))

// Pitch fader on the right.
let fx: CGFloat = 852
ctx.setFillColor(c(0x050508)); ctx.addPath(CGPath(roundedRect: CGRect(x: fx - 9, y: 600, width: 18, height: 230), cornerWidth: 9, cornerHeight: 9, transform: nil)); ctx.fillPath()
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 22, color: c(0xE040FB, 0.9))
ctx.setFillColor(c(0xE040FB))
ctx.addPath(CGPath(roundedRect: CGRect(x: fx - 30, y: 690, width: 60, height: 30), cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
ctx.restoreGState()
ctx.setFillColor(c(0xFFFFFF, 0.85)); ctx.fill(CGRect(x: fx - 24, y: 703, width: 48, height: 4))
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("ok")
