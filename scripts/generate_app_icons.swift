import AppKit
import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)

let brandingDir = root.appendingPathComponent("assets/branding", isDirectory: true)
let androidResDir = root.appendingPathComponent("android/app/src/main/res", isDirectory: true)
let iosAppIconDir = root.appendingPathComponent(
  "ios/Runner/Assets.xcassets/AppIcon.appiconset",
  isDirectory: true
)
let iosLaunchDir = root.appendingPathComponent(
  "ios/Runner/Assets.xcassets/LaunchImage.imageset",
  isDirectory: true
)
let macosAppIconDir = root.appendingPathComponent(
  "macos/Runner/Assets.xcassets/AppIcon.appiconset",
  isDirectory: true
)
let webIconsDir = root.appendingPathComponent("web/icons", isDirectory: true)
let windowsIconURL = root.appendingPathComponent("windows/runner/resources/app_icon.ico")
let webFaviconURL = root.appendingPathComponent("web/favicon.png")

try fileManager.createDirectory(at: brandingDir, withIntermediateDirectories: true)
try fileManager.createDirectory(at: webIconsDir, withIntermediateDirectories: true)

let squareSource = brandingDir.appendingPathComponent("sputni_icon_square.png")
let roundSource = brandingDir.appendingPathComponent("sputni_icon_round.png")
let introLogo = brandingDir.appendingPathComponent("sputni_intro_logo.png")
let androidLaunchLogo = androidResDir
  .appendingPathComponent("drawable-nodpi", isDirectory: true)
  .appendingPathComponent("launch_logo.png")

struct IOSIconSpec {
  let fileName: String
  let points: CGFloat
  let scale: CGFloat
}

struct BitmapSize {
  let width: Int
  let height: Int
}

func ensureDirectory(_ url: URL) throws {
  try fileManager.createDirectory(
    at: url,
    withIntermediateDirectories: true
  )
}

func savePNG(_ image: NSImage, to url: URL) throws {
  guard
    let tiffData = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiffData),
    let pngData = rep.representation(using: .png, properties: [:])
  else {
    throw NSError(domain: "sputni.icon", code: 1)
  }
  try pngData.write(to: url)
}

func pngData(for image: NSImage) throws -> Data {
  guard
    let tiffData = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiffData),
    let pngData = rep.representation(using: .png, properties: [:])
  else {
    throw NSError(domain: "sputni.icon", code: 2)
  }
  return pngData
}

func resizedImage(_ image: NSImage, size: CGSize) -> NSImage {
  let nextImage = NSImage(size: size)
  nextImage.lockFocus()
  NSGraphicsContext.current?.imageInterpolation = .high
  image.draw(
    in: NSRect(origin: .zero, size: size),
    from: NSRect(origin: .zero, size: image.size),
    operation: .copy,
    fraction: 1.0
  )
  nextImage.unlockFocus()
  return nextImage
}

func roundedPath(rect: NSRect, radius: CGFloat) -> NSBezierPath {
  NSBezierPath(
    roundedRect: rect,
    xRadius: radius,
    yRadius: radius
  )
}

