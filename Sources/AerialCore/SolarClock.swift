import Foundation

/// The sun's height for a place, computed locally (NOAA solar position algorithm, accurate to
/// about a minute), and the part of the day it gives. No network, no location services.
public struct SolarClock: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = min(max(latitude, -89.9), 89.9)
        self.longitude = longitude
    }

    /// Sun elevation above the horizon in degrees (no refraction), and the hour angle
    /// (negative before solar noon).
    public func position(at date: Date) -> (elevation: Double, hourAngle: Double, declination: Double) {
        let jd = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (jd - 2_451_545) / 36_525
        let l0 = (280.46646 + t * (36_000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(rad(2 * m)) * (0.019993 - 0.000101 * t) + sin(rad(3 * m)) * 0.000289
        let omega = 125.04 - 1934.136 * t
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(rad(omega))
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let declination = deg(asin(sin(rad(eps)) * sin(rad(lambda))))
        let y = pow(tan(rad(eps / 2)), 2)
        let equationOfTime = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
            - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        let utcMinutes = (date.timeIntervalSince1970 / 60).truncatingRemainder(dividingBy: 1440)
        var trueSolar = (utcMinutes + equationOfTime + 4 * longitude).truncatingRemainder(dividingBy: 1440)
        if trueSolar < 0 { trueSolar += 1440 }
        let hourAngle = trueSolar / 4 - 180
        let cosZenith = sin(rad(latitude)) * sin(rad(declination)) + cos(rad(latitude)) * cos(rad(declination)) * cos(rad(hourAngle))
        let elevation = 90 - deg(acos(min(max(cosZenith, -1), 1)))
        return (elevation, hourAngle, declination)
    }

    public func elevation(at date: Date) -> Double { position(at: date).elevation }

    /// Above this the sun counts as day: 60 % of the day's highest point, kept within 6°…15°,
    /// so a winter day far north still has a "day" when the sun gets high enough at all.
    public func dayThreshold(declination: Double) -> Double {
        let noon = 90 - abs(latitude - declination)
        return min(max(noon * 0.6, 6), 15)
    }

    public static let nightBelow = -6.0
    public static let twilightBelow = 2.0

    public func phase(at date: Date) -> SkyPhase {
        let p = position(at: date)
        let rising = p.hourAngle < 0
        if p.elevation < Self.nightBelow { return .night }
        if p.elevation < Self.twilightBelow { return rising ? .dawn : .dusk }
        if p.elevation < dayThreshold(declination: p.declination) { return rising ? .morning : .golden }
        return .day
    }

    /// The moments the part of the day changes between `start` and `start + horizon`,
    /// to about 10 seconds.
    public func transitions(after start: Date, horizon: TimeInterval = 48 * 3600) -> [(date: Date, phase: SkyPhase)] {
        var result: [(Date, SkyPhase)] = []
        let step: TimeInterval = 120
        var previousDate = start
        var previous = phase(at: start)
        var t = start + step
        while t <= start + horizon {
            let current = phase(at: t)
            if current != previous {
                // Narrow down to the moment of change.
                var low = previousDate, high = t
                while high.timeIntervalSince(low) > 10 {
                    let mid = low + high.timeIntervalSince(low) / 2
                    if phase(at: mid) == previous { low = mid } else { high = mid }
                }
                result.append((high, phase(at: high)))
                previous = phase(at: high)
            }
            previousDate = t
            t += step
        }
        return result
    }

    /// When each part of the day next begins (within the horizon); missing when it doesn't
    /// occur, as with no night in a polar summer.
    public func nextStarts(after start: Date, horizon: TimeInterval = 48 * 3600) -> [SkyPhase: Date] {
        var starts: [SkyPhase: Date] = [:]
        for transition in transitions(after: start, horizon: horizon) where starts[transition.phase] == nil {
            starts[transition.phase] = transition.date
        }
        return starts
    }

    /// Sunrise/sunset-style crossing of `elevation` (degrees) after `start`, for tests and display.
    public func nextCrossing(of elevation: Double, rising: Bool, after start: Date) -> Date? {
        let step: TimeInterval = 300
        var t = start
        while t < start + 2 * 86_400 {
            let a = self.elevation(at: t), b = self.elevation(at: t + step)
            if rising ? (a < elevation && b >= elevation) : (a >= elevation && b < elevation) {
                var low = t, high = t + step
                while high.timeIntervalSince(low) > 5 {
                    let mid = low + high.timeIntervalSince(low) / 2
                    let value = self.elevation(at: mid)
                    if rising ? value < elevation : value >= elevation { low = mid } else { high = mid }
                }
                return high
            }
            t += step
        }
        return nil
    }
}

private func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
private func deg(_ radians: Double) -> Double { radians * 180 / .pi }
