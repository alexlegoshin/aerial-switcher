import Foundation
import Observation

/// Runs the rotation: notices when the part of the day changes, puts the right Aerial on
/// screen, keeps the next ones downloaded within the cache limits. Every step is safe to
/// repeat, and any error leaves the wallpaper as it is.
@MainActor @Observable
public final class Engine {
    public struct DownloadStatus: Equatable, Sendable {
        public var clipID: String
        public var received: Int64
        public var total: Int64?
    }

    public private(set) var config: Config
    public private(set) var catalog = Catalog(clips: [])
    public private(set) var rotation = RotationState()
    public private(set) var phase: SkyPhase = .day
    public private(set) var nextChange: (date: Date, phase: SkyPhase)?
    public private(set) var download: DownloadStatus?
    /// Why downloads are on hold, if they are.
    public private(set) var networkBlock: String?
    public private(set) var waitingFor: String?
    public private(set) var cacheFiles: [CachedFile] = []
    public private(set) var lastError: String?

    public let paths: Paths
    public let store: WallpaperStore
    private let downloader: Downloader
    private let reload: @Sendable () -> Void
    private let now: @Sendable () -> Date
    private let log: Log
    private let lowPowerMode: @Sendable () -> Bool
    private var network: NetworkSnapshot = .offline
    private var failures: FailureLog
    private var remoteSizes: [String: Int64] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var lastPrefetchKick = Date.distantPast

    public init(paths: Paths = .live,
                downloader: Downloader? = nil,
                reload: @escaping @Sendable () -> Void = WallpaperStore.reloadAgent,
                now: @escaping @Sendable () -> Date = { Date() },
                lowPowerMode: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
                log: Log = .shared) {
        self.paths = paths
        store = WallpaperStore(paths: paths)
        self.downloader = downloader ?? Downloader(paths: paths)
        self.reload = reload
        self.now = now
        self.lowPowerMode = lowPowerMode
        self.log = log
        config = Config.load(from: paths.config)
        var loaded = RotationState.load(from: paths.rotation)
        if loaded.rules != RotationState.currentRules {
            // Picks made under older rules are redone; what is on screen stays.
            loaded.onDeck = [:]
            loaded.rules = RotationState.currentRules
            try? loaded.save(to: paths.rotation)
        }
        rotation = loaded
        failures = FailureLog.load(from: paths.cacheState)
        try? config.save(to: paths.config)
        reloadCatalog()
    }

    // MARK: - Reading

    public var clock: SolarClock { SolarClock(latitude: config.latitude, longitude: config.longitude) }
    public var pool: [Clip] { catalog.clips(config.pool) }
    public var shownClip: Clip? { rotation.shown.flatMap { catalog[$0.clipID] } }
    public func isOnDisk(_ id: String) -> Bool { FileManager.default.fileExists(atPath: paths.video(id).path) }
    public var cacheBytes: Int64 { cacheFiles.reduce(0) { $0 + $1.size } }
    public func partialBytes(_ id: String) -> Int64 { downloader.partialSize(id) }

    /// What will show at each coming change of the part of the day.
    public var upcoming: [(date: Date, phase: SkyPhase, pick: Pick?)] {
        // One pick per part of the day: a second occurrence gets its own pick only after the
        // first one has been shown.
        var seen = Set<SkyPhase>()
        return clock.transitions(after: now(), horizon: 26 * 3600).map { transition in
            (transition.date, transition.phase, seen.insert(transition.phase).inserted ? rotation.onDeck[transition.phase] : nil)
        }
    }

    // MARK: - Changing settings

    public func update(_ change: (inout Config) -> Void) {
        let before = config
        change(&config)
        guard config != before else { return }
        do {
            try config.save(to: paths.config)
        } catch {
            fail("Couldn't save settings: \(error.localizedDescription)")
        }
        if config.enabled != before.enabled {
            if config.enabled {
                // Back on: take over again right away.
                rotation.shown = nil
            } else {
                do {
                    if try store.restoreBackup() { reload() }
                    log.info("Switching off, original wallpaper restored")
                } catch {
                    fail("Couldn't restore the original wallpaper: \(error.localizedDescription)")
                }
            }
        }
        if config.pool != before.pool || config.latitude != before.latitude || config.longitude != before.longitude
            || config.nightWaterWeight != before.nightWaterWeight || config.nightEarthWeight != before.nightEarthWeight {
            // Picks made under the old settings are redone; what is on screen stays.
            rotation.onDeck = [:]
        }
        if config.regions != before.regions { reloadCatalog() }
        tick()
        kickPrefetch(force: true)
    }

