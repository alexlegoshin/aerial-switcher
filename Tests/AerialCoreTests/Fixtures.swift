import Foundation
@testable import AerialCore

enum Fixtures {
    // MARK: - Clips

    static func clip(_ name: String, place: String, zone: Zone, brightness: Double?, hues: [Double]? = nil, region: String? = nil) -> Clip {
        let metrics = brightness.map {
            ImageMetrics(brightness: $0, saturation: 0.5, hues: hues ?? [1] + [Double](repeating: 0, count: ImageMetrics.hueBins - 1))
        }
        return Clip(id: name, english: name, placeID: place, placeEnglish: place, zone: zone,
                    videoURL: URL(string: "https://example.com/\(name.replacingOccurrences(of: " ", with: "-")).mov"),
                    metrics: metrics, region: region)
    }

    static func hue(_ bin: Int) -> [Double] {
        var hues = [Double](repeating: 0, count: ImageMetrics.hueBins)
        hues[bin] = 1
        return hues
    }

    /// A small pool shaped like the real one.
    static let sequoiaNight = clip("Sequoia Night", place: "Sequoia", zone: .land, brightness: 37, region: "california")
    static let sequoiaSunrise = clip("Sequoia Sunrise", place: "Sequoia", zone: .land, brightness: 55, region: "california")
    static let sequoiaMorning = clip("Sequoia Morning", place: "Sequoia", zone: .land, brightness: 79, region: "california")
    static let icelandLake = clip("Iceland Lake", place: "Iceland", zone: .land, brightness: 83, hues: hue(6), region: "aurora")
    static let sonomaClouds = clip("Sonoma Clouds", place: "Sonoma", zone: .land, brightness: 103, region: "california")
    static let sonomaHorizon = clip("Sonoma Horizon", place: "Sonoma", zone: .land, brightness: 70, region: "california")
    static let londonSkyline = clip("London Skyline", place: "London", zone: .city, brightness: 87, region: "europe")
    static let londonEvening = clip("London Evening", place: "London", zone: .city, brightness: 110, region: "europe")
    static let newYorkNight = clip("New York Night", place: "New York", zone: .city, brightness: 56, region: "newyork")
    static let newYorkSkyline = clip("New York Skyline", place: "New York", zone: .city, brightness: 116, region: "newyork")
    static let kelpDark = clip("Kelp Dark", place: "Kelp", zone: .water, brightness: 43, hues: hue(6))
    static let sealPod = clip("Seal Pod", place: "Seals", zone: .water, brightness: 66, hues: hue(1))
    static let whale = clip("Humpback Whale", place: "Humpback Whale", zone: .water, brightness: 120)
    static let europeNight = clip("Europe Night", place: "Ireland to Asia", zone: .earth, brightness: 24, region: "europe")
    static let california = clip("California", place: "California to Vegas", zone: .earth, brightness: 39, region: "california")
    static let aurora = clip("North America Aurora", place: "North America Aurora", zone: .earth, brightness: 34, region: "aurora")

    static let all: [Clip] = [sequoiaNight, sequoiaSunrise, sequoiaMorning, icelandLake, sonomaClouds, sonomaHorizon,
                              londonSkyline, londonEvening, newYorkNight, newYorkSkyline, kelpDark, sealPod, whale,
                              europeNight, california, aurora]

    static func config(pool: [Clip], _ change: (inout Config) -> Void = { _ in }) -> Config {
        var config = Config()
        config.pool = pool.map(\.id)
        config.seed = 42
        change(&config)
        return config
    }

    static func picker(_ pool: [Clip], _ change: (inout Config) -> Void = { _ in }) -> Picker {
        Picker(pool: pool, config: config(pool: pool, change))
    }

    // MARK: - Manifest

    static func asset(_ id: String, _ name: String, _ subcategory: String, _ category: String) -> [String: Any] {
        ["id": id, "accessibilityLabel": name, "localizedNameKey": "\(id)_NAME", "subcategories": [subcategory],
         "categories": [category], "url-4K-SDR-240FPS": "https://example.com/\(id).mov"]
    }