func drawBackground(in rect: NSRect, clipPath: NSBezierPath) {
  clipPath.addClip()

  let baseGradient = NSGradient(
    colors: [
      NSColor(calibratedRed: 0.02, green: 0.30, blue: 0.98, alpha: 1.0),
      NSColor(calibratedRed: 0.06, green: 0.60, blue: 1.0, alpha: 1.0),
      NSColor(calibratedRed: 0.34, green: 0.88, blue: 1.0, alpha: 1.0),
    ]
  )!
  baseGradient.draw(in: clipPath, angle: -36)

  let glowTop = NSBezierPath(
    ovalIn: NSRect(
      x: rect.minX - rect.width * 0.22,
      y: rect.maxY - rect.height * 0.50,
      width: rect.width * 0.94,
      height: rect.height * 0.94
    )
  )
  NSColor(calibratedRed: 0.95, green: 0.99, blue: 1.0, alpha: 0.28).setFill()
  glowTop.fill()

  let glowBottom = NSBezierPath(
    ovalIn: NSRect(
      x: rect.maxX - rect.width * 0.68,
      y: rect.minY - rect.height * 0.08,
      width: rect.width * 0.82,
      height: rect.height * 0.82
    )
  )
  NSColor(calibratedRed: 0.57, green: 0.93, blue: 1.0, alpha: 0.24).setFill()
  glowBottom.fill()

  let innerGlow = NSGradient(
    colors: [
      NSColor.white.withAlphaComponent(0.40),
      NSColor.white.withAlphaComponent(0.16),
      NSColor.clear,
    ]
  )!
  innerGlow.draw(
    in: roundedPath(
      rect: NSRect(
        x: rect.minX + rect.width * 0.08,
        y: rect.midY + rect.height * 0.08,
        width: rect.width * 0.84,
        height: rect.height * 0.34
      ),
      radius: rect.width * 0.18
    ),
    angle: 90
  )

  let haloRect = NSRect(
    x: rect.minX + rect.width * 0.11,
    y: rect.minY + rect.height * 0.14,
    width: rect.width * 0.78,
    height: rect.height * 0.78
  )
  let halo = NSBezierPath(ovalIn: haloRect)
  halo.lineWidth = rect.width * 0.024
  NSColor.white.withAlphaComponent(0.12).setStroke()
  halo.stroke()

  NSColor.white.withAlphaComponent(0.08).setStroke()
  clipPath.lineWidth = max(4, rect.width * 0.012)
  clipPath.stroke()
}

func normalizedPoint(in rect: NSRect, x: CGFloat, y: CGFloat) -> NSPoint {
  NSPoint(
    x: rect.minX + rect.width * x,
    y: rect.minY + rect.height * y
  )
}

func polygonPath(in rect: NSRect, points: [(CGFloat, CGFloat)]) -> NSBezierPath {
  let path = NSBezierPath()
  for (index, point) in points.enumerated() {
    let nextPoint = normalizedPoint(in: rect, x: point.0, y: point.1)
    if index == 0 {
      path.move(to: nextPoint)
    } else {
      path.line(to: nextPoint)
    }
  }
  path.close()
  return path
}

func drawMonogram(in rect: NSRect) {
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(calibratedRed: 0.00, green: 0.13, blue: 0.36, alpha: 0.24)
  shadow.shadowBlurRadius = rect.width * 0.05
  shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.02)
  shadow.set()

  let paragraphStyle = NSMutableParagraphStyle()
  paragraphStyle.alignment = .center

  let fontSize = rect.height * 0.78
  let letterRect = NSRect(
    x: rect.minX + rect.width * 0.06,
    y: rect.minY + rect.height * 0.10,
    width: rect.width * 0.70,
    height: rect.height * 0.78
  )
  let letterAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
    .foregroundColor: NSColor.white.withAlphaComponent(0.96),
    .paragraphStyle: paragraphStyle,
    .kern: -rect.width * 0.03,
  ]
  NSString(string: "S").draw(in: letterRect, withAttributes: letterAttributes)

  let dotRect = NSRect(
    x: rect.minX + rect.width * 0.67,
    y: rect.minY + rect.height * 0.16,
    width: rect.width * 0.10,
    height: rect.width * 0.10
  )
  NSColor.white.withAlphaComponent(0.96).setFill()
  let dotPath = NSBezierPath(ovalIn: dotRect)
  dotPath.fill()

  NSColor(calibratedRed: 0.77, green: 0.95, blue: 1.0, alpha: 0.38).setStroke()
  dotPath.lineWidth = rect.width * 0.008
  dotPath.stroke()
}

func drawGlyph(in rect: NSRect) {
  let scaleRect = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07)
  drawMonogram(in: scaleRect)
}

