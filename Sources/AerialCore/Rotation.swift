import Foundation

/// What this app put on screen and for which part of the day.
public struct Shown: Codable, Hashable, Sendable {
    public var clipID: String
    public var phase: SkyPhase
    public var since: Date
    /// Set when `clipID` stands in for a clip that wasn't downloaded yet; once that one is on
    /// disk (still in the same part of the day) it takes over.
    public var intended: String?
}

/// Saved between launches in `state/rotation.json`; losing it only loses variety history.
public struct RotationState: Codable, Equatable, Sendable {
    public var shown: Shown?
    /// The clip picked in advance for the next time each part of the day begins; these are
    /// what gets downloaded ahead.
    public var onDeck: [SkyPhase: Pick] = [:]
    /// Recently shown clip IDs, newest first.
    public var history: [String] = []
    public var lastShown: [String: Date] = [:]

    public init() {}

    static let historyLimit = 40

    public static func load(from url: URL) -> RotationState { readJSON(RotationState.self, from: url) ?? RotationState() }
    public func save(to url: URL) throws { try writeJSONAtomically(self, to: url) }
}

public enum Decision: Equatable, Sendable {
    /// The part of the day hasn't changed since the wallpaper was chosen: leave it.
    case stay
    /// Show this clip for this part of the day.
    case show(Pick, phase: SkyPhase, intended: String?)
    /// Nothing suitable is on disk yet; keep what's showing and try again on the next tick.
    case wait(for: String?)
}

/// The rules of the rotation, as pure functions over `RotationState`. The wallpaper changes
/// only when the part of the day differs from the one it was chosen for: a Mac that sleeps
/// through a whole day and wakes in the same part of the day keeps its wallpaper.
public struct Rotation: Sendable {
    public let catalog: Catalog
    public let config: Config
    public let picker: Picker

    public init(catalog: Catalog, config: Config) {
        self.catalog = catalog
        self.config = config
        picker = Picker(pool: catalog.clips(config.pool), config: config)
    }

    var poolIDs: Set<String> { Set(config.pool) }

    public func decide(_ state: RotationState, phase: SkyPhase, isOnDisk: (String) -> Bool) -> Decision {
        if let shown = state.shown, shown.phase == phase {
            if let intended = shown.intended, poolIDs.contains(intended), isOnDisk(intended) {
                let reason = state.onDeck[phase].flatMap { $0.clipID == intended ? $0.reason : nil } ?? .direct
                return .show(Pick(clipID: intended, reason: reason), phase: phase, intended: nil)
            }
            return .stay
        }

        let target: Pick? = state.onDeck[phase].flatMap { poolIDs.contains($0.clipID) ? $0 : nil } ?? {
            var rng = RandomSource(mixing: config.seed, UInt64(phase.hashIndex), 0xA11)
            return picker.choose(for: phase, previous: state.shown.flatMap { catalog[$0.clipID] }, recent: state.history, rng: &rng)
        }()

        if let target, isOnDisk(target.clipID) {
            return .show(target, phase: phase, intended: nil)
        }
        if let standIn = standIn(for: phase, avoiding: state.history, isOnDisk: isOnDisk) {
            return .show(standIn, phase: phase, intended: target?.clipID)
        }
        return .wait(for: target?.clipID)
    }

    /// A downloaded pool clip that suits the part of the day: pinned ones first, then the best
    /// suited, then the least recently shown.
    func standIn(for phase: SkyPhase, avoiding history: [String], isOnDisk: (String) -> Bool) -> Pick? {
        let pinned = Set(config.pinned)
        let candidates = picker.pool
            .filter { isOnDisk($0.id) }
            .map { (clip: $0, score: picker.suitability(of: $0, for: phase)) }
            .filter { $0.score >= Picker.good }
        let best = candidates.max { a, b in
            func key(_ c: (clip: Clip, score: Double)) -> (Int, Double, Int) {
                (pinned.contains(c.clip.id) ? 1 : 0, c.score, -(history.firstIndex(of: c.clip.id) ?? Int.max / 2))
            }
            return key(a) < key(b)
        }
        return best.map { Pick(clipID: $0.clip.id, reason: .standIn) }
    }

    /// Records a change made on screen.
    public func apply(_ decision: Decision, to state: inout RotationState, now: Date) {
        guard case let .show(pick, phase, intended) = decision else { return }
        state.shown = Shown(clipID: pick.clipID, phase: phase, since: now, intended: intended)
        state.history.removeAll { $0 == pick.clipID }
        state.history.insert(pick.clipID, at: 0)
        state.history = Array(state.history.prefix(RotationState.historyLimit))
        state.lastShown[pick.clipID] = now
        // The pick for this part of the day is used up; a new one is chosen for next time.
        if intended == nil { state.onDeck[phase] = nil }
    }

    /// Drops picks that left the pool and picks a clip for every part of the day coming up,
    /// in the order they come, each continuing from the one before it.
    public func refill(_ state: inout RotationState, starts: [SkyPhase: Date], cached: Set<String> = []) {
        state.onDeck = state.onDeck.filter { poolIDs.contains($0.value.clipID) }
        let upcoming = starts.sorted { $0.value < $1.value }
        var previous = state.shown.flatMap { catalog[$0.clipID] }
        for (phase, date) in upcoming {
            if let existing = state.onDeck[phase] {
                previous = catalog[existing.clipID]
                continue
            }
            // Avoid what was shown recently and what is already lined up for other parts of the day.
            let lined = state.onDeck.values.map(\.clipID)
            var rng = RandomSource(mixing: config.seed, UInt64(phase.hashIndex), UInt64(max(date.timeIntervalSince1970, 0) / 60))
            if let pick = picker.choose(for: phase, previous: previous, recent: lined + state.history, cached: cached, rng: &rng) {
                state.onDeck[phase] = pick
                previous = catalog[pick.clipID]
            }
        }
    }

    /// What should be on disk, most urgent first, with when it's needed.
    public func wanted(_ state: RotationState, phase: SkyPhase, starts: [SkyPhase: Date], now: Date) -> [(clipID: String, needed: Date)] {
        var list: [(String, Date)] = []
        if let intended = state.shown?.intended { list.append((intended, now)) }
        if state.shown?.phase != phase, let pick = state.onDeck[phase] { list.append((pick.clipID, now)) }
        let soon = now + 6 * 3600
        let deck = starts.compactMap { phase, date in state.onDeck[phase].map { ($0.clipID, date) } }.sorted { $0.1 < $1.1 }
        list += deck.filter { $0.1 <= soon }
        // Pinned clips: after what's due within six hours, before the rest.
        list += config.pinned.filter { poolIDs.contains($0) || catalog[$0] != nil }.map { ($0, soon) }
        list += deck.filter { $0.1 > soon }
        var seen = Set<String>()
        return list.filter { seen.insert($0.0).inserted }.map { (clipID: $0.0, needed: $0.1) }
    }
}

extension SkyPhase {
    var hashIndex: Int { SkyPhase.allCases.firstIndex(of: self)! + 1 }
}
