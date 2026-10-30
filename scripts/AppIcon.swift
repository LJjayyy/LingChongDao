import AppKit
import Foundation
import ImageIO

private func fail(_ message: String) -> Never {
    fputs("AppIcon: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("usage: AppIcon.swift <boss-mouse.png> <preview.png> <iconset-directory>")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let previewURL = URL(fileURLWithPath: CommandLine.arguments[2])
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
guard let source = NSImage(contentsOf: sourceURL),
      let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fail("cannot read mascot image at \(sourceURL.path)")
}

let pixelWidth = cgSource.width
let pixelHeight = cgSource.height
guard let alphaData = cgSource.dataProvider?.data,
      let bytes = CFDataGetBytePtr(alphaData),
      let colorSpace = cgSource.colorSpace,
      let info = cgSource.bitmapInfo.rawValue as UInt32? else {
    fail("cannot inspect mascot alpha channel")
}
let bitsPerPixel = cgSource.bitsPerPixel
let bytesPerPixel = bitsPerPixel / 8
let bytesPerRow = cgSource.bytesPerRow
guard bytesPerPixel >= 4 else { fail("mascot image must have an alpha channel") }

let alphaInfo = cgSource.alphaInfo
let alphaOffset: Int
switch alphaInfo {
case .premultipliedFirst, .first: alphaOffset = 0
case .premultipliedLast, .last: alphaOffset = bytesPerPixel - 1
default: fail("mascot image has no usable alpha channel")
}

var minX = pixelWidth
var minY = pixelHeight
var maxX = -1
var maxY = -1
for y in 0..<pixelHeight {
    for x in 0..<pixelWidth {
        let alpha = bytes[y * bytesPerRow + x * bytesPerPixel + alphaOffset]
        if alpha > 8 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
}
guard maxX >= minX, maxY >= minY else { fail("mascot image is fully transparent") }

let padding = max(12, Int(Double(max(pixelWidth, pixelHeight)) * 0.012))
let cropX = max(0, minX - padding)
let cropY = max(0, minY - padding)
let cropRight = min(pixelWidth, maxX + padding + 1)
let cropBottom = min(pixelHeight, maxY + padding + 1)
guard let mascot = cgSource.cropping(to: CGRect(x: cropX, y: cropY, width: cropRight - cropX, height: cropBottom - cropY)) else {
    fail("cannot crop mascot alpha bounds")
}

func render(size: Int, writeTo url: URL, includeBackground: Bool) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fail("cannot allocate \(size)px image")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    if includeBackground {
        let inset = CGFloat(size) * 0.035
        let backing = canvas.insetBy(dx: inset, dy: inset)
        let radius = CGFloat(size) * 0.205
        let path = NSBezierPath(roundedRect: backing, xRadius: radius, yRadius: radius)
        NSColor(srgbRed: 0.965, green: 0.936, blue: 0.883, alpha: 1).setFill()
        path.fill()
        NSColor(srgbRed: 0.70, green: 0.58, blue: 0.43, alpha: 0.16).setStroke()
        path.lineWidth = CGFloat(size) * 0.008
        path.stroke()
    }

    // Keep the entire face, ears, and folded arms visible inside the standard icon safe area.
    let targetSide = CGFloat(size) * 0.855
    let aspect = CGFloat(mascot.width) / CGFloat(mascot.height)
    let drawSize: CGSize
    if aspect >= 1 {
        drawSize = CGSize(width: targetSide, height: targetSide / aspect)
    } else {
        drawSize = CGSize(width: targetSide * aspect, height: targetSide)
    }
    let destination = CGRect(
        x: (CGFloat(size) - drawSize.width) / 2,
        y: CGFloat(size) * 0.475 - drawSize.height / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    NSGraphicsContext.current?.cgContext.interpolationQuality = .high
    context.cgContext.draw(mascot, in: destination)

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { fail("cannot encode PNG") }
    try png.write(to: url, options: .atomic)
}

do {
    try FileManager.default.createDirectory(at: previewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    try render(size: 1024, writeTo: previewURL, includeBackground: true)

    let variants: [(String, Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    for (name, size) in variants {
        try render(size: size, writeTo: iconsetURL.appendingPathComponent(name), includeBackground: true)
    }
} catch {
    fail("\(error.localizedDescription)")
}