    /// Re-reads the manifest, e.g. after macOS updated it.
    public func reloadCatalog() {
        do {
            let parsed = try Catalog.load(from: paths.manifest)
            let metrics = MetricsStore.load(paths: paths, clips: parsed.clips)
            catalog = parsed.enriched(metrics: metrics, regionOverrides: config.regions)
        } catch {
            fail(error.localizedDescription)
        }
    }

    // MARK: - Switching

    /// Safe to call any time (timer, wake, login): changes the wallpaper only when the part of
    /// the day differs from the one the current wallpaper was chosen for.
    public func tick() {
        let date = now()
        let clock = clock
        phase = clock.phase(at: date)
        let starts = clock.nextStarts(after: date)
        nextChange = starts.min { $0.value < $1.value }.map { ($0.value, $0.key) }
        cacheFiles = CacheScanner.scan(paths.videos)
        guard config.enabled, !config.paused, !config.pool.isEmpty, !catalog.clips.isEmpty else { return }

        let rules = Rotation(catalog: catalog, config: config)
        var state = rotation
        // The video on screen vanished (deleted by hand or by macOS): choose again now.
        if let shown = state.shown, !isOnDisk(shown.clipID), (try? store.state()) == .aerial(assetID: shown.clipID) {
            log.error("Video on screen is gone: \(name(shown.clipID)); choosing another")
            state.shown = nil
        }
        let onDisk = Set(cacheFiles.map(\.id))
        rules.refill(&state, starts: starts, cached: onDisk)
        let decision = rules.decide(state, phase: phase, isOnDisk: { onDisk.contains($0) })

        switch decision {
        case .stay:
            waitingFor = nil
        case let .wait(target):
            if waitingFor != target { log.info("\(phase.title): waiting for \(target.map(name) ?? "nothing suitable") to download") }
            waitingFor = target
        case let .show(pick, phase, intended):
            waitingFor = intended
            do {
                if try store.state() != .aerial(assetID: pick.clipID) {
                    try store.setAerial(pick.clipID, now: date)
                    reload()
                }
                rules.apply(decision, to: &state, now: date)
                rules.refill(&state, starts: starts, cached: onDisk)
                log.info("\(phase.title): \(name(pick.clipID)) (\(pick.reason.rawValue))" + (intended.map { ", standing in for \(name($0))" } ?? ""))
                lastError = nil
                // The previous clip is no longer needed: room for the next ones.
                kickPrefetch(force: true)
            } catch {
                fail("Couldn't change the wallpaper: \(error.localizedDescription)")
            }
        }

        if state != rotation {
            rotation = state
            do { try rotation.save(to: paths.rotation) } catch { fail("Couldn't save state: \(error.localizedDescription)") }
        }
        tidyCache()
        if date.timeIntervalSince(lastPrefetchKick) > 30 * 60 { kickPrefetch() }
    }

    // MARK: - Network

    public func networkChanged(_ snapshot: NetworkSnapshot) {
        let wasBlocked = networkBlock
        network = snapshot
        networkBlock = NetworkPolicy.blockReason(snapshot, lowPowerMode: lowPowerMode())
        if networkBlock != wasBlocked { log.info("Network: \(networkBlock ?? "downloads allowed")") }
        if networkBlock != nil {
            // Stops at once; the part on disk is resumed later.
            prefetchTask?.cancel()
        } else if wasBlocked != nil {
            kickPrefetch(force: true)
        }
    }

    // MARK: - Cache

    private var protectedIDs: Set<String> {
        var ids = store.referencedAssetIDs().union(config.pinned)
        if let shown = rotation.shown { ids.insert(shown.clipID) }
        return ids
    }

    private func policy(needs: [String: Date]) -> CachePolicy {
        CachePolicy(softLimit: config.softLimitBytes, hardLimit: config.hardLimitBytes, protected: protectedIDs,
                    needs: needs, lastShown: rotation.lastShown, deletable: Set(catalog.clips.map(\.id)))
    }

    private var needs: [String: Date] {
        let date = now()
        let rules = Rotation(catalog: catalog, config: config)
        let list = rules.wanted(rotation, phase: phase, starts: clock.nextStarts(after: date), now: date)
        return Dictionary(list.map { ($0.clipID, $0.needed) }, uniquingKeysWith: min)
    }

    private func tidyCache() {
        let evict = policy(needs: needs).tidy(cacheFiles)
        guard !evict.isEmpty else { return }
        delete(evict, why: "over the cache limit, not needed")
    }

    private func delete(_ ids: [String], why: String) {
        for id in ids {
            // Never the one on screen, whatever the caller thought.
            guard id != rotation.shown?.clipID else { continue }
            do {
                try FileManager.default.removeItem(at: paths.video(id))
                log.info("Removed \(name(id)): \(why)")
            } catch {
                log.error("Couldn't remove \(name(id)): \(error.localizedDescription)")
            }
        }
        cacheFiles = CacheScanner.scan(paths.videos)
    }

