import CoreGraphics
import Foundation
import ImageIO

/// Brightness and colors of a video, measured on its thumbnail.
public struct ImageMetrics: Codable, Hashable, Sendable {
    /// Mean luminance (Rec. 601), 0–255.
    public var brightness: Double
    /// Mean HSV saturation, 0–1.
    public var saturation: Double
    /// Hue histogram, 12 bins of 30°, weighted by saturation × value, summing to 1
    /// (all zero for a gray image).
    public var hues: [Double]
    /// Size and modification date of the thumbnail measured, to notice when it changes.
    public var sourceSize: Int?
    public var sourceDate: Date?

    public static let hueBins = 12

    public init(brightness: Double, saturation: Double, hues: [Double], sourceSize: Int? = nil, sourceDate: Date? = nil) {
        self.brightness = brightness
        self.saturation = saturation
        self.hues = hues
        self.sourceSize = sourceSize
        self.sourceDate = sourceDate
    }

    /// 0…1: how alike two palettes are (histogram overlap, with brightness closeness mixed in).
    public func similarity(to other: ImageMetrics) -> Double {
        let overlap: Double
        if hues.reduce(0, +) == 0 || other.hues.reduce(0, +) == 0 {
            overlap = 0.5
        } else {
            overlap = zip(hues, other.hues).map { min($0, $1) }.reduce(0, +)
        }
        let light = 1 - min(abs(brightness - other.brightness) / 128, 1)
        return 0.7 * overlap + 0.3 * light
    }

    /// Average palette of several clips, for comparing a place with a candidate.
    static func average(_ items: [ImageMetrics]) -> ImageMetrics? {
        guard !items.isEmpty else { return nil }
        let n = Double(items.count)
        var hues = [Double](repeating: 0, count: hueBins)
        for item in items { for (i, h) in item.hues.enumerated() where i < hueBins { hues[i] += h / n } }
        return ImageMetrics(brightness: items.map(\.brightness).reduce(0, +) / n,
                            saturation: items.map(\.saturation).reduce(0, +) / n, hues: hues)
    }

    /// Measures an image file, downsampled to at most 64 px so memory stays tiny.
    public static func measure(_ url: URL) -> ImageMetrics? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: false,
            ] as CFDictionary)
        else { return nil }
        var metrics = measure(image)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        metrics?.sourceSize = attributes?[.size] as? Int
        metrics?.sourceDate = attributes?[.modificationDate] as? Date
        return metrics
    }

    static func measure(_ image: CGImage) -> ImageMetrics? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return measure(rgba: pixels, count: width * height)
    }

    static func measure(rgba pixels: [UInt8], count: Int) -> ImageMetrics {
        var luminance = 0.0, saturation = 0.0
        var hues = [Double](repeating: 0, count: hueBins)
        for i in 0..<count {
            let r = Double(pixels[i * 4]) / 255, g = Double(pixels[i * 4 + 1]) / 255, b = Double(pixels[i * 4 + 2]) / 255
            luminance += 0.299 * r + 0.587 * g + 0.114 * b
            let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
            let s = maxC > 0 ? delta / maxC : 0
            saturation += s
            guard delta > 0.02 else { continue }
            var hue: Double
            if maxC == r { hue = (g - b) / delta } else if maxC == g { hue = (b - r) / delta + 2 } else { hue = (r - g) / delta + 4 }
            hue = (hue * 60).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
            hues[min(Int(hue / 30), hueBins - 1)] += s * maxC
        }
        let total = hues.reduce(0, +)
        if total > 0 { hues = hues.map { $0 / total } }
        let n = Double(max(count, 1))
        return ImageMetrics(brightness: luminance / n * 255, saturation: saturation / n, hues: hues)
    }
}

/// Measured metrics for every clip, kept in `metrics.json` and only re-measured when a
/// thumbnail is new or changed.
public enum MetricsStore {
    public static func load(paths: Paths, clips: [Clip]) -> [String: ImageMetrics] {
        var stored = readJSON([String: ImageMetrics].self, from: paths.metrics) ?? [:]
        var changed = false
        for clip in clips {
            let url = paths.thumbnail(clip.id)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let size = attributes[.size] as? Int, date = attributes[.modificationDate] as? Date
            if let existing = stored[clip.id], existing.sourceSize == size, existing.sourceDate == date { continue }
            if let measured = ImageMetrics.measure(url) {
                stored[clip.id] = measured
                changed = true
            }
        }
        if changed { try? writeJSONAtomically(stored, to: paths.metrics) }
        return stored
    }
}
