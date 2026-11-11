import AerialCore
import SwiftUI

@main
struct AerialRotatorApp: App {
    // Plain `let`s: SwiftUI's macros (@State) aren't available with the Command Line Tools alone.
    private let model: AppModel
    private let settings: SettingsWindow
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        // Menu bar only, also when run outside an .app bundle (swift run).
        NSApplication.shared.setActivationPolicy(.accessory)
        model = AppModel()
        settings = SettingsWindow(model: model)
        if model.engine.config.pool.isEmpty {
            DispatchQueue.main.async { [settings] in settings.show() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.engine.phase.symbol)
        }
    }
}

/// Opening the app again while it runs shows Settings, so it can be reached even when
/// the menu bar icon is hidden behind the notch or by a menu bar manager.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .showSettings, object: nil)
        return false
    }
}

extension SkyPhase {
    var symbol: String {
        switch self {
        case .night: "moon.stars"
        case .dawn: "sunrise"
        case .morning: "sun.haze"
        case .day: "sun.max"
        case .golden: "sun.horizon"
        case .dusk: "sunset"
        }
    }

    var color: Color {
        switch self {
        case .night: Color(red: 0.17, green: 0.21, blue: 0.45)
        case .dawn: Color(red: 0.98, green: 0.69, blue: 0.47)
        case .morning: Color(red: 0.96, green: 0.79, blue: 0.42)
        case .day: Color(red: 0.36, green: 0.67, blue: 0.95)
        case .golden: Color(red: 0.95, green: 0.60, blue: 0.25)
        case .dusk: Color(red: 0.52, green: 0.40, blue: 0.75)
        }
    }
}

extension Tone {
    var symbol: String {
        switch self {
        case .night: "moon.stars"
        case .dawn: "sunrise"
        case .morning: "sun.haze"
        case .day, .bright: "sun.max"
        case .golden: "sun.horizon"
        case .dusk: "sunset"
        case .twilight: "cloud.sun"
        }
    }
}

extension PickReason {
    var title: String {
        switch self {
        case .direct: "suits the time"
        case .samePlace: "same place"
        case .nightWater: "night: underwater"
        case .nightEarth: "night: Earth"
        case .cityEarth: "night: Earth over the city"
        case .fallback: "best available"
        case .standIn: "stand-in"
        }
    }
}

/// Binary units (1 GB = 1024 MB), the same the cache limits are set in.
func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
}

func formatTime(_ date: Date) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return time }
    if calendar.isDateInTomorrow(date) { return "tomorrow \(time)" }
    return date.formatted(date: .abbreviated, time: .shortened)
}
