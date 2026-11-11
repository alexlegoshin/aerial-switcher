import Foundation

/// Major cities for the sun's position: only latitude and longitude matter (the clock shown
/// is the Mac's own time zone).
public struct City: Hashable, Sendable {
    public let name: String
    public let country: String
    public let latitude: Double
    public let longitude: Double
}

public enum Cities {
    public static let all: [City] = [
        // Russia
        City(name: "Moscow", country: "Russia", latitude: 55.7558, longitude: 37.6173),
        City(name: "Saint Petersburg", country: "Russia", latitude: 59.9343, longitude: 30.3351),
        // Samara's time zone (UTC+4) with Ulyanovsk's position, as the user lives by it.
        City(name: "Samara", country: "Russia", latitude: 54.3142, longitude: 48.4031),
        City(name: "Kazan", country: "Russia", latitude: 55.7963, longitude: 49.1088),
        City(name: "Nizhny Novgorod", country: "Russia", latitude: 56.2965, longitude: 43.9361),
        City(name: "Yekaterinburg", country: "Russia", latitude: 56.8389, longitude: 60.6057),
        City(name: "Novosibirsk", country: "Russia", latitude: 55.0084, longitude: 82.9357),
        City(name: "Krasnodar", country: "Russia", latitude: 45.0355, longitude: 38.9753),
        City(name: "Vladivostok", country: "Russia", latitude: 43.1155, longitude: 131.8855),
        // Europe
        City(name: "London", country: "United Kingdom", latitude: 51.5074, longitude: -0.1278),
        City(name: "Paris", country: "France", latitude: 48.8566, longitude: 2.3522),
        City(name: "Berlin", country: "Germany", latitude: 52.5200, longitude: 13.4050),
        City(name: "Madrid", country: "Spain", latitude: 40.4168, longitude: -3.7038),
        City(name: "Barcelona", country: "Spain", latitude: 41.3874, longitude: 2.1686),
        City(name: "Lisbon", country: "Portugal", latitude: 38.7223, longitude: -9.1393),
        City(name: "Rome", country: "Italy", latitude: 41.9028, longitude: 12.4964),
        City(name: "Milan", country: "Italy", latitude: 45.4642, longitude: 9.1900),
        City(name: "Amsterdam", country: "Netherlands", latitude: 52.3676, longitude: 4.9041),
        City(name: "Vienna", country: "Austria", latitude: 48.2082, longitude: 16.3738),
        City(name: "Zurich", country: "Switzerland", latitude: 47.3769, longitude: 8.5417),
        City(name: "Prague", country: "Czechia", latitude: 50.0755, longitude: 14.4378),
        City(name: "Warsaw", country: "Poland", latitude: 52.2297, longitude: 21.0122),
        City(name: "Stockholm", country: "Sweden", latitude: 59.3293, longitude: 18.0686),
        City(name: "Oslo", country: "Norway", latitude: 59.9139, longitude: 10.7522),
        City(name: "Helsinki", country: "Finland", latitude: 60.1699, longitude: 24.9384),
        City(name: "Copenhagen", country: "Denmark", latitude: 55.6761, longitude: 12.5683),
        City(name: "Reykjavik", country: "Iceland", latitude: 64.1466, longitude: -21.9426),
        City(name: "Athens", country: "Greece", latitude: 37.9838, longitude: 23.7275),
        City(name: "Istanbul", country: "Türkiye", latitude: 41.0082, longitude: 28.9784),
        City(name: "Minsk", country: "Belarus", latitude: 53.9006, longitude: 27.5590),
        City(name: "Kyiv", country: "Ukraine", latitude: 50.4501, longitude: 30.5234),
        City(name: "Riga", country: "Latvia", latitude: 56.9496, longitude: 24.1052),
        // Caucasus, Central Asia, Middle East
        City(name: "Tbilisi", country: "Georgia", latitude: 41.7151, longitude: 44.8271),
        City(name: "Yerevan", country: "Armenia", latitude: 40.1792, longitude: 44.4991),
        City(name: "Baku", country: "Azerbaijan", latitude: 40.4093, longitude: 49.8671),
        City(name: "Almaty", country: "Kazakhstan", latitude: 43.2220, longitude: 76.8512),
        City(name: "Astana", country: "Kazakhstan", latitude: 51.1694, longitude: 71.4491),
        City(name: "Tashkent", country: "Uzbekistan", latitude: 41.2995, longitude: 69.2401),
        City(name: "Dubai", country: "UAE", latitude: 25.2048, longitude: 55.2708),
        City(name: "Tel Aviv", country: "Israel", latitude: 32.0853, longitude: 34.7818),
        City(name: "Riyadh", country: "Saudi Arabia", latitude: 24.7136, longitude: 46.6753),
        City(name: "Tehran", country: "Iran", latitude: 35.6892, longitude: 51.3890),
        // Africa
        City(name: "Cairo", country: "Egypt", latitude: 30.0444, longitude: 31.2357),
        City(name: "Casablanca", country: "Morocco", latitude: 33.5731, longitude: -7.5898),
        City(name: "Lagos", country: "Nigeria", latitude: 6.5244, longitude: 3.3792),
        City(name: "Nairobi", country: "Kenya", latitude: -1.2921, longitude: 36.8219),
        City(name: "Johannesburg", country: "South Africa", latitude: -26.2041, longitude: 28.0473),
        City(name: "Cape Town", country: "South Africa", latitude: -33.9249, longitude: 18.4241),
        // Asia
        City(name: "Delhi", country: "India", latitude: 28.6139, longitude: 77.2090),
        City(name: "Mumbai", country: "India", latitude: 19.0760, longitude: 72.8777),
        City(name: "Bangalore", country: "India", latitude: 12.9716, longitude: 77.5946),
        City(name: "Goa", country: "India", latitude: 15.4909, longitude: 73.8278),
        City(name: "Bangkok", country: "Thailand", latitude: 13.7563, longitude: 100.5018),
        City(name: "Singapore", country: "Singapore", latitude: 1.3521, longitude: 103.8198),
        City(name: "Jakarta", country: "Indonesia", latitude: -6.2088, longitude: 106.8456),
        City(name: "Bali", country: "Indonesia", latitude: -8.6500, longitude: 115.2167),
        City(name: "Hong Kong", country: "China", latitude: 22.3193, longitude: 114.1694),
        City(name: "Shanghai", country: "China", latitude: 31.2304, longitude: 121.4737),
        City(name: "Beijing", country: "China", latitude: 39.9042, longitude: 116.4074),
        City(name: "Taipei", country: "Taiwan", latitude: 25.0330, longitude: 121.5654),
        City(name: "Seoul", country: "South Korea", latitude: 37.5665, longitude: 126.9780),
        City(name: "Tokyo", country: "Japan", latitude: 35.6762, longitude: 139.6503),
        City(name: "Manila", country: "Philippines", latitude: 14.5995, longitude: 120.9842),
        City(name: "Ulaanbaatar", country: "Mongolia", latitude: 47.8864, longitude: 106.9057),
        // Oceania
        City(name: "Sydney", country: "Australia", latitude: -33.8688, longitude: 151.2093),
        City(name: "Melbourne", country: "Australia", latitude: -37.8136, longitude: 144.9631),
        City(name: "Perth", country: "Australia", latitude: -31.9505, longitude: 115.8605),
        City(name: "Auckland", country: "New Zealand", latitude: -36.8485, longitude: 174.7633),
        City(name: "Honolulu", country: "USA", latitude: 21.3069, longitude: -157.8583),
        // Americas
        City(name: "Anchorage", country: "USA", latitude: 61.2181, longitude: -149.9003),
        City(name: "Vancouver", country: "Canada", latitude: 49.2827, longitude: -123.1207),
        City(name: "Seattle", country: "USA", latitude: 47.6062, longitude: -122.3321),
        City(name: "San Francisco", country: "USA", latitude: 37.7749, longitude: -122.4194),
        City(name: "Los Angeles", country: "USA", latitude: 34.0522, longitude: -118.2437),
        City(name: "Las Vegas", country: "USA", latitude: 36.1699, longitude: -115.1398),
        City(name: "Denver", country: "USA", latitude: 39.7392, longitude: -104.9903),
        City(name: "Chicago", country: "USA", latitude: 41.8781, longitude: -87.6298),
        City(name: "Toronto", country: "Canada", latitude: 43.6532, longitude: -79.3832),
        City(name: "Montreal", country: "Canada", latitude: 45.5019, longitude: -73.5674),
        City(name: "New York", country: "USA", latitude: 40.7128, longitude: -74.0060),
        City(name: "Miami", country: "USA", latitude: 25.7617, longitude: -80.1918),
        City(name: "Mexico City", country: "Mexico", latitude: 19.4326, longitude: -99.1332),
        City(name: "Havana", country: "Cuba", latitude: 23.1136, longitude: -82.3666),
        City(name: "Bogotá", country: "Colombia", latitude: 4.7110, longitude: -74.0721),
        City(name: "Lima", country: "Peru", latitude: -12.0464, longitude: -77.0428),
        City(name: "Santiago", country: "Chile", latitude: -33.4489, longitude: -70.6693),
        City(name: "Buenos Aires", country: "Argentina", latitude: -34.6037, longitude: -58.3816),
        City(name: "São Paulo", country: "Brazil", latitude: -23.5505, longitude: -46.6333),
        City(name: "Rio de Janeiro", country: "Brazil", latitude: -22.9068, longitude: -43.1729),
    ]

    /// Cities whose name or country contains `query` (ignoring case and accents), names that
    /// start with it first.
    public static func search(_ query: String, limit: Int = 8) -> [City] {
        let q = query.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !q.isEmpty else { return [] }
        func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let matches = all.filter { fold($0.name).contains(q) || fold($0.country).contains(q) }
        let ranked = matches.filter { fold($0.name).hasPrefix(q) } + matches.filter { !fold($0.name).hasPrefix(q) }
        return Array(ranked.prefix(limit))
    }
}