    // MARK: - Downloading

    /// Starts downloading what is needed next, unless already doing so.
    public func kickPrefetch(force: Bool = false) {
        guard prefetchTask == nil else { return }
        guard force || now().timeIntervalSince(lastPrefetchKick) > 60 else { return }
        lastPrefetchKick = now()
        prefetchTask = Task(priority: .background) { [weak self] in
            await self?.prefetch()
            self?.prefetchTask = nil
        }
    }

    public var isDownloading: Bool { prefetchTask != nil }

    private func prefetch() async {
        guard config.enabled else { return }
        while !Task.isCancelled {
            networkBlock = NetworkPolicy.blockReason(network, lowPowerMode: lowPowerMode())
            let date = now()
            let rules = Rotation(catalog: catalog, config: config)
            let starts = clock.nextStarts(after: date)
            let wanted = rules.wanted(rotation, phase: phase, starts: starts, now: date)
            let nextTransition = starts.values.min() ?? date
            guard let item = wanted.first(where: { !isOnDisk($0.clipID) && failures.canRetry($0.clipID, now: date) && catalog[$0.clipID]?.videoURL != nil }),
                  let clip = catalog[item.clipID] else { return }

            // Past the soft limit only for what the next change needs, and the pinned ones.
            let urgent = item.needed <= nextTransition || config.pinned.contains(clip.id)
            if let reason = networkBlock {
                // Low Power Mode still lets the very next one through.
                guard reason == "Low Power Mode", item.needed <= nextTransition else { return }
            }

            let size: Int64
            if let known = remoteSizes[clip.id] {
                size = known
            } else if let fetched = await downloader.remoteSize(of: clip.videoURL!) {
                remoteSizes[clip.id] = fetched
                size = fetched
            } else {
                log.error("No size for \(clip.english); will retry")
                failures.failed(clip.id, now: date)
                try? failures.save(to: paths.cacheState)
                continue
            }
            let remaining = size - downloader.partialSize(clip.id)
            let free = (try? paths.appSupport.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
            guard free > remaining + 2_000_000_000 else {
                log.error("Not downloading \(clip.english): only \(free / 1_000_000) MB free on disk")
                return
            }
            cacheFiles = CacheScanner.scan(paths.videos)
            let currentNeeds = Dictionary(wanted.map { ($0.clipID, $0.needed) }, uniquingKeysWith: min)
            let admission = policy(needs: currentNeeds).admit(size: size, needed: item.needed, urgent: urgent, files: cacheFiles)
            guard admission.allowed else {
                // Full of things needed sooner; the next change of the part of the day frees room.
                return
            }

            let resumeFrom = downloader.partialSize(clip.id)
            log.info("Downloading \(clip.english) (\(size / 1_000_000) MB, needed \(item.needed.formatted(date: .abbreviated, time: .shortened)))"
                + (resumeFrom > 0 ? ", resuming from \(resumeFrom / 1_000_000) MB" : "")
                + (admission.evict.isEmpty ? "" : ", will make room: \(admission.evict.map(name).joined(separator: ", "))"))
            download = DownloadStatus(clipID: clip.id, received: downloader.partialSize(clip.id), total: size)
            do {
                try await downloader.download(id: clip.id, from: clip.videoURL) { [weak self] received, total in
                    Task { @MainActor [weak self] in
                        guard self?.download?.clipID == clip.id else { return }
                        self?.download?.received = received
                        self?.download?.total = total ?? size
                    }
                }
                failures.succeeded(clip.id)
                try? failures.save(to: paths.cacheState)
                download = nil
                log.info("Downloaded \(clip.english)")
                // Make room now that it's in: the same rule, with nothing more to add.
                cacheFiles = CacheScanner.scan(paths.videos)
                let after = policy(needs: currentNeeds).admit(size: 0, needed: item.needed, urgent: urgent, files: cacheFiles)
                delete(after.evict, why: "making room for \(clip.english)")
                tick()
            } catch is CancellationError {
                download = nil
                log.info("Download of \(clip.english) paused")
                return
            } catch {
                download = nil
                failures.failed(clip.id, now: now())
                try? failures.save(to: paths.cacheState)
                log.error("Download of \(clip.english) failed: \(error.localizedDescription)")
                if (error as? URLError)?.code == .notConnectedToInternet { return }
            }
        }
    }

    // MARK: - Helpers

    private func name(_ id: String) -> String { catalog[id]?.english ?? id }

    private func fail(_ message: String) {
        lastError = message
        log.error(message)
    }
}
