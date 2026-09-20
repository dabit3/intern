import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
  NSColor(
    calibratedRed: CGFloat((hex >> 16) & 255) / 255,
    green: CGFloat((hex >> 8) & 255) / 255,
    blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func bitmap(width: Int, height: Int, scale: Int, draw: () -> Void) -> NSBitmapImageRep {
  let image = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  image.size = NSSize(width: width, height: height)
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
  draw()
  NSGraphicsContext.restoreGraphicsState()
  return image
}

func drawIcon() {
  let tile = NSBezierPath(
    roundedRect: NSRect(x: 96, y: 96, width: 832, height: 832), xRadius: 186, yRadius: 186)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = color(0x000000, alpha: 0.28)
  shadow.shadowBlurRadius = 26
  shadow.shadowOffset = NSSize(width: 0, height: -18)
  shadow.set()
  color(0x181818).setFill()
  tile.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: color(0x101010), ending: color(0x303030))!.draw(in: tile, angle: 90)
  color(0xFFFFFF, alpha: 0.14).setStroke()
  tile.lineWidth = 2
  tile.stroke()

  func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: 242 + x * 22, y: 784 - y * 22)
  }
  let bolt = NSBezierPath()
  bolt.move(to: point(13.6, 1.6))
  bolt.line(to: point(4.2, 13.2))
  bolt.curve(to: point(4.9, 14.6), controlPoint1: point(3.7, 13.8), controlPoint2: point(4.1, 14.6))
  bolt.line(to: point(10.7, 14.6))
  bolt.line(to: point(9.4, 21.8))
  bolt.curve(
    to: point(10.9, 22.5), controlPoint1: point(9.2, 22.7), controlPoint2: point(10.3, 23.2))
  bolt.line(to: point(20.3, 10.9))
  bolt.curve(
    to: point(19.6, 9.5), controlPoint1: point(20.8, 10.3), controlPoint2: point(20.4, 9.5))
  bolt.line(to: point(13.8, 9.5))
  bolt.line(to: point(15.1, 2.3))
  bolt.curve(to: point(13.6, 1.6), controlPoint1: point(15.3, 1.4), controlPoint2: point(14.2, 0.9))
  bolt.close()
  NSGradient(starting: color(0xE6E6E6), ending: color(0xFFFFFF))!.draw(in: bolt, angle: 90)
}

func text(
  _ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
  ink: UInt32 = 0x1D1D1F
) {
  (value as NSString).draw(
    at: NSPoint(x: x, y: y),
    withAttributes: [
      .font: NSFont.systemFont(ofSize: size, weight: weight),
      .foregroundColor: color(ink),
    ])
}

func drawBackground() {
  color(0xFBFBFA).setFill()
  NSRect(x: 0, y: 0, width: 660, height: 420).fill()
  text("Intern", x: 44, y: 338, size: 32, weight: .semibold)
  text("Drag Intern into Applications to install.", x: 44, y: 309, size: 15, ink: 0x6E6E73)

  let arrow = NSBezierPath()
  arrow.move(to: NSPoint(x: 303, y: 210))
  arrow.line(to: NSPoint(x: 357, y: 210))
  arrow.move(to: NSPoint(x: 348, y: 219))
  arrow.line(to: NSPoint(x: 357, y: 210))
  arrow.line(to: NSPoint(x: 348, y: 201))
  arrow.lineWidth = 2.5
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  color(0xA1A1A6).setStroke()
  arrow.stroke()

  color(0xE5E5E5).setFill()
  NSRect(x: 44, y: 92, width: 572, height: 1).fill()
  text("Open Intern, then press Option + Space.", x: 44, y: 59, size: 13, weight: .medium)
  text("macOS 14 or later  ·  Apple silicon and Intel", x: 44, y: 34, size: 12, ink: 0x6E6E73)
}

let manager = FileManager.default
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
try manager.createDirectory(at: output, withIntermediateDirectories: true)
let temporary = manager.temporaryDirectory.appendingPathComponent(
  "InternAssets-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("Intern.iconset")
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: temporary) }

for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let image = bitmap(width: size, height: size, scale: scale) {
      NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
      drawIcon()
    }
    let suffix = scale == 2 ? "@2x" : ""
    try image.representation(using: .png, properties: [:])!.write(
      to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
  "-c", "icns", iconset.path, "-o", output.appendingPathComponent("Intern.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 { exit(iconutil.terminationStatus) }

let backgrounds = [1, 2].map { bitmap(width: 660, height: 420, scale: $0, draw: drawBackground) }
try NSBitmapImageRep.representationOfImageReps(
  in: backgrounds, using: .tiff,
  properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])!
  .write(to: output.appendingPathComponent("dmg-background.tiff"))
try backgrounds[1].representation(using: .png, properties: [:])!.write(
  to: output.appendingPathComponent("dmg-background.png"))
print("Generated Intern.icns and DMG backgrounds in \(output.path)")
