// Draws Grove's app icon and writes Grove.icns.
//
//   swift scripts/make-icon.swift Grove/Resources
//
// The artwork is a tree that is also a git graph: one trunk splitting into
// branches, each tip a commit node. That is what a workspace is — several
// branches growing from one root.
import AppKit

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

// MARK: - Palette

let deepGreen = NSColor(srgbRed: 0.09, green: 0.36, blue: 0.27, alpha: 1)
let midGreen = NSColor(srgbRed: 0.15, green: 0.52, blue: 0.38, alpha: 1)
let cream = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.91, alpha: 1)

func drawIcon(size: CGFloat, into context: CGContext) {
  let scale = size / 1024

  func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * scale, y: y * scale) }
  func v(_ value: CGFloat) -> CGFloat { value * scale }

  // Rounded-square plate, inset so the icon has the margin macOS expects.
  let inset: CGFloat = 100
  let plate = CGRect(
    x: v(inset), y: v(inset), width: v(1024 - 2 * inset), height: v(1024 - 2 * inset))
  let plated = CGPath(
    roundedRect: plate, cornerWidth: v(185), cornerHeight: v(185), transform: nil)

  context.saveGState()
  context.addPath(plated)
  context.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [midGreen.cgColor, deepGreen.cgColor] as CFArray,
    locations: [0, 1]
  )!
  context.drawLinearGradient(
    gradient, start: p(0, 1024), end: p(0, 0), options: [])
  context.restoreGState()

  // Trunk and branches, drawn as one stroked path with round joins.
  context.saveGState()
  context.setStrokeColor(cream.cgColor)
  context.setLineWidth(v(58))
  context.setLineCap(.round)
  context.setLineJoin(.round)

  let fork = p(512, 500)
  let trunk = CGMutablePath()
  trunk.move(to: p(512, 250))
  trunk.addLine(to: fork)
  context.addPath(trunk)

  // Left branch, right branch, and the trunk carrying on upward.
  let left = CGMutablePath()
  left.move(to: fork)
  left.addCurve(to: p(300, 700), control1: p(512, 600), control2: p(300, 590))
  context.addPath(left)

  let right = CGMutablePath()
  right.move(to: fork)
  right.addCurve(to: p(724, 700), control1: p(512, 600), control2: p(724, 590))
  context.addPath(right)

  let centre = CGMutablePath()
  centre.move(to: fork)
  centre.addLine(to: p(512, 760))
  context.addPath(centre)

  context.strokePath()
  context.restoreGState()

  // Commit nodes: one root, three tips.
  context.setFillColor(cream.cgColor)
  for (point, radius) in [
    (p(512, 250), v(62)),
    (p(300, 700), v(74)),
    (p(512, 760), v(74)),
    (p(724, 700), v(74)),
  ] {
    context.fillEllipse(
      in: CGRect(
        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
  }

  // Hollow the tips so they read as commits rather than leaves — but only where
  // there is room. At 16pt the ring is under two pixels wide and turns the node
  // into mud, so those sizes keep solid dots.
  guard size >= 32 else { return }
  context.setStrokeColor(deepGreen.cgColor)
  context.setLineWidth(v(26))
  for point in [p(300, 700), p(512, 760), p(724, 700)] {
    let radius = v(34)
    context.strokeEllipse(
      in: CGRect(
        x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
  }
}

func render(size: CGFloat) -> NSBitmapImageRep {
  let pixels = Int(size)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  let ctx = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.current = ctx
  drawIcon(size: size, into: ctx.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

// MARK: - Write the iconset

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "Grove.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let entries: [(name: String, size: CGFloat)] = [
  ("icon_16x16", 16), ("icon_16x16@2x", 32),
  ("icon_32x32", 32), ("icon_32x32@2x", 64),
  ("icon_128x128", 128), ("icon_128x128@2x", 256),
  ("icon_256x256", 256), ("icon_256x256@2x", 512),
  ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for entry in entries {
  let rep = render(size: entry.size)
  let png = rep.representation(using: .png, properties: [:])!
  try png.write(to: iconset.appending(path: "\(entry.name).png"))
}

// A 1024 preview for the README. Kept out of the resources directory: every file
// in there is copied into the app, and a 180KB PNG nobody loads is dead weight.
if CommandLine.arguments.count > 2 {
  let preview = render(size: 1024)
  try preview.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
  "-c", "icns", iconset.path, "-o", "\(outputDirectory)/Grove.icns",
]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote \(outputDirectory)/Grove.icns" : "iconutil failed")