func makeFullIcon(size: CGFloat, circular: Bool) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()

  let canvas = NSRect(x: 0, y: 0, width: size, height: size)
  let clipPath = circular
    ? NSBezierPath(ovalIn: canvas)
    : roundedPath(rect: canvas, radius: size * 0.23)

  drawBackground(in: canvas, clipPath: clipPath)
  drawMonogram(in: canvas.insetBy(dx: size * 0.08, dy: size * 0.08))

  image.unlockFocus()
  return image
}

func makeLaunchImage(size: BitmapSize) -> NSImage {
  let image = NSImage(size: NSSize(width: size.width, height: size.height))
  image.lockFocus()

  let canvas = NSRect(x: 0, y: 0, width: size.width, height: size.height)
  NSColor(calibratedRed: 0.03, green: 0.10, blue: 0.22, alpha: 1.0).setFill()
  canvas.fill()

  let logoSide = min(canvas.width, canvas.height) * 0.42
  let icon = makeFullIcon(size: logoSide, circular: false)
  icon.draw(
    in: NSRect(
      x: canvas.midX - logoSide / 2,
      y: canvas.midY - logoSide / 2,
      width: logoSide,
      height: logoSide
    )
  )

  image.unlockFocus()
  return image
}

func saveICO(from image: NSImage, to url: URL) throws {
  let iconImage = resizedImage(image, size: CGSize(width: 256, height: 256))
  let imageData = try pngData(for: iconImage)

  var data = Data()

  func appendUInt16(_ value: UInt16) {
    var littleEndian = value.littleEndian
    data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
  }

  func appendUInt32(_ value: UInt32) {
    var littleEndian = value.littleEndian
    data.append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
  }

  appendUInt16(0)
  appendUInt16(1)
  appendUInt16(1)

  data.append(0)
  data.append(0)
  data.append(0)
  data.append(0)
  appendUInt16(1)
  appendUInt16(32)
  appendUInt32(UInt32(imageData.count))
  appendUInt32(22)
  data.append(imageData)

  try data.write(to: url)
}

func generateAndroidIcons(square: NSImage, round: NSImage) throws {
  let specs: [(directory: String, size: CGFloat)] = [
    ("mipmap-mdpi", 48),
    ("mipmap-hdpi", 72),
    ("mipmap-xhdpi", 96),
    ("mipmap-xxhdpi", 144),
    ("mipmap-xxxhdpi", 192),
  ]

  for spec in specs {
    let directory = androidResDir.appendingPathComponent(spec.directory, isDirectory: true)
    try ensureDirectory(directory)
    try savePNG(
      resizedImage(square, size: CGSize(width: spec.size, height: spec.size)),
      to: directory.appendingPathComponent("ic_launcher.png")
    )
    try savePNG(
      resizedImage(round, size: CGSize(width: spec.size, height: spec.size)),
      to: directory.appendingPathComponent("ic_launcher_round.png")
    )
  }

  try ensureDirectory(androidLaunchLogo.deletingLastPathComponent())
  try savePNG(
    resizedImage(square, size: CGSize(width: 220, height: 220)),
    to: androidLaunchLogo
  )
}

