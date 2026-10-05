// mlx-agent pixel art: the dog drawn as a 32x32 sprite (not a photo), old-school icon, modern finish.
//   swift pixel-art.swift icon  out.png   1024 app tile
//   swift pixel-art.swift sheet out.png   768x256 animation sheet: [open, blink, ear twitch]
import AppKit

let G = 32
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ h: UInt32) -> CGColor { CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: 1) }

// Palette: deep-green fur, mid-green tan, mint markings, near-black eyes/nose, phosphor outline.
let FUR = rgb(0x0b3a22), TAN = rgb(0x178a4c), MINT = rgb(0xa6ffcb), INK = rgb(0x010805), GLINT = rgb(0xf0fff5)
let OUTLINE: (UInt8, UInt8, UInt8) = (0x2b, 0xff, 0x88)

func poly(_ c: CGContext, _ pts: [(Double, Double)], _ col: CGColor) {
  c.setFillColor(col); c.beginPath(); c.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
  for p in pts.dropFirst() { c.addLine(to: CGPoint(x: p.0, y: p.1)) }
  c.closePath(); c.fillPath()
}
func oval(_ c: CGContext, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ col: CGColor) {
  c.setFillColor(col); c.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
}
func box(_ c: CGContext, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ col: CGColor) {
  c.setFillColor(col); c.fill(CGRect(x: x, y: y, width: w, height: h))
}

// Draw one frame into a 32x32 buffer (design coords: x right, y down). Returns RGBA bytes, row 0 = top.
func frame(_ f: Int) -> [UInt8] {
  var buf = [UInt8](repeating: 0, count: G * G * 4)
  let c = CGContext(data: &buf, width: G, height: G, bitsPerComponent: 8, bytesPerRow: G * 4,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  c.setShouldAntialias(false); c.interpolationQuality = .none
  c.translateBy(x: 0, y: CGFloat(G)); c.scaleBy(x: 1, y: -1)   // y-down design space

  // Neck and shoulders, bust cut off at the bottom edge.
  poly(c, [(8, 24), (24, 24), (27, 32), (5, 32)], FUR)
  // Ears: tall and pointed like his. Frame 2 flicks the right ear outward.
  let rTip = f == 2 ? (29.0, 3.0) : (26.0, 1.0)
  poly(c, [(5, 1), (2.5, 14), (13.5, 9.5)], FUR)
  poly(c, [rTip, (18.5, 9.5), (29.5, 14)], FUR)
  poly(c, [(5.5, 4), (4.5, 12), (10.5, 9.8)], TAN)
  poly(c, [(rTip.0 - 0.5, rTip.1 + 3), (21.5, 9.8), (27.5, 12)], TAN)
  // Head and muzzle.
  oval(c, 16, 16.5, 10, 8.6, FUR)
  oval(c, 16, 22.5, 6, 4.4, FUR)
  // Tan cheeks.
  box(c, 8, 19, 2, 2, TAN); box(c, 22, 19, 2, 2, TAN)
  // White blaze down the forehead, widening into the muzzle, and the white chest.
  box(c, 15, 10, 2, 8, MINT)
  box(c, 14, 17, 4, 3, MINT)
  oval(c, 16, 23.2, 4.4, 3.2, MINT)
  poly(c, [(12, 27), (20, 27), (22.5, 32), (9.5, 32)], MINT)
  // Eyebrow spots.
  box(c, 10, 12, 2, 2, MINT); box(c, 20, 12, 2, 2, MINT)
  // Eyes: open with a glint, or a blink line.
  if f == 1 {
    box(c, 10, 16, 3, 1, INK); box(c, 19, 16, 3, 1, INK)
  } else {
    box(c, 10, 15, 3, 3, INK); box(c, 19, 15, 3, 3, INK)
    box(c, 10, 15, 1, 1, GLINT); box(c, 19, 15, 1, 1, GLINT)
  }
  // Nose and mouth.
  box(c, 14, 21, 4, 2, INK); box(c, 15, 23, 2, 1, INK)
  box(c, 14, 21, 1, 1, GLINT)
  box(c, 15, 25, 2, 1, FUR)
  return buf
}

// 1px phosphor outline around the silhouette (8-neighbour), the classic sprite look.
func outlined(_ b: [UInt8]) -> [UInt8] {
  var o = b
  for y in 0..<G { for x in 0..<G {
    if b[(y * G + x) * 4 + 3] != 0 { continue }
    var touch = false
    for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
      let nx = x + dx, ny = y + dy
      if nx >= 0, ny >= 0, nx < G, ny < G, b[(ny * G + nx) * 4 + 3] != 0 { touch = true }
    } }
    if touch { let i = (y * G + x) * 4; o[i] = OUTLINE.0; o[i + 1] = OUTLINE.1; o[i + 2] = OUTLINE.2; o[i + 3] = 255 }
  } }
  return o
}

