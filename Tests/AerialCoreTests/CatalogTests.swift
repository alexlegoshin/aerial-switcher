import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AerialCore

@Suite struct CatalogTests {
    let catalog = try! Catalog.parse(Fixtures.manifest, strings: Fixtures.strings)

    @Test func readsEveryClipWithZoneAndPlace() throws {
        #expect(catalog.clips.count == 7)
        let sequoia = try #require(catalog["11111111-0000-0000-0000-000000000001"])
        #expect(sequoia.zone == .land && sequoia.placeEnglish == "Sequoia" && sequoia.tone == .night)
        #expect(catalog["11111111-0000-0000-0000-000000000003"]?.zone == .city)
        #expect(catalog["11111111-0000-0000-0000-000000000004"]?.zone == .earth)
        #expect(catalog["11111111-0000-0000-0000-000000000005"]?.zone == .water)
        #expect(catalog["11111111-0000-0000-0000-000000000006"]?.zone == .other)
    }

    @Test func prefersTheStringsTableOverRawShotNames() throws {
        let day = try #require(catalog["11111111-0000-0000-0000-000000000007"])
        #expect(day.english == "Sequoia Day" && day.tone == .day)
        let russian = try Catalog.parse(Fixtures.manifest, strings: Strings(Fixtures.strings.tables, preferredLanguages: ["ru"]))
        #expect(russian["11111111-0000-0000-0000-000000000007"]?.label == "Секвойя днём")
        #expect(russian["11111111-0000-0000-0000-000000000007"]?.english == "Sequoia Day")
    }

    @Test func enrichmentAddsRegionsAndMetrics() throws {
        let metrics = ["11111111-0000-0000-0000-000000000005": ImageMetrics(brightness: 43, saturation: 0.4, hues: Fixtures.hue(6))]
        let enriched = catalog.enriched(metrics: metrics, regionOverrides: ["London": "custom"])
        #expect(enriched["11111111-0000-0000-0000-000000000001"]?.region == "california")
        #expect(enriched["11111111-0000-0000-0000-000000000004"]?.region == "europe")
        #expect(enriched["11111111-0000-0000-0000-000000000003"]?.region == "custom")
        #expect(enriched["11111111-0000-0000-0000-000000000005"]?.tone == .night)
    }

    @Test(arguments: [("Sequoia Night", Tone.night), ("Sequoia Sunrise", .dawn), ("Tahoe Morning", .morning),
                      ("Tahoe Day", .day), ("London Evening", .golden), ("Los Angeles Sunset", .dusk)])
    func toneFromName(name: String, tone: Tone) {
        #expect(Tone.fromName(name) == tone)
    }

    @Test func toneFromBrightness() {
        #expect(Tone.fromBrightness(40) == .night)
        #expect(Tone.fromBrightness(70) == .twilight)
        #expect(Tone.fromBrightness(120) == .bright)
        // Unknown brightness never counts as night.
        #expect(Tone.fromBrightness(nil) == .bright)
    }

    @Test func badManifestThrows() {
        #expect(throws: AerialError.self) { try Catalog.parse(Data("[]".utf8)) }
        #expect(throws: AerialError.self) { try Catalog.load(from: URL(fileURLWithPath: "/nonexistent/entries.json")) }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: Paths.live.manifest.path)))
    func readsTheRealManifest() throws {
        let real = try Catalog.load(from: Paths.live.manifest, preferredLanguages: ["en"])
        #expect(real.clips.count > 100)
        #expect(Set(real.clips.map(\.zone)).isSuperset(of: [.land, .city, .water, .earth]))
        // Every default region names a place that exists (or a future one).
        let places = Set(real.clips.map(\.placeEnglish))
        #expect(places.contains("Sequoia") && places.contains("Ireland to Asia") && places.contains("London"))
    }
}

@Suite struct ImageMetricsTests {
    @Test func grayHasNoHues() {
        let metrics = ImageMetrics.measure(rgba: [UInt8](repeating: 128, count: 4 * 16), count: 16)
        #expect(abs(metrics.brightness - 128) < 0.6)
        #expect(metrics.hues.allSatisfy { $0 == 0 })
        #expect(metrics.saturation == 0)
    }

    @Test func pureColorsLandInTheirBin() {
        let red = ImageMetrics.measure(rgba: [255, 0, 0, 255], count: 1)
        let blue = ImageMetrics.measure(rgba: [0, 0, 255, 255], count: 1)
        #expect(red.hues[0] == 1 && blue.hues[8] == 1)
        #expect(abs(red.brightness - 76.2) < 0.5)
        #expect(red.similarity(to: red) > 0.99)
        #expect(red.similarity(to: blue) < 0.5)
    }

    @Test func measuresAnImageFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let metrics = try #require(ImageMetrics.measure(url))
        #expect(metrics.brightness < 20)
        #expect(metrics.hues[8] > 0.99)
        #expect(metrics.sourceSize != nil)
    }
}