    static let manifest: Data = try! JSONSerialization.data(withJSONObject: [
        "assets": [
            asset("11111111-0000-0000-0000-000000000001", "Sequoia Night", "sub-sequoia", "cat-land"),
            asset("11111111-0000-0000-0000-000000000002", "Sequoia Morning", "sub-sequoia", "cat-land"),
            asset("11111111-0000-0000-0000-000000000003", "London Skyline", "sub-london", "cat-city"),
            asset("11111111-0000-0000-0000-000000000004", "Europe Night", "sub-europe", "cat-space"),
            asset("11111111-0000-0000-0000-000000000005", "Kelp Dark", "sub-kelp", "cat-water"),
            asset("11111111-0000-0000-0000-000000000006", "macOS", "sub-mac", "cat-mac"),
            asset("11111111-0000-0000-0000-000000000007", "SEQ_RAW_SHOT_DAY_V2", "sub-sequoia", "cat-land"),
        ],
        "categories": [
            ["id": "cat-land", "localizedNameKey": "AerialCategoryLandscapes",
             "subcategories": [["id": "sub-sequoia", "localizedNameKey": "AerialSubcategorySequoia"]]],
            ["id": "cat-city", "localizedNameKey": "AerialCategoryCities",
             "subcategories": [["id": "sub-london", "localizedNameKey": "AerialSubcategoryLondon"]]],
            ["id": "cat-water", "localizedNameKey": "AerialCategoryUnderwater",
             "subcategories": [["id": "sub-kelp", "localizedNameKey": "AerialSubcategoryKelp"]]],
            ["id": "cat-space", "localizedNameKey": "AerialCategorySpace",
             "subcategories": [["id": "sub-europe", "localizedNameKey": "AerialSubcategoryIrelandToAsia"]]],
            ["id": "cat-mac", "localizedNameKey": "AerialCategoryMac"],
        ],
    ])

    static let strings = Strings([
        "en": ["11111111-0000-0000-0000-000000000007_NAME": "Sequoia Day", "AerialSubcategorySequoia": "Sequoia",
               "AerialSubcategoryLondon": "London", "AerialSubcategoryIrelandToAsia": "Ireland to Asia"],
        "ru": ["11111111-0000-0000-0000-000000000007_NAME": "Секвойя днём", "AerialSubcategorySequoia": "Секвойя"],
    ], preferredLanguages: ["en"])

    // MARK: - Wallpaper store

    static func choice(provider: String, config: [String: Any]?) -> [String: Any] {
        let data = config.map { try! PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) } ?? Data()
        return ["Provider": provider, "Configuration": data, "Files": [Any]()]
    }

    static func aerialChoice(_ id: String = "OLD") -> [String: Any] { choice(provider: "com.apple.wallpaper.choice.aerials", config: ["assetID": id]) }
    static var aerialChoice: [String: Any] { aerialChoice() }
    static var imageChoice: [String: Any] { choice(provider: "com.apple.wallpaper.choice.image", config: ["type": "imageFile"]) }
    static var defaultChoice: [String: Any] { choice(provider: "default", config: nil) }

    static func store(_ choice: [String: Any]) -> [String: Any] {
        let scope: [String: Any] = [
            "Linked": ["Content": ["Choices": [choice], "Shuffle": "$null"], "LastSet": Date(timeIntervalSince1970: 0)],
            "Type": "linked",
        ]
        return ["AllSpacesAndDisplays": scope, "SystemDefault": scope, "Displays": [String: Any](), "Spaces": [String: Any]()]
    }

    /// A throwaway home folder with a wallpaper store in it.
    static func paths(store: [String: Any]) throws -> Paths {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aerial-tests-\(UUID().uuidString)")
        let paths = Paths(home: home)
        try FileManager.default.createDirectory(at: paths.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(store, to: paths)
        return paths
    }

    /// Replaces the store, as when the user picks a wallpaper in System Settings.
    static func write(_ store: [String: Any], to paths: Paths) throws {
        try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0).write(to: paths.store)
    }

    static func download(_ ids: [String], into paths: Paths, size: Int = 1) throws {
        try FileManager.default.createDirectory(at: paths.videos, withIntermediateDirectories: true)
        for id in ids {
            try Data(repeating: 1, count: size).write(to: paths.video(id))
        }
    }

    // MARK: - Time

    static let moscow = SolarClock(latitude: 55.7558, longitude: 37.6173)
    static let moscowZone = TimeZone(identifier: "Europe/Moscow")!

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, zone: TimeZone = moscowZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
