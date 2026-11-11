import AerialCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel
    private var engine: Engine { model.engine }

    var body: some View {
        ForEach(statusLines, id: \.self) { Text($0) }
        Divider()
        Toggle("Switch Wallpaper", isOn: Binding(get: { engine.config.enabled }, set: { value in engine.update { $0.enabled = value } }))
            .disabled(engine.config.pool.isEmpty)
        Toggle("Pause", isOn: Binding(get: { engine.config.paused }, set: { value in engine.update { $0.paused = value } }))
            .disabled(engine.config.pool.isEmpty || !engine.config.enabled)
        Divider()
        Button("Settings…") {
            NotificationCenter.default.post(name: .showSettings, object: nil)
        }
        .keyboardShortcut(",")
        Button("Quit Aerial Rotator") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLines: [String] {
        if engine.config.pool.isEmpty { return ["Choose Aerials in Settings"] }
        var lines: [String] = []
        let shown = engine.shownClip.map { "\($0.label)" } ?? "—"
        lines.append("\(engine.phase.title) · \(shown)")

        if let error = engine.lastError ?? model.error {
            lines.append("⚠︎ \(error)")
        }
        if !engine.config.enabled {
            lines.append("Off · original wallpaper")
        } else if engine.config.paused {
            lines.append("Paused")
        } else if let next = engine.nextChange {
            let pick = engine.rotation.onDeck[next.phase].flatMap { engine.catalog[$0.clipID] }
            var line = "\(next.phase.title) at \(formatTime(next.date))"
            if let pick {
                line += " · \(pick.label)"
                if let status = model.status(of: pick.id) { line += " (\(status))" }
            }
            lines.append(line)
        }
        if let waiting = engine.waitingFor.flatMap({ engine.catalog[$0] }) {
            lines.append("Waiting for \(waiting.label)" + (model.status(of: waiting.id).map { " · \($0)" } ?? ""))
        }
        if let download = engine.download, let clip = engine.catalog[download.clipID], download.clipID != engine.nextChange.flatMap({ engine.rotation.onDeck[$0.phase]?.clipID }) {
            let percent = download.total.map { Int(Double(download.received) / Double(max($0, 1)) * 100) } ?? 0
            lines.append("Downloading \(clip.label) · \(percent)%")
        }
        return lines
    }
}
