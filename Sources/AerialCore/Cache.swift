import Foundation

public struct CachedFile: Hashable, Sendable {
    public var id: String
    public var size: Int64
    public var modified: Date
}

/// The video cache is the macOS videos folder itself: macOS plays Aerials only from there, so
/// keeping copies elsewhere would only double the space. The disk is the source of truth;
/// nothing here needs an index that could go stale.
public enum CacheScanner {
    /// Every `<uuid>.mov` in the folder.
    public static func scan(_ folder: URL) -> [CachedFile] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "mov", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return CachedFile(id: url.deletingPathExtension().lastPathComponent,
                              size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast)
        }
    }
}

/// Which videos to delete to make room, by priority. Pure, so every rule is tested.
public struct CachePolicy: Sendable {
    public var softLimit: Int64
    public var hardLimit: Int64
    /// Never deleted: on screen, in the wallpaper store, pinned.
    public var protected: Set<String>
    /// When each clip is next needed.
    public var needs: [String: Date]
    public var lastShown: [String: Date]
    /// Only these can be deleted (known Aerials); anything else in the folder is counted but left alone.
    public var deletable: Set<String>

    public init(softLimit: Int64, hardLimit: Int64, protected: Set<String>, needs: [String: Date],
                lastShown: [String: Date], deletable: Set<String>) {
        self.softLimit = softLimit
        self.hardLimit = max(hardLimit, softLimit)
        self.protected = protected
        self.needs = needs
        self.lastShown = lastShown
        self.deletable = deletable
    }

    /// Deletion order: clips not needed at all, least recently shown first; then clips needed
    /// later than `before`, the latest first. Clips needed sooner are never given up.
    func candidates(_ files: [CachedFile], neededAfter before: Date?) -> [CachedFile] {
        let free = files.filter { deletable.contains($0.id) && !protected.contains($0.id) }
        let unneeded = free.filter { needs[$0.id] == nil }
            .sorted { (lastShown[$0.id] ?? $0.modified) < (lastShown[$1.id] ?? $1.modified) }
        guard let before else { return unneeded }
        let later = free.filter { needs[$0.id].map { $0 > before } ?? false }
            .sorted { needs[$0.id]! > needs[$1.id]! }
        return unneeded + later
    }

    public struct Admission: Equatable, Sendable {
        public var allowed: Bool
        public var evict: [String]
    }

    /// Whether a video of `size` bytes needed at `needed` may be downloaded, and what to delete
    /// once it's in. Within the soft limit if possible; up to the hard limit only when `urgent`.
    public func admit(size: Int64, needed: Date, urgent: Bool, files: [CachedFile]) -> Admission {
        let used = files.reduce(0) { $0 + $1.size }
        if used + size <= softLimit { return Admission(allowed: true, evict: []) }
        let order = candidates(files, neededAfter: needed)
        func fit(_ limit: Int64) -> [String]? {
            var total = used + size, evict: [String] = []
            if total <= limit { return [] }
            for file in order {
                total -= file.size
                evict.append(file.id)
                if total <= limit { return evict }
            }
            return nil
        }
        if let evict = fit(softLimit) { return Admission(allowed: true, evict: evict) }
        if urgent, let evict = fit(hardLimit) { return Admission(allowed: true, evict: evict) }
        return Admission(allowed: false, evict: [])
    }

    /// Back under the soft limit by deleting only clips nothing needs.
    public func tidy(_ files: [CachedFile]) -> [String] {
        var total = files.reduce(0) { $0 + $1.size }
        var evict: [String] = []
        for file in candidates(files, neededAfter: nil) where total > softLimit {
            total -= file.size
            evict.append(file.id)
        }
        return evict
    }
}

/// Download failures, so a broken video isn't retried in a loop.
public struct FailureLog: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var attempts: Int
        public var last: Date
    }

    public var entries: [String: Entry] = [:]

    public init() {}

    /// 5 → 15 minutes between attempts; from the third failure on, a day between attempts.
    public func canRetry(_ id: String, now: Date) -> Bool {
        guard let entry = entries[id] else { return true }
        let wait: TimeInterval = switch entry.attempts {
        case 0: 0
        case 1: 5 * 60
        case 2: 15 * 60
        default: 24 * 3600
        }
        return now.timeIntervalSince(entry.last) >= wait
    }

    public mutating func failed(_ id: String, now: Date) {
        var entry = entries[id] ?? Entry(attempts: 0, last: now)
        entry.attempts += 1
        entry.last = now
        entries[id] = entry
    }

    public mutating func succeeded(_ id: String) { entries[id] = nil }

    public static func load(from url: URL) -> FailureLog { readJSON(FailureLog.self, from: url) ?? FailureLog() }
    public func save(to url: URL) throws { try writeJSONAtomically(self, to: url) }
}
