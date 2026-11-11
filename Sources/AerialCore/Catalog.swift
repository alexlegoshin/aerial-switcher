import Foundation

/// A part of the day by the sun, in the order they follow each other. Wallpapers change only
/// when the part of the day changes.
public enum SkyPhase: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    /// Sun below −6° (after civil twilight).
    case night
    /// Sun rising, −6°…+2°.
    case dawn
    /// Sun rising, +2° up to the day threshold.
    case morning
    /// Sun above the day threshold (depends on how high the sun gets that day).
    case day
    /// Sun setting, from the day threshold down to +2°.
    case golden
    /// Sun setting, +2°…−6°.
    case dusk

    public var next: SkyPhase {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var title: String {
        switch self {
        case .night: "Night"
        case .dawn: "Dawn"
        case .morning: "Morning"
        case .day: "Day"
        case .golden: "Golden hour"
        case .dusk: "Dusk"
        }
    }
}

/// How a video looks: from the last word of its name when it has one ("Sequoia Night"),
/// otherwise from the brightness of its thumbnail.
public enum Tone: String, Codable, Sendable {
    case night, dawn, morning, day, golden, dusk
    /// No time word, brightness between night and day.
    case twilight
    /// No time word, bright.
    case bright

    static func fromName(_ english: String) -> Tone? {
        switch english.split(separator: " ").last?.lowercased() {
        case "night": .night
        case "sunrise": .dawn
        case "morning": .morning
        case "day": .day
        case "evening": .golden
        case "sunset": .dusk
        default: nil
        }
    }

    /// Thresholds on the 0–255 luminance scale of `ImageMetrics`.
    static let nightBelow = 55.0
    static let twilightBelow = 80.0

    static func fromBrightness(_ value: Double?) -> Tone {
        // Without a thumbnail nothing is known: treat as day, so it never lands in the night.
        guard let value else { return .bright }
        if value < nightBelow { return .night }
        if value < twilightBelow { return .twilight }
        return .bright
    }
}

public enum Zone: String, Codable, CaseIterable, Sendable {
    case land, city, water, earth, other

    init(categoryKey: String?) {
        switch categoryKey {
        case "AerialCategoryLandscapes": self = .land
        case "AerialCategoryCities": self = .city
        case "AerialCategoryUnderwater": self = .water
        case "AerialCategorySpace": self = .earth
        default: self = .other
        }
    }

    public var title: String {
        switch self {
        case .land: "Landscapes"
        case .city: "Cities"
        case .water: "Underwater"
        case .earth: "Earth"
        case .other: "Other"
        }
    }
}

/// One Aerial video from the manifest.
public struct Clip: Identifiable, Hashable, Sendable {
    public let id: String
    /// English name, used for matching (tone, regions).
    public let english: String
    /// Name in the user's language, for display.
    public let label: String
    /// Manifest subcategory: one place (Sonoma, London) or one Earth flight.
    public let placeID: String
    public let placeEnglish: String
    public let placeLabel: String
    public let zone: Zone
    public let videoURL: URL?
    public internal(set) var metrics: ImageMetrics?
    /// Region key for night fallbacks, see `Regions`.
    public internal(set) var region: String?

    public init(id: String, english: String, label: String? = nil, placeID: String, placeEnglish: String, placeLabel: String? = nil,
                zone: Zone, videoURL: URL? = nil, metrics: ImageMetrics? = nil, region: String? = nil) {
        self.id = id
        self.english = english
        self.label = label ?? english
        self.placeID = placeID
        self.placeEnglish = placeEnglish
        self.placeLabel = placeLabel ?? placeEnglish
        self.zone = zone
        self.videoURL = videoURL
        self.metrics = metrics
        self.region = region
    }

    public var nameTone: Tone? { Tone.fromName(english) }
    public var tone: Tone { nameTone ?? Tone.fromBrightness(metrics?.brightness) }
    public var brightness: Double? { metrics?.brightness }
}

/// Every Aerial in the manifest macOS keeps on disk.
public struct Catalog: Sendable {
    public let clips: [Clip]
    private let byID: [String: Clip]

