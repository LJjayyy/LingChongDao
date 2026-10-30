import AppKit
import Foundation
import ImageIO
import IslandPets

struct DecodedPetAnimation: @unchecked Sendable {
    let frames: [NSImage]
    let durations: [TimeInterval]
    let estimatedBytes: Int
    var duration: TimeInterval { durations.reduce(0, +) }

    func frame(at time: TimeInterval) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        let total = duration
        guard frames.count > 1, total > 0, time.isFinite else { return frames.first }
        var cursor = max(0, time).truncatingRemainder(dividingBy: total)
        for (index, delay) in durations.enumerated() {
            if cursor < delay { return frames[min(index, frames.count - 1)] }
            cursor -= delay
        }
        return frames.last
    }
}

enum PetAnimationDecoder {
    enum Failure: Error { case invalidImage, invalidLayout }
    private static let thumbnailSize = 128

    static func decode(_ resource: PetAnimationResource, stillOnly: Bool) throws -> DecodedPetAnimation {
        if let layout = resource.spriteLayout { return try decodeSprite(resource.data, layout: layout, stillOnly: stillOnly) }
        let data = stillOnly ? (resource.stillData ?? resource.data) : resource.data
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.invalidImage }
        try validateDimensions(source)
        let count = stillOnly ? 1 : CGImageSourceGetCount(source)
        guard count > 0, count <= 240 else { throw Failure.invalidImage }
        var frames: [NSImage] = []
        var delays: [TimeInterval] = []
        var bytes = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                           kCGImageSourceCreateThumbnailWithTransform: true,
                                           kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
                                           kCGImageSourceShouldCacheImmediately: true]
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw Failure.invalidImage }
            frames.append(NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height)))
            delays.append(frameDelay(source, index: index))
            bytes += frame.bytesPerRow * frame.height
        }
        return DecodedPetAnimation(frames: frames, durations: delays, estimatedBytes: bytes)
    }

    private static func decodeSprite(_ data: Data, layout: PetSpriteLayout, stillOnly: Bool) throws -> DecodedPetAnimation {
        guard layout.columns > 0, layout.columns <= 32, layout.rows > 0, layout.rows <= 32,
              layout.row >= 0, layout.row < layout.rows, !layout.frameDurations.isEmpty,
              layout.frameDurations.count <= layout.columns,
              layout.frameDurations.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 30 }),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.invalidLayout }
        try validateDimensions(source)
        guard let sheet = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              sheet.width % layout.columns == 0, sheet.height % layout.rows == 0 else { throw Failure.invalidLayout }
        let width = sheet.width / layout.columns, height = sheet.height / layout.rows
        guard width > 0, height > 0 else { throw Failure.invalidLayout }
        let count = stillOnly ? 1 : layout.frameDurations.count
        var frames: [NSImage] = []; var bytes = 0
        for column in 0..<count {
            try Task.checkCancellation()
            guard let crop = sheet.cropping(to: CGRect(x: column * width, y: layout.row * height, width: width, height: height)),
                  let scaled = scaledCopy(crop) else { throw Failure.invalidImage }
            frames.append(NSImage(cgImage: scaled, size: NSSize(width: scaled.width, height: scaled.height)))
            bytes += scaled.bytesPerRow * scaled.height
        }
        return DecodedPetAnimation(frames: frames, durations: Array(layout.frameDurations.prefix(count)), estimatedBytes: bytes)
    }

    private static func scaledCopy(_ image: CGImage) -> CGImage? {
        let scale = min(1, Double(thumbnailSize) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func validateDimensions(_ source: CGImageSource) throws {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height <= 24_000_000 else { throw Failure.invalidImage }
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        for key in ["{WebP}", "{GIF}", "{PNG}"] {
            if let values = properties[key] as? [String: Any] {
                for name in ["UnclampedDelayTime", "DelayTime"] {
                    if let delay = values[name] as? Double, delay.isFinite, delay > 0 { return min(10, max(1.0 / 60, delay)) }
                }
            }
        }
        return 1.0 / 30
    }
}
