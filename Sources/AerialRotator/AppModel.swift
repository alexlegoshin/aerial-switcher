import AerialCore
import AppKit
import ImageIO
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
    let engine: Engine
    let thumbnails: Thumbnails
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    var poolOnly = false
    var citySearch = ""
    var error: String?

    @ObservationIgnored private var network: NetworkWatcher?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        // A background app: disk access at utility priority, so a 500 MB download never
        // competes with what the user is doing.
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_PROCESS, IOPOL_UTILITY)
        engine = Engine()
        thumbnails = Thumbnails(paths: engine.paths)
        network = NetworkWatcher { [weak self] snapshot in
            Task { @MainActor in self?.engine.networkChanged(snapshot) }
        }
        startClock()
        observeSystemEvents()
        engine.tick()
        engine.kickPrefetch(force: true)
        Log.shared.info("Started; pool \(engine.config.pool.count), pinned \(engine.config.pinned.count)")
    }

    // MARK: - Pool

    func inPool(_ id: String) -> Bool { engine.config.pool.contains(id) }
    func isPinned(_ id: String) -> Bool { engine.config.pinned.contains(id) }

    func togglePool(_ id: String) {
        engine.update { config in
            if let index = config.pool.firstIndex(of: id) {
                config.pool.remove(at: index)
                config.pinned.removeAll { $0 == id }
            } else {
                config.pool.append(id)
            }
        }
    }

    func togglePinned(_ id: String) {
        engine.update { config in
            if let index = config.pinned.firstIndex(of: id) {
                config.pinned.remove(at: index)
            } else {
                config.pinned.append(id)
                if !config.pool.contains(id) { config.pool.append(id) }
            }
        }
    }

    func setZone(_ zone: Zone, inPool: Bool) {
        let ids = engine.catalog.clips.filter { $0.zone == zone }.map(\.id)
        engine.update { config in
            if inPool {
                config.pool += ids.filter { !config.pool.contains($0) }
            } else {
                config.pool.removeAll { ids.contains($0) }
                config.pinned.removeAll { ids.contains($0) }
            }
        }
    }

    // MARK: - Settings

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// The reason a clip isn't on disk yet, or nil if it is.
    func status(of id: String) -> String? {
        if engine.isOnDisk(id) { return nil }
        if let download = engine.download, download.clipID == id {
            let percent = download.total.map { Int(Double(download.received) / Double(max($0, 1)) * 100) } ?? 0
            return "downloading \(percent)%"
        }
        if let block = engine.networkBlock { return "waiting: \(block)" }
        let partial = engine.partialBytes(id)
        return partial > 0 ? "queued (\(formatBytes(partial)) so far)" : "queued"
    }

    // MARK: - Timers and events

    private func startClock() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.engine.tick()
            }
        }
    }

    private func observeSystemEvents() {
        let events: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
            (.default, .NSSystemClockDidChange),
            (.default, .NSSystemTimeZoneDidChange),
            (.default, .NSProcessInfoPowerStateDidChange),
        ]
        for (center, name) in events {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.engine.tick()
                    self.engine.kickPrefetch(force: true)
                }
            })
        }
        // Manifest updated by macOS (System Settings › Wallpaper): new Aerials show up.
        observers.append(NotificationCenter.default.addObserver(forName: .reloadCatalog, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.reloadCatalog() }
        })
    }
}

extension Notification.Name {
    static let reloadCatalog = Notification.Name("reloadCatalog")
}

/// Thumbnails for the gallery, downsampled to 320 px and kept only while needed.
@MainActor @Observable
final class Thumbnails {
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private let paths: Paths

    init(paths: Paths) { self.paths = paths }

    func request(_ id: String) {
        guard images[id] == nil, !loading.contains(id) else { return }
        loading.insert(id)
        let url = paths.thumbnail(id)
        Task.detached(priority: .utility) {
            let image = Self.load(url)
            await MainActor.run {
                self.loading.remove(id)
                if let image { self.images[id] = image }
            }
        }
    }

    /// Frees memory when the gallery closes.
    func purge() { images = [:] }

    nonisolated static func load(_ url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