    public init(clips: [Clip]) {
        self.clips = clips
        byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(id: String) -> Clip? { byID[id] }

    public func clips(_ ids: [String]) -> [Clip] { ids.compactMap { byID[$0] } }

    /// Reads the manifest and the names next to it. Names are in the first of
    /// `preferredLanguages` that macOS has them in.
    public static func load(from url: URL, preferredLanguages: [String] = Locale.preferredLanguages) throws -> Catalog {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AerialError("Couldn't read the Aerial manifest. Open System Settings › Wallpaper once so macOS downloads it.")
        }
        let strings = Strings(contentsOf: url.deletingLastPathComponent()
            .appendingPathComponent("TVIdleScreenStrings.bundle/Contents/Resources/Localizable.nocache.loctable"),
            preferredLanguages: preferredLanguages)
        return try parse(data, strings: strings)
    }

    public static func parse(_ data: Data, strings: Strings = Strings()) throws -> Catalog {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let assets = json["assets"] as? [[String: Any]]
        else {
            throw AerialError("The Aerial manifest has an unexpected format.")
        }

        var categoryKeys: [String: String] = [:]
        var subcategoryKeys: [String: String] = [:]
        for category in json["categories"] as? [[String: Any]] ?? [] {
            if let id = category["id"] as? String { categoryKeys[id] = category["localizedNameKey"] as? String }
            for subcategory in category["subcategories"] as? [[String: Any]] ?? [] {
                if let id = subcategory["id"] as? String, let key = subcategory["localizedNameKey"] as? String {
                    subcategoryKeys[id] = key
                }
            }
        }

        var clips: [Clip] = []
        for asset in assets {
            guard let id = asset["id"] as? String else { continue }
            // accessibilityLabel is sometimes a raw shot name; the strings table has the real one.
            let key = asset["localizedNameKey"] as? String
            guard let english = key.flatMap(strings.english) ?? asset["accessibilityLabel"] as? String else { continue }
            let placeID = (asset["subcategories"] as? [String])?.first ?? id
            let placeKey = subcategoryKeys[placeID]
            let placeEnglish = placeKey.flatMap(strings.english) ?? placeKey?.replacingOccurrences(of: "AerialSubcategory", with: "") ?? english
            let categoryID = (asset["categories"] as? [String])?.first
            clips.append(Clip(
                id: id,
                english: english,
                label: key.flatMap(strings.localized) ?? english,
                placeID: placeID,
                placeEnglish: placeEnglish,
                placeLabel: placeKey.flatMap(strings.localized) ?? placeEnglish,
                zone: Zone(categoryKey: categoryID.flatMap { categoryKeys[$0] }),
                videoURL: (asset["url-4K-SDR-240FPS"] as? String).flatMap(URL.init(string:))
            ))
        }
        return Catalog(clips: clips)
    }

    /// Adds measured brightness and colors and the region of each clip.
    public func enriched(metrics: [String: ImageMetrics], regionOverrides: [String: String] = [:]) -> Catalog {
        Catalog(clips: clips.map { clip in
            var clip = clip
            clip.metrics = metrics[clip.id] ?? clip.metrics
            clip.region = Regions.region(of: clip, overrides: regionOverrides)
            return clip
        })
    }
}

/// The Aerial names macOS shows, from the strings table that ships next to the manifest:
/// a plist of `[localization: [key: name]]`.
public struct Strings: Sendable {
    let tables: [String: [String: String]]
    let preferred: String?

    public init(_ tables: [String: [String: String]] = [:], preferredLanguages: [String] = Locale.preferredLanguages) {
        self.tables = tables
        preferred = Bundle.preferredLocalizations(from: Array(tables.keys), forPreferences: preferredLanguages).first
    }

    init(contentsOf url: URL, preferredLanguages: [String]) {
        let plist = (try? Data(contentsOf: url)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        // Tables can hold non-string entries (plural rules, metadata); keep only the names.
        let tables = (plist as? [String: Any] ?? [:]).compactMapValues { table in
            (table as? [String: Any])?.compactMapValues { $0 as? String }
        }
        self.init(tables, preferredLanguages: preferredLanguages)
    }

    func english(_ key: String) -> String? { tables["en"]?[key] }
    func localized(_ key: String) -> String? { preferred.flatMap { tables[$0]?[key] } ?? english(key) }
}
