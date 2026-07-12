import Foundation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case ringsPercent
    case rings
    case text
    case bars

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ringsPercent: return "Rings + %"
        case .rings: return "Rings only"
        case .text: return "Text"
        case .bars: return "Bars"
        }
    }
}

/// User preferences, persisted in UserDefaults and applied live.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Fired after any change so the AppDelegate can redraw the status item
    /// and reschedule the refresh timer.
    var onChange: (() -> Void)?

    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle"); onChange?() }
    }
    @Published var showClaude: Bool {
        didSet { defaults.set(showClaude, forKey: "showClaude"); onChange?() }
    }
    @Published var showCodex: Bool {
        didSet { defaults.set(showCodex, forKey: "showCodex"); onChange?() }
    }
    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes"); onChange?() }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var hasCompletedWelcome: Bool {
        didSet { defaults.set(hasCompletedWelcome, forKey: "hasCompletedWelcome") }
    }

    /// Backed directly by SMAppService; only works from a real .app bundle,
    /// so failures (e.g. running via `swift run`) are swallowed.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Not fatal: leave the system state as-is; the toggle re-reads it.
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .ringsPercent
        showClaude = defaults.object(forKey: "showClaude") as? Bool ?? true
        showCodex = defaults.object(forKey: "showCodex") as? Bool ?? true
        refreshMinutes = {
            let m = defaults.integer(forKey: "refreshMinutes")
            return [2, 3, 5, 10].contains(m) ? m : 3
        }()
        notificationsEnabled = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        hasCompletedWelcome = defaults.bool(forKey: "hasCompletedWelcome")
    }
}
