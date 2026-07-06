// Renders AppIcon at 1024x1024 with true alpha transparency around the inset
// squircle card. Geometry mirrors Resources/AppIcon.svg (kept as a readable
// design reference) — edit both together if the design changes.
//
// This renders directly with CoreGraphics rather than rasterizing the SVG:
// `qlmanage -t` (QuickLook thumbnailing) silently flattens standalone SVGs onto
// an opaque white page background, so a PNG produced that way looks fine
// on-screen but is NOT actually transparent — the app icon would appear as a
// plain white square outside the card in Finder. CoreGraphics renders straight
// to a transparent bitmap, so there's no flattening step to get wrong.
//
// Usage:
//   swift scripts/generate-icon.swift Resources/AppIcon_1024.png
//   (then rebuild the .iconset/.icns — see scripts/make-app.sh's icon step,
//   or re-run the same sips + iconutil commands used to produce Resources/AppIcon.icns)

import AppKit
import CoreGraphics

func hex(_ s: String, _ alpha: CGFloat = 1) -> CGColor {
  var v: UInt64 = 0
  Scanner(string: s).scanHexInt64(&v)
  let r = CGFloat((v >> 16) & 0xFF) / 255
  let g = CGFloat((v >> 8) & 0xFF) / 255
  let b = CGFloat(v & 0xFF) / 255
  return CGColor(red: r, green: g, blue: b, alpha: alpha)
}

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                           space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
  fatalError("no context")
}
// SVG-style top-left-origin, y-down coordinates.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
  CGGradient(colorsSpace: cs, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}

func fillPath(_ path: CGPath, gradient grad: CGGradient, start: CGPoint, end: CGPoint) {
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.drawLinearGradient(grad, start: start, end: end, options: [])
  ctx.restoreGState()
}

func fillPathRadial(_ path: CGPath, gradient grad: CGGradient, center: CGPoint, radius: CGFloat) {
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.drawRadialGradient(grad, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
  ctx.restoreGState()
}

// ---- Card (inset squircle, transparent margin around it) ----
let card = CGRect(x: 76, y: 76, width: 872, height: 872)
let cardPath = CGPath(roundedRect: card, cornerWidth: 160, cornerHeight: 160, transform: nil)

let bgGrad = gradient([(0.0, hex("2B1B5E")), (0.55, hex("4C2A9C")), (1.0, hex("7C3AED"))])
fillPath(cardPath, gradient: bgGrad, start: CGPoint(x: card.minX, y: card.minY), end: CGPoint(x: card.maxX, y: card.maxY))

// sheen (top highlight)
ctx.saveGState()
ctx.addPath(cardPath)
ctx.clip()
let sheenRect = CGPath(rect: CGRect(x: 76, y: 76, width: 872, height: 436), transform: nil)
let sheenGrad = gradient([(0.0, hex("FFFFFF", 0.16)), (0.45, hex("FFFFFF", 0.0))])
ctx.addPath(sheenRect); ctx.clip()
ctx.drawLinearGradient(sheenGrad, start: CGPoint(x: 76, y: 76), end: CGPoint(x: 76, y: 512), options: [])
ctx.restoreGState()

// ---- Monitor ----
let screenRect = CGRect(x: 182, y: 228, width: 660, height: 440)
let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 46, cornerHeight: 46, transform: nil)
let screenGrad = gradient([(0.0, hex("171335")), (1.0, hex("261D52"))])
fillPath(screenPath, gradient: screenGrad, start: CGPoint(x: screenRect.midX, y: screenRect.minY), end: CGPoint(x: screenRect.midX, y: screenRect.maxY))

ctx.setStrokeColor(hex("FFFFFF", 0.88))
ctx.setLineWidth(22)
ctx.addPath(screenPath)
ctx.strokePath()

func fillSolid(_ rect: CGRect, corner: CGFloat, color: CGColor) {
  let p = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
  ctx.addPath(p)
  ctx.setFillColor(color)
  ctx.fillPath()
}
fillSolid(CGRect(x: 482, y: 668, width: 60, height: 88), corner: 14, color: hex("FFFFFF", 0.9))
fillSolid(CGRect(x: 392, y: 748, width: 240, height: 34), corner: 17, color: hex("FFFFFF", 0.9))

// ---- Sun ----
let sunCenter = CGPoint(x: 512, y: 448)
let sunRadius: CGFloat = 94
let sunPath = CGPath(ellipseIn: CGRect(x: sunCenter.x - sunRadius, y: sunCenter.y - sunRadius, width: sunRadius * 2, height: sunRadius * 2), transform: nil)
let sunGrad = gradient([(0.0, hex("FFEBB0")), (0.55, hex("FDBA3D")), (1.0, hex("F59E0B"))])
fillPathRadial(sunPath, gradient: sunGrad, center: sunCenter, radius: sunRadius)

let rays: [(CGPoint, CGPoint)] = [
  (CGPoint(x: 512, y: 288), CGPoint(x: 512, y: 330)),
  (CGPoint(x: 512, y: 566), CGPoint(x: 512, y: 608)),
  (CGPoint(x: 352, y: 448), CGPoint(x: 394, y: 448)),
  (CGPoint(x: 630, y: 448), CGPoint(x: 672, y: 448)),
  (CGPoint(x: 399, y: 335), CGPoint(x: 428, y: 364)),
  (CGPoint(x: 596, y: 532), CGPoint(x: 625, y: 561)),
  (CGPoint(x: 625, y: 335), CGPoint(x: 596, y: 364)),
  (CGPoint(x: 428, y: 532), CGPoint(x: 399, y: 561)),
]
ctx.setStrokeColor(hex("FDBA3D"))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
for (a, b) in rays {
  ctx.move(to: a)
  ctx.addLine(to: b)
}
ctx.strokePath()

// ---- Export ----
guard let cgImage = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: cgImage)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png data") }
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
