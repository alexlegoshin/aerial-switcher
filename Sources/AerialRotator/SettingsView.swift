import AerialCore
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case pool, upcoming, general, about

    var title: String {
        switch self {
        case .pool: "Pool"
        case .upcoming: "Upcoming"
        case .general: "General"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .pool: "square.grid.3x2"
        case .upcoming: "clock"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// A classic preferences window: icon tabs on top.
struct SettingsView: View {
    let model: AppModel
    let onTabChange: (SettingsTab) -> Void
    let onSizeChange: (CGSize) -> Void
    @AppStorage("settingsTab") private var tab = SettingsTab.pool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { item in
                    TabButton(tab: item, isSelected: item == tab) {
                        withAnimation(.easeInOut(duration: 0.2)) { tab = item }
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 8)

            Group {
                switch tab {
                case .pool: PoolPane(model: model)
                case .upcoming: UpcomingPane(model: model)
                case .general: GeneralPane(model: model)
                case .about: AboutPane()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(width: 860)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { onSizeChange($0) }
        .onChange(of: tab, initial: true) { onTabChange(tab) }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.symbol).font(.system(size: 22)).frame(height: 26)
                Text(tab.title).font(.system(size: 12))
            }
            .frame(minWidth: 64)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

// MARK: - Pool

private struct PoolPane: View {
    let model: AppModel
    private var engine: Engine { model.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(engine.config.pool.count) in the pool · \(engine.config.pinned.count) pinned")
                    .font(.headline)
                Spacer()
                Toggle("Pool only", isOn: Binding(get: { model.poolOnly }, set: { model.poolOnly = $0 }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            Caption("Click a picture to add it to the pool or take it out. The pin keeps a video on disk at all times, so the wallpaper still follows the sun offline (keep one for night, one for day, one for dusk).")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach([Zone.land, .city, .water, .earth], id: \.self) { zone in
                        let clips = engine.catalog.clips
                            .filter { $0.zone == zone && (!model.poolOnly || model.inPool($0.id)) }
                            .sorted { ($0.placeEnglish, $0.english) < ($1.placeEnglish, $1.english) }
                        if !clips.isEmpty {
                            Section {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 10)], spacing: 10) {
                                    ForEach(clips) { clip in ClipCell(model: model, clip: clip) }
                                }
                            } header: {
                                ZoneHeader(model: model, zone: zone, count: clips.filter { model.inPool($0.id) }.count, total: clips.count)
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 560)
        }
        .onDisappear { model.thumbnails.purge() }
    }
}

private struct ZoneHeader: View {
    let model: AppModel
    let zone: Zone
    let count: Int
    let total: Int

    var body: some View {
        HStack {
            Text(zone.title).font(.title3.bold())
            Text("\(count) of \(total)").foregroundStyle(.secondary)
            Spacer()
            Button("All") { model.setZone(zone, inPool: true) }.controlSize(.small)
            Button("None") { model.setZone(zone, inPool: false) }.controlSize(.small)
        }
        .padding(.vertical, 4)
        .background(.background)
    }
}

private struct ClipCell: View {
    let model: AppModel
    let clip: Clip

    var body: some View {
        let selected = model.inPool(clip.id)
        let pinned = model.isPinned(clip.id)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = model.thumbnails.images[clip.id] {
                        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary).aspectRatio(16 / 9, contentMode: .fit)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(selected ? 1 : 0.35)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
                .onAppear { model.thumbnails.request(clip.id) }

                Button {
                    model.togglePinned(clip.id)
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .foregroundStyle(pinned ? .yellow : .white)
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(pinned ? "Pinned: always kept on disk" : "Pin: always keep on disk")
            }
            .contentShape(Rectangle())
            .onTapGesture { model.togglePool(clip.id) }

            HStack(spacing: 4) {
                Image(systemName: clip.tone.symbol).foregroundStyle(.secondary)
                Text(clip.label).lineLimit(1).truncationMode(.tail)
            }
            .font(.callout)
            HStack(spacing: 6) {
                if let brightness = clip.brightness { Text("☀︎ \(Int(brightness))") }
                if model.engine.isOnDisk(clip.id) { Image(systemName: "internaldrive").help("On disk") }
                if model.engine.rotation.shown?.clipID == clip.id { Image(systemName: "display").help("On screen") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Upcoming

private struct UpcomingPane: View {
    let model: AppModel
    private var engine: Engine { model.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Now").font(.headline)
                HStack {
                    PhaseBadge(phase: engine.phase)
                    if let shown = engine.shownClip, let state = engine.rotation.shown {
                        Text(shown.label)
                        Text("since \(formatTime(state.since))").foregroundStyle(.secondary)
                        if let intended = state.intended.flatMap({ engine.catalog[$0] }) {
                            Text("· standing in for \(intended.label)").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Nothing chosen yet").foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Next changes (\(engine.config.placeName))").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(engine.upcoming.enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(formatTime(item.date)).monospacedDigit()
                            PhaseBadge(phase: item.phase)
                            if let pick = item.pick, let clip = engine.catalog[pick.clipID] {
                                Text(clip.label)
                                Text(pick.reason.title).foregroundStyle(.secondary)
                                Text(model.status(of: clip.id) ?? "on disk ✓").foregroundStyle(.secondary)
                            } else {
                                Text("—").foregroundStyle(.secondary)
                                Text("picked after the one before is shown").foregroundStyle(.secondary)
                                Text("")
                            }
                        }
                    }
                }
                Caption("The wallpaper changes only when the part of the day changes. Waking up in the same part of the day keeps it, however long the Mac slept.")
            }

            CachePanel(model: model)
        }
    }
}

private struct PhaseBadge: View {
    let phase: SkyPhase
    var body: some View {
        Label(phase.title, systemImage: phase.symbol)
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(phase.color.opacity(0.25)))
    }
}

private struct CachePanel: View {
    let model: AppModel
    private var engine: Engine { model.engine }

    var body: some View {
        let used = engine.cacheBytes
        let soft = engine.config.softLimitBytes, hard = engine.config.hardLimitBytes
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Video cache").font(.headline)
                Spacer()
                Text(engine.networkBlock.map { "Downloads paused: \($0)" } ?? (engine.isDownloading ? "Downloading…" : "Downloads allowed"))
                    .foregroundStyle(.secondary)
                Button("Check Now") { engine.kickPrefetch(force: true) }.controlSize(.small)
            }
            ProgressView(value: Double(min(used, hard)), total: Double(hard))
            Text("\(formatBytes(used)) used · aims for \(formatBytes(soft)), never above \(formatBytes(hard))")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(engine.cacheFiles.sorted { $0.size > $1.size }, id: \.id) { file in
                        GridRow {
                            Text(engine.catalog[file.id]?.label ?? file.id).lineLimit(1)
                            Text(formatBytes(file.size)).monospacedDigit().foregroundStyle(.secondary)
                            Text(role(of: file.id)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 150)
        }
    }

    private func role(of id: String) -> String {
        var roles: [String] = []
        if engine.rotation.shown?.clipID == id { roles.append("on screen") }
        if engine.config.pinned.contains(id) { roles.append("pinned") }
        if let phase = engine.rotation.onDeck.first(where: { $0.value.clipID == id })?.key { roles.append("next \(phase.title.lowercased())") }
        if !engine.config.pool.contains(id) { roles.append("not in pool") }
        return roles.isEmpty ? "spare" : roles.joined(separator: ", ")
    }
}

// MARK: - General

private struct GeneralPane: View {
    let model: AppModel
    private var engine: Engine { model.engine }

    var body: some View {
        Form {
            LabeledContent("Wallpaper") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Switch Wallpaper", isOn: Binding(get: { engine.config.enabled }, set: { value in engine.update { $0.enabled = value } }))
                    Caption("When off, the wallpaper you had before is put back.")
                    Toggle("Pause", isOn: Binding(get: { engine.config.paused }, set: { value in engine.update { $0.paused = value } }))
                        .disabled(!engine.config.enabled)
                    Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
            }
            LabeledContent("Sun") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(engine.config.placeName).font(.headline)
                        Text(String(format: "%.4f, %.4f", engine.config.latitude, engine.config.longitude))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    TextField("Search a city…", text: Binding(get: { model.citySearch }, set: { model.citySearch = $0 }))
                        .frame(width: 260)
                    ForEach(Cities.search(model.citySearch), id: \.self) { city in
                        Button("\(city.name), \(city.country)") {
                            engine.update { $0.placeName = city.name; $0.latitude = city.latitude; $0.longitude = city.longitude }
                            model.citySearch = ""
                        }
                        .buttonStyle(.link)
                    }
                    HStack(spacing: 8) {
                        Text("Latitude")
                        TextField("Latitude", value: Binding(get: { engine.config.latitude }, set: { value in
                            guard (-90...90).contains(value), value != engine.config.latitude else { return }
                            engine.update { $0.latitude = value; $0.placeName = "Custom" }
                        }), format: .number.precision(.fractionLength(4)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 110)
                        Text("Longitude").padding(.leading, 8)
                        TextField("Longitude", value: Binding(get: { engine.config.longitude }, set: { value in
                            guard (-180...180).contains(value), value != engine.config.longitude else { return }
                            engine.update { $0.longitude = value; $0.placeName = "Custom" }
                        }), format: .number.precision(.fractionLength(4)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 110)
                    }
                    .fixedSize()
                    Caption("Sunrise and sunset are computed on the Mac; no location access needed.")
                }
            }
            LabeledContent("Cache") {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper("Aim for \(gigabytes(engine.config.cacheSoftLimitMB))", value: Binding(
                        get: { engine.config.cacheSoftLimitMB },
                        set: { value in engine.update { $0.cacheSoftLimitMB = value; $0.cacheHardLimitMB = max($0.cacheHardLimitMB, value) } }
                    ), in: 1024...30720, step: 512)
                    Stepper("Never above \(gigabytes(engine.config.cacheHardLimitMB))", value: Binding(
                        get: { engine.config.cacheHardLimitMB },
                        set: { value in engine.update { $0.cacheHardLimitMB = max(value, $0.cacheSoftLimitMB) } }
                    ), in: 1024...40960, step: 512)
                    Caption("Videos are 150 MB – 1.5 GB each. Going past the first number is allowed only for the next video due and the pinned ones. Downloads run on Wi-Fi or Ethernet only, never over a Personal Hotspot.")
                }
            }
            LabeledContent("Night") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Landscapes without a night shot:")
                        Text("underwater \(Int(waterShare * 100))% · Earth \(100 - Int(waterShare * 100))%").monospacedDigit()
                    }
                    Slider(value: Binding(get: { waterShare }, set: { value in
                        engine.update { $0.nightWaterWeight = value; $0.nightEarthWeight = 1 - value }
                    }), in: 0...1, step: 0.05)
                    .frame(width: 300)
                    HStack {
                        Text("Underwater counts as night up to brightness")
                        Text("\(Int(engine.config.nightWaterMaxBrightness))").monospacedDigit()
                    }
                    Slider(value: Binding(get: { engine.config.nightWaterMaxBrightness }, set: { value in
                        engine.update { $0.nightWaterMaxBrightness = value }
                    }), in: 40...120, step: 5)
                    .frame(width: 300)
                    HStack {
                        Text("Stay at the same place when it has a shot for the next part of the day:")
                        Text("\(Int(engine.config.continuity * 100))%").monospacedDigit()
                    }
                    Slider(value: Binding(get: { engine.config.continuity }, set: { value in
                        engine.update { $0.continuity = value }
                    }), in: 0...1, step: 0.1)
                    .frame(width: 300)
                }
            }
            if let error = engine.lastError ?? model.error {
                LabeledContent("Problem") { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.columns)
    }

    private var waterShare: Double {
        let total = engine.config.nightWaterWeight + engine.config.nightEarthWeight
        return total > 0 ? engine.config.nightWaterWeight / total : 0.5
    }

    private func gigabytes(_ mb: Int) -> String { String(format: "%.1f GB", Double(mb) / 1024) }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Aerial Rotator").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Aerial wallpapers from your own pool, changing with the sun.\nA fork of Aerial Switcher by YnNJU.")
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            HStack(spacing: 16) {
                Link("Aerial Rotator on GitHub", destination: URL(string: "https://github.com/alexlegoshin/aerial-switcher")!)
                Link("Original project", destination: URL(string: "https://github.com/YnNJU/aerial-switcher")!)
            }
            .padding(.top, 4)
            Button("Show Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Paths.live.logs.appendingPathComponent("rotator.log")])
            }
            .controlSize(.small)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