func generateIOSIcons(square: NSImage) throws {
  let specs = [
    IOSIconSpec(fileName: "Icon-App-20x20@1x.png", points: 20, scale: 1),
    IOSIconSpec(fileName: "Icon-App-20x20@2x.png", points: 20, scale: 2),
    IOSIconSpec(fileName: "Icon-App-20x20@3x.png", points: 20, scale: 3),
    IOSIconSpec(fileName: "Icon-App-29x29@1x.png", points: 29, scale: 1),
    IOSIconSpec(fileName: "Icon-App-29x29@2x.png", points: 29, scale: 2),
    IOSIconSpec(fileName: "Icon-App-29x29@3x.png", points: 29, scale: 3),
    IOSIconSpec(fileName: "Icon-App-40x40@1x.png", points: 40, scale: 1),
    IOSIconSpec(fileName: "Icon-App-40x40@2x.png", points: 40, scale: 2),
    IOSIconSpec(fileName: "Icon-App-40x40@3x.png", points: 40, scale: 3),
    IOSIconSpec(fileName: "Icon-App-60x60@2x.png", points: 60, scale: 2),
    IOSIconSpec(fileName: "Icon-App-60x60@3x.png", points: 60, scale: 3),
    IOSIconSpec(fileName: "Icon-App-76x76@1x.png", points: 76, scale: 1),
    IOSIconSpec(fileName: "Icon-App-76x76@2x.png", points: 76, scale: 2),
    IOSIconSpec(fileName: "Icon-App-83.5x83.5@2x.png", points: 83.5, scale: 2),
    IOSIconSpec(fileName: "Icon-App-1024x1024@1x.png", points: 1024, scale: 1),
  ]

  for spec in specs {
    let pixelSize = spec.points * spec.scale
    try savePNG(
      resizedImage(square, size: CGSize(width: pixelSize, height: pixelSize)),
      to: iosAppIconDir.appendingPathComponent(spec.fileName)
    )
  }
}

func generateIOSLaunchImages() throws {
  let specs: [(fileName: String, size: BitmapSize)] = [
    ("LaunchImage.png", BitmapSize(width: 168, height: 185)),
    ("LaunchImage@2x.png", BitmapSize(width: 336, height: 370)),
    ("LaunchImage@3x.png", BitmapSize(width: 504, height: 555)),
  ]

  for spec in specs {
    try savePNG(
      makeLaunchImage(size: spec.size),
      to: iosLaunchDir.appendingPathComponent(spec.fileName)
    )
  }
}

func generateMacOSIcons(square: NSImage) throws {
  let specs: [(fileName: String, size: CGFloat)] = [
    ("app_icon_16.png", 16),
    ("app_icon_32.png", 32),
    ("app_icon_64.png", 64),
    ("app_icon_128.png", 128),
    ("app_icon_256.png", 256),
    ("app_icon_512.png", 512),
    ("app_icon_1024.png", 1024),
  ]

  for spec in specs {
    try savePNG(
      resizedImage(square, size: CGSize(width: spec.size, height: spec.size)),
      to: macosAppIconDir.appendingPathComponent(spec.fileName)
    )
  }
}

func generateWebIcons(square: NSImage) throws {
  let specs: [(url: URL, size: CGFloat)] = [
    (webIconsDir.appendingPathComponent("Icon-192.png"), 192),
    (webIconsDir.appendingPathComponent("Icon-512.png"), 512),
    (webIconsDir.appendingPathComponent("Icon-maskable-192.png"), 192),
    (webIconsDir.appendingPathComponent("Icon-maskable-512.png"), 512),
    (webFaviconURL, 64),
  ]

  for spec in specs {
    try savePNG(
      resizedImage(square, size: CGSize(width: spec.size, height: spec.size)),
      to: spec.url
    )
  }
}

let squareIcon = makeFullIcon(size: 1024, circular: false)
let roundIcon = makeFullIcon(size: 1024, circular: true)
let introMark = resizedImage(squareIcon, size: CGSize(width: 512, height: 512))

try savePNG(squareIcon, to: squareSource)
try savePNG(roundIcon, to: roundSource)
try savePNG(introMark, to: introLogo)

try generateAndroidIcons(square: squareIcon, round: roundIcon)
try generateIOSIcons(square: squareIcon)
try generateIOSLaunchImages()
try generateMacOSIcons(square: squareIcon)
try generateWebIcons(square: squareIcon)
try saveICO(from: squareIcon, to: windowsIconURL)

print(squareSource.path)
print(roundSource.path)
print(introLogo.path)
