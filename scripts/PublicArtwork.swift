// Copyright (c) 2026 LJjayyy. MIT License; see the repository's LICENSE.
// Original geometric fallback artwork. No mascot, SF Symbol or external image input.
import AppKit
import Foundation

private func fail(_ message: String) -> Never {
    fputs("PublicArtwork: \(message)\n", stderr)
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: PublicArtwork <output-directory>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = output.appendingPathComponent("AppIcon.iconset", isDirectory: true)

func render(size: Int, template: Bool, to url: URL) throws {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fail("cannot allocate image")
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let side = CGFloat(size)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.setFill()
    canvas.fill()
    if !template {
        NSColor(srgbRed: 0.965, green: 0.936, blue: 0.883, alpha: 1).setFill()
        NSBezierPath(roundedRect: canvas.insetBy(dx: side * 0.035, dy: side * 0.035),
                     xRadius: side * 0.205, yRadius: side * 0.205).fill()
    }
    let pill = CGRect(x: side * 0.15, y: side * 0.36,
                      width: side * 0.70, height: side * 0.28)
    (template ? NSColor.black : NSColor(srgbRed: 0.16, green: 0.19, blue: 0.18, alpha: 1)).setFill()
    NSBezierPath(roundedRect: pill, xRadius: side * 0.14, yRadius: side * 0.14).fill()
    let colors: [NSColor] = [
        NSColor(srgbRed: 0.55, green: 0.75, blue: 0.64, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.79, blue: 0.54, alpha: 1),
        NSColor(srgbRed: 0.77, green: 0.84, blue: 0.88, alpha: 1)
    ]
    for (index, x) in [0.34, 0.50, 0.66].enumerated() {
        let dot = CGRect(x: side * (x - 0.035), y: side * 0.465,
                         width: side * 0.07, height: side * 0.07)
        if template {
            graphics.cgContext.setBlendMode(.clear)
            graphics.cgContext.fillEllipse(in: dot)
            graphics.cgContext.setBlendMode(.normal)
        } else {
            colors[index].setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fail("cannot encode PNG")
    }
    try png.write(to: url, options: .atomic)
}

do {
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    try render(size: 1024, template: false, to: output.appendingPathComponent("AppIcon-preview.png"))
    try render(size: 256, template: false, to: output.appendingPathComponent("plugin-icon.png"))
    try render(size: 128, template: true, to: output.appendingPathComponent("MenuBarIcon.png"))
    for (name, size) in [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ] {
        try render(size: size, template: false, to: iconset.appendingPathComponent(name))
    }
} catch {
    fail(error.localizedDescription)
}