// Paint a sprite buffer as crisp square pixels. Bright pixels get a bloom for the modern finish.
func paint(_ ctx: CGContext, _ b: [UInt8], ox: CGFloat, oy: CGFloat, cell: CGFloat, glow: Bool) {
  for y in 0..<G { for x in 0..<G {
    let i = (y * G + x) * 4
    if b[i + 3] == 0 { continue }
    let r = CGFloat(b[i]) / 255, g = CGFloat(b[i + 1]) / 255, bl = CGFloat(b[i + 2]) / 255
    let bright = g > 0.55
    if glow && bright { ctx.setShadow(offset: .zero, blur: cell * 1.1, color: CGColor(srgbRed: 0.1, green: 1, blue: 0.5, alpha: 0.75)) }
    else { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: bl, alpha: 1))
    ctx.fill(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(G - 1 - y) * cell, width: cell, height: cell))
  } }
  ctx.setShadow(offset: .zero, blur: 0, color: nil)
}

func save(_ ctx: CGContext, _ path: String) {
  let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
  CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
}

let mode = CommandLine.arguments[1], out = CommandLine.arguments[2]
if mode == "icon" {
  let S = 1024
  let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
  ctx.saveGState(); ctx.addPath(tile); ctx.clip()
  ctx.setFillColor(rgb(0x020a06)); ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
  let grad = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0.02, green: 0.16, blue: 0.08, alpha: 1), CGColor(srgbRed: 0, green: 0.02, blue: 0.01, alpha: 1)] as CFArray, locations: [0, 1])!
  ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 512, y: 600), startRadius: 20, endCenter: CGPoint(x: 512, y: 512), endRadius: 600, options: [])
  // Faint pixel grid floor for the "screen" feel.
  ctx.setFillColor(CGColor(srgbRed: 0.17, green: 1, blue: 0.53, alpha: 0.035))
  var gx = 100.0; while gx < 924 { ctx.fill(CGRect(x: gx, y: 100, width: 1, height: 824)); gx += 22 }
  var gy = 100.0; while gy < 924 { ctx.fill(CGRect(x: 100, y: gy, width: 824, height: 1)); gy += 22 }
  let cell: CGFloat = 22, span = cell * CGFloat(G)
  paint(ctx, outlined(frame(0)), ox: (1024 - span) / 2, oy: (1024 - span) / 2 - 6, cell: cell, glow: true)
  // CRT scanlines across the tile.
  ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
  var s = 100.0; while s < 924 { ctx.fill(CGRect(x: 100, y: s, width: 824, height: 2)); s += 5 }
  ctx.restoreGState()
  ctx.addPath(tile); ctx.setStrokeColor(CGColor(srgbRed: 0.17, green: 1, blue: 0.53, alpha: 0.55)); ctx.setLineWidth(3); ctx.strokePath()
  save(ctx, out)
} else {
  // Animation sheet: three 256px frames side by side, transparent, crisp.
  let cell: CGFloat = 8, F = 3
  let ctx = CGContext(data: nil, width: G * 8 * F, height: G * 8, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.setShouldAntialias(false)
  for f in 0..<F { paint(ctx, outlined(frame(f)), ox: CGFloat(f * G * 8), oy: 0, cell: cell, glow: false) }
  save(ctx, out)
}
print("wrote \(out)")
