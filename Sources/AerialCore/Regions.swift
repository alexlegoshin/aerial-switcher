import Foundation

/// Which part of the world a place is in, to pair a landscape or a city that has no night
/// shot with an Earth flight over the same region. Keyed by the manifest subcategory's
/// English name; `Config.regions` overrides or extends it.
public enum Regions {
    public static let defaults: [String: String] = [
        // Earth flights
        "California to Vegas": "california",
        "New York Night": "newyork",
        "Ireland to Asia": "europe",
        "Italy to Asia": "southeurope",
        "Korea and Japan Night": "eastasia",
        "North America Aurora": "aurora",
        "Australia": "australia",
        "Antarctica": "antarctica",
        // Cities
        "New York": "newyork",
        "Los Angeles": "california",
        "San Francisco": "california",
        "London": "europe",
        "Hong Kong": "eastasia",
        "Dubai": "southeurope",
        // Landscapes
        "Sequoia": "california",
        "Redwoods": "california",
        "Sonoma": "california",
        "Tahoe": "california",
        "Golden Gate": "california",
        "Grand Canyon": "california",
        "Monument Valley": "california",
        "Iceland": "aurora",
        "Greenland": "aurora",
        "Goa": "eastasia",
        "Kerala": "eastasia",
        "Scotland": "europe",
        "Patagonia": "antarctica",
        // Underwater
        "California Dolphins": "california",
        "California Kelp Forest": "california",
    ]

    static func region(of clip: Clip, overrides: [String: String]) -> String? {
        overrides[clip.placeEnglish] ?? defaults[clip.placeEnglish]
    }
}
